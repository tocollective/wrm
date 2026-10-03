"""Task preparation and first restore from checked sources; never build code.

Blob bytes and linker addresses are fixtures. M and assembly interpretation
checks permissions, rollback and IRET operands, not CPU execution in UM.
"""

import unittest

from test_kernel import LAIX, parse_asm
from test_memory import SECTIONS
from test_trap_entry import EntryMachine
from source_m import SourceM, KernelPanic, LAYOUT

PAGE = 4096
USER_CODE, USER_DATA = 0x40000000, 0x40001000
STACK_BOTTOM, STACK_TOP, STACK_GUARD = 0xBFFFF000, 0xC0000000, 0xBFFFE000


class TaskEntered(Exception):
    pass


class TaskM(SourceM):
    def __init__(self, ram=0x100000):
        super().__init__(LAIX / "src/trap/trap.m")
        self.task_type = self.decls["firstTask"].sym.type
        self.addresses.update(userCodeStart=0x14000, userCodeEnd=0x1401C,
                              kernelStackBottom=0x91000, taskKernelResume=0x14100)
        # Arbitrary fixture words, never generated machine instructions.
        self.blob = [0x100 + i for i in range(7)]
        for i, word in enumerate(self.blob):
            self.memory[self.addresses["userCodeStart"] + 4 * i] = word
        self.memory[0xFD000004] = 0
        self.entered = None
        self.fail_mapping = None
        self.mapping_calls = 0
        assert self.call("memoryInit", ram)
        assert self.call("mmuInit")
        self.kernel_root = self.ptbr & ~4095
        self.events.clear()

    def field_address(self, field):
        return self.addresses["firstTask"] + self.task_type.field(field).offset

    def field(self, field):
        return self.memory[self.field_address(field)]

    def pages(self):
        return [self.memory[self.addresses["taskPages"] + 4 * i] for i in range(3)]

    def free_pages(self):
        return [address for address in range(self.globals["kernelReservedEnd"],
                                             self.globals["kernelRamEnd"], PAGE)
                if self.call("physicalPageAvailable", address)]

    def call(self, name, *args):
        if name == "mapPage":
            self.mapping_calls += 1
            if self.mapping_calls == self.fail_mapping:
                return False
        if name == "trapRestoreFrame":
            self.entered = args[0]
            self.events.append(("entry", [args[0]]))
            raise TaskEntered()
        return super().call(name, *args)


