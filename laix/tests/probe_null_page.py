#!/usr/bin/env python3
"""Check low entry state and a real kernel NULL call in a ready image.

Never build code. Map an existing ROM JALR at a temporary supervisor RX alias
and redirect the first armed boot BREAK's saved context to it with r1=0.
The CPU makes the NULL call itself. Page-zero PTEs and all kernel instructions
remain untouched. Use the regular null_call UART assertions with the observed
call continuation, rather than claiming to run the separate null_call image.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct

from probe_boot import Monitor, ready_monitor, require
from probe_unexpected_traps import LAYOUT, instruction, locations, disassemble
from run_ready import ROOT, check_layout, check_output, read_symbols

ROM_BASE = 0xFE000000
ROM_ALIAS = 0x400000
SLOTS = ("KERNEL_SP", "KERNEL_STACK_BOTTOM", "KERNEL_STACK_TOP", "TRAP_SAVED_R1")


def check_entry_state(words, symbols):
    expected = [symbols["kernelStackTop"], symbols["kernelStackBottom"],
                symbols["kernelStackTop"], 0]
    require(words == expected, "wrong initial entry-state words at 0x1FF0..0x1FFC")


def check_low_mapping(directory, leaves):
    require(directory & LAYOUT["PTE_V"] and not directory & LAYOUT["PTE_RWX_BITS"],
            "low directory entry must point to a page table")
    require(leaves[0] == 0, "page zero is mapped")
    require(leaves[1] & ~LAYOUT["PAGE_MASK"] == LAYOUT["BOOT_INFO"] and
            leaves[1] & (LAYOUT["PTE_RWX_BITS"] | LAYOUT["PTE_U"] | LAYOUT["PTE_V"]) ==
            LAYOUT["PTE_RW"], "page 1 must be supervisor-only identity RW, without X")


def rom_call_offset(data):
    matches = [offset for offset in range(0, len(data) - 3, 4)
               if disassemble(struct.unpack_from("<I", data, offset)[0], ROM_BASE + offset) ==
               "jalr r31, r1, 0"]
    require(matches, "ready ROM lacks an indirect call through r1")
    require(matches[0] < 0x400000, "ROM call lies outside the alias superpage")
    return matches[0]


def probe(data, symbols, rom_data, emulator, rom, timeout, log_dir):
    require([LAYOUT[name] for name in SLOTS] == [0x1FF0, 0x1FF4, 0x1FF8, 0x1FFC],
            "source entry slots are not at the end of page 1")
    _, dispatch_return = locations(data, symbols)
    call = ROM_ALIAS + rom_call_offset(rom_data)
    continuation = call + 4
    transcript = []
    with ready_monitor(data, emulator, rom, timeout) as (monitor, process, stdout, stderr):
        transcript.append(monitor.receive())
        transcript.append(monitor.stop_at(symbols["main"]))
        entry_words = monitor.words(LAYOUT["KERNEL_SP"], 4)
        check_entry_state(entry_words, symbols)
        require(monitor.words(0, 1) == [0], "physical word zero is not HLT (0)")
        transcript.append(monitor.command("xp 0x1FF0 4"))
        transcript.append(monitor.stop_at(symbols["trapEntry"]))
        first = Monitor.registers(monitor.command("r"))
        require(first["cause"] == 13 and first["status"] == LAYOUT["STATUS_EXL"] and
                instruction(data, first["epc"]) == 9, "first trap is not the expected boot BREAK")
        ptbr = first["ptbr"]
        require(ptbr & 1, "MMU is not enabled")
        directory = monitor.words(ptbr & ~LAYOUT["PAGE_MASK"], 1)[0]
        table = directory & ~LAYOUT["PAGE_MASK"]
        leaves = monitor.words(table, 2)
        check_low_mapping(directory, leaves)
        transcript.append(monitor.command(f"xp 0x{table:X} 2"))
        transcript.append(monitor.command("x 0 1"))
        transcript.append(monitor.stop_at(dispatch_return))
        frame = Monitor.registers(monitor.command("r"))["r30"]
        require(monitor.words(frame + LAYOUT["TF_EPC"], 1) == [first["epc"] + 4],
                "expected BREAK did not advance EPC exactly once")
        # Use unused space above the bottom canary for diagnostic-stage bytes.
        stage_address = symbols["kernelStackBottom"] + LAYOUT["WORD_BYTES"]
        stage = b"null-call-test\0".ljust(16, b"\0")
        require(stage_address + len(stage) <= frame - LAYOUT["TRAP_DISPATCH_HEADROOM"],
                "stage fixture would overlap the active kernel stack")
        changes = {frame + LAYOUT["TF_EPC"]: call, frame + LAYOUT["TF_R1"]: 0,
                   (ptbr & ~LAYOUT["PAGE_MASK"]) + LAYOUT["WORD_BYTES"]: ROM_BASE | LAYOUT["PTE_RX"],
                   symbols["panic__panicStage"]: stage_address}
        changes.update({stage_address + offset: struct.unpack_from("<I", stage, offset)[0]
                        for offset in range(0, len(stage), 4)})
        for address, value in changes.items():
            transcript.append(monitor.command(f"wp 0x{address:X} 0x{value:X}"))
            require(monitor.words(address, 1) == [value], "monitor data write failed")
        monitor.command("del all")
        transcript.append(monitor.stop_at(call))
        before = Monitor.registers(monitor.command("r"))
        require(before["status"] == 0 and before["r1"] == 0, "NULL call is not supervisor/r1=0")
        transcript.append(monitor.command(f"dis 0x{call:X} 1"))
        require(monitor.words(ROM_BASE + call - ROM_ALIAS, 1) ==
                [struct.unpack_from("<I", rom_data, call - ROM_ALIAS)[0]], "ROM call bytes differ")
        transcript.append(monitor.stop_at(symbols["trapEntry"]))
        fault = Monitor.registers(monitor.command("r"))
        require((fault["cause"], fault["epc"], fault["badaddr"], fault["r31"], fault["status"]) ==
                (8, 0, 0, continuation, LAYOUT["STATUS_EXL"]), "CPU did not raise the NULL fetch fault")
        check_low_mapping(directory, monitor.words(table, 2))
        require(monitor.words(LAYOUT["KERNEL_SP"], 3) == entry_words[:3], "entry stack words changed")
        monitor.command("del all")
        monitor.connection.sendall(b"c\n")
        process.wait(timeout=timeout)
        stdout.seek(0)
        stderr.seek(0)
        uart, emulator_output = stdout.read(), stderr.read()
        check_output("null_call", dict(symbols, nullCallReturn=continuation), uart, process.returncode)
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / "null_page.uart.txt").write_text(uart)
    (log_dir / "null_page.emulator.txt").write_text(emulator_output)
    (log_dir / "null_page.monitor.txt").write_text("\n".join(transcript))
    return dict(entry_words=[f"{value:08X}" for value in entry_words],
                entry_addresses=[f"{LAYOUT[name]:08X}" for name in SLOTS],
                low_ptes=[f"{value:08X}" for value in leaves],
                physical_word_zero=0, cause=8, epc=0, badaddr=0,
                null_call=f"{call:08X}", null_call_return=f"{continuation:08X}",
                exit_code=process.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance/null_page")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    symbols = read_symbols(args.map)
    check_layout(symbols)
    require({"main", "kernelInit", "trapDispatch", "panic__panicStage"} <= symbols.keys(),
            "map lacks current kernel/probe symbols")
    data, rom_data = args.image.read_bytes(), args.rom.read_bytes()
    require(len(data) >= 16, "missing WRMB header")
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    require(magic == 0x424D5257 and reserved == 0 and sectors > 0 and
            entry + 0x10000 == symbols["kernelStart"] and len(data) >= sectors * 512 and
            symbols["__image_end"] <= 0x10000 + sectors * 512 <= symbols["__bss_start"],
            "WRMB image does not match the map")
    result = probe(data, symbols, rom_data, args.emulator.resolve(), args.rom.resolve(),
                   args.timeout, args.log_dir)
    report = dict(image=str(args.image.resolve()), image_sha256=hashlib.sha256(data).hexdigest(),
                  map_sha256=hashlib.sha256(args.map.read_bytes()).hexdigest(),
                  emulator_sha256=hashlib.sha256(args.emulator.read_bytes()).hexdigest(),
                  rom_sha256=hashlib.sha256(rom_data).hexdigest(),
                  method="monitor data injection; existing ROM JALR; page zero unchanged; no build",
                  result=result)
    (args.log_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS null page: entry state at 0x1FF0, CAUSE=8, EPC=BADADDR=0, "
          f"r31={result['null_call_return']}, exit 254")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
