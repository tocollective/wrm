"""Interpret the real entry instructions without assembly, linking or building.

The M dispatcher executes from its checked source AST. Hardware transitions
use synthetic instruction locations, not CPU pipeline or translated code.
"""

import re
import unittest

from test_kernel import LAIX, parse_asm, asm_constants
from source_m import SourceM, KernelPanic
import asm

# Synthetic address of the first parsed statement: labels are code_base + 4 * i.
CODE_BASE = 0x700000
# start.asm early UART routines and the register holding their continuation.
EARLY_ROUTINES = {"earlyTrapReport": "r13", "earlyField": "r12",
                  "earlyString": "r12", "earlyHex": "r12"}
EARLY_STOPS = ("earlyStop", "earlyPanic", "earlyTrapPanic")


class EntryMachine:
    def __init__(self, user, interrupted_sp, kernel_sp=0x92000, bottom=0x90000,
                 top=0x92000, cause=13):
        self.parser = parse_asm(LAIX / "src/trap.asm")
        self.code = self.parser.stmts
        self.constants = asm_constants(self.parser)
        self.labels = {label: i for i, st in enumerate(self.code) for label in st.labels}
        self.pc = self.labels["trapEntry"]
        self.regs = {f"r{i}": 0xA000 + i for i in range(32)}
        self.regs.update(r0=0, r30=interrupted_sp)
        self.original = dict(self.regs)
        self.control = {"status": 16 | 2 | 64 | (8 if user else 0), "epc": 0x800010,
                        "cause": cause, "badaddr": 0x1234, "fcsr": 0x61, "ptbr": 0x98001}
        self.initial_control = dict(self.control)
        self.memory = {self.constants[name]: value for name, value in (
            ("KERNEL_SP", kernel_sp), ("KERNEL_STACK_BOTTOM", bottom),
            ("KERNEL_STACK_TOP", top), ("TRAP_SAVED_R1", 0))}
        self.accesses = []
        self.writes = []
        self.frame = None
        self.stop = None
        self.symbols = {}
        self.selftest = False
        self.inject = None
        self.traps = []
        self.early = []  # simulated early UART output: (routine or label, value)
        self.memory[bottom] = self.constants["STACK_CANARY"]
        self.dispatch = SourceM(LAIX / "src/trap.m", self.memory)
        self.dispatcher = self.dispatch.call

    def symbol(self, name, scope=None):
        if name in self.symbols:
            return self.symbols[name]
        return CODE_BASE + 4 * self.labels[self.parser.qualify(name, scope)]

    def label_at(self, address):
        index = (address - CODE_BASE) // 4
        return next(label for label, i in self.labels.items() if i == index)

    def early_routine(self, name):
        """Records what a start.asm early routine prints and returns to its continuation."""
        if name == "earlyTrapReport":
            self.early.append((name, self.label_at(self.get("r1"))))
        elif name == "earlyField":
            self.early.append((self.label_at(self.get("r1")), self.get("r6")))
        else:
            raise AssertionError(f"unexpected early routine: {name}")
        self.pc = (self.get(EARLY_ROUTINES[name]) - CODE_BASE) // 4

    def entry_state(self, address):
        return self.constants["KERNEL_SP"] <= address <= self.constants["TRAP_SAVED_R1"]

    @staticmethod
    def register(name):
        return {"sp": "r30", "ra": "r31"}.get(name, name)

    def get(self, name):
        return self.regs[self.register(name)]

    def put(self, name, value):
        name = self.register(name)
        assert name != "r0"
        self.regs[name] = value & 0xFFFFFFFF

    def constant(self, expression):
        return asm.ExprParser(expression, self.constants.__getitem__).parse()

    def address(self, operand):
        match = re.fullmatch(r"(.+)\((\w+)\)", operand)
        address = (self.constant(match[1]) + self.get(match[2])) & 0xFFFFFFFF
        assert address % 4 == 0
        return address

    def run(self):
        for _ in range(30000):
            st = self.code[self.pc]
            if "earlyPanic" in st.labels:
                self.stop = "earlyPanic"
                return
            self.pc += 1
            op, a = st.op, st.args
            if op is None:
                continue
            if op == "li":
                self.put(a[0], self.constant(a[1]))
            elif op == "la":
                self.put(a[0], self.symbol(a[1], st.scope))
            elif op == "jr":
                self.pc = (self.get(a[0]) - CODE_BASE) // 4
            elif op == "mfcr":
                self.put(a[0], self.control[a[1]])
            elif op == "mtcr":
                self.control[a[0]] = self.get(a[1])
            elif op in ("andi", "ori", "addi"):
                left, right = self.get(a[1]), self.constant(a[2])
                self.put(a[0], {"andi": lambda: left & right,
                                "ori": lambda: left | right,
                                "addi": lambda: left + right}[op]())
            elif op == "mv":
                self.put(a[0], self.get(a[1]))
            elif op in ("lw", "sw"):
                address = self.address(a[1])
                self.accesses.append((op, address))
                if op == "sw":
                    self.memory[address] = self.get(a[0])
                    self.writes.append((address, self.get(a[0])))
                else:
                    self.put(a[0], self.memory[address])
            elif op == "j" and a[0] in EARLY_ROUTINES:
                self.early_routine(a[0])
            elif op == "j" and a[0] in EARLY_STOPS:
                self.stop = a[0]
                return
            elif op in ("j", "beqz", "bnez", "bltu", "bne"):
                taken = (op == "j" or op == "beqz" and self.get(a[0]) == 0 or
                         op == "bnez" and self.get(a[0]) != 0 or
                         op == "bltu" and self.get(a[0]) < self.get(a[1]) or
                         op == "bne" and self.get(a[0]) != self.get(a[1]))
                if taken:
                    self.pc = self.labels[self.parser.qualify(a[-1], st.scope)]
            elif op == "call":
                if a == ["main"]:
                    self.stop = "main"
                    return
                if a == ["trapExpect"]:
                    self.dispatch.call("trapExpect", self.get("r1"))
                elif a == ["trapBadStack"]:
                    self.stop = "trapBadStack"
                    self.bad_stack_call = (self.get("r1"), self.get("r2"), self.get("sp"))
                    self.dispatch.call("trapBadStack", self.get("r1"), self.get("r2"))
                    raise AssertionError("trapBadStack returned")
                else:
                    assert a == ["trapDispatch"]
                    self.frame = self.get("r1")
                    self.dispatcher("trapDispatch", self.frame)
                # A compiled M call may clobber these registers.
                for i in list(range(1, 10)) + [31]:
                    self.put(f"r{i}", 0xBAD000 + i)
                self.control["fcsr"] = 0
            elif op == "iret":
                if self.selftest:
                    status = self.control["status"]
                    self.control["status"] = ((status & ~(1 | 4 | 16 | 32)) |
                                              ((status & 2) >> 1) |
                                              ((status & 8) >> 1) |
                                              ((status & 64) >> 1))
                    if self.inject:
                        self.inject(self)
                    self.pc = self.control["epc"] // 4
                    continue
                self.stop = "iret"
                return
            elif op in ("break", "syscall"):
                assert self.selftest
                status = self.control["status"]
                self.control["status"] = ((status & ~(1 | 2 | 4 | 8 | 32 | 64)) | 16 |
                                          ((status & 1) << 1) | ((status & 4) << 1) |
                                          ((status & 32) << 1))
                self.control["epc"] = (self.pc - 1) * 4
                self.control["cause"] = 13 if op == "break" else 12
                self.traps.append(self.control["cause"])
                self.pc = self.labels["trapEntry"]
            elif op == "ret":
                self.stop = "ret"
                return
            else:
                raise AssertionError(f"unexpected entry instruction: {op}")
        raise AssertionError("entry did not terminate")


