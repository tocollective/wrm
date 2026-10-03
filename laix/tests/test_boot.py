"""Acceptance checks against boot sources, with synthetic physical addresses."""

import unittest

from test_kernel import LAIX, parse_asm, asm_constants
from test_trap_entry import EntryMachine
from source_m import SourceM, KernelPanic


def start_machine():
    vm = EntryMachine(False, 0x10000)
    vm.parser = parse_asm(LAIX / "src/arch/wrm081632/start.asm")
    vm.code = vm.parser.stmts
    vm.constants = asm_constants(vm.parser)
    vm.labels = {label: i for i, st in enumerate(vm.code) for label in st.labels}
    # Symbol locations are fixtures: never assemble or lay out an image.
    vm.symbols = {label: 0x10000 + 4 * i for label, i in vm.labels.items()}
    vm.symbols.update(__bss_start=0x11000, __bss_end=0x14004,
                      bootInfoAddress=0x14000, kernelStackBottom=0x12000,
                      kernelStackTop=0x14000, trapEntry=0x10800)
    vm.pc = vm.labels["kernelStart"]
    vm.put("r1", 0x1000)
    vm.memory = {address: 0xDEADBEEF for address in range(0x10FFC, 0x14008, 4)}
    vm.memory.update({0x1000: vm.constants["BOOT_INFO_MAGIC"], 0x1004: 40,
                      0x1008: 0x20000, 0xFD000004: 0xFFFFFFFF})
    return vm


def boot_m():
    vm = SourceM(LAIX / "src/kernel/boot.m")
    vm.addresses.update(__image_start=0x10000, __image_end=0x80000,
                        kernelStackBottom=0x91000, kernelStackTop=0x93000,
                        kernelBootInfo=0x98000)  # after the synthetic MMU tables
    vm.globals["bootInfoAddress"] = 0x1000
    vm.memory[0xFD000004] = 0
    info = vm.decls["kernelBootInfo"].sym.type
    fields = dict(magic=0x4F464E49, size=40, ramSize=0x100000, disk=0xFD005000,
                  diskSectors=2000, image=0x10000, imageSize=0x70000, clock=1000000,
                  devices=2, deviceTable=0x1040)
    for field in info.fields:
        vm.memory[0x1000 + field.offset] = fields[field.name]
    return vm, info


class BootAcceptanceTests(unittest.TestCase):
    def test_start_zeros_all_bss_before_globals_stack_and_main(self):
        vm = start_machine()
        vm.run()
        self.assertEqual(vm.stop, "main")
        writes = [(address, value) for address, value in vm.writes if 0x11000 <= address < 0x14004]
        zeros = [(address, 0) for address in range(0x11000, 0x14004, 4)]
        self.assertEqual(writes, zeros + [(0x14000, 0x1000), (0x12000, vm.constants["STACK_CANARY"])])
        self.assertEqual(vm.memory[0x10FFC], 0xDEADBEEF)
        self.assertEqual(vm.memory[0x14004], 0xDEADBEEF)
        self.assertEqual(vm.memory[0x1000], vm.constants["BOOT_INFO_MAGIC"])
        self.assertEqual(vm.memory[vm.constants["KERNEL_SP"]], 0x14000)
        self.assertEqual(vm.get("sp"), 0x14000)
        self.assertEqual(vm.control["ivec"], vm.symbols["trapEntry"])
        self.assertEqual(vm.control["status"], 0)
        self.assertEqual(vm.control["ptbr"], 0)
        self.assertEqual(vm.memory[0xFD000004], 0)

    def test_invalid_early_boot_contract_never_writes_bss(self):
        for address, value in ((0x1000, 0), (0x1004, 36), (0x1004, 4097), (0x1008, 0x14000)):
            with self.subTest(address=hex(address), value=value):
                vm = start_machine()
                vm.memory[address] = value
                vm.run()
                self.assertEqual(vm.stop, "earlyPanic")
                self.assertFalse(any(0x11000 <= address < 0x14004 for address, _ in vm.writes))
        vm = start_machine()
        vm.put("r1", 0x1004)
        vm.run()
        self.assertEqual(vm.stop, "earlyPanic")

    def test_boot_info_snapshot_is_independent_of_firmware_memory(self):
        vm, info = boot_m()
        original = [vm.memory[0x1000 + field.offset] for field in info.fields]
        vm.call("kernelInit")
        for field in info.fields:
            vm.memory[0x1000 + field.offset] = 0
        saved = [vm.memory[vm.addresses["kernelBootInfo"] + field.offset] for field in info.fields]
        self.assertEqual(saved, original)
        self.assertTrue(vm.ptbr & 1)
        self.assertTrue(vm.call("trapExpectationMet"))

    def test_full_boot_info_validation_rejects_bad_fields_and_device_ranges(self):
        for name, value in (("magic", 0), ("size", 39), ("size", 4097),
                            ("image", 0x10004), ("imageSize", 0x70004),
                            ("ramSize", 0x98000), ("clock", 0),
                            ("devices", 0xFFFFFFFF), ("deviceTable", 0x1024),
                            ("deviceTable", 0x2004), ("deviceTable", 0x1041),
                            ("deviceTable", 0x1FFC), ("deviceTable", 0x1FE8),
                            ("size", 0xFF4)):
            with self.subTest(name=name, value=hex(value)):
                vm, info = boot_m()
                vm.memory[0x1000 + info.field(name).offset] = value
                with self.assertRaises(KernelPanic):
                    vm.call("kernelInit")
                self.assertEqual(vm.ptbr, 0)

    def test_device_table_may_end_right_below_entry_state(self):
        vm, info = boot_m()
        constants = asm_constants(parse_asm(LAIX / "src/arch/wrm081632/defs.inc"))
        table = constants["BOOT_INFO_LIMIT"] - 2 * constants["DEVICE_ENTRY_BYTES"]
        vm.memory[0x1000 + info.field("deviceTable").offset] = table
        vm.call("kernelInit")
        self.assertTrue(vm.ptbr & 1)

    def test_stack_layout_rejects_image_overlap_bad_guard_and_service_memory(self):
        for symbol, address in (("kernelStackGuard", 0x7F000),
                                ("kernelStackGuard", 0x90001),
                                ("kernelStackBottom", 0x90000),
                                ("kernelStackTop", 0x91000),
                                ("kernelStackTop", 0x99000),
                                ("kernelStackBottom", 0x1000)):
            with self.subTest(symbol=symbol):
                vm, _ = boot_m()
                vm.addresses[symbol] = address
                with self.assertRaisesRegex(KernelPanic, "invalid kernel memory layout"):
                    vm.call("kernelInit")
                self.assertEqual(vm.ptbr, 0)

    def test_boot_rejects_enabled_cpu_or_pic_interrupts(self):
        for status, enable in ((1, 0), (0, 1), (1, 0xFFFFFFFF)):
            vm, _ = boot_m()
            vm.controls[0], vm.memory[0xFD000004] = status, enable
            with self.assertRaisesRegex(KernelPanic, "IRQs enabled"):
                vm.call("kernelInit")

    def test_boot_detects_irq_state_changed_by_trap_return(self):
        for pic in (False, True):
            vm, _ = boot_m()
            original_call = vm.call
            def changed_call(name, *args):
                value = original_call(name, *args)
                if name == "trapRegisterSelfTest":
                    if pic:
                        vm.memory[0xFD000004] = 1
                    else:
                        vm.controls[0] = 1
                return value
            vm.call = changed_call
            with self.assertRaisesRegex(KernelPanic, "trap return enabled IRQs"):
                vm.call("kernelInit")


if __name__ == "__main__":
    unittest.main()
