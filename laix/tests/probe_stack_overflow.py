#!/usr/bin/env python3
"""Exercise stack-guard rejection and emergency diagnostics in a ready image.

Never build code. Redirect the first armed BREAK's saved IRET context to the
existing main prologue with SP at the bottom canary. Its own allocation/store
crosses the guard and causes a real CPU fault. This tests the fatal overflow
path without claiming to execute the recursive stack_overflow.m test image.
Only data in a temporary machine is changed; kernel instructions/PTEs stay
untouched. Verify the entire saved context and both UART diagnostics.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct

from probe_boot import Monitor, ready_monitor, require
from probe_unexpected_traps import LAYOUT, instruction, locations, disassemble
from run_ready import ROOT, check_layout, check_output, read_symbols, field


def check_prologue(data, entry):
    require(disassemble(instruction(data, entry), entry) == "addi r30, r30, -8" and
            disassemble(instruction(data, entry + 4), entry + 4) == "sw r31, 4(r30)",
            "ready main lacks the expected stack-allocation/store prologue")


def check_saved_frame(words, before):
    expected = [before[f"r{i}"] for i in range(32)]
    expected += [before[name] for name in ("epc", "status", "cause", "badaddr", "fcsr", "ptbr")]
    expected += [0] * LAYOUT["TF_RESERVED_WORDS"]
    require(words == expected, "emergency TrapFrame does not preserve the interrupted context")


def probe(data, symbols, emulator, rom, timeout, log_dir):
    _, dispatch_return = locations(data, symbols)
    entry = symbols["main"]
    check_prologue(data, entry)
    guard, bottom, top = (symbols[name] for name in
                          ("kernelStackGuard", "kernelStackBottom", "kernelStackTop"))
    emergency = symbols["trapEmergencyFrame"]
    emergency_top = symbols["trapEmergencyStackTop"]
    require(emergency + LAYOUT["TF_SIZE"] == symbols["trapEmergencyStack"] < emergency_top and
            emergency >= top and emergency_top % LAYOUT["STACK_ALIGNMENT"] == 0,
            "emergency frame/stack is not separate from the normal stack")
    transcript = []
    with ready_monitor(data, emulator, rom, timeout) as (monitor, process, stdout, stderr):
        transcript.append(monitor.receive())
        transcript.append(monitor.stop_at(symbols["trapEntry"]))
        first = Monitor.registers(monitor.command("r"))
        require(first["cause"] == 13 and first["status"] == LAYOUT["STATUS_EXL"] and
                instruction(data, first["epc"]) == 9, "first trap is not the expected boot BREAK")
        require(first["ptbr"] & 1, "MMU is not enabled")
        directory = monitor.words(first["ptbr"] & ~LAYOUT["PAGE_MASK"], 1)[0]
        require(directory & LAYOUT["PTE_V"] and not directory & LAYOUT["PTE_RWX_BITS"],
                "low directory entry is not a page table")
        guard_pte = (directory & ~LAYOUT["PAGE_MASK"]) + guard // LAYOUT["PAGE_SIZE"] * 4
        require(monitor.words(guard_pte, 1) == [0], "stack guard is mapped")
        transcript.append(monitor.command(f"xp 0x{guard_pte:X} 1"))
        transcript.append(monitor.stop_at(dispatch_return))
        frame = Monitor.registers(monitor.command("r"))["r30"]
        require(monitor.words(frame + LAYOUT["TF_EPC"], 1) == [first["epc"] + 4],
                "expected BREAK did not advance EPC exactly once")
        require(monitor.words(bottom, 1) == [LAYOUT["STACK_CANARY"]], "initial stack canary is damaged")
        stage_address = bottom + LAYOUT["WORD_BYTES"]
        stage = b"stack-overflow-test\0".ljust(20, b"\0")
        require(stage_address + len(stage) <= frame - LAYOUT["TRAP_DISPATCH_HEADROOM"],
                "stage fixture would overlap the active stack")
        changes = {frame + LAYOUT["TF_EPC"]: entry, frame + LAYOUT["TF_R30"]: bottom,
                   frame + LAYOUT["TF_FCSR"]: 0x61, symbols["panic__panicStage"]: stage_address}
        changes.update({frame + 4 * i: 0xA5010000 + i for i in (*range(1, 30), 31)})
        changes.update({stage_address + offset: struct.unpack_from("<I", stage, offset)[0]
                        for offset in range(0, len(stage), 4)})
        for address, value in changes.items():
            transcript.append(monitor.command(f"wp 0x{address:X} 0x{value:X}"))
            require(monitor.words(address, 1) == [value], "monitor data write failed")
        # Snapshot both the guard and the normal stack after fixture injection.
        stack_words = (top - guard) // LAYOUT["WORD_BYTES"]
        stack_before = monitor.words(guard, stack_words)
        monitor.command("del all")
        transcript.append(monitor.stop_at(entry))
        resumed = Monitor.registers(monitor.command("r"))
        require(resumed["r30"] == bottom and resumed["status"] == 0,
                "IRET did not resume on the exhausted supervisor stack")
        transcript.append(monitor.stop_at(symbols["trapEntry"]))
        fault = Monitor.registers(monitor.command("r"))
        require((fault["cause"], fault["epc"], fault["badaddr"], fault["r30"], fault["status"]) ==
                (10, entry + 4, bottom - 4, bottom - 8, LAYOUT["STATUS_EXL"]),
                "CPU did not fault on the prologue's store into the guard")
        transcript.append(monitor.stop_at(symbols["trapBadStack"]))
        bad_stack = Monitor.registers(monitor.command("r"))
        require((bad_stack["r1"], bad_stack["r2"], bad_stack["r30"]) ==
                (emergency, bottom - 8, emergency_top),
                "trapBadStack is not called with the static frame on the emergency stack")
        check_saved_frame(monitor.words(emergency, LAYOUT["TF_SIZE"] // 4), fault)
        transcript.append(monitor.command(f"xp 0x{emergency:X} {LAYOUT['TF_SIZE'] // 4}"))
        require(monitor.words(guard, stack_words) == stack_before,
                "faulting store or trap entry wrote to the guard/normal stack")
        require(monitor.words(guard_pte, 1) == [0], "trap entry changed the guard mapping")
        monitor.command("del all")
        monitor.connection.sendall(b"c\n")
        process.wait(timeout=timeout)
        stdout.seek(0)
        stderr.seek(0)
        uart, emulator_output = stdout.read(), stderr.read()
        check_output("stack_overflow", symbols, uart, process.returncode)
        # The static frame must survive both early formatting and the M panic.
        full = uart.partition("LA/IX PANIC: invalid kernel stack")[2]
        for i in range(32):
            require(field(full, f"r{i:02d}") == fault[f"r{i}"], f"full dump changed r{i}")
        for name in ("epc", "status", "cause", "badaddr", "fcsr", "ptbr"):
            require(field(full, name) == fault[name], f"full dump changed {name}")
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / "stack_overflow.uart.txt").write_text(uart)
    (log_dir / "stack_overflow.emulator.txt").write_text(emulator_output)
    (log_dir / "stack_overflow.monitor.txt").write_text("\n".join(transcript))
    return dict(cause=10, epc=f"{entry + 4:08X}", badaddr=f"{bottom - 4:08X}",
                rejected_sp=f"{bottom - 8:08X}", emergency_frame=f"{emergency:08X}",
                emergency_stack_top=f"{emergency_top:08X}",
                guard_and_normal_stack_unchanged=True, registers_preserved=True,
                exit_code=process.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance/stack_overflow_probe")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    symbols = read_symbols(args.map)
    check_layout(symbols)
    required = {"main", "kernelInit", "trapDispatch", "panic__panicStage", "trapBadStack",
                "trapEmergencyFrame", "trapEmergencyStack", "trapEmergencyStackTop"}
    require(required <= symbols.keys(), "map lacks the emergency-stack handler/probe symbols")
    data = args.image.read_bytes()
    require(len(data) >= 16, "missing WRMB header")
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    require(magic == 0x424D5257 and reserved == 0 and sectors > 0 and
            entry + 0x10000 == symbols["kernelStart"] and len(data) >= sectors * 512 and
            symbols["__image_end"] <= 0x10000 + sectors * 512 <= symbols["__bss_start"],
            "WRMB image does not match the map")
    result = probe(data, symbols, args.emulator.resolve(), args.rom.resolve(), args.timeout, args.log_dir)
    report = dict(image=str(args.image.resolve()), image_sha256=hashlib.sha256(data).hexdigest(),
                  map_sha256=hashlib.sha256(args.map.read_bytes()).hexdigest(),
                  emulator_sha256=hashlib.sha256(args.emulator.read_bytes()).hexdigest(),
                  rom_sha256=hashlib.sha256(args.rom.read_bytes()).hexdigest(),
                  method="monitor data injection; real stack store fault; kernel code/PTEs unchanged; no build",
                  result=result)
    (args.log_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS stack overflow path: SP={result['rejected_sp']}, early + full dump, "
          f"all registers preserved, emergency stack, exit 254")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