class TaskTests(unittest.TestCase):
    def running_task(self):
        vm = TaskM()
        self.assertTrue(vm.call("taskPrepare"))
        with self.assertRaises(TaskEntered):
            vm.call("taskStart")
        return vm

    def user_trap(self, vm, cause=12, number=0, arg=65, sp=0):
        machine = EntryMachine(True, sp, kernel_sp=vm.field("kernelStackTop"),
            bottom=vm.field("kernelStackBottom"), top=vm.field("kernelStackTop"), cause=cause)
        machine.memory, machine.dispatcher = vm.memory, vm.call
        machine.control["ptbr"] = vm.ptbr
        machine.put("r9", number)
        machine.put("r1", arg)
        machine.original = dict(machine.regs)
        return machine

    def test_returning_syscalls_preserve_all_other_registers_and_fcsr(self):
        vm = self.running_task()
        root = vm.ptbr
        # Valid endpoints, invalid unsigned values and arbitrary unknown numbers.
        cases = [(0, 0, 0), (0, 255, 0), (0, 256, -22), (0, 0xFFFFFFFF, -22),
                 (2, 77, -38), (0xFFFFFFFF, 88, -38), (0, 65, 0)]
        uart = LAYOUT["UART_BASE"]
        for i, (number, arg, result) in enumerate(cases):
            for sp in (0, 3, 0xDEADBEE8):
                with self.subTest(number=number, arg=arg, sp=sp):
                    vm.memory[uart] = 0x12345678
                    machine = self.user_trap(vm, number=number, arg=arg, sp=sp)
                    machine.control["epc"] += i * 4
                    epc = machine.control["epc"]
                    machine.run()
                    self.assertEqual(machine.stop, "iret")
                    expected = dict(machine.original, r1=result & 0xFFFFFFFF)
                    self.assertEqual(machine.regs, expected)
                    self.assertEqual(machine.control["fcsr"], machine.initial_control["fcsr"])
                    self.assertEqual(machine.control["status"], machine.initial_control["status"])
                    self.assertEqual(machine.control["epc"], epc + 4)
                    self.assertEqual(vm.ptbr, root)
                    self.assertEqual(vm.field("state"), 2)
                    self.assertEqual(vm.memory[uart], arg if result == 0 else 0x12345678)
                    context = vm.field_address("context")
                    self.assertEqual([vm.memory[context + 4 * n] for n in range(32)],
                                     [expected[f"r{n}"] for n in range(32)])
                    self.assertEqual(vm.memory[context + LAYOUT["TF_EPC"]], epc + 4)
                    self.assertFalse(any(address in (0, 3, 0xDEADBEE8) for _, address in machine.accesses))

    def test_exit_and_fatal_user_faults_resume_trusted_kernel_then_reap(self):
        # Every synchronous fault, including BREAK and privileged instructions.
        for cause in range(1, 16):
            with self.subTest(cause=cause):
                vm = self.running_task()
                pages, root = vm.pages(), vm.field("directory")
                machine = self.user_trap(vm, cause=cause, number=1, arg=0xFFFFFF85,
                                         sp=0xFFFFFFF9)
                vm.call("trapExpect", cause)  # user traps cannot consume self-test expectations
                machine.run()
                self.assertEqual(machine.stop, "iret")
                self.assertFalse(vm.call("trapExpectationMet"))
                self.assertEqual(vm.field("state"), 3 if cause == 12 else 4)
                self.assertEqual(vm.field("exitCode"), 0xFFFFFF85 if cause == 12 else cause)
                context = vm.field_address("context")
                self.assertEqual(vm.memory[context + LAYOUT["TF_EPC"]],
                    machine.initial_control["epc"] + (4 if cause == 12 else 0))
                self.assertEqual(vm.memory[context + LAYOUT["TF_CAUSE"]], cause)
                self.assertEqual(vm.memory[context + LAYOUT["TF_BADADDR"]], machine.control["badaddr"])
                self.assertEqual([vm.memory[context + 4 * n] for n in range(32)],
                                 [machine.original[f"r{n}"] for n in range(32)])
                expected = [0] * 32
                expected[30] = vm.addresses["kernelStackTop"]
                self.assertEqual([machine.get(f"r{n}") for n in range(32)], expected)
                self.assertEqual(machine.control["epc"], vm.addresses["taskKernelResume"])
                self.assertEqual(machine.control["status"], 16)  # IRET -> supervisor, IE/SS off
                self.assertEqual(machine.control["fcsr"], 0)
                self.assertEqual(vm.ptbr, vm.kernel_root | 1)
                for name in ("kernelStackBottom", "kernelStackTop"):
                    slot = "KERNEL_STACK_BOTTOM" if name.endswith("Bottom") else "KERNEL_STACK_TOP"
                    self.assertEqual(vm.memory[LAYOUT[slot]], vm.addresses[name])
                self.assertEqual(vm.memory[LAYOUT["KERNEL_SP"]], expected[30])
                # The task root and pages stay allocated while trap restore reads its stack.
                self.assertTrue(vm.call("physicalPageOwned", root, 1, 3))
                self.assertTrue(all(vm.call("physicalPageReferences", p) == 1 for p in pages))
                self.assertEqual(machine.accesses[-1], ("lw", machine.frame + LAYOUT["TF_R30"]))
                # Model the trusted continuation after IRET switched stacks.
                vm.controls[0] = 0
                vm.call("taskReap")
                self.assertEqual(vm.field("directory"), 0)
                self.assertEqual(vm.pages(), [0, 0, 0])
                self.assertTrue(all(vm.call("physicalPageAvailable", p) for p in pages + [root]))
                self.assertFalse(vm.call("taskPrepare"))  # terminal task cannot reenter user code
                with self.assertRaises(KernelPanic):
                    vm.call("taskStart")

    def test_user_trap_with_wrong_root_does_not_overwrite_task_context(self):
        vm = self.running_task()
        context = vm.field_address("context")
        original = [vm.memory[context + i] for i in range(0, LAYOUT["TF_SIZE"], 4)]
        machine = self.user_trap(vm)
        machine.control["ptbr"] = vm.kernel_root | 1
        with self.assertRaisesRegex(KernelPanic, "without running task"):
            machine.run()
        self.assertEqual([vm.memory[context + i] for i in range(0, LAYOUT["TF_SIZE"], 4)], original)

    def test_isolated_pages_guards_and_inherited_supervisor_mappings(self):
        vm = TaskM()
        boot_ptbr = vm.ptbr
        self.assertTrue(vm.call("taskPrepare"))
        root = vm.field("directory")
        code, data, stack = vm.pages()
        self.assertEqual(len({root, code, data, stack}), 4)
        for va, physical, flags, purpose in ((USER_CODE, code, 27, 5),
                (USER_DATA, data, 23, 5), (STACK_BOTTOM, stack, 23, 6)):
            self.assertEqual(vm.leaf(va, root), physical | flags)
            self.assertTrue(vm.call("physicalPageOwned", physical, 1, purpose))
            self.assertEqual(vm.call("physicalPageReferences", physical), 1)
        self.assertEqual([vm.memory[code + 4 * i] for i in range(7)], vm.blob)
        self.assertTrue(all(vm.memory[code + i] == 0 for i in range(28, PAGE, 4)))
        for physical in (data, stack):
            self.assertTrue(all(vm.memory[physical + i] == 0 for i in range(0, PAGE, 4)))
        self.assertEqual(vm.leaf(code, root) & 31, 3)  # kernel alias R, no W/U/X
        for physical in (data, stack):
            self.assertEqual(vm.leaf(physical, root) & 31, 7)
        for va in (0, STACK_GUARD, USER_DATA + PAGE, STACK_TOP):
            self.assertEqual(vm.leaf(va, root), 0)
        for va in (0x1FF0, SECTIONS["__start_text"], SECTIONS["__start_rodata"],
                   root, vm.field("kernelStackBottom"), vm.field("kernelStackTop") - PAGE):
            self.assertEqual(vm.leaf(va, root), vm.leaf(va, vm.kernel_root))
            self.assertEqual(vm.leaf(va, root) & 16, 0)
        for guard in (vm.addresses["kernelStackGuard"], vm.addresses["taskKernelStackGuard"]):
            self.assertEqual(vm.leaf(guard, root), 0)
        self.assertEqual(vm.memory[vm.field("kernelStackBottom")], LAYOUT["STACK_CANARY"])
        self.assertEqual(vm.ptbr, boot_ptbr)  # preparation never activates the root
        self.assertEqual(vm.field("state"), 1)
        snapshot = dict(vm.memory), dict(vm.globals), vm.ptbr
        self.assertFalse(vm.call("taskPrepare"))
        self.assertEqual((dict(vm.memory), dict(vm.globals), vm.ptbr), snapshot)

    def test_initial_context_and_common_restore_to_iret(self):
        vm = TaskM()
        self.assertTrue(vm.call("taskPrepare"))
        frame = vm.field_address("context")
        expected = [0] * 32
        expected[1], expected[2], expected[30] = USER_DATA, PAGE, STACK_TOP
        self.assertEqual([vm.memory[frame + 4 * i] for i in range(32)], expected)
        for field, value in (("EPC", USER_CODE), ("STATUS", 24), ("FCSR", 0),
                ("PTBR", vm.field("directory") | 1), ("CAUSE", 0), ("BADADDR", 0)):
            self.assertEqual(vm.memory[frame + LAYOUT["TF_" + field]], value)
        with self.assertRaises(TaskEntered):
            vm.call("taskStart")
        self.assertEqual(vm.entered, frame)
        self.assertEqual(vm.field("state"), 2)
        self.assertEqual(vm.controls[0] & 1, 0)
        self.assertEqual(vm.ptbr, vm.field("directory") | 1)
        for name, field in (("KERNEL_SP", "kernelStackTop"),
                ("KERNEL_STACK_BOTTOM", "kernelStackBottom"), ("KERNEL_STACK_TOP", "kernelStackTop")):
            self.assertEqual(vm.memory[LAYOUT[name]], vm.field(field))
        switch = [e for e in vm.events if e[0] != "fence"][-3:]
        self.assertEqual(switch, [("tlbi", [0, 2]), ("mtcr", [6, vm.ptbr]), ("entry", [frame])])
        machine = EntryMachine(False, 0x92000)
        machine.memory = vm.memory
        machine.pc = machine.labels["trapRestoreFrame"]
        machine.put("r1", frame)
        machine.control["ptbr"] = vm.ptbr
        machine.run()
        self.assertEqual(machine.stop, "iret")
        self.assertEqual([machine.get(f"r{i}") for i in range(32)], expected)
        self.assertEqual(machine.control["epc"], USER_CODE)
        self.assertEqual(machine.control["status"], 24)  # IRET will set UM=1, IE=SS=0
        self.assertEqual(machine.control["fcsr"], 0)
        self.assertEqual(machine.control["ptbr"], vm.ptbr)
        self.assertEqual(machine.accesses[-1], ("lw", frame + LAYOUT["TF_R30"]))
        self.assertTrue(all(frame <= address < frame + LAYOUT["TF_SIZE"]
                            for _, address in machine.accesses))
        wrapper = machine.code[machine.labels["trapRestoreFrame"]:machine.labels["trapEntry"]]
        self.assertEqual([(st.op, st.args) for st in wrapper if st.op],
                         [("li", ["r2", "STATUS_EXL"]), ("mtcr", ["status", "r2"]),
                          ("mv", ["sp", "r1"]), ("j", ["trapEntry.restore"])])

    def test_every_creation_oom_rolls_back_and_can_retry(self):
        # Task root + three frames + two user tables = six free pages needed.
        for count in range(6):
            with self.subTest(free_pages=count):
                vm = TaskM()
                held = []
                while address := vm.call("allocPage", 9, 2):
                    held.append(address)
                for address in held[:count]:
                    self.assertTrue(vm.call("freePage", address, 9, 2))
                baseline = vm.free_pages()
                self.assertFalse(vm.call("taskPrepare"))
                self.assertEqual(vm.free_pages(), baseline)
                self.assertEqual(vm.pages(), [0, 0, 0])
                self.assertEqual(vm.field("directory"), 0)
                self.assertEqual(vm.field("state"), 0)
                self.assertEqual(vm.ptbr, vm.kernel_root | 1)
                for address in held[count:]:
                    self.assertTrue(vm.call("freePage", address, 9, 2))
                self.assertTrue(vm.call("taskPrepare"))

    def test_each_mapping_failure_revokes_x_and_releases_only_task_pages(self):
        for failure in (1, 2, 3):
            with self.subTest(mapping=failure):
                vm = TaskM()
                unrelated = vm.call("allocPage", 1, 5)
                baseline = vm.free_pages()
                vm.fail_mapping = failure
                self.assertFalse(vm.call("taskPrepare"))
                self.assertEqual(vm.free_pages(), baseline)
                self.assertTrue(vm.call("physicalPageOwned", unrelated, 1, 5))
                self.assertEqual(vm.pages(), [0, 0, 0])
                for address in baseline:
                    self.assertEqual(vm.leaf(address) & 31, 7)
                vm.fail_mapping = None
                self.assertTrue(vm.call("taskPrepare"))

    def test_bad_blob_or_enabled_irqs_do_not_allocate_or_enter(self):
        for end in (0x14000, 0x13FFC, 0x14003, 0x15004):
            vm = TaskM()
            vm.addresses["userCodeEnd"] = end
            baseline = vm.free_pages()
            self.assertFalse(vm.call("taskPrepare"))
            self.assertEqual(vm.free_pages(), baseline)
        for cpu, pic in ((1, 0), (0, 1)):
            vm = TaskM()
            vm.controls[0], vm.memory[0xFD000004] = cpu, pic
            self.assertFalse(vm.call("taskPrepare"))
            with self.assertRaises(KernelPanic):
                vm.call("taskStart")
            self.assertIsNone(vm.entered)
        vm = TaskM()
        self.assertTrue(vm.call("taskPrepare"))
        vm.memory[0xFD000004] = 1
        with self.assertRaises(KernelPanic):
            vm.call("taskStart")
        self.assertEqual(vm.ptbr, vm.kernel_root | 1)
        self.assertEqual(vm.field("state"), 1)

    def test_user_trap_uses_task_stack_and_saves_live_context(self):
        vm = TaskM()
        self.assertTrue(vm.call("taskPrepare"))
        with self.assertRaises(TaskEntered):
            vm.call("taskStart")
        machine = EntryMachine(True, 0, kernel_sp=vm.field("kernelStackTop"),
                               bottom=vm.field("kernelStackBottom"), top=vm.field("kernelStackTop"))
        machine.memory = vm.memory
        machine.dispatcher = vm.call
        machine.control["ptbr"] = vm.ptbr
        machine.run()
        self.assertEqual(machine.stop, "iret")
        self.assertEqual(vm.field("state"), 4)
        self.assertEqual(machine.frame, vm.field("kernelStackTop") - LAYOUT["TF_SIZE"])
        context = vm.field_address("context")
        self.assertEqual([vm.memory[context + i * 4] for i in range(32)],
                         [machine.original[f"r{i}"] for i in range(32)])
        self.assertEqual(vm.memory[context + LAYOUT["TF_EPC"]], machine.initial_control["epc"])
        self.assertEqual(machine.control["epc"], vm.addresses["taskKernelResume"])
        self.assertFalse(any(address < PAGE for _, address in machine.accesses))

    def test_user_blob_is_self_contained_and_both_kernel_stacks_have_guards(self):
        parser = parse_asm(LAIX / "src/task/task.asm")
        begin = next(i for i, st in enumerate(parser.stmts) if "userCodeStart" in st.labels)
        instructions = [st for st in parser.stmts[begin:] if st.op and not st.op.startswith(".") and st.op != "="]
        self.assertEqual([st.op for st in instructions], ["addi", "li", "sw", "lw", "addi", "sw",
            "li", "li", "syscall", "li", "li", "syscall", "li", "li", "syscall", "j"])
        self.assertEqual(instructions[-1].args, [".exit_returned"])
        self.assertTrue(all(st.args[-1] in ("0(sp)", "0(r1)") for st in instructions if st.op in ("lw", "sw")))
        statements = parse_asm(LAIX / "src/arch/wrm081632/start.asm").stmts
        guard = next(i for i, st in enumerate(statements) if "taskKernelStackGuard" in st.labels)
        bottom = next(i for i, st in enumerate(statements) if "taskKernelStackBottom" in st.labels)
        top = next(i for i, st in enumerate(statements) if "taskKernelStackTop" in st.labels)
        self.assertEqual((statements[guard - 1].op, statements[guard - 1].args), (".align", ["PAGE_SIZE"]))
        self.assertEqual([(st.op, st.args) for st in statements[guard:bottom] if st.op], [(".space", ["PAGE_SIZE"])])
        self.assertEqual([(st.op, st.args) for st in statements[bottom:top] if st.op], [(".space", ["KERNEL_STACK_BYTES"])])


if __name__ == "__main__":
    unittest.main()