def future_user_handler(machine):
    """Stage 3 stand-in that completes a user BREAK/SYSCALL.

    These tests cover the entry path with user stacks; the real dispatcher
    still rejects every user trap (test_unexpected_* below).
    """
    c = machine.constants
    def handler(name, frame):
        assert name == "trapDispatch"
        if machine.memory[frame + c["TF_CAUSE"]] == c["CAUSE_SYSCALL"]:
            machine.memory[frame + c["TF_R1"]] = (-c["ERRNO_ENOSYS"]) & 0xFFFFFFFF
        machine.memory[frame + c["TF_EPC"]] += c["INSTRUCTION_BYTES"]
    return handler


def user_machine(*args, **kwargs):
    machine = EntryMachine(True, *args, **kwargs)
    machine.dispatcher = future_user_handler(machine)
    return machine


def expected_supervisor_machine(*args, **kwargs):
    machine = EntryMachine(False, *args, **kwargs)
    machine.dispatch.call("trapExpect", machine.control["cause"])
    return machine


class TrapEntryTests(unittest.TestCase):
    def check_context(self, machine, selected_sp):
        machine.run()
        self.assertEqual(machine.stop, "iret")
        self.assertEqual(machine.frame, selected_sp - machine.constants["TF_SIZE"])
        for i in range(32):
            slot = machine.frame + i * 4
            expected = machine.original[f"r{i}"]
            if i == 1 and machine.control["cause"] == 12:
                expected = (-38) & 0xFFFFFFFF
            self.assertEqual(machine.memory[slot], expected, f"saved r{i}")
            self.assertEqual(machine.regs[f"r{i}"], expected, f"restored r{i}")
        for name in ("status", "fcsr", "ptbr"):
            self.assertEqual(machine.control[name], machine.initial_control[name])
        self.assertEqual(machine.control["epc"], machine.initial_control["epc"] + 4)
        self.assertEqual(machine.accesses[-1], ("lw", machine.frame + 30 * 4))
        self.assertTrue(all(machine.entry_state(address) or machine.frame <= address < selected_sp
                            for _, address in machine.accesses))

    def test_user_sp_is_only_saved_never_dereferenced(self):
        # Unmapped, supervisor-only, unaligned and near-wrap user SP values.
        for sp in (0, 0x1000, 0x800000, 0x800003, 0xFFFFFFFF):
            for cause in (12, 13):
                with self.subTest(sp=hex(sp), cause=cause):
                    self.check_context(user_machine(sp, cause=cause), 0x92000)

    def test_supervisor_keeps_current_stack_ignoring_kernel_sp(self):
        machine = expected_supervisor_machine(0x91E00, kernel_sp=0)
        self.check_context(machine, 0x91E00)
        self.assertTrue(machine.dispatch.call("trapExpectationMet"))

    def test_current_task_stack_is_selected_instead_of_bootstrap_stack(self):
        self.check_context(user_machine(0x800003, kernel_sp=0xA3000,
                                        bottom=0xA1000, top=0xA3000), 0xA3000)

    def test_bad_trusted_stack_reports_from_static_frame_and_emergency_stack(self):
        for user in (False, True):
            for sp in (0, 0x90000, 0x902A0, 0x92008, 0x91FFF):
                with self.subTest(user=user, sp=hex(sp)):
                    # From user mode the rejected stack is KERNEL_SP, distinct
                    # from the interrupted (user) sp.
                    interrupted = 0x800000 if user else sp
                    machine = EntryMachine(user, interrupted, kernel_sp=sp)
                    with self.assertRaisesRegex(KernelPanic, "invalid kernel stack"):
                        machine.run()
                    c = machine.constants
                    self.assertEqual(machine.stop, "trapBadStack")
                    self.assertIsNone(machine.frame)  # no frame on either stack
                    emergency = machine.symbol("trapEmergencyFrame")
                    self.assertTrue(all(machine.entry_state(address) or
                                        emergency <= address < emergency + c["TF_SIZE"]
                                        for _, address in machine.accesses))
                    # The static frame holds the whole interrupted context.
                    for i in range(32):
                        self.assertEqual(machine.memory[emergency + 4 * i],
                                         machine.original[f"r{i}"], f"r{i}")
                    for field in ("epc", "status", "cause", "badaddr", "fcsr", "ptbr"):
                        self.assertEqual(machine.memory[emergency + c["TF_" + field.upper()]],
                                         machine.initial_control[field], field)
                    # The early line comes first and needs no stack or M code.
                    self.assertEqual(machine.early, [
                        ("earlyTrapReport", "badKernelStackMessage"),
                        ("badStackSpMessage", sp),
                        ("badStackScratchMessage", interrupted),
                        ("badStackBottomMessage", 0x90000),
                        ("badStackTopMessage", 0x92000),
                        ("badStackRaMessage", machine.original["r31"])])
                    self.assertEqual(machine.bad_stack_call,
                                     (emergency, sp, machine.symbol("trapEmergencyStackTop")))
                    self.assertEqual(machine.control["fcsr"], 0)

    def test_emergency_stack_is_static_aligned_and_separate(self):
        machine = EntryMachine(False, 0)
        c = machine.constants
        frame = machine.labels["trapEmergencyFrame"]
        stack = machine.labels["trapEmergencyStack"]
        top = machine.labels["trapEmergencyStackTop"]
        body = [(st.op, st.args) for st in machine.code[frame:top] if st.op]
        self.assertEqual(body, [(".space", ["TF_SIZE"]), (".space", ["TRAP_EMERGENCY_STACK_BYTES"])])
        self.assertLess(frame, stack)
        self.assertEqual(machine.code[frame - 1].op, ".align")
        self.assertEqual(machine.code[frame - 1].args, ["STACK_ALIGNMENT"])
        self.assertEqual(c["TF_SIZE"] % c["STACK_ALIGNMENT"], 0)
        self.assertEqual(c["TRAP_EMERGENCY_STACK_BYTES"] % c["STACK_ALIGNMENT"], 0)

    def test_real_dispatch_reports_fatal_frame_without_advancing_epc(self):
        for cause, badaddr in ((3, 0x1001), (10, 0x8F000)):
            with self.subTest(cause=cause):
                machine = EntryMachine(False, 0x91E00, cause=cause)
                machine.control["badaddr"] = badaddr
                with self.assertRaisesRegex(KernelPanic, "unexpected exception"):
                    machine.run()
                for field, value in (("CAUSE", cause), ("BADADDR", badaddr),
                                     ("EPC", machine.initial_control["epc"])):
                    self.assertEqual(machine.memory[machine.frame + machine.constants["TF_" + field]], value)

    def assert_rejected(self, machine, message):
        r1 = machine.original["r1"]
        with self.assertRaisesRegex(KernelPanic, message):
            machine.run()
        for field, value in (("EPC", machine.initial_control["epc"]), ("R1", r1)):
            self.assertEqual(machine.memory[machine.frame + machine.constants["TF_" + field]], value)

    def test_unexpected_supervisor_break_or_syscall_panics_without_skipping(self):
        for cause, armed, message in ((13, None, "unexpected breakpoint"),
                                      (12, None, "unexpected syscall"),
                                      (13, 12, "unexpected breakpoint"),
                                      (12, 13, "unexpected syscall")):
            with self.subTest(cause=cause, armed=armed):
                machine = EntryMachine(False, 0x91E00, cause=cause)
                if armed is not None:
                    machine.dispatch.call("trapExpect", armed)
                self.assert_rejected(machine, message)

    def test_unexpected_user_break_or_syscall_panics_even_when_armed(self):
        for cause, message in ((13, "unexpected breakpoint"), (12, "unexpected syscall")):
            with self.subTest(cause=cause):
                machine = EntryMachine(True, 0x800000, cause=cause)
                machine.dispatch.call("trapExpect", cause)
                self.assert_rejected(machine, message)
                self.assertFalse(machine.dispatch.call("trapExpectationMet"))

    def test_expectation_is_one_shot(self):
        machine = expected_supervisor_machine(0x91E00)
        machine.run()
        self.assertEqual(machine.stop, "iret")
        self.assertTrue(machine.dispatch.call("trapExpectationMet"))
        again = EntryMachine(False, 0x91E00)
        again.dispatch = machine.dispatch
        again.dispatcher = machine.dispatch.call
        again.dispatch.memory = again.memory
        self.assert_rejected(again, "unexpected breakpoint")

    def test_current_task_canary_is_checked(self):
        machine = EntryMachine(True, 0x800000, kernel_sp=0xA3000, bottom=0xA1000, top=0xA3000)
        machine.memory[0xA1000] = 0
        with self.assertRaisesRegex(KernelPanic, "canary damaged"):
            machine.run()

    def selftest_machine(self):
        machine = EntryMachine(False, 0x91E00)
        machine.pc = machine.labels["trapRegisterSelfTest"]
        machine.selftest = True
        machine.control["status"] = 0
        return machine

    def test_assembly_selftest_covers_break_syscall_and_preserves_caller(self):
        machine = self.selftest_machine()
        machine.run()
        self.assertEqual(machine.stop, "ret")
        self.assertEqual(machine.traps, [13, 12])
        self.assertEqual(machine.get("r1"), 0)
        for i in range(10, 32):
            self.assertEqual(machine.get(f"r{i}"), machine.original[f"r{i}"], f"r{i}")
        self.assertEqual(machine.control["fcsr"], machine.initial_control["fcsr"])
        self.assertEqual(machine.control["status"] & 1, 0)
        self.assertTrue(machine.dispatch.call("trapExpectationMet"))

    def test_assembly_selftest_detects_corrupted_tp_ra_fcsr_and_syscall_result(self):
        for register, failure in (("r28", 28), ("ra", 31), ("fcsr", 33), ("r1", 1)):
            with self.subTest(register=register):
                machine = self.selftest_machine()
                def corrupt(vm):
                    if vm.control["cause"] != 12:
                        return
                    if register == "fcsr":
                        vm.control["fcsr"] = 0
                    else:
                        vm.put(register, 0)
                machine.inject = corrupt
                machine.run()
                self.assertEqual(machine.stop, "ret")
                self.assertEqual(machine.get("r1"), failure)


if __name__ == "__main__":
    unittest.main()
