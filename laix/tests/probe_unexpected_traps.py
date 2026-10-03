#!/usr/bin/env python3
"""Exercise fatal BREAK/SYSCALL paths in a ready image; never build code.

The monitor changes only data in a temporary machine. After the first armed
boot BREAK returns from trapDispatch, redirect its saved IRET context to an
existing BREAK/SYSCALL instruction, with no expectation or a wrong expectation.
For user cases, add a temporary RXU alias and return through the real IRET with
an unmapped user SP. The CPU then raises the actual user exception. Handler
instructions, the ready image and its map remain unchanged.
"""

import argparse
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time

from probe_boot import Monitor, require, disassemble, LAIX, parse_asm, asm_constants
from run_ready import ROOT, check_layout, read_symbols, field

LAYOUT = asm_constants(parse_asm(LAIX / "src/trap_layout.inc"))
USER_ALIAS = 0x400000
USER_SP = 0xFFFFFFF8  # unmapped, and outside the trusted kernel stack


def instruction(data, address):
    return struct.unpack_from("<I", data, address - 0x10000)[0]


def locations(data, symbols):
    """Find instructions in executable bytes, without generating any code."""
    traps = {}
    dispatch_return = None
    for pc in range(symbols["__start_text"] + 16, symbols["__stop_text"], 4):
        word = instruction(data, pc)
        if word in (7, 9) and pc >= symbols["kernelInit"]:
            traps.setdefault(12 if word == 7 else 13, pc)
        if disassemble(word, pc) == f"jal r31, 0x{symbols['trapDispatch']:08X}":
            require(dispatch_return is None, "multiple calls to trapDispatch")
            dispatch_return = pc + 4
    require(traps.keys() == {12, 13} and dispatch_return is not None,
            "image lacks BREAK, SYSCALL or the entry -> trapDispatch call")
    return traps, dispatch_return


def check_panic(output, exit_code, cause, user, epc, before):
    reason = "unexpected breakpoint" if cause == 13 else "unexpected syscall"
    require(exit_code == 254, f"expected exit 254, got {exit_code}")
    require(output.count("LA/IX PANIC:") == 1 and f"LA/IX PANIC: {reason}\n" in output,
            "missing or incorrect fatal diagnostic")
    require(f"origin={'user' if user else 'supervisor'}\n" in output, "wrong trap origin")
    for name, value in (("cause", cause), ("epc", epc), ("status", before["status"]),
                        ("badaddr", before["badaddr"]), ("fcsr", before["fcsr"]),
                        ("ptbr", before["ptbr"])):
        require(field(output, name) == value, f"panic changed {name}")
    require(field(output, "ptbr") & 1, "MMU was not enabled")
    for i in range(32):
        require(field(output, f"r{i:02d}") == before[f"r{i}"], f"panic changed r{i}")


