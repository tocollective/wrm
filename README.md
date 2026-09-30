# WRM.081632

<img src="./images/cpu.png" width="256"/>

WRM.081632 – is a 32-bit, RISC based, little-endian CPU architecture.

```sh
dd if=/dev/zero of=firmware.rom  bs=1m  count=32
```

## Running

```sh
python3 tools/asm.py firmware/main.asm -o firmware.rom
bin/wrm081632 [--rom PATH] [--ram SIZE[,...]] [--clock HZ] [--hdd PATH]
              [--headless] [--trace[=PATH]] [--debug]
```

| Option             | Description                                              |
|--------------------|----------------------------------------------------------|
| `--rom PATH`       | firmware image, `firmware.rom` by default                |
| `--ram SIZE[,...]` | RAM in slots 0–3, mapped back to back from address 0: `1M`, `2M`, `4M`, `8M`, `16M` or `32M` each (`--ram 4M,4M`); `1M` by default |
| `--clock HZ`       | clock rate, with an optional `k`, `M` or `G` suffix; `48M` by default |
| `--hdd PATH`       | disk image for disk 0; a second `--hdd` attaches disk 1 (see [Booting from disk](#booting-from-disk)) |
| `--headless`       | no window (the video card still runs, but nothing is shown); the UART console still uses stdin and stdout |
| `--trace[=PATH]`   | log every instruction that reaches write-back to `PATH`, or to stderr (see [Debugging](#debugging)) |
| `--debug`          | dump the CPU state when the machine stops or the emulator quits |
| `-h, --help`       | show the options                                         |

The emulator quits when the guest powers the machine off through the
power controller (see [docs/SPECIFICATION.md](docs/SPECIFICATION.md#power-controller));
the exit code written there becomes the process exit status. In headless
mode it also quits when the CPU halts:

| Exit status | Reason                                                   |
|-------------|----------------------------------------------------------|
| guest's     | power off                                                |
| `0`         | `HLT` (headless only)                                    |
| `1`         | a fault the CPU couldn't handle (headless only, reported on stderr), or an emulator error |

With a window, a halted machine keeps the window open.

## Booting from disk

A disk image is a plain file of 512-byte sectors. The disk is written
back to the file, and a file the emulator can't write is attached
read-only.

The firmware boots from disk 0 when it holds a boot image. A boot image
starts with a small header and is loaded to `0x00010000`
([docs/SPECIFICATION.md](docs/SPECIFICATION.md#boot-protocol)). Assembled
at that address and padded to a whole sector, the assembler output is
itself a bootable disk image:

```sh
python3 tools/asm.py firmware/disk/hello.asm --base 0x10000 -o hdd0.img
bin/wrm081632 --hdd hdd0.img
```

Without a boot image, or without `--hdd`, the firmware runs its demos.
The calling conventions for code on the machine are in
[docs/ABI.md](docs/ABI.md).

## Debugging

**State dump.** When the CPU halts on a fault it couldn't handle, the
emulator prints its state on stderr; with `--debug` it does so whenever
the machine stops (`HLT`, power off) or the emulator quits. A halted CPU
keeps its pipeline, so `MEM/WB` holds the instruction that stopped it:

```
CPU: halted by a fault at 0xFE000044: load page fault (0x00400000)
  pc FE000044  cycles 1234  retired 1180  irq 0
  r0  00000000  r1  00400000  r2  00000000  r3  00000000
  ...
  status   00000010  EXL
  epc      FE000010
  ...
  ptbr     00010001  paging on
  MEM/WB  FE000044  00002144  lw r1, 0(r1)                  ! load page fault (0x00400000)
  EX/MEM  bubble
  ...
```

**Trace.** `--trace` writes a line for every instruction that reaches
write-back: the cycle, its address and word, the instruction, and what it
changes — a register (`r1 = 0x...`), memory (`[0x...] = 0x...`, as wide
as the store), a control register (`status = 0x...`) or the PC after
`IRET` — or the fault it raises (`! cause (BADADDR)`). A taken interrupt
gets a line of its own, at the address it returns to:

```
         5  FE000000  00101E30  lui r30, 0x00080              r30 = 0x00100000
        10  FE00000C  00082005  mtcr ivec, r1                 ivec = 0xFE0000D0
       812  FE000040  0200014A  sw r1, 128(r0)                [0x00000080] = 0x0000002A
      9031  FE000120  --------                                ! interrupt
```

Squashed instructions never reach write-back, so they aren't traced.
Tracing is slow (the host usually falls behind the clock rate, and the
machine just runs slower) and the log grows by about 80 bytes per
instruction, so it suits short test ROMs best.

**Disassembler.** `tools/disasm.py` prints a ROM image in the same
syntax as the trace; the output assembles back to the same bytes.
Words the assembler can't produce (data, reserved bits set) are shown as
`.word`, and runs of the same word are folded into `*` unless `--all`:

```sh
python3 tools/disasm.py firmware.rom [--base 0xFE000000] [--start ADDR] [-n WORDS]
```

## Tests

```sh
python3 tests/run.py [--emulator PATH] [tests/isa/alu.asm ...]
ctest --test-dir build --output-on-failure
```

Each `tests/<group>/<name>.asm` is a test ROM: `tests/run.py` assembles it
and runs it with `--headless` (by default with `bin/wrm081632`); CTest
runs every ROM through it as a test of its own.

| Group      | What                                                        |
|------------|-------------------------------------------------------------|
| `isa`      | every instruction, control registers, exceptions, user mode |
| `pipeline` | forwarding and stalls, cycle timing, precise faults and interrupts |
| `mmu`      | pages and superpages, permissions, TLB invalidation, `U`    |
| `disk`     | the disk controller, booting from disk                      |
| `video`    | the video card: modes, palette, drawing engine, DMA, VBLANK |

A test includes `tests/common/harness.asm` and defines `test_main`. It
sets `r28` to the number of each check and ends with `j pass`, or
branches to `fail`, which prints the check number and `r1`–`r4` and
powers off with the check number as the exit code. A test passes only
if it powers off with `0` after printing `PASS`.

Comment lines in a test set up the machine it runs on:

| Line              | Effect                                                  |
|-------------------|---------------------------------------------------------|
| `; @hdd N`        | attach a disk of `N` sectors; the word at byte offset `o` of sector `s` is `s << 16 \| o / 4` |
| `; @hdd FILE.asm` | attach a boot image assembled from `FILE.asm` (relative to the test) at `0x00010000` |
| `; @args ARGS`    | more emulator options, e.g. `--ram 4M,2M`               |

Each `@hdd` attaches the next disk, 0 and then 1.

## Web (Emscripten)

```sh
emcmake cmake -S . -B build-web
cmake --build build-web
emrun bin/wrm081632.html
```

The firmware is packed into the build from `bin/firmware.rom`
(override with `-DWRM081632_WEB_FIRMWARE=path`). The UART console has
no input in the browser; its output goes to the page and the JS console.

# Useful links

[Pentium](https://en.wikipedia.org/wiki/Pentium_(original))
[xremu](https://github.com/xrarch/xremu/)
[fox32](https://codeberg.org/fox32-arch/fox32/)
[fox32 hardware reference](https://host12prog.github.io/fox32hw-reference/)
[Aphelion ISA](https://codeberg.org/orbitsystems/aphelion/src/branch/main/spec/Aphelion%20ISA.pdf)
[RISC-V ISA](https://www2.eecs.berkeley.edu/Pubs/TechRpts/2016/Archive/EECS-2016-118.pdf)
[MIPS ISA](https://www.cs.gordon.edu/courses/cs311/handouts-2015/MIPS%20ISA.pdf)
[RISC Pipeline](https://en.wikipedia.org/wiki/Classic_RISC_pipeline)
