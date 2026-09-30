# WRM.081632

<img src="./images/cpu.png" width="256"/>

WRM.081632 – is a 32-bit, RISC based, little-endian CPU architecture.

```sh
dd if=/dev/zero of=firmware.rom  bs=1m  count=32
```

## Running

```sh
python3 tools/asm.py firmware/main.asm -o firmware.rom
bin/wrm081632 [--rom PATH] [--headless]
```

| Option        | Description                                              |
|---------------|----------------------------------------------------------|
| `--rom PATH`  | firmware image, `firmware.rom` by default                |
| `--headless`  | no window; the UART console still uses stdin and stdout |
| `-h, --help`  | show the options                                         |

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

A test includes `tests/common/harness.asm` and defines `test_main`. It
sets `r28` to the number of each check and ends with `j pass`, or
branches to `fail`, which prints the check number and `r1`–`r4` and
powers off with the check number as the exit code. A test passes only
if it powers off with `0` after printing `PASS`.

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