def run_case(data, symbols, traps, dispatch_return, emulator, rom, timeout,
             cause, user, armed, log_dir):
    name = f"{'user' if user else 'supervisor'}_{'break' if cause == 13 else 'syscall'}_{armed}"
    expectation = {"unarmed": 0, "mismatch": 12 if cause == 13 else 13, "matched": cause}[armed]
    transcript = []
    with tempfile.TemporaryDirectory(prefix="laix-unexpected-") as directory:
        disk = Path(directory) / "boot.img"
        sectors = struct.unpack_from("<I", data, 4)[0]
        disk.write_bytes(data[:sectors * 512])
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
            process = subprocess.Popen([str(emulator), "--headless", "--no-net", "--rom", str(rom),
                                        "--hdd", str(disk), f"--monitor={port}", "--pause"],
                                       cwd=directory, stdout=stdout, stderr=stderr)
            connection = None
            try:
                deadline = time.monotonic() + timeout
                while connection is None:
                    require(process.poll() is None, "emulator exited before opening monitor")
                    require(time.monotonic() < deadline, "monitor connection timed out")
                    try:
                        connection = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                    except ConnectionRefusedError:
                        time.sleep(0.02)
                connection.settimeout(timeout)
                monitor = Monitor(connection)
                transcript.append(monitor.receive())
                first = Monitor.registers(monitor.stop_at(symbols["trapEntry"]))
                require(first["cause"] == 13 and first["status"] == LAYOUT["STATUS_EXL"],
                        "first boot trap is not a supervisor BREAK with IRQs off")
                require(instruction(data, first["epc"]) == 9, "first trap EPC is not BREAK")
                transcript.append(monitor.stop_at(dispatch_return))
                frame = Monitor.registers(monitor.command("r"))["r30"]
                require(monitor.words(frame + LAYOUT["TF_EPC"], 1) == [first["epc"] + 4],
                        "armed boot BREAK did not advance EPC exactly once")
                require(monitor.words(symbols["trap__expectedTrap"], 1) == [0],
                        "armed boot BREAK did not consume its expectation")
                epc = traps[cause] + (USER_ALIAS if user else 0)
                changes = {frame + LAYOUT["TF_EPC"]: epc,
                           frame + LAYOUT["TF_STATUS"]: LAYOUT["STATUS_EXL"] |
                           (LAYOUT["STATUS_PUM"] if user else 0),
                           symbols["trap__expectedTrap"]: expectation}
                if user:
                    ptbr = Monitor.registers(monitor.command("r"))["ptbr"]
                    require(ptbr & 1, "MMU is not enabled")
                    # Slot 1 is not used by boot/self-tests: no stale TLB entry.
                    # RXU superpage alias of physical [0, 4 MiB), in this VM only.
                    changes[(ptbr & ~0xFFF) + 4] = (LAYOUT["PTE_RX"] | LAYOUT["PTE_U"])
                    changes[frame + LAYOUT["TF_R30"]] = USER_SP
                for address, value in changes.items():
                    transcript.append(monitor.command(f"wp 0x{address:X} 0x{value:X}"))
                    require(monitor.words(address, 1) == [value], "monitor data write failed")
                monitor.command(f"del 0x{dispatch_return:X}")
                # This is the CPU's new trap, after executing the real IRET.
                transcript.append(monitor.stop_at(symbols["trapEntry"]))
                before = Monitor.registers(monitor.command("r"))
                require((before["cause"], before["epc"]) == (cause, epc),
                        "CPU did not execute the selected BREAK/SYSCALL")
                require(before["status"] == LAYOUT["STATUS_EXL"] |
                        (LAYOUT["STATUS_PUM"] if user else 0), "CPU reported wrong origin")
                if user:
                    require(before["r30"] == USER_SP, "user SP was not restored by IRET")
                transcript.append(monitor.stop_at(symbols["panic"]))
                fatal_frame = Monitor.registers(monitor.command("r"))["r2"]
                require(symbols["kernelStackBottom"] < fatal_frame and
                        fatal_frame + LAYOUT["TF_SIZE"] <= symbols["kernelStackTop"],
                        "fatal frame is outside the trusted kernel stack")
                require(monitor.words(fatal_frame + LAYOUT["TF_EPC"], 1) == [epc],
                        "EPC changed before panic")
                require(monitor.words(symbols["trap__expectedTrap"], 1) == [expectation],
                        "fatal trap consumed the expectation")
                monitor.command("del all")
                connection.sendall(b"c\n")
                process.wait(timeout=timeout)
                stdout.seek(0)
                stderr.seek(0)
                uart, emulator_output = stdout.read(), stderr.read()
                check_panic(uart, process.returncode, cause, user, epc, before)
            finally:
                if connection is not None:
                    connection.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / f"{name}.uart.txt").write_text(uart)
    (log_dir / f"{name}.emulator.txt").write_text(emulator_output)
    (log_dir / f"{name}.monitor.txt").write_text("\n".join(transcript))
    print(f"PASS {name}: panic, EPC={epc:08X}, exit 254")
    return dict(case=name, cause=cause, epc=f"{epc:08X}", expectation=expectation,
                origin="user" if user else "supervisor", exit_code=process.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance/unexpected_traps")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    symbols = read_symbols(args.map)
    check_layout(symbols)
    require({"kernelInit", "trapDispatch", "trap__expectedTrap", "panic"} <= symbols.keys(),
            "image map lacks the armed-trap handler; use a newer ready image")
    data = args.image.read_bytes()
    require(len(data) >= 16, "missing WRMB header")
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    require(magic == 0x424D5257 and reserved == 0 and sectors > 0 and
            entry + 0x10000 == symbols["kernelStart"] and len(data) >= sectors * 512 and
            symbols["__image_end"] <= 0x10000 + sectors * 512 <= symbols["__bss_start"],
            "WRMB image does not match the map")
    traps, dispatch_return = locations(data, symbols)
    cases = [run_case(data, symbols, traps, dispatch_return, args.emulator.resolve(),
                      args.rom.resolve(), args.timeout, cause, user, armed, args.log_dir)
             for user in (False, True) for cause in (13, 12)
             for armed in (("unarmed", "mismatch", "matched") if user else ("unarmed", "mismatch"))]
    report = dict(image=str(args.image.resolve()),
                  image_sha256=hashlib.sha256(data).hexdigest(),
                  map_sha256=hashlib.sha256(args.map.read_bytes()).hexdigest(),
                  emulator_sha256=hashlib.sha256(args.emulator.read_bytes()).hexdigest(),
                  rom_sha256=hashlib.sha256(args.rom.read_bytes()).hexdigest(),
                  method="monitor data injection; real IRET and CPU traps; no code changes or build",
                  cases=cases)
    (args.log_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
