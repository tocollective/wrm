# WRM.081632 audit

State of `main` on 2026-10-04 (commit `aee696d`, "floppy size limit, hdd
speed fix"; the `laix`, `mc` and `wfw` submodules have local commits that
the superproject doesn't record yet).

## Scope and method

Checked:

- the emulator: `source/`, `include/` (about 15k lines of C);
- the specifications: `docs/INSTRUCTIONS.md`, `docs/SPECIFICATION.md`,
  `README.md`;
- the web build: `web/shell.html`, `source/web.c`, `source/network_web.c`,
  `tools/netproxy.py`;
- tests and CI: `tests/`, `tests/run.py`, `.github/workflows/ci.yml`,
  `CMakeLists.txt`.

`laix/`, `mc/` and `wfw/` are separate repositories; only how they plug
into this one was checked (CI, submodule pointers).

Everything here comes from reading the code. Nothing was built or run
(see `AGENTS.md`), so the items marked *to verify* need a quick check on
a real build.

Earlier decisions stand and are not re-proposed: the 128MB RAM limit,
and the items rejected in stage 4 (widescreen modes, CD-ROM, NVRAM, SMP
beyond `HARTID`, a second NIC).

Priorities:

- **P0**: a realistic way to harm the host (its files, its data);
- **P1**: memory corruption in the host process, an escape from a
  sandbox the docs promise, or a bug that breaks a feature for good;
- **P2**: needed for everyday use, or a weaker security issue;
- **P3**: minor: polish, edge cases, cleanup.

---

## 0. Summary

The core is in very good shape. The CPU pipeline, the MMU, the soft-float
unit, the device register files and the NAT's packet parsers were read
line by line, and no correctness bugs turned up in them (see §1). The
problems are at the edges, where the emulator meets the host: the
monitor's TCP port, the shared folder, snapshot files and the web page.

| # | Finding | Priority | § |
|---|---------|----------|---|
| 1 | The monitor takes commands from any local process, including a web page through a cross-protocol HTTP request; `save PATH` then writes a file with attacker-chosen contents anywhere the user can write | **P0** | 2.1 |
| 2 | Shared folder: a dangling symbolic link in the folder lets `OPEN` with `CREATE` make and write a file outside it | **P1** | 2.2 |
| 3 | Snapshots are trusted without saying so: a crafted file writes out of bounds in the host process (TLB victim index, disk buffer position, video DMA address) and makes the floppy drive open any host file read-write | **P1** | 2.3 |
| 4 | Web build: a floppy image over 1.44MB inserted through the page is saved in IndexedDB, and every later visit dies on start (`--floppy` is fatal) | **P1** | 3.1 |
| 5 | DNS queries skip the network policy and start an unbounded number of host threads | P2 | 2.4 |
| 6 | Windowed mode has no frame pacing: no vsync and no callback rate (*to verify*) | P2 | 4.1 |
| 7 | A beeper that sounds costs a function call per clock tick (32M a second) | P2 | 4.2 |
| 8 | Web page: console output grows without bound (quadratic), the whole disk image is re-saved every 5s | P2 | 4.3 |
| 9 | No tests for snapshots, the monitor, symbolic links in the share, the floppy size limit; CI builds neither the web nor Windows | P2 | 5 |
| 10 | Smaller issues: `?netproxy=` from the URL, UDP flood loop, debugger stop after an interrupt, stray key-ups, a silent empty ROM, dead config fields | P3 | 2.5, 2.6, 3.2–3.5, 6 |

Suggested order: §2.1 → §2.2 → §2.3 → §3.1, then tests for all four (§5),
then the rest.

---

## 1. What was checked and holds up

These parts were read closely, looking for the usual bugs, and nothing
was found:

- **CPU pipeline** ([cpu.c](../source/cpu.c)): forwarding from EX/MEM and
  MEM/WB against the old latches, the load-use stall (including stores,
  branches and `FMADD`/`FMSUB`, which read `rd`), serialization of
  `MFCR`/`MTCR`/`IRET`, precise faults, interrupts taken before MEM (so a
  squashed store never writes), `SS` taken from the status at the start of
  the instruction, triggers checked after alignment and before the MMU,
  `LL`/`SC` with the reservation dropped on traps, `PTBR`, `TLBI` and any
  write that overlaps it, `MULH*` and the division corner cases.
- **MMU** ([mmu.c](../source/mmu.c)): the walk, the superpage alignment
  check, the A/D writeback, global entries, `TLBI` modes, and the lookup
  cache, which every change to the TLB clears.
- **Soft float** ([softfloat.c](../source/softfloat.c)): sticky bits stay
  below the rounding bit in every operation, tininess is detected before
  rounding, overflow follows the rounding mode, `FMA` cancels exactly,
  conversions saturate. It matches `INSTRUCTIONS.md`.
- **Device registers and guest-driven DMA**: the video engine's range
  checks (`surface_fits`, EXPAND's line buffer, which is at most 8200 bytes),
  the disk range and scatter-gather checks, the Ethernet rings (sizes
  capped, `% size` only with a size above zero), the audio card's loop
  math, the cursor base masked into VRAM.
- **NAT parsers** ([nat.c](../source/nat.c)): IP, TCP option, UDP, DHCP
  option and DNS label lengths are all checked against the frame;
  replies fit their buffers.
- **Network policy and proxy**: the default deny list
  ([netpolicy.c](../source/netpolicy.c)) covers `0.0.0.0/8`, loopback,
  private, CGNAT, link-local, multicast and reserved space;
  `tools/netproxy.py` checks token, `Origin` and address.
- **Disk images**: locking against a second emulator, `FLUSH` that really
  reaches the medium (`F_FULLFSYNC` on macOS).

---

## 2. Security

### 2.1 The monitor can be driven by a web page — P0

[monitor.c:13](../source/monitor.c#L13) listens on `127.0.0.1` with no
authentication, and [monitor.c:695](../source/monitor.c#L695) runs every
line that arrives as a command. Unknown lines are just answered with an
error, and the connection stays open.

A page in the user's browser can send one request:

```js
fetch("http://127.0.0.1:4040/", { method: "POST", mode: "no-cors",
      body: "\nwp 0x1000 0x0a6c7275\n...\nsave /Users/me/.zshrc\n" });
```

The request line and the headers fail as unknown commands; the body's
lines run. `wp` puts chosen bytes into guest RAM, and `save`
([monitor.c:547](../source/monitor.c#L547)) writes the whole snapshot,
RAM included in the clear, to any path the user can write. A shell
generally reports the lines of an rc file it can't parse and goes on
with the rest, so this can become code execution, not just a clobbered
file. Any local user on a shared machine can do the same with `nc`.

Chrome is starting to ask before a public page reaches localhost; Firefox
and Safari don't, and a page served from localhost (a dev server) is
never asked.

Fix, from the cheapest:

1. Drop the client at once on a line that looks like HTTP: a request line
   (`^[A-Z]+ \S+ HTTP/1`) or a header (`Host:`, `User-Agent:`, `Origin:`).
   Redis does this for the same reason.
2. Require a token: `--monitor` prints a random one, and the first line
   must be it. That also covers other local users.
3. Optionally, on POSIX, listen on a Unix socket with mode `0600`.

### 2.2 Shared folder: a dangling link leads out — P1

[share.c:287](../source/devices/share.c#L287) checks a path with
`realpath`. When the path doesn't exist yet, it checks the parent
directory instead ([share.c:297](../source/devices/share.c#L297)).
`realpath` also fails with `ENOENT` on a **dangling** symbolic link, so a
link in the folder that points at a missing file outside it passes as "to
be made inside". Then `open(host, O_CREAT | O_RDWR)`
([share.c:427](../source/devices/share.c#L427)) follows the link and
creates the target outside the folder.

The scenario: `--share ./project`, where `project/` holds an unpacked
archive or a git checkout with a link `notes -> ../../.ssh/authorized_keys`
that doesn't resolve yet. The guest opens `notes` with
`WRITE | CREATE` and writes its own key. The README promises that "a
symbolic link that leads out of it" is refused.

Fix:

- Pass `O_NOFOLLOW` to `open`. When `realpath` fails with `ENOENT`,
  `lstat` the path: if it is a link, return `SHARE_ERROR_OUTSIDE`.
- Better, walk the path one name at a time with
  `openat(dirfd, name, O_NOFOLLOW | ...)` from a descriptor of the root.
  Nothing is then resolved twice, so a host process can't swap a name
  between the check and the use either.
- Windows: `_fullpath` doesn't resolve junctions or symbolic links, so a
  junction in the folder leads out. The spec admits that links aren't
  checked there; check `FILE_ATTRIBUTE_REPARSE_POINT` on each name, or
  refuse reparse points.

Add the dangling-link case to `tests/share/` (`run.py` can make the link
in the fresh folder).

### 2.3 Snapshots are trusted input — P1

`snapshot_load` checks the magic, the version, the machine's makeup and
a checksum, but a checksum keeps out damage, not intent: anyone can
compute FNV-1a. Many loaded fields are then used as indices or addresses
without a check:

| Field | Where it is used | Effect |
|-------|------------------|--------|
| `mmu->next_victim` ([snapshot.c:142](../source/snapshot.c#L142)) | `mmu->tlb[mmu->next_victim]` ([mmu.c:142](../source/mmu.c#L142)) once the TLB is full | heap write a few KB past the TLB |
| `disk->position` ([snapshot.c:243](../source/snapshot.c#L243)) | `&disk->buffer[disk->position]` ([disk.c:307](../source/devices/disk.c#L307)) with `busy` set | heap read and write up to 4GB past the buffer |
| video `busy` + `command` + `dst_base`/`src_base` ([snapshot.c:326](../source/snapshot.c#L326)) | `videocard_vram_poke32(…, dst_base)` ([videocard.c:486](../source/devices/videocard.c#L486)): the range is only checked when a command starts | heap write up to 4GB past VRAM |
| video `mode` ([snapshot.c:306](../source/snapshot.c#L306)) | `videocard_depths[depth]` ([videocard.c:20](../source/devices/videocard.c#L20)), depth up to 7, array of 5 | out-of-bounds read |
| video `line_bit` ([snapshot.c:333](../source/snapshot.c#L333)) | `line_buffer[bit >> 3]` ([videocard.c:414](../source/devices/videocard.c#L414)) | out-of-bounds read |
| floppy path ([snapshot.c:212](../source/snapshot.c#L212)) | `disk_insert(disk, path)`: opened `r+b` if it can be | the guest reads and **writes** any host file of up to 1.44MB (`~/.ssh/id_ed25519`, a config file) |

Snapshots are files people pass around (bug reports, "here is where it
hangs"). Ctrl+Alt+L also loads `wrm081632.snap` from the current
directory, which may be a freshly cloned repository.

Fix:

- Validate every loaded index and every state that skips a check made at
  command start: `next_victim < MMU_TLB_SIZE`; disk `position < 512` and a
  multiple of 4, `wait < word_ticks`; video `mode` through
  `videocard_valid_mode`, and with `busy` set the DMA range again
  (`dst_base`/`src_base` + `count` within VRAM) and `line_bit <
  line_bytes * 8`. Better still, validate in one place after loading,
  through the same functions the registers use.
- Never open a host path that comes from a snapshot without the user
  saying so. Re-insert the floppy only if the path is the one given with
  `--floppy` (or dropped in this session); otherwise leave the drive empty
  and print the path. At the least, open it read-only.
- Say in the README that a snapshot is as trusted as an executable.

### 2.4 DNS skips the policy and spawns threads — P2

[nat.c:860](../source/nat.c#L860) answers every query to `10.0.2.3`
through the host's resolver before any policy check. With
`--net-deny 0.0.0.0/0` the guest still:

- reaches the outside through DNS: names it makes up go to the host's
  resolvers, a known exfiltration channel;
- learns names inside the host's network (`intranet.corp` resolves to a
  private address; connecting to it is refused, but the address is known).

Each lookup is a host thread ([network.c:354](../source/network.c#L354)).
At most 16 run per NAT, but `nat_reset` (every Ethernet card reset) leaves
the running ones behind, still running, and frees their slots. A guest
that resets the card in a loop while asking for names that take seconds
to fail piles up threads in the host process.

Fix: let DNS go through the policy as `10.0.2.3:53`, allowed by default,
so `--net-deny 10.0.2.3` (or a `--no-dns`) turns it off; count abandoned
lookups and refuse new ones above a cap.

### 2.5 `?netproxy=` comes from the page's URL — P3

[network_web.c:24](../source/network_web.c#L24) takes the proxy address
from the query string as is. A link to a hosted copy of the page with
`?netproxy=attacker.example:80` sends all the guest's TCP and DNS through
the attacker's proxy. Ask before using a proxy that isn't on `localhost`
or `127.0.0.1`.

### 2.6 A UDP flood holds up the main loop — P3

`nat_udp_receive` ([nat.c:960](../source/nat.c#L960)) reads until the
socket is empty. A forwarded port open to the network
(`--net-forward 0.0.0.0:…`) that gets datagrams faster than the loop reads
them keeps the emulator in that loop; the frames are dropped anyway once
the guest's queue of 64 is full. Read at most a fixed number per poll.

---

## 3. Bugs

### 3.1 Web: an oversized floppy breaks the page for good — P1

The floppy size limit is new (`aee696d`). The page writes the file to
IndexedDB first and then asks the emulator to insert it
([shell.html:215-218](../web/shell.html#L215)). The emulator refuses an
image over 2880 sectors, but the page says "Inserted" and keeps the file.
On the next visit `start()` passes `--floppy` for it
([shell.html:189](../web/shell.html#L189)), `disk_create` treats a failed
image as fatal ([disk.c:162](../source/devices/disk.c#L162)), and the page
dies on every load until the user finds *Forget saved disks*. A floppy
saved before the limit came in does the same.

Fix: have `web_floppy_insert` return whether it worked and delete the file
if it didn't. On start, a saved floppy that can't be attached should warn
and leave the drive empty, not stop the machine.

### 3.2 A debugger stop comes after an interrupt or a single-step trap — P3

After WB, `cpu_update` first takes an interrupt and only then lets the
debugger stop ([cpu.c:1502-1504](../source/cpu.c#L1502)). When a
watchpoint has matched (or a step has ended) and an interrupt is pending
on the same cycle, the machine stops at the first instruction of the
handler, not right after the access. A guest single-step trap
(`STATUS.SS`) does the same. The registers stay exact, but the stop is
reported somewhere else than the README describes. Check `watch_hit` and
the step target before `cpu_interrupt`, and before returning from a
step trap.

### 3.3 Ctrl+Alt+R/S/L: the guest gets a key-up without a key-down — P3

The key-down of R, S and L is kept from the guest
([application.c:369](../source/application.c#L369)), but the key-up goes
through to `keyboard_key`. Keep the release of a key whose press was
taken too (remember the scancode).

### 3.4 An empty or unreadable ROM halts silently with exit status 0 — P3

`rom_load` ([rom.c:38](../source/rom.c#L38)) ignores what `ftell` and
`fread` return. An empty file, or a path that is a directory, gives a
ROM of zeros. Word 0 is `HLT`, so headless mode exits with status 0, the
"success" of an `HLT`. Warn when the ROM is empty or a read fails.

### 3.5 The monitor can't show the VRAM window — P3

`x`/`xp` read through `bus.fetch` ([monitor.c:125](../source/monitor.c#L125)),
which refuses the VRAM window, so `xp 0xFC000000` prints `--------`. Read
the window directly (it has no side effects); keep refusing the I/O
region.

---

## 4. Performance

### 4.1 No frame pacing with a window — P2, *to verify*

In headless mode [main.c](../source/main.c) sets
`SDL_HINT_MAIN_CALLBACK_RATE`, and its comment assumes that a window waits
for vsync. But the renderer is made with no vsync
([display.c:32](../source/display.c#L32)), and SDL3 doesn't turn it on by
default. If the driver doesn't throttle `SDL_RenderPresent` itself, the
loop spins a core and presents thousands of frames a second. Check the
CPU use of an idle machine with a window; if it is high, call
`SDL_SetRenderVSync(renderer, 1)` and keep a callback rate as a fallback.

### 4.2 The beeper runs tick by tick while it sounds — P2

While the tone is on and a speaker is connected, `beeper_run` calls
`beeper_tick` for every clock tick ([beeper.c:93](../source/devices/beeper.c#L93)):
32 million calls a second, a large share of the time budget that the
title bar's percentage depends on, more so in the browser. A square wave
can be summed per output sample instead: from `phase` and `step`, count
how many of the ticks up to the next sample have the high level.

### 4.3 Web page — P2

- `output.textContent += text + "\n"` ([shell.html:257](../web/shell.html#L257))
  copies the whole log on every line: quadratic, and it never shrinks.
  Keep the last N KB and append text nodes.
- `persist` runs every 5s ([shell.html:123](../web/shell.html#L123)), and
  IDBFS stores a changed file whole: a guest that writes now and then
  makes the page re-save the entire disk image every 5s. Save on `FLUSH`
  (already done), on `visibilitychange` and on a longer timer.

### 4.4 Smaller — P3

- Drawing commands finish in zero machine time: one store to `COMMAND`
  can mean up to ~32M pixel operations, each through `surface_bit`, a
  64-bit multiply and a switch. It is bounded, but it is a host stall the
  guest doesn't pay for. Fast paths for 8/16/32 bpp with a whole-line loop
  would cut it; giving the engine a duration would make timing honest.
- Scanout converts every pixel through `videocard_peek` and a switch,
  ~47M calls a second at 1024×768. Use one loop per depth.
- The UART calls `fflush(stdout)` after every byte
  ([uart.c:61](../source/devices/uart.c#L61)). Flush at the end of a batch
  of ticks instead.

---

## 5. Tests and CI — P2

What has no test at all:

- **Snapshots**: save → load → identical state; a cut-short or damaged
  file is refused; the out-of-bounds fields of §2.3 are refused. A
  `--save-at TICK PATH` option, or a monitor script, would make this
  testable headless.
- **Monitor**: one scripted session (break, step, `x`, `w`), and the
  HTTP-looking input of §2.1 being refused.
- **Shared folder links**: a link inside, a link outside, a dangling link
  outside (§2.2). `run.py` already builds the folder.
- **Floppy size limit**: an image of 2881 sectors isn't attached.

Fuzzing: the guest controls three parsers in the host process, and CI
already builds with ASan and UBSan. Small libFuzzer harnesses would find
what reading misses:

- `nat_input` with random frames;
- `share_host_path` / `share_resolve` with random paths;
- `snapshot_load` with random files.

CI:

- No web build. The Emscripten build is the one that broke in §3.1;
  `emcmake cmake` plus a build is enough to catch compile errors.
- No Windows build, though `disk.c`, `share.c`, `network.c`, `rng.c` and
  `console.c` all have Windows branches that nothing compiles.
- `laix/` tests don't run in CI.
- The submodule pointers are behind the working copies (`git status` shows
  `laix`, `mc` and `wfw` modified): CI tests the recorded commits, not
  what runs locally. Commit the pointers together with the changes that
  need them.

---

## 6. Code and docs — P3

- `config_t` has fields that nothing reads: `make_dump`, `window_scale`,
  `step_mode` ([config.h:24-26](../include/config.h#L24)).
- Every `*_destroy` ends with `x = NULL;` on its own parameter, which does
  nothing; drop it or pass `x**`.
- `application_create` doesn't check its `calloc`.
- `--ram 010M` is octal (8M): `config_parse_number` uses base 0. Use base
  10 for sizes and keep `0x` only where hex makes sense.
- README: say that the monitor is for trusted local use (until §2.1 is
  fixed), that snapshots are trusted input (§2.3), and add the Windows
  caveat about links next to the shared folder's promise.

---

## 7. Plan

| Step | What | § |
|------|------|---|
| 1 | Monitor: drop HTTP-looking input, then a token | 2.1 |
| 2 | Shared folder: `O_NOFOLLOW` and an `lstat` check now, `openat` walk later; test with links | 2.2, 5 |
| 3 | Snapshot validation, floppy path not reopened; test with damaged files | 2.3, 5 |
| 4 | Web floppy: refuse and delete an image that can't be attached, start without it | 3.1 |
| 5 | CI: web and Windows build jobs, submodule pointers | 5 |
| 6 | DNS through the policy, lookup cap | 2.4 |
| 7 | Frame pacing, beeper, web page log and saving | 4 |
| 8 | Fuzz harnesses for the NAT, share paths, snapshots | 5 |
| 9 | The P3 items | 2.5, 2.6, 3.2–3.5, 4.4, 6 |
