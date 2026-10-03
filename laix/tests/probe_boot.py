#!/usr/bin/env python3
"""Probe a ready trap image through the local emulator monitor, without building.

Dirty the entire BSS before kernelStart; inspect every word before main;
verify the boot-info copy, stack and IRQ state after kernelInit returns.
"""

import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time

from run_ready import ROOT, check_layout, check_output, read_symbols

sys.path.insert(0, str(ROOT / "tools"))
from disasm import disassemble
from test_kernel import LAIX, parse_asm, asm_constants

# The four entry-state words (KERNEL_SP first) in the boot info page.
ENTRY_STATE = asm_constants(parse_asm(LAIX / "src/defs.inc"))["KERNEL_SP"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


@contextmanager
def ready_monitor(data, emulator, rom, timeout):
    """Open a temporary, paused machine using existing executable bytes only."""
    with tempfile.TemporaryDirectory(prefix="laix-ready-monitor-") as directory:
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
                yield Monitor(connection), process, stdout, stderr
            finally:
                if connection is not None:
                    connection.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()


class Monitor:
    def __init__(self, connection):
        self.connection = connection
        self.pending = ""

    def receive(self, count=1):
        while True:
            prompts = list(re.finditer(r"(?m)^> ", self.pending))
            if len(prompts) >= count:
                end = prompts[count - 1].end()
                result, self.pending = self.pending[:end], self.pending[end:]
                return result
            chunk = self.connection.recv(65536)
            require(chunk, "monitor disconnected before the expected stop")
            self.pending += chunk.decode("ascii")

    def commands(self, commands):
        self.connection.sendall(("\n".join(commands) + "\n").encode("ascii"))
        return self.receive(len(commands))

    def command(self, command):
        return self.commands([command])

    def words(self, address, count):
        responses = []
        for i in range(0, count, 1024):
            responses.append(self.command(f"xp 0x{address + 4 * i:X} {min(1024, count - i)}"))
        memory = {}
        for response in responses:
            for line in response.splitlines():
                parts = line.split()
                if len(parts) >= 2 and all(re.fullmatch(r"[0-9A-F]{8}", part) for part in parts):
                    base = int(parts[0], 16)
                    for i, part in enumerate(parts[1:]):
                        memory[base + 4 * i] = int(part, 16)
        require(all(address + 4 * i in memory for i in range(count)), "incomplete monitor memory dump")
        return [memory[address + 4 * i] for i in range(count)]

    def stop_at(self, address):
        self.command(f"b 0x{address:X}")
        self.command("c")
        regs = self.command("r")
        require(re.search(rf"\bpc {address:08X}\b", regs), f"did not stop at {address:08X}")
        return regs

    def irqs_and_stack(self, bottom, top, mmu):
        regs, devices = self.command("r"), self.command("info")
        status = re.search(r"(?m)^status\s+([0-9A-F]{8})", regs)
        ptbr = re.search(r"(?m)^ptbr\s+([0-9A-F]{8})", regs)
        sp = re.search(r"\br30\s+([0-9A-F]{8})", regs)
        require(status and int(status[1], 16) & 1 == 0, "STATUS.IE is enabled")
        require("enable 00000000" in devices, "PIC ENABLE is nonzero")
        require(ptbr and bool(int(ptbr[1], 16) & 1) == mmu, "unexpected MMU state")
        require(sp and bottom < int(sp[1], 16) <= top and int(sp[1], 16) % 8 == 0,
                "SP is outside the aligned kernel stack")
        return regs + devices

    @staticmethod
    def registers(output):
        values = {f"r{number}": int(value, 16) for number, value in
                  re.findall(r"\br(\d+)\s+([0-9A-F]{8})", output)}
        for name in ("pc", "epc", "status", "cause", "badaddr", "fcsr", "ptbr"):
            match = re.search(rf"\b{name}\s+([0-9A-F]{{8}})", output)
            require(match, f"monitor register dump lacks {name}")
            values[name] = int(match[1], 16)
        require(all(f"r{i}" in values for i in range(32)), "monitor dump lacks GPRs")
        return values

    def trap_return(self, entry, cause, data):
        before_text = self.stop_at(entry)
        before = self.registers(before_text)
        require(before["cause"] == cause, f"unexpected trap cause {before['cause']}")
        word = struct.unpack_from("<I", data, before["epc"] - 0x10000)[0]
        require(word == (9 if cause == 13 else 7), "EPC does not point at BREAK/SYSCALL")
        resume = before["epc"] + 4
        after_text = self.stop_at(resume)
        after = self.registers(after_text)
        require(after["epc"] == resume and after["status"] & 16 == 0,
                "IRET did not resume exactly after the trap instruction")
        for register in range(32):
            name = f"r{register}"
            expected = 0xFFFFFFDA if cause == 12 and register == 1 else before[name]
            require(after[name] == expected, f"trap did not preserve {name}")
        require(after["fcsr"] == before["fcsr"], "trap did not preserve FCSR")
        self.command(f"del 0x{resume:X}")
        return before_text + after_text


def probe(image, map_path, emulator, rom, log_dir, timeout):
    symbols = read_symbols(map_path)
    check_layout(symbols)
    for name in ("main", "kernelInit", "bootInfoAddress", "kernelBootInfo"):
        require(name in symbols, f"map lacks {name}")
    data = Path(image).read_bytes()
    require(len(data) >= 16, "missing WRMB header")
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    require(magic == 0x424D5257 and reserved == 0 and sectors > 0 and
            0x10000 + entry == symbols["kernelStart"], "WRMB header does not match map")
    require(len(data) >= sectors * 512, "boot image is truncated")
    # Find the real compiled call's return PC without assuming prologue size.
    return_pc = None
    for pc in range(symbols["main"], min(symbols["main"] + 512, symbols["__image_end"]), 4):
        word = struct.unpack_from("<I", data, pc - 0x10000)[0]
        if disassemble(word, pc) == f"jal r31, 0x{symbols['kernelInit']:08X}":
            return_pc = pc + 4
            break
    require(return_pc is not None, "could not find the compiled main -> kernelInit call")
    start, end = symbols["__bss_start"], symbols["__bss_end"]
    require(start % 4 == end % 4 == 0, "BSS bounds are not word aligned")
    bottom, top = symbols["kernelStackBottom"], symbols["kernelStackTop"]
    log_dir.mkdir(parents=True, exist_ok=True)
    transcript = []
    with tempfile.TemporaryDirectory(prefix="laix-boot-probe-") as temporary:
        disk = Path(temporary) / "boot.img"
        disk.write_bytes(data[:sectors * 512])  # no glyph bitmaps
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        with tempfile.TemporaryFile(mode="w+") as stdout, tempfile.TemporaryFile(mode="w+") as stderr:
            process = subprocess.Popen([str(emulator), "--headless", "--no-net", "--rom", str(rom),
                                        "--hdd", str(disk), f"--monitor={port}", "--pause"],
                                       cwd=temporary, stdout=stdout, stderr=stderr)
            connection = None
            try:
                deadline = time.monotonic() + timeout
                while connection is None:
                    require(process.poll() is None, "emulator exited before opening the monitor")
                    require(time.monotonic() < deadline, "monitor connection timed out")
                    try:
                        connection = socket.create_connection(("127.0.0.1", port), timeout=0.2)
                    except ConnectionRefusedError:
                        time.sleep(0.02)
                connection.settimeout(timeout)
                monitor = Monitor(connection)
                transcript.append(monitor.receive())
                transcript.append(monitor.stop_at(symbols["kernelStart"]))
                info = monitor.words(0x1000, 10)
                require(info[0] == 0x4F464E49, "firmware did not provide valid boot info")
                # Fill and read back every BSS word, including guard/stack/tables.
                commands = [f"wp 0x{address:X} 0xA5A5A5A5" for address in range(start, end, 4)]
                for i in range(0, len(commands), 128):
                    response = monitor.commands(commands[i:i + 128])
                    require("usage:" not in response and "no RAM" not in response, "could not dirty BSS")
                require(all(word == 0xA5A5A5A5 for word in monitor.words(start, (end - start) // 4)),
                        "BSS was not fully dirtied")
                transcript.append(monitor.stop_at(symbols["main"]))
                actual = monitor.words(start, (end - start) // 4)
                exceptions = {bottom: 0x4C414958, symbols["bootInfoAddress"]: 0x1000}
                for i, word in enumerate(actual):
                    address = start + 4 * i
                    require(word == exceptions.get(address, 0), f"BSS was not cleared at {address:08X}")
                require(monitor.words(0x1000, 10) == info, "BSS clearing overwrote boot info")
                require(monitor.words(ENTRY_STATE, 4) == [top, bottom, top, 0], "low stack state is incorrect")
                transcript.append(monitor.irqs_and_stack(bottom, top, mmu=False))
                # Observe the builtin BREAK, seeded BREAK, seeded SYSCALL and
                # builtin SYSCALL at IVEC and immediately after each IRET.
                for cause in (13, 13, 12, 12):
                    transcript.append(monitor.trap_return(symbols["trapEntry"], cause, data))
                monitor.command(f"del 0x{symbols['trapEntry']:X}")
                transcript.append(monitor.stop_at(return_pc))
                transcript.append(monitor.irqs_and_stack(bottom, top, mmu=True))
                require(monitor.words(symbols["kernelBootInfo"], 10) == info, "boot info snapshot differs")
                monitor.command("wp 0x1000 0")
                require(monitor.words(0x1000, 1) == [0], "firmware-info mutation failed")
                require(monitor.words(symbols["kernelBootInfo"], 10) == info, "kernel did not copy boot info")
                monitor.command(f"wp 0x1000 0x{info[0]:X}")
                connection.sendall(b"c\n")
                process.wait(timeout=timeout)
                stdout.seek(0)
                stderr.seek(0)
                uart, emulator_output = stdout.read(), stderr.read()
                check_output("trap", symbols, uart, process.returncode)
            finally:
                if connection is not None:
                    connection.close()
                if process.poll() is None:
                    process.kill()
                    process.wait()
    (log_dir / "boot_probe.uart.txt").write_text(uart)
    (log_dir / "boot_probe.emulator.txt").write_text(emulator_output)
    (log_dir / "boot_probe.monitor.txt").write_text("\n".join(transcript))
    report = dict(bss_words_verified=(end - start) // 4, bss_start=f"{start:08X}", bss_end=f"{end:08X}",
                  boot_info_copied=True, kernel_stack_valid=True, low_stack_state_valid=True,
                  trap_returns_verified=["builtin BREAK", "seeded BREAK", "seeded SYSCALL", "builtin SYSCALL"],
                  continuation="EPC + 4; all GPRs and FCSR preserved except syscall r1=-ENOSYS",
                  irq_checks="IE=0 and PIC ENABLE=0 before and after kernelInit", exit_code=process.returncode)
    (log_dir / "boot_probe.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS boot probe: {report['bss_words_verified']} dirty BSS words cleared; boot info copied; stack and IRQ state valid")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    try:
        require(args.timeout > 0, "timeout must be positive")
        probe(args.image, args.map, args.emulator.resolve(), args.rom.resolve(), args.log_dir, args.timeout)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f"FAIL boot probe: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
