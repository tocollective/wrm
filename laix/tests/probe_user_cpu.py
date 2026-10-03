#!/usr/bin/env python3
"""Check Task/IRET/syscalls/faults on a ready CPU image. Never build code.

Natural boot executes the complete image, including its user blob. Other
cases change saved contexts/data in temporary machines and use the existing
kernel APIs. Instruction fixtures are copies of ready-image instructions,
loaded by CPU memcpy before mapPage grants X; no instructions are generated.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from probe_boot import Monitor, ready_monitor, require, disassemble
from probe_mmu_cpu import CpuProbe, symbols_from_map
from probe_unexpected_traps import LAYOUT, instruction, locations
from run_ready import ROOT, check_layout
from test_kernel import LAIX, check_m

CODE, DATA, FIXTURE = 0x40000000, 0x40001000, 0x40002000
PAGE, EXL, PUM, UM = 4096, 16, 8, 4
USER_STATUS = UM | PUM  # IRET retains the saved PUM bit while setting UM.
CASES = ("natural", "registers", "sp_zero", "sp_unaligned", "sp_unmapped",
         "kernel_read", "kernel_write", "nx", "privileged", "supervisor_fault", "supervisor_guard")
COPY_SYMBOLS = {"copyFromUser", "copyToUser", "mmuUserBufferValid"}


def task_offsets():
    # Type/layout checking only; no code generation, assembly or linking.
    module = check_m(LAIX / "src/task/task.m")[0]
    task = module.scope["Task"].type
    return {field.name: field.offset for field in task.fields}


def check_user_context(before, after, result=None, trapped=False):
    require(before["status"] == USER_STATUS, "instruction did not start in UM with IRQ/EXL off")
    require(after["status"] == (EXL | PUM if trapped else USER_STATUS), "wrong CPU trap/return mode")
    for i in range(32):
        expected = result if i == 1 and result is not None else before[f"r{i}"]
        require(after[f"r{i}"] == expected, f"CPU changed r{i}")
    require(after["fcsr"] == before["fcsr"], "CPU changed FCSR")
    require(after["ptbr"] == before["ptbr"], "CPU changed task PTBR")
    if not trapped:
        require(after["pc"] == before["pc"] + 4, "syscall did not resume exactly at EPC+4")


class TaskProbe(CpuProbe):
    def __init__(self, monitor, data, symbols, timeout, offsets, natural=False):
        self.offsets = offsets
        if natural:
            self.m, self.data, self.s, self.timeout = monitor, data, symbols, timeout
            self.log, self.calls = [monitor.receive()], []
            _, self.dispatch_return = locations(data, symbols)
        else:
            super().__init__(monitor, data, symbols, timeout)
        self.extra_pages = []
        self.observations = []

    def stop(self, pc):
        self.cmd("del all")
        self.log.append(self.m.stop_at(pc))
        return self.regs()

    def field_address(self, name):
        return self.s["firstTask"] + self.offsets[name]

    def field(self, name):
        return self.m.words(self.field_address(name), 1)[0]

    def leaf(self, directory, virtual):
        entry = self.m.words(directory + (virtual >> 22) * 4, 1)[0]
        require(entry & 1 and entry & 14 == 0, "expected a valid 4 KiB parent")
        return self.m.words((entry & ~4095) + (virtual >> 12 & 1023) * 4, 1)[0]

    def capture_task(self):
        self.directory = self.field("directory")
        self.pages = self.m.words(self.s["task__taskPages"], 3)
        require(self.field("id") == 1 and self.field("state") in (1, 2), "task was not prepared")
        require(self.field("userCode") == CODE and self.field("userData") == DATA,
                "ready task layout does not match this probe")
        for va, page, flags in ((CODE, self.pages[0], 0x1B), (DATA, self.pages[1], 0x17),
                                (0xBFFFF000, self.pages[2], 0x17)):
            require(self.leaf(self.directory, va) & ~0x60 == page | flags,
                    "task leaf has wrong frame/permissions")
        require(self.field("kernelStackBottom") == self.s["taskKernelStackBottom"] and
                self.field("kernelStackTop") == self.s["taskKernelStackTop"], "wrong trusted task stack")

    def set_context(self, pc, sp, registers=None):
        values = {f"R{i}": 0xA5010000 + i * 0x101 for i in range(1, 32)}
        values.update(EPC=pc, STATUS=EXL | PUM, FCSR=0x61, R30=sp)
        values.update(registers or {})
        for name, value in values.items():
            self.write(self.field_address("context") + LAYOUT["TF_" + name], value)

    def enter(self, pc):
        # call() stops before a supervisor BREAK; get a fresh trap frame before
        # redirecting the next real IRET into taskStart.
        self.bridge()
        self.prepare(self.s["taskStart"])
        regs = self.stop(pc)
        require(regs["status"] == USER_STATUS and self.field("state") == 2, "taskStart did not enter RUNNING UM")
        require(regs["ptbr"] == self.directory | 1, "taskStart did not activate task root")
        return regs

    def frame_words(self, frame):
        return self.m.words(frame, LAYOUT["TF_SIZE"] // 4)

    def check_frame(self, frame, before, cause, epc, result=None, badaddr=None):
        bottom, top = self.s["taskKernelStackBottom"], self.s["taskKernelStackTop"]
        require(bottom < frame and frame + LAYOUT["TF_SIZE"] == top, "trap is not on the task kernel stack")
        saved = self.frame_words(frame)
        for i in range(32):
            expected = result if i == 1 and result is not None else before[f"r{i}"]
            require(saved[i] == expected, f"saved frame changed r{i}")
        for name, expected in (("EPC", epc), ("CAUSE", cause), ("STATUS", EXL | PUM),
                               ("FCSR", before["fcsr"]), ("PTBR", before["ptbr"])):
            require(saved[LAYOUT["TF_" + name] // 4] == expected, f"wrong saved {name}")
        if badaddr is not None:
            require(saved[LAYOUT["TF_BADADDR"] // 4] == badaddr, "wrong saved BADADDR")
        return saved

    def returning_syscall(self, before, result):
        trapped = self.stop(self.s["trapEntry"])
        check_user_context(before, trapped, trapped=True)
        require(trapped["cause"] == 12 and trapped["epc"] == before["pc"], "wrong SYSCALL entry")
        dispatched = self.stop(self.dispatch_return)
        saved = self.check_frame(dispatched["r30"], before, 12, before["pc"] + 4, result)
        require(self.frame_words(self.field_address("context")) == saved, "TCB did not save syscall context")
        require(self.m.words(0x1FF0, 3) == [self.s["taskKernelStackTop"],
                                          self.s["taskKernelStackBottom"], self.s["taskKernelStackTop"]],
                "entry words do not select the trusted task stack")
        returned = self.stop(before["pc"] + 4)
        check_user_context(before, returned, result)
        self.observations.append(dict(kind="syscall", epc=f"{before['pc']:08X}",
                                      user_sp=f"{before['r30']:08X}", result=f"{result:08X}",
                                      frame=f"{dispatched['r30']:08X}", fcsr=f"{before['fcsr']:08X}"))
        return returned

    def terminal(self, before, state, code, cause, badaddr=None):
        trapped = self.stop(self.s["trapEntry"])
        check_user_context(before, trapped, trapped=True)
        require(trapped["cause"] == cause and trapped["epc"] == before["pc"], "wrong terminal CPU trap")
        if badaddr is not None:
            require(trapped["badaddr"] == badaddr, "wrong terminal CPU BADADDR")
        # Observe the complete input frame before taskFinish switches roots.
        handler = self.stop(self.s["trapDispatch"])
        frame = handler["r1"]
        saved = self.check_frame(frame, before, cause, before["pc"], badaddr=badaddr)
        if cause == 12:
            saved[LAYOUT["TF_EPC"] // 4] += 4
        resumed = self.stop(self.s["taskKernelResume"])
        require(resumed["status"] == 0 and resumed["r30"] == self.s["kernelStackTop"],
                "terminal IRET did not restore the trusted supervisor stack/mode")
        require(resumed["ptbr"] != before["ptbr"] and resumed["ptbr"] & 1, "task directory is still active")
        kernel_root = self.m.words(self.s["mmu__kernelPageDirectory"], 1)[0]
        require(resumed["ptbr"] == kernel_root | 1, "wrong resumed kernel directory")
        require(all(resumed[f"r{i}"] == 0 for i in range(32) if i != 30) and resumed["fcsr"] == 0,
                "kernel continuation inherited user register values")
        require(self.field("state") == state and self.field("exitCode") == code & 0xFFFFFFFF,
                "wrong terminal task state/code")
        require(self.frame_words(self.field_address("context")) == saved, "wrong terminal TCB context")
        require(self.m.words(0x1FF0, 3) == [self.s["kernelStackTop"], self.s["kernelStackBottom"],
                                          self.s["kernelStackTop"]], "kernel entry words were not restored")
        held = [self.directory] + self.pages + self.extra_pages
        refs = self.m.words(self.s["memory__pageReferences"], 1)[0]
        purposes = self.m.words(self.s["memory__pagePurposes"], 1)[0]
        require(all(self.m.words(refs + page // PAGE * 4, 1)[0] > 0 for page in held),
                "task pages were freed before leaving its stack")
        halted = self.stop(self.s["taskKernelResume.halt"])
        require(halted["status"] == 0 and halted["ptbr"] == resumed["ptbr"] and
                halted["r30"] == self.s["kernelStackTop"], "cleanup left the trusted context")
        require(self.field("directory") == 0 and self.m.words(self.s["task__taskPages"], 3) == [0, 0, 0],
                "cleanup retained task creation ledger")
        require(all(self.m.words(refs + page // PAGE * 4, 1) == [0] and
                    self.m.words(purposes + page // PAGE * 4, 1) == [0] for page in held),
                "cleanup did not release all task frames/root")
        self.observations.append(dict(kind="terminal", cause=cause, state=state, code=code,
                                      epc=f"{before['pc']:08X}", badaddr=f"{trapped['badaddr']:08X}",
                                      frame=f"{frame:08X}", kernel_ptbr=f"{resumed['ptbr']:08X}",
                                      deferred_cleanup=True))

    def fixture_page(self, sources):
        physical = self.call("allocPage", 1, 5)
        require(physical != 0, "could not allocate user instruction fixture")
        self.extra_pages.append(physical)
        offset = 0
        for source, size in sources:
            self.call("memcpy", physical + offset, source, size)
            offset += size
        require(offset <= PAGE, "fixture exceeds one page")
        self.ok("mapPage", self.directory, 1, FIXTURE, physical, 0x1B)
        return physical


def user_instructions(data, symbols):
    start, end = symbols["userCodeStart"], symbols["userCodeEnd"]
    instructions = [(pc, disassemble(instruction(data, pc), pc)) for pc in range(start, end, 4)]
    syscalls = [pc for pc, asm in instructions if asm == "syscall"]
    require(len(syscalls) == 3, "ready blob must contain two debug syscalls and exit")
    load = next(pc for pc, asm in instructions if asm == "lw r3, 0(r30)")
    store = next(pc for pc, asm in instructions if asm == "sw r3, 0(r1)")
    privileged = next(pc for pc in range(symbols["mmuSwitchAddressSpace"], symbols["mmuActivateKernel"], 4)
                      if disassemble(instruction(data, pc), pc).startswith("mtcr ptbr,"))
    register = int(disassemble(instruction(data, privileged), privileged).split("r")[-1])
    require(disassemble(instruction(data, syscalls[2] - 8), syscalls[2] - 8) == "addi r1, r0, 0" and
            disassemble(instruction(data, syscalls[2] - 4), syscalls[2] - 4) == "addi r9, r0, 1",
            "ready blob exit ABI does not match probe")
    return dict(syscalls=syscalls, load=load, store=store, privileged=privileged, register=register)


def run_case(case, data, symbols, emulator, rom, timeout, offsets, fixtures, log_dir):
    natural = case == "natural"
    with ready_monitor(data, emulator, rom, timeout, full_image=natural) as (m, process, stdout, stderr):
        p = TaskProbe(m, data, symbols, timeout, offsets, natural)
        try:
            if case in ("supervisor_fault", "supervisor_guard"):
                require(p.call("taskPrepare") == 1, "CPU taskPrepare failed before supervisor regression")
                if case == "supervisor_fault":
                    fault, _, _ = p.fatal(process, stdout, stderr, "trap-fault-test", 3, 0x1001,
                                          pc=symbols["memcpy.word"] + 4, registers={"R2": 0x1001})
                else:
                    fault, _, _ = p.fatal(process, stdout, stderr, "stack-guard-test", 10,
                                          symbols["kernelStackGuard"], store=True)
                return dict(case=case, observations=[fault], kernel_calls=p.calls, exit_code=process.returncode)
            if natural:
                # The original boot self-tests run with the new user dispatcher.
                for cause in (13, 13, 12, 12):
                    p.log.append(m.trap_return(symbols["trapEntry"], cause, data))
                first = p.stop(CODE)
                p.capture_task()
                require(first["status"] == USER_STATUS and p.field("state") == 2, "natural task did not enter UM")
                require(first["ptbr"] == p.directory | 1, "natural task has wrong PTBR")
                require(first["r1"] == DATA and first["r2"] == PAGE and first["r30"] == 0xC0000000 and
                        first["fcsr"] == 0 and all(first[f"r{i}"] == 0 for i in range(32) if i not in (1, 2, 30)),
                        "natural entry ABI mismatch")
                for syscall in fixtures["syscalls"][:2]:
                    before = p.stop(CODE + syscall - symbols["userCodeStart"])
                    require(m.words(p.pages[1], 1) == [1], "user blob did not execute its data store")
                    require(m.words(p.pages[2] + PAGE - 8, 1) == [1], "user blob did not execute stack store/load")
                    p.returning_syscall(before, 0)
                before = p.stop(CODE + fixtures["syscalls"][2] - symbols["userCodeStart"])
                p.terminal(before, 3, 0, 12)
            else:
                require(p.call("taskPrepare") == 1, "CPU taskPrepare failed")
                p.capture_task()
                if case in ("registers", "sp_zero", "sp_unaligned", "sp_unmapped"):
                    # Eight existing SYSCALL words, then the existing exit sequence.
                    p.fixture_page([(fixtures["syscalls"][0], 4)] * 8 + [(fixtures["syscalls"][2] - 8, 12)])
                    sp = {"sp_zero": 0, "sp_unaligned": 0xBFFFFFFD,
                          "sp_unmapped": 0xBFFFE000}.get(case, 0xC0000000)
                    p.set_context(FIXTURE, sp, {"R9": 0xFFFFFFFF})
                    before = p.enter(FIXTURE)
                    for index in range(8):
                        require(before["pc"] == FIXTURE + index * 4, "repeated syscall sequence skipped/repeated")
                        before = p.returning_syscall(before, 0xFFFFFFDA)
                    before = p.stop(FIXTURE + 8 * 4 + 8)
                    p.terminal(before, 3, 0, 12)
                else:
                    sentinel = m.words(0x1000, 1)[0]
                    if case == "kernel_read":
                        pc, cause, badaddr = CODE + fixtures["load"] - symbols["userCodeStart"], 9, 0x1000
                        p.set_context(pc, 0x1000)
                    elif case == "kernel_write":
                        pc, cause, badaddr = CODE + fixtures["store"] - symbols["userCodeStart"], 10, 0x1000
                        p.set_context(pc, 0xC0000000, {"R1": 0x1000, "R3": 0xDEADBEEF})
                    elif case == "nx":
                        pc, cause, badaddr = DATA, 8, DATA
                        require(m.words(p.pages[1], 1) == [0], "NX fixture is not HLT")
                        p.set_context(pc, 0xC0000000)
                    else:
                        p.fixture_page([(fixtures["privileged"], 4)])
                        pc, cause, badaddr = FIXTURE, 11, instruction(data, fixtures["privileged"])
                        p.set_context(pc, 0xC0000000, {f"R{fixtures['register']}": 0})
                    # Stop at the end of task restore: NX must fault on fetch
                    # and cannot be reached by an instruction breakpoint.
                    p.bridge()
                    p.prepare(symbols["taskStart"])
                    restore = p.stop(symbols["trapEntry.restore"])
                    require(restore["status"] == EXL, "first-task restore entered wrong mode")
                    frame = p.frame_words(p.field_address("context"))
                    before = {f"r{i}": frame[i] for i in range(32)}
                    before.update(status=USER_STATUS, pc=pc, fcsr=frame[LAYOUT["TF_FCSR"] // 4], ptbr=p.directory | 1)
                    p.terminal(before, 4, cause, cause, badaddr)
                    require(m.words(0x1000, 1) == [sentinel], "user fault damaged kernel boot info")
            p.cmd("del all")
            m.connection.sendall(b"c\n")
            process.wait(timeout=timeout)
            stdout.seek(0)
            stderr.seek(0)
            uart, emulator_output = stdout.read(), stderr.read()
            require(process.returncode == 0 and "PANIC" not in uart and "double fault" not in emulator_output.lower(),
                    f"task did not stop cleanly: exit={process.returncode}\n{uart}\n{emulator_output}")
            require("LA/IX: task 1 stopped, state=" in uart, "task cleanup diagnostic missing")
            if natural:
                require("LA/IX: TrapFrame and syscall self-tests passed\n" in uart and "U\n" in uart,
                        "natural boot/user output missing")
        finally:
            log_dir.mkdir(parents=True, exist_ok=True)
            (log_dir / f"{case}.monitor.txt").write_text("\n".join(p.log))
            stdout.seek(0)
            stderr.seek(0)
            (log_dir / f"{case}.uart.txt").write_text(stdout.read())
            (log_dir / f"{case}.emulator.txt").write_text(stderr.read())
    return dict(case=case, observations=p.observations, kernel_calls=p.calls, exit_code=process.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("map", type=Path)
    parser.add_argument("--emulator", type=Path, default=ROOT / "bin/wrm081632")
    parser.add_argument("--rom", type=Path, default=ROOT / "bin/firmware.rom")
    parser.add_argument("--timeout", type=float, default=20)
    parser.add_argument("--case", choices=CASES, action="append")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "laix/build/acceptance/user_cpu")
    args = parser.parse_args()
    require(args.timeout > 0, "timeout must be positive")
    paths = {"image": args.image.resolve(), "map": args.map.resolve(),
             "emulator": args.emulator.resolve(), "rom": args.rom.resolve()}
    hashes = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    symbols = symbols_from_map(args.map)
    check_layout(symbols)
    required = {"firstTask", "taskPrepare", "taskStart", "taskKernelResume", "taskKernelResume.halt",
                "taskKernelStackBottom", "taskKernelStackTop", "task__taskPages", "mmu__kernelPageDirectory",
                "memory__pageReferences", "memory__pagePurposes", "trapEntry.restore", "userCodeStart", "userCodeEnd"}
    require(required <= symbols.keys(), "ready map lacks Task/restore/cleanup symbols: " +
            ", ".join(sorted(required - symbols.keys())))
    data = args.image.read_bytes()
    magic, sectors, entry, reserved = struct.unpack_from("<4I", data)
    require(magic == 0x424D5257 and sectors > 0 and reserved == 0 and len(data) >= sectors * 512 and
            entry + 0x10000 == symbols["kernelStart"] and
            symbols["__image_end"] <= 0x10000 + sectors * 512 <= symbols["__bss_start"], "invalid ready image/map")
    offsets, fixtures = task_offsets(), user_instructions(data, symbols)
    selected = args.case or CASES
    report = dict(method="ready image CPU execution; saved contexts and copied existing instructions; no build",
                  artifacts={name: dict(path=str(paths[name]), sha256=digest) for name, digest in hashes.items()},
                  requested_cases=selected, complete=False, results=[],
                  buffer_cpu_check=dict(complete=False, missing_symbols=sorted(COPY_SYMBOLS - symbols.keys()),
                                        runner="probe_user_buffers_cpu.py"))
    args.log_dir.mkdir(parents=True, exist_ok=True)
    report_path = args.log_dir / "results.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    try:
        for case in selected:
            result = run_case(case, data, symbols, paths["emulator"], paths["rom"], args.timeout,
                              offsets, fixtures, args.log_dir)
            report["results"].append(result)
            report_path.write_text(json.dumps(report, indent=2) + "\n")
            print(f"PASS {case}", flush=True)
        require(all(hashlib.sha256(path.read_bytes()).hexdigest() == hashes[name] for name, path in paths.items()),
                "original ready artifacts changed during probe")
        report["complete"] = True
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        print(f"FAIL user CPU probe: {error}", flush=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    if report["buffer_cpu_check"]["missing_symbols"]:
        print("OPEN buffer CPU check: ready image lacks " + ", ".join(report["buffer_cpu_check"]["missing_symbols"]))
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
