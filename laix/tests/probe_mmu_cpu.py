#!/usr/bin/env python3
"""Exercise MMU APIs and CPU faults in an existing image, without building.

The monitor edits only saved IRET contexts and fixture data in a temporary
machine. CPU executes the existing allocator/MMU/memcpy instructions. PTEs
are changed only by the kernel API. BREAK/IRET between calls do not flush TLB.
The MMU's executed FENCE/TLBI/PTBR instructions are traced. Original files remain
unchanged; user instruction fixtures are copies of existing executable bytes.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from probe_boot import Monitor, ready_monitor, require, disassemble
from probe_unexpected_traps import LAYOUT, instruction, locations
from run_ready import ROOT, check_layout, check_full_dump, field

VA, OLD_VA = 0x40000000, 0x40001000
RW, RO, RX = 0x17, 0x13, 0x1B


def symbols_from_map(path):
    return {m[2]: int(m[1], 16) for line in path.read_text().splitlines()
            if (m := re.fullmatch(r"([0-9A-Fa-f]{8})\s+(\S+)", line.strip()))}


def check_fault(uart, code, stage, cause, address, pc, user, registers):
    require(code == 254 and uart.count("LA/IX PANIC:") == 1 and
            "LA/IX PANIC: unexpected exception\n" in uart, "missing fatal page-fault dump")
    require(f"stage={stage} origin={'user' if user else 'supervisor'}\n" in uart,
            "wrong fault stage/origin")
    for name, expected in (("cause", cause), ("badaddr", address), ("epc", pc),
                           ("status", registers["status"]), ("ptbr", registers["ptbr"]),
                           ("fcsr", registers["fcsr"])):
        require(field(uart, name) == expected, f"wrong dumped {name}")
    for i in range(32):
        require(field(uart, f"r{i:02d}") == registers[f"r{i}"], f"wrong dumped r{i}")
    # User-origin dumps retain PUM; the regular ready runner checks supervisor.
    require(registers["status"] == 16 | (8 if user else 0), "wrong CPU fault status")
    if not user:
        check_full_dump(uart)
    require(registers["ptbr"] & 1, "fault happened with MMU disabled")


class CpuProbe:
    def __init__(self, monitor, data, symbols, timeout):
        self.m, self.data, self.s = monitor, data, symbols
        self.timeout = timeout
        self.log, self.calls = [], []
        traps, self.dispatch_return = locations(data, symbols)
        self.break_pc = traps[13]
        self.trace_points = {}
        for pc in range(symbols["mmu__mmuInvalidate"], symbols["trapLayoutValid"], 4):
            asm = disassemble(instruction(data, pc), pc)
            if asm in ("fence", "tlbi.all") or asm.startswith("mtcr ptbr,"):
                self.trace_points[pc] = asm
        self.log.append(monitor.receive())
        self.log.append(monitor.stop_at(symbols["trapEntry"]))
        first = self.regs()
        require(first["cause"] == 13 and first["status"] == 16, "unexpected first boot trap")
        self.to_frame()
        self.scratch = self.call("allocPage", 99, 2)
        require(self.scratch != 0, "could not allocate probe data")

    def cmd(self, command):
        try:
            result = self.m.command(command)
        except (ValueError, OSError) as error:
            raise ValueError(f"{error}; command={command}; recent monitor:\n" + "\n".join(self.log[-8:])) from error
        self.log.append(command + "\n" + result)
        return result

    def regs(self):
        return Monitor.registers(self.cmd("r"))

    def write(self, address, value):
        self.cmd(f"wp 0x{address:X} 0x{value & 0xFFFFFFFF:X}")
        require(self.m.words(address, 1) == [value & 0xFFFFFFFF], "fixture write failed")

    def to_frame(self):
        self.cmd("del all")
        self.log.append(self.m.stop_at(self.dispatch_return))
        self.frame = self.regs()["r30"]
        require(self.m.words(self.frame + LAYOUT["TF_EPC"], 1)[0] != self.break_pc,
                "expected BREAK did not advance EPC")

    def prepare(self, pc, args=(), registers=None, user=False):
        changes = {"EPC": pc, "STATUS": 16 | (8 if user else 0), "R31": self.break_pc}
        changes.update({f"R{i}": value for i, value in enumerate(args, 1)})
        changes.update(registers or {})
        if user:
            changes["R30"] = 0xFFFFFFF8
        for name, value in changes.items():
            self.write(self.frame + LAYOUT["TF_" + name], value)
        self.cmd("del all")
        for address in self.trace_points:
            require("at most" not in self.cmd(f"b 0x{address:X}"), "monitor breakpoint capacity exceeded")
        for address in (self.s['trapEntry'], self.break_pc):
            require("at most" not in self.cmd(f"b 0x{address:X}"), "monitor breakpoint capacity exceeded")

    def execute(self, expected_pc):
        events = []
        for _ in range(500):
            self.cmd("c")
            regs = self.regs()
            pc = regs["pc"]
            if pc == expected_pc:
                return regs, events
            require(pc in self.trace_points, f"unexpected CPU stop at {pc:08X}: {regs}")
            asm = self.trace_points[pc]
            if asm == "tlbi.all":
                require(events and events[-1]["instruction"] == "fence",
                        "CPU did not execute FENCE before TLBI.ALL")
            if asm.startswith("mtcr ptbr,"):
                require(events and events[-1]["instruction"] == "tlbi.all",
                        "CPU changed PTBR before TLBI.ALL")
            self.cmd("s 1")
            after = self.regs()
            events.append(dict(pc=f"{pc:08X}", instruction=asm,
                               ptbr_before=f"{regs['ptbr']:08X}", ptbr_after=f"{after['ptbr']:08X}"))
        raise ValueError("too many traced instructions")

    def call(self, name, *args, invalidate=False):
        if hasattr(self, "at_return"):
            self.write(self.s["trap__expectedTrap"], 13)
            self.cmd("del all")
            self.log.append(self.m.stop_at(self.s["trapEntry"]))
            require(self.regs()["cause"] == 13, "call bridge raised another trap")
            self.to_frame()
        self.prepare(self.s[name], args)
        regs, events = self.execute(self.break_pc)
        require(regs["status"] == 0, "API returned outside supervisor mode/with IRQs enabled")
        if invalidate:
            require(any(e["instruction"] == "tlbi.all" for e in events),
                    f"{name} did not execute TLBI.ALL")
        self.calls.append(dict(function=name, arguments=[f"{a:08X}" for a in args],
                               result=f"{regs['r1']:08X}", events=events))
        self.at_return = True
        return regs["r1"]

    def ok(self, name, *args):
        require(self.call(name, *args, invalidate=True) == 1, f"{name} rejected valid probe operation")

    def space(self, owner):
        directory = self.call("mmuCreateAddressSpace", owner)
        require(directory != 0, "could not create address space")
        return directory

    def page(self, owner, value=0):
        physical = self.call("allocPage", owner, 5)
        require(physical != 0, "could not allocate user page")
        self.write(physical, value)
        return physical

    def read(self, virtual, expected):
        self.write(self.scratch, 0xBAD)
        self.call("memcpy", self.scratch, virtual, 4)
        require(self.m.words(self.scratch, 1) == [expected], "CPU read stale/wrong mapping")

    def store(self, virtual, value):
        self.write(self.scratch, value)
        self.call("memcpy", virtual, self.scratch, 4)

    def bridge(self):
        self.write(self.s["trap__expectedTrap"], 13)
        self.cmd("del all")
        self.log.append(self.m.stop_at(self.s["trapEntry"]))
        require(self.regs()["cause"] == 13, "unexpected bridge trap")
        self.to_frame()

    def fatal(self, process, stdout, stderr, stage, cause, address, pc=None, user=False,
              registers=None, store=False):
        self.bridge()
        stage_bytes = (stage.encode() + b"\0").ljust(64, b"\0")
        for offset in range(0, len(stage_bytes), 4):
            self.write(self.scratch + 64 + offset, struct.unpack_from("<I", stage_bytes, offset)[0])
        self.write(self.s["panic__panicStage"], self.scratch + 64)
        if pc is None:
            # memcpy's aligned word loop is an actual CPU LW followed by SW.
            args = (address, self.scratch, 4) if store else (self.scratch, address, 4)
            pc = self.s["memcpy"]
            fault_pc = self.s["memcpy.word"] + (8 if store else 4)
        else:
            args, fault_pc = (), address if cause == 8 else pc
        self.prepare(pc, args, registers, user)
        regs, events = self.execute(self.s["trapEntry"])
        require((regs["cause"], regs["badaddr"], regs["epc"]) == (cause, address, fault_pc),
                f"wrong CPU fault: {regs}")
        self.cmd("del all")
        self.m.connection.sendall(b"c\n")
        process.wait(timeout=self.timeout)
        stdout.seek(0)
        stderr.seek(0)
        uart, emulator_output = stdout.read(), stderr.read()
        check_fault(uart, process.returncode, stage, cause, address, fault_pc, user, regs)
        return dict(cause=cause, badaddr=f"{address:08X}", epc=f"{fault_pc:08X}",
                    origin="user" if user else "supervisor", ptbr=f"{regs['ptbr']:08X}",
                    exit_code=process.returncode), uart, emulator_output


def run_case(case, data, symbols, emulator, rom, timeout, log_dir):
    with ready_monitor(data, emulator, rom, timeout) as (m, process, stdout, stderr):
        p = CpuProbe(m, data, symbols, timeout)
        if case in ("remap", "unmap_table", "unmap_leaf", "protect", "upgrade", "asid",
                    "user_text_write", "user_data_exec", "window_write", "window_restore"):
            d = p.space(7)
            a, b = p.page(7, 0xA0), p.page(7, 0xB0)
            p.ok("mapPage", d, 7, VA, a, RW)
            if case in ("remap", "unmap_leaf"):
                p.ok("mapPage", d, 7, OLD_VA, b, RW)
            if case == "asid":
                other = p.space(8)
                c = p.page(8, 0xC0)
                p.ok("mapPage", d, 7, OLD_VA, a, RW)
                p.ok("mapPage", other, 8, VA, c, RW)
            p.ok("mmuSwitchAddressSpace", d, 7, 7)
            table_slot = d + (VA >> 22) * 4
            original_table = m.words(table_slot, 1)[0] & ~4095
            require(original_table != 0, "map did not publish a table")
            p.read(VA, 0xA0)
            p.store(VA, 0xA1)
            require(m.words(a, 1) == [0xA1], "CPU store missed mapped frame")
            if case == "remap":
                p.ok("unmapPage", d, 7, VA)
                require(m.words(table_slot, 1)[0] & ~4095 == original_table,
                        "unmap discarded a table with a live sibling")
                p.ok("mapPage", d, 7, VA, b, RW)
                require(m.words(table_slot, 1)[0] & ~4095 == original_table,
                        "remap did not reuse the live table")
                p.read(VA, 0xB0)
                p.store(VA, 0xB1)
                require(m.words(a, 1) == [0xA1] and m.words(b, 1) == [0xB1], "remap wrote old frame")
                p.ok("unmapPage", d, 7, OLD_VA)
                p.ok("unmapPage", d, 7, VA)
                require(m.words(table_slot, 1) == [0] and
                        p.call("physicalPageAvailable", original_table) == 1,
                        "last unmap did not release the table")
                p.ok("mapPage", d, 7, VA, a, RW)
                p.read(VA, 0xA1)
            if case == "asid":
                p.read(OLD_VA, 0xA1)
                p.ok("mmuActivateKernel")
                p.ok("mmuSwitchAddressSpace", other, 8, 7)
                p.read(VA, 0xC0)
                require(m.words(a, 1) == [0xA1], "ASID replacement touched old owner")
                result = p.fatal(process, stdout, stderr, "asid-reuse-test", 9, OLD_VA)
            elif case == "protect":
                p.ok("setPagePermissions", d, 7, VA, RO)
                result = p.fatal(process, stdout, stderr, "mmu-protect-test", 10, VA, store=True)
            elif case == "upgrade":
                p.ok("setPagePermissions", d, 7, VA, RO)
                p.read(VA, 0xA1)
                p.ok("setPagePermissions", d, 7, VA, RW)
                p.store(VA, 0xA2)
                require(m.words(a, 1) == [0xA2], "CPU rejected RO to RW upgrade")
                p.ok("unmapPage", d, 7, VA)
                result = p.fatal(process, stdout, stderr, "mmu-upgrade-test", 9, VA)
            elif case in ("user_text_write", "window_write", "window_restore"):
                # Copy existing memcpy bytes as a loader would, then revoke W.
                p.call("memcpy", a, symbols["memcpy"], symbols["memcpy.done"] + 4 - symbols["memcpy"])
                p.ok("setPagePermissions", d, 7, VA, RX)
                pte = m.words((m.words(d + (a >> 22) * 4, 1)[0] & ~4095) + (a >> 12 & 1023) * 4, 1)[0]
                require(pte & 0x1F == 3, "physical window kept W while X exists")
                if case == "user_text_write":
                    store_pc = VA + symbols["memcpy.word"] + 8 - symbols["memcpy"]
                    result = p.fatal(process, stdout, stderr, "user-text-write-test", 10, VA,
                                     pc=store_pc, user=True, registers={"R4": VA, "R5": 0})
                elif case == "window_write":
                    result = p.fatal(process, stdout, stderr, "window-write-test", 10, a, store=True)
                else:
                    p.ok("setPagePermissions", d, 7, VA, RW)
                    p.store(a, 0xA2)
                    require(m.words(a, 1) == [0xA2], "physical-window W was not restored")
                    p.ok("unmapPage", d, 7, VA)
                    result = p.fatal(process, stdout, stderr, "window-restore-test", 9, VA)
            elif case == "user_data_exec":
                p.store(VA, 0)  # HLT if incorrectly executable.
                result = p.fatal(process, stdout, stderr, "user-data-exec-test", 8, VA, pc=VA, user=True)
            else:
                p.ok("unmapPage", d, 7, VA)
                if case == "unmap_leaf":
                    require(m.words(table_slot, 1)[0] & ~4095 == original_table,
                            "unmap did not keep its live sibling table")
                    p.read(OLD_VA, 0xB0)
                else:
                    require(m.words(table_slot, 1) == [0] and
                            p.call("physicalPageAvailable", original_table) == 1,
                            "unmap did not release its empty table")
                result = p.fatal(process, stdout, stderr, "mmu-unmap-test", 9, VA)
        elif case in ("text_write", "rodata_write"):
            target = symbols["main"] if case == "text_write" else symbols["__start_rodata"]
            result = p.fatal(process, stdout, stderr, case.replace("_", "-") + "-test", 10, target, store=True)
        elif case == "data_exec":
            # RET is an existing indirect jump; target zero is an NX data word.
            p.write(p.scratch, 0)
            result = p.fatal(process, stdout, stderr, "data-exec-test", 8, p.scratch,
                             pc=symbols["memcpy.done"], registers={"R31": p.scratch})
        else:
            raise ValueError(f"unknown probe case: {case}")
        outcome, uart, emulator_output = result
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / f"{case}.uart.txt").write_text(uart)
    (log_dir / f"{case}.emulator.txt").write_text(emulator_output)
    (log_dir / f"{case}.monitor.txt").write_text("\n".join(p.log))
    return dict(case=case, calls=p.calls, fault=outcome)


CASES = ("remap", "unmap_table", "unmap_leaf", "protect", "upgrade", "asid",
         "text_write", "rodata_write", "data_exec", "user_text_write", "user_data_exec",
         "window_write", "window_restore")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance/mmu_cpu")
    args = parser.parse_args()
    require(args.timeout > 0, "timeout must be positive")
    symbols = symbols_from_map(args.map)
    check_layout(symbols)
    paths = dict(image=args.image, map=args.map, emulator=args.emulator, rom=args.rom)
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    data = args.image.read_bytes()
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    require(magic == 0x424D5257 and reserved == 0 and sectors > 0 and len(data) >= sectors * 512 and
            entry + 0x10000 == symbols["kernelStart"] and
            symbols["__image_end"] <= 0x10000 + sectors * 512 <= symbols["__bss_start"], "invalid ready image")
    results = []
    selected = args.case or CASES
    report = dict(method="ready CPU functions, saved IRET contexts, data fixtures; no build",
                  artifacts={name: dict(path=str(paths[name].resolve()), sha256=digest)
                             for name, digest in hashes.items()}, requested_cases=selected,
                  complete=False, results=results)
    args.log_dir.mkdir(parents=True, exist_ok=True)
    (args.log_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    for case in selected:
        outcome = run_case(case, data, symbols, args.emulator.resolve(), args.rom.resolve(),
                           args.timeout, args.log_dir)
        results.append(outcome)
        print(f"PASS {case}: CAUSE={outcome['fault']['cause']}, EPC={outcome['fault']['epc']}, exit 254", flush=True)
        (args.log_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    require(all(hashlib.sha256(path.read_bytes()).hexdigest() == hashes[name]
                for name, path in paths.items()), "original artifact changed")
    report["complete"] = True
    (args.log_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
