#!/usr/bin/env python3
"""Run acceptance checks on existing LA/IX test images. Never build code."""

import argparse
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LAYOUT_SYMBOLS = ("__image_start", "__image_end", "__bss_start", "__bss_end", "kernelStart",
                  "trapEntry", "kernelStackGuard", "kernelStackBottom", "kernelStackTop",
                  "__start_text", "__stop_text", "__start_rodata", "__stop_rodata",
                  "__start_data")
# Expected fatal dumps: stage, CAUSE, BADADDR, EPC and r31 (None: any).
# A string is a map symbol, an integer an exact value.
FAULTS = {
    "trap_fault": ("trap-fault-test", 3, 0x1001, "trapFaultInstruction", None),
    "stack_guard": ("stack-guard-test", 10, "kernelStackGuard", "stackGuardFaultInstruction", None),
    # A NULL call fetches from the unmapped page zero, not its HLT word.
    "null_call": ("null-call-test", 8, 0, 0, "nullCallReturn"),
    # Kernel W^X: .text is not writable, .data is not executable.
    "text_write": ("text-write-test", 10, "triggerTextWrite", "textWriteInstruction", None),
    "data_exec": ("data-exec-test", 8, "dataExecTarget", "dataExecTarget", "dataExecReturn"),
}
CASES = {"trap", "stack_overflow"} | FAULTS.keys()
MAP_SYMBOLS = set(LAYOUT_SYMBOLS) | {"main", "kernelInit", "bootInfoAddress", "kernelBootInfo",
                                  "panic", "panic__panicStage", "trapDispatch", "trap__expectedTrap",
                                  "trapBadStack", "trapEmergencyFrame", "trapEmergencyStack",
                                  "trapEmergencyStackTop"} | {
    value for fault in FAULTS.values() for value in fault[1:] if isinstance(value, str)}


def read_symbols(path):
    symbols = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r"([0-9A-Fa-f]{8})\s+(\S+)", line.strip())
        if match:
            name = match[2]
            # Maps also list object-local symbols, such as repeated __str0.
            # Only the global symbols used by the acceptance checks matter.
            if name not in MAP_SYMBOLS:
                continue
            if name in symbols:
                raise ValueError(f"duplicate map symbol: {name}")
            symbols[name] = int(match[1], 16)
    return symbols


def check_layout(symbols):
    missing = set(LAYOUT_SYMBOLS) - symbols.keys()
    if missing:
        raise ValueError("map lacks current kernel symbols: " + ", ".join(sorted(missing)))
    start, end = symbols["__image_start"], symbols["__image_end"]
    guard, bottom, top = (symbols[name] for name in
                          ("kernelStackGuard", "kernelStackBottom", "kernelStackTop"))
    if not (start == 0x10000 < end <= symbols["__bss_start"] <= guard and
            guard % 4096 == 0 and bottom == guard + 4096 and top == bottom + 8192 and
            top <= symbols["__bss_end"]):
        raise ValueError("kernel image/BSS/stack/guard layout is invalid")
    if not all(start <= symbols[name] < end for name in ("kernelStart", "trapEntry")):
        raise ValueError("entry code lies outside the image")
    # W^X needs .text, .rodata and .data on pages of their own (mmu.m).
    text, rodata, data = (symbols[name] for name in
                          ("__start_text", "__start_rodata", "__start_data"))
    if not (text == start and rodata % 4096 == 0 and data % 4096 == 0 and
            symbols["__stop_text"] <= rodata and symbols["__stop_rodata"] <= data <= guard and
            symbols["__bss_end"] <= 0x400000):
        raise ValueError("kernel sections are not page-aligned for W^X or exceed 4 MiB")


def field(output, name):
    values = re.findall(r"\b" + re.escape(name) + r"=([0-9A-Fa-f]{8})\b", output)
    if len(values) != 1:
        raise ValueError(f"expected exactly one {name} in UART dump")
    return int(values[0], 16)


def check_output(case, symbols, output, exit_code):
    if case not in CASES:
        raise ValueError(f"unknown case: {case}")
    if case == "trap":
        if exit_code != 0 or "PANIC" in output:
            raise ValueError(f"trap test failed, exit={exit_code}")
        for marker in ("MMU enabled, kernel stack guard active, kernel W^X",
                       "TrapFrame and syscall self-tests passed", "trap runtime OK"):
            if marker not in output:
                raise ValueError(f"missing UART success marker: {marker}")
        return
    if case == "stack_overflow":
        check_stack_overflow(symbols, output, exit_code)
        return
    if exit_code != 254 or "LA/IX PANIC: unexpected exception" not in output:
        raise ValueError(f"expected diagnostic panic and exit 254, got exit={exit_code}")
    if "origin=supervisor" not in output:
        raise ValueError("fault origin is not supervisor")
    stage, *expected = FAULTS[case]
    for value in expected:
        if isinstance(value, str) and value not in symbols:
            raise ValueError(f"map lacks {value}")
    cause, badaddr, epc, ra = (symbols[value] if isinstance(value, str) else value
                               for value in expected)
    if f"stage={stage} " not in output:
        raise ValueError(f"wrong panic stage, expected {stage}")
    for name, expected in (("cause", cause), ("badaddr", badaddr), ("epc", epc), ("r31", ra)):
        if expected is None:
            continue
        actual = field(output, name)
        if actual != expected:
            raise ValueError(f"{name}: got {actual:08X}, expected {expected:08X}")
    check_full_dump(output)


