#!/usr/bin/env python3
"""Execute user-buffer helpers on a ready CPU image, including EXL=1.

Never build code. The monitor changes temporary data/saved IRET frames.
The EXL trampoline copies four existing instructions through CPU memcpy.
Mappings run the MMU API except one explicit negative U-bit fixture, followed
by CPU TLBI.ALL. Missing helpers fail preflight.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from probe_boot import ready_monitor, require, disassemble
from probe_mmu_cpu import CpuProbe, symbols_from_map
from probe_unexpected_traps import instruction
from run_ready import ROOT, check_layout

PAGE, SUPER, USER, END = 4096, 0x400000, 0x40000000, 0xC0000000
BASE, TRAMPOLINE = USER + SUPER - PAGE, USER + 2 * SUPER
EFAULT, EXL = 0xFFFFFFF2, 16
HELPERS = {"copyFromUser", "copyToUser", "mmuUserBufferValid"}


def missing_helpers(symbols):
    return sorted(HELPERS - symbols.keys())


def trampoline_sources(data, symbols):
    wanted = ("mtcr status, r10", "jalr r0, r12, 0", "mtcr status, r0", "break")
    found = {}
    for pc in range(symbols["__start_text"], symbols["__stop_text"], 4):
        asm = disassemble(instruction(data, pc), pc)
        if asm in wanted:
            found.setdefault(asm, pc)
    require(set(wanted) <= found.keys(), "ready image lacks existing EXL trampoline instructions")
    return [found[asm] for asm in wanted]


def check_copy_return(entry, returned, expected):
    require(entry["status"] == EXL and returned["status"] == EXL, "copy did not execute/return inside EXL=1")
    require(returned["r1"] == expected, f"wrong copy result: {returned['r1']:08X}, expected {expected:08X}")
    require(returned["ptbr"] == entry["ptbr"], "copy changed PTBR")
    require(returned["r30"] == entry["r30"], "copy did not restore kernel SP")
    require(returned["fcsr"] == entry["fcsr"], "copy changed FCSR")
    for i in range(10, 30):
        require(returned[f"r{i}"] == entry[f"r{i}"], f"copy damaged callee-saved r{i}")


class BufferProbe(CpuProbe):
    def stop(self, pc):
        self.cmd("del all")
        self.log.append(self.m.stop_at(pc))
        return self.regs()

    def call_exl(self, name, args, expected):
        self.bridge()
        self.prepare(TRAMPOLINE, args, {"R10": EXL, "R12": self.s[name], "R31": TRAMPOLINE + 8})
        entry = self.stop(self.s[name])
        require(entry["status"] == EXL, "trampoline did not set EXL before calling helper")
        require([entry[f"r{i}"] for i in range(1, 6)] == list(args), "trampoline changed copy arguments")
        returned = self.stop(TRAMPOLINE + 8)
        check_copy_return(entry, returned, expected)
        # The next instruction is copied MTCR STATUS,r0. Do not execute BREAK
        # while EXL is set: clear it explicitly before the next bridge trap.
        self.cmd("s 1")
        outside = self.regs()
        require(outside["pc"] == TRAMPOLINE + 12 and outside["status"] == 0,
                "trampoline did not leave EXL before its bridge BREAK")
        record = dict(function=name, arguments=[f"{arg:08X}" for arg in args],
                      result=f"{returned['r1']:08X}", entry_status=entry["status"],
                      return_status=returned["status"], ptbr=f"{returned['ptbr']:08X}",
                      kernel_sp=f"{returned['r30']:08X}")
        self.calls.append(record)
        return record

    def bytes(self, address, count):
        aligned = address & ~3
        words = self.m.words(aligned, ((address & 3) + count + 3) // 4)
        raw = b"".join(struct.pack("<I", word) for word in words)
        return raw[address & 3:(address & 3) + count]

    def seed(self, address, values):
        first = address & ~3
        count = ((address & 3) + len(values) + 3) // 4
        raw = bytearray(b"".join(struct.pack("<I", word) for word in self.m.words(first, count)))
        raw[address & 3:(address & 3) + len(values)] = values
        for offset in range(0, len(raw), 4):
            self.write(first + offset, struct.unpack_from("<I", raw, offset)[0])

    def snapshot(self):
        return [self.m.words(page, PAGE // 4) for page in self.data_pages]

    def reject(self, address, size, name):
        results = []
        for function, args in (
                ("copyFromUser", (self.directory, 7, self.scratch + 1, address, size)),
                ("copyToUser", (self.directory, 7, address, self.scratch + 1, size))):
            before = self.snapshot()
            record = self.call_exl(function, args, EFAULT)
            require(self.snapshot() == before, f"{name}: invalid buffer caused a partial data write")
            results.append(record)
        return dict(case=name, complete=True, copies=results, destination_unchanged=True)


def execute(data, symbols, paths, timeout, log_dir):
    sources = trampoline_sources(data, symbols)
    results = []
    with ready_monitor(data, paths["emulator"], paths["rom"], timeout) as (m, process, stdout, stderr):
        p = BufferProbe(m, data, symbols, timeout)
        try:
            p.directory = p.space(7)
            first = p.page(7)
            gap = p.call("allocPage", 99, 2)
            second = p.page(7)
            require(gap != 0 and second != first + PAGE, "user frames are not separated physically")
            p.data_pages = [first, second, p.scratch]
            p.ok("mapPage", p.directory, 7, BASE, first, 0x17)
            p.ok("mapPage", p.directory, 7, BASE + PAGE, second, 0x17)
            code = p.page(7)
            for offset, source in enumerate(sources):
                p.call("memcpy", code + offset * 4, source, 4)
            p.ok("mapPage", p.directory, 7, TRAMPOLINE, code, 0x1B)
            p.ok("mmuSwitchAddressSpace", p.directory, 7, 7)
            p.break_pc = TRAMPOLINE + 12
            payload = bytes([0, 255, 128, 1, 17, 240, 3, 4, 5, 6, 7])
            p.seed(p.scratch, b"\xA5" * 32)
            p.seed(first + PAGE - 3, payload[:3])
            p.seed(second, payload[3:])
            before_user = [m.words(page, PAGE // 4) for page in (first, second)]
            copied = p.call_exl("copyFromUser", (p.directory, 7, p.scratch + 1, BASE + PAGE - 3, len(payload)), 0)
            require(p.bytes(p.scratch, 13) == b"\xA5" + payload + b"\xA5", "cross-page read copied wrong bytes")
            require(before_user == [m.words(page, PAGE // 4) for page in (first, second)], "read modified user data")
            p.seed(p.scratch + 1, payload[::-1])
            written = p.call_exl("copyToUser", (p.directory, 7, BASE + PAGE - 3, p.scratch + 1, len(payload)), 0)
            require(p.bytes(first + PAGE - 3, 3) + p.bytes(second, 8) == payload[::-1], "cross-page write copied wrong bytes")
            require(p.bytes(first + PAGE - 4, 1) == b"\0" and p.bytes(second + 8, 1) == b"\0", "copy overran user buffer")
            results.append(dict(case="boundary_valid", complete=True, copies=[copied, written], noncontiguous_frames=True))
            p.ok("unmapPage", p.directory, 7, BASE + PAGE)
            results.append(p.reject(BASE + PAGE - 1, 2, "boundary_unmapped"))
            p.ok("mapPage", p.directory, 7, BASE + PAGE, second, 0x13)
            before = p.snapshot()
            read = p.call_exl("copyFromUser", (p.directory, 7, p.scratch + 1, BASE + PAGE - 1, 2), 0)
            after_read = p.snapshot()
            written = p.call_exl("copyToUser", (p.directory, 7, BASE + PAGE - 1, p.scratch + 1, 2), EFAULT)
            require(before[:2] == after_read[:2] and p.snapshot() == after_read,
                    "readonly-page case changed user memory or partially copied on error")
            results.append(dict(case="boundary_readonly", complete=True, copies=[read, written]))
            # mapPage deliberately forbids supervisor leaves in the user window.
            # Clear only U as an explicit negative fixture in this temporary
            # machine, then run real CPU invalidation (never rely on monitor
            # writes flushing the TLB). A real supervisor memcpy must succeed
            # at the SAME VA that both user-copy helpers subsequently reject.
            table = m.words(p.directory + (BASE + PAGE) // SUPER * 4, 1)[0] & ~4095
            slot = table + (BASE + PAGE) // PAGE % 1024 * 4
            original = m.words(slot, 1)[0]
            p.write(slot, original & ~0x10)
            p.call("mmu__mmuInvalidate", invalidate=True)
            p.call("memcpy", p.scratch + 16, BASE + PAGE, 4)
            require(p.bytes(p.scratch + 16, 4) == p.bytes(second, 4),
                    "supervisor could not read the non-U fixture VA")
            results.append(p.reject(BASE + PAGE - 1, 2, "boundary_supervisor_leaf"))
            p.write(slot, original)
            p.call("mmu__mmuInvalidate", invalidate=True)
            for address, size, name in ((0, 1, "null"), (first, 1, "supervisor"),
                                        (BASE, 0xFFFFFFFF, "length_overflow"),
                                        (0xFFFFFFFC, 8, "address_wrap"), (END - 1, 2, "user_end")):
                results.append(p.reject(address, size, name))
            # Reaching a new expected trap after all EXL copies also proves the
            # CPU remained live. Finish using the image's existing HLT word.
            p.bridge()
            halt = symbols["taskKernelResume.halt"]
            p.prepare(halt)
            p.cmd("del all")
            m.connection.sendall(b"c\n")
            process.wait(timeout=timeout)
            stdout.seek(0)
            stderr.seek(0)
            uart, emulator_output = stdout.read(), stderr.read()
            require(process.returncode == 0 and "PANIC" not in uart and "double fault" not in emulator_output.lower(),
                    f"unexpected CPU termination: {process.returncode}\n{uart}\n{emulator_output}")
            return dict(cases=results, calls=p.calls, exit_code=process.returncode,
                        exl_verified=True, no_double_fault=True)
        finally:
            log_dir.mkdir(parents=True, exist_ok=True)
            (log_dir / "buffers.monitor.txt").write_text("\n".join(p.log))
            stdout.seek(0)
            stderr.seek(0)
            (log_dir / "buffers.uart.txt").write_text(stdout.read())
            (log_dir / "buffers.emulator.txt").write_text(stderr.read())
            (log_dir / "partial_cases.json").write_text(json.dumps(results, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance/user_buffers_cpu")
    args = parser.parse_args()
    require(args.timeout > 0, "timeout must be positive")
    paths = dict(image=args.image.resolve(), map=args.map.resolve(), emulator=args.emulator.resolve(), rom=args.rom.resolve())
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    symbols = symbols_from_map(args.map)
    report = dict(complete=False, method="ready CPU copy helpers inside EXL=1; no build",
                  artifacts={name: dict(path=str(paths[name]), sha256=digest) for name, digest in hashes.items()},
                  missing_symbols=missing_helpers(symbols))
    args.log_dir.mkdir(parents=True, exist_ok=True)
    report_path = args.log_dir / "results.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    if report["missing_symbols"]:
        print("BLOCKED: ready image lacks " + ", ".join(report["missing_symbols"]))
        return 2
    try:
        check_layout(symbols)
        data = args.image.read_bytes()
        magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
        require(magic == 0x424D5257 and sectors > 0 and reserved == 0 and len(data) >= sectors * 512 and
                entry + 0x10000 == symbols["kernelStart"] and
                symbols["__image_end"] <= 0x10000 + sectors * 512 <= symbols["__bss_start"], "invalid ready image/map")
        report.update(execute(data, symbols, paths, args.timeout, args.log_dir))
        require(all(hashlib.sha256(path.read_bytes()).hexdigest() == hashes[name] for name, path in paths.items()),
                "original ready artifacts changed")
        report["complete"] = True
        for case in report["cases"]:
            print("PASS " + case["case"])
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        print(f"FAIL buffer CPU probe: {error}")
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