def check_full_dump(output):
    status = field(output, "status")
    if status & (1 | 4 | 8) or not status & 16:
        raise ValueError("fatal entry must have IE=UM=PUM=0 and EXL=1")
    if not field(output, "ptbr") & 1:
        raise ValueError("fault occurred before MMU was enabled")
    field(output, "fcsr")
    for register in range(32):
        field(output, f"r{register:02d}")


def check_stack_overflow(symbols, output, exit_code):
    """The guard fault is reported twice: the dependency-free early line from
    trapEntry's .bad_stack path, then the full dump from its emergency stack."""
    early, separator, full = output.partition("LA/IX PANIC: invalid kernel stack")
    if exit_code != 254 or not separator or "LA/IX EARLY PANIC: invalid kernel stack" not in early:
        raise ValueError(f"expected early and full stack panics and exit 254, got exit={exit_code}")
    guard, bottom, top = (symbols[name] for name in
                          ("kernelStackGuard", "kernelStackBottom", "kernelStackTop"))
    for part in (early, full):
        if field(part, "cause") != 10:
            raise ValueError("expected a store page fault into the guard")
        if not guard <= field(part, "badaddr") < bottom:
            raise ValueError("BADADDR is not in the stack guard page")
    for name in ("epc", "badaddr"):
        if field(early, name) != field(full, name):
            raise ValueError(f"full dump {name} does not match the early line")
    if (field(early, "bottom"), field(early, "top")) != (bottom, top):
        raise ValueError("early line reports wrong stack bounds")
    sp, scratch = field(early, "sp"), field(early, "scratch")
    # Supervisor origin: the interrupted stack is the one that was rejected.
    if sp != scratch or not sp < bottom:
        raise ValueError(f"rejected sp {sp:08X} is not the overflowed stack")
    if "stage=stack-overflow-test " not in full or "origin=supervisor" not in full:
        raise ValueError("full dump lacks the stage or supervisor origin")
    if field(full, "r30") != scratch or field(full, "r31") != field(early, "ra"):
        raise ValueError("full dump does not match the early line")
    if not symbols["__start_text"] <= field(full, "epc") < symbols["__stop_text"]:
        raise ValueError("EPC is not in kernel code")
    check_full_dump(full)


def run_case(case, image, map_path, emulator, rom, timeout):
    symbols = read_symbols(map_path)
    check_layout(symbols)
    data = Path(image).read_bytes()
    if len(data) < 16:
        raise ValueError("boot image header is missing")
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    if magic != 0x424D5257 or sectors == 0 or reserved != 0 or entry != symbols["kernelStart"] - 0x10000:
        raise ValueError("WRMB header does not match the map")
    load_bytes = sectors * 512
    if len(data) < load_bytes or not (symbols["__image_end"] <= 0x10000 + load_bytes <= symbols["__bss_start"]):
        raise ValueError("image length or load range does not match the map")
    # Copy existing executable bytes only, without appended glyph bitmaps.
    # Tests must finish/report panic without console or font initialization.
    with tempfile.TemporaryDirectory(prefix="laix-ready-") as directory:
        disk = Path(directory) / "boot.img"
        disk.write_bytes(data[:load_bytes])
        result = subprocess.run([str(emulator), "--headless", "--no-net", "--rom", str(rom),
                                 "--hdd", str(disk)], cwd=directory, capture_output=True,
                                text=True, errors="replace", timeout=timeout)
    try:
        check_output(case, symbols, result.stdout, result.returncode)
    except ValueError as error:
        raise ValueError(f"{error}\nUART:\n{result.stdout}\nEmulator:\n{result.stderr}") from error
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", nargs=3, action="append", required=True,
                        metavar=("NAME", "IMAGE", "MAP"),
                        help="trap, stack_overflow or a fault case (" + ", ".join(sorted(FAULTS)) + "); repeat for multiple images")
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--log-dir", type=Path, help="save UART and emulator output for each case")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    emulator, rom = args.emulator.resolve(), args.rom.resolve()
    if not emulator.is_file() or not rom.is_file():
        parser.error("an existing emulator and ROM are required")
    failed = False
    for case, image, map_path in args.case:
        try:
            if case not in CASES:
                raise ValueError(f"unknown case: {case}")
            result = run_case(case, image, map_path, emulator, rom, args.timeout)
            if args.log_dir:
                args.log_dir.mkdir(parents=True, exist_ok=True)
                (args.log_dir / f"{case}.uart.txt").write_text(result.stdout)
                (args.log_dir / f"{case}.emulator.txt").write_text(result.stderr)
            print(f"PASS {case}")
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            print(f"FAIL {case}: {error}")
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
