"""Run the checked MMU/allocator AST. No code generation or building.

Checks table structure, ownership, rollback and architectural instruction
ordering; it does not claim to execute CPU translations or exceptions.
"""

import unittest

from test_memory import BootstrapM
from test_page_allocator import LockedWrites

PAGE, SUPER = 4096, 0x400000
USER, END = 0x40000000, 0xC0000000
V, R, W, X, U = 1, 2, 4, 8, 16
RW, RO, RX = V | R | W | U, V | R | U, V | R | X | U


class AddressSpaceTests(unittest.TestCase):
    def vm(self, ram=0x800000, status=0):
        vm = BootstrapM()
        vm.memory = LockedWrites(vm)
        vm.controls[0] = status
        self.assertTrue(vm.call("memoryInit", ram))
        self.assertTrue(vm.call("mmuInit"))
        self.assertEqual(vm.controls[0], status)
        vm.events.clear()
        return vm

    def snapshot(self, vm):
        return dict(vm.memory), dict(vm.globals), vm.ptbr

    def space(self, vm, owner=7):
        address = vm.call("mmuCreateAddressSpace", owner)
        self.assertNotEqual(address, 0)
        self.assertTrue(vm.call("physicalPageOwned", address, owner, 3))
        self.assertEqual(vm.call("physicalPageReferences", address), 1)
        return address

    def invalidate(self, vm, count=1):
        tlbi = [i for i, event in enumerate(vm.events) if event[0] == "tlbi"]
        self.assertEqual(len(tlbi), count)
        for i in tlbi:
            self.assertEqual(vm.events[i], ("tlbi", [0, 2]))
            self.assertEqual(vm.events[i - 1], ("fence", []))

    def test_kernel_allocation_failure_rolls_back_and_can_retry(self):
        # zero, one free page: directory or low-table allocation fails.
        for ram in (0x9A000, 0x9B000):
            vm = BootstrapM()
            self.assertTrue(vm.call("memoryInit", ram))
            self.assertFalse(vm.call("mmuInit"))
            self.assertEqual(vm.ptbr, 0)
            self.assertEqual(vm.globals["kernelPageDirectory"], 0)
            for address in range(vm.globals["kernelReservedEnd"], ram, PAGE):
                self.assertTrue(vm.call("physicalPageAvailable", address))
        # Force the separately required partial-RAM-tail table to fail.
        vm = BootstrapM()
        self.assertTrue(vm.call("memoryInit", 0x501123))
        held = []
        while (address := vm.call("allocPage", 5, 2)):
            held.append(address)
        for address in held[:2]:
            self.assertTrue(vm.call("freePage", address, 5, 2))
        self.assertFalse(vm.call("mmuInit"))
        for address in held[:2]:
            self.assertTrue(vm.call("physicalPageAvailable", address))
        self.assertTrue(vm.call("freePage", held[2], 5, 2))
        self.assertTrue(vm.call("mmuInit"))
        # Two free frames suffice when the RAM fits in the low table.
        vm = self.vm(0x9C000)
        self.assertEqual(vm.call("mmuCreateAddressSpace", 7), 0)

    def test_map_protect_unmap_and_refuse_to_free_live_frames(self):
        vm = self.vm(status=0x4B)
        directory = self.space(vm)
        physical = vm.call("allocPage", 7, 5)
        vm.events.clear()
        self.assertTrue(vm.call("mapPage", directory, 7, USER, physical, RW))
        self.invalidate(vm)
        table = vm.memory[directory + USER // SUPER * 4] & ~4095
        self.assertTrue(vm.call("physicalPageOwned", table, 7, 4))
        self.assertFalse(vm.call("freePage", table, 7, 4))
        self.assertFalse(vm.call("freePage", directory, 7, 3))
        self.assertFalse(vm.call("freePage", physical, 7, 5))
        self.assertEqual(vm.leaf(USER, directory), physical | RW)
        vm.memory.update({table: vm.memory[table] | 0x60})  # hardware A/D, outside the software lock
        for permissions, count in ((RO, 2), (RX, 3), (RW, 3)):
            vm.events.clear()
            self.assertTrue(vm.call("setPagePermissions", directory, 7, USER, permissions))
            self.invalidate(vm, count)
            self.assertEqual(vm.leaf(USER, directory), physical | permissions | 0x60)
        vm.events.clear()
        self.assertTrue(vm.call("unmapPage", directory, 7, USER))
        self.invalidate(vm)
        self.assertEqual(vm.leaf(USER, directory), 0)
        self.assertTrue(vm.call("physicalPageAvailable", table))
        self.assertTrue(vm.call("physicalPageOwned", physical, 7, 5))
        self.assertEqual(vm.call("physicalPageReferences", physical), 0)
        self.assertTrue(vm.call("freePage", physical, 7, 5))
        self.assertFalse(vm.call("unmapPage", directory, 7, USER))
        self.assertEqual(vm.controls[0], 0x4B)

    def test_invalid_ranges_flags_ownership_and_aliases_do_not_mutate(self):
        vm = self.vm()
        directory = self.space(vm)
        physical = vm.call("allocPage", 7, 5)
        forbidden = [0, 0x1000, 0x90000, 0x98000, 0x800000, 0xFFFFFFFF,
                     vm.ptbr & ~4095, directory, physical + 1]
        for purpose in (2, 4, 7):
            forbidden.append(vm.call("allocPage", 7, purpose))
        forbidden.append(vm.call("allocPage", 8, 5))
        for address in forbidden:
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mapPage", directory, 7, USER, address, RW))
            self.assertEqual(self.snapshot(vm), before)
        for virtual in (0, 0x1000, 0x1FF0, 0x90000, USER - PAGE, USER + 1,
                        END, 0xFC000000, 0xFFFFF000, 0xFFFFFFFF):
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mapPage", directory, 7, virtual, physical, RW))
            self.assertFalse(vm.call("unmapPage", directory, 7, virtual))
            self.assertFalse(vm.call("setPagePermissions", directory, 7, virtual, RW))
            self.assertEqual(self.snapshot(vm), before)
        for permissions in (0, V, V | U, V | W | U, 7, RW | X, RW | 0x20,
                            RW | 0x40, RW | 0x80, RW | 0x100, RW | 0x1000):
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mapPage", directory, 7, USER, physical, permissions))
            self.assertEqual(self.snapshot(vm), before)
        for root, owner in ((directory, 8), (directory + 1, 7), (0, 7), (physical, 7)):
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mapPage", root, owner, USER, physical, RW))
            self.assertEqual(self.snapshot(vm), before)
        self.assertTrue(vm.call("mapPage", directory, 7, END - PAGE, physical, RW))
        before = self.snapshot(vm)
        self.assertFalse(vm.call("mapPage", directory, 7, END - PAGE, physical, RO))
        self.assertFalse(vm.call("setPagePermissions", directory, 7, END - PAGE, RW | X))
        self.assertFalse(vm.call("mmuInitAddressSpace", directory, 7))
        self.assertEqual(self.snapshot(vm), before)
        for address, size, valid in ((USER, END - USER, True), (END - PAGE, PAGE, True),
                (END - PAGE, 2 * PAGE, False), (USER, 0xFFFFFFFF, False),
                (0xFFFFF000, 2 * PAGE, False), (USER, 0, False), (USER, 1, False)):
            self.assertEqual(vm.call("mmuUserRangeValid", address, size), valid)

    def test_mapping_failure_returns_reference_and_keeps_directory(self):
        vm = self.vm(0x9E000)  # kernel root + low table, task root + user frame
        directory = self.space(vm)
        physical = vm.call("allocPage", 7, 5)
        before = self.snapshot(vm)
        self.assertFalse(vm.call("mapPage", directory, 7, USER, physical, RW))
        self.assertEqual(self.snapshot(vm), before)
        self.assertEqual(vm.call("physicalPageReferences", physical), 0)
        self.assertTrue(vm.call("freePage", physical, 7, 5))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", directory, 7))
        self.assertEqual(vm.call("mmuCreateAddressSpace", 7), directory)

    def test_destroy_aliases_and_spaces_frees_last_reference_once(self):
        vm = self.vm(status=0x18)
        baseline = vm.globals["nextFreePage"]
        first, second = self.space(vm), self.space(vm)
        physical = vm.call("allocPage", 7, 6)
        unrelated = vm.call("allocPage", 7, 5)
        for directory, virtual in ((first, USER), (first, USER + PAGE),
                                   (first, USER + SUPER), (second, USER)):
            self.assertTrue(vm.call("mapPage", directory, 7, virtual, physical, RW))
        self.assertEqual(vm.call("physicalPageReferences", physical), 4)
        shared = vm.memory[vm.ptbr & ~4095] & ~4095
        before_kernel = [vm.leaf(v) for v in (0, 0x1000, 0x10000, 0x90000, 0xFD002000)]
        self.assertTrue(vm.call("mmuDestroyAddressSpace", first, 7))
        self.assertEqual(vm.call("physicalPageReferences", physical), 1)
        self.assertTrue(vm.call("physicalPageOwned", physical, 7, 6))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", second, 7))
        self.assertTrue(vm.call("physicalPageAvailable", physical))
        self.assertFalse(vm.call("mmuDestroyAddressSpace", first, 7))
        self.assertTrue(vm.call("physicalPageOwned", shared, 0xFFFFFFFF, 4))
        self.assertTrue(vm.call("physicalPageOwned", unrelated, 7, 5))
        self.assertEqual([vm.leaf(v) for v in (0, 0x1000, 0x10000, 0x90000, 0xFD002000)], before_kernel)
        self.assertEqual(vm.globals["nextFreePage"], baseline)
        self.assertEqual(vm.controls[0], 0x18)

    def test_split_preserves_every_leaf_and_frees_only_private_table(self):
        vm = self.vm()
        directory = self.space(vm)
        kernel_root = vm.ptbr & ~4095
        for base in (0xFC000000, 0xFD000000):
            old = vm.memory[kernel_root + base // SUPER * 4]
            vm.memory[directory + base // SUPER * 4] |= 0x60
            vm.events.clear()
            self.assertTrue(vm.call("mmuSplitSuperpage", directory, 7, base))
            self.invalidate(vm)
            self.assertEqual(vm.memory[kernel_root + base // SUPER * 4], old)
            for virtual in range(base, base + SUPER, PAGE):
                self.assertEqual(vm.leaf(virtual, directory) & ~0x60, vm.leaf(virtual))
            self.assertFalse(vm.call("mmuSplitSuperpage", directory, 7, base))
        for virtual in (0, PAGE, USER, SUPER, SUPER + 1):
            self.assertFalse(vm.call("mmuSplitSuperpage", directory, 7, virtual))
        private = [vm.memory[directory + base // SUPER * 4] & ~4095
                   for base in (0xFC000000, 0xFD000000)]
        self.assertTrue(vm.call("mmuDestroyAddressSpace", directory, 7))
        for table in private:
            self.assertTrue(vm.call("physicalPageAvailable", table))

    def test_switch_invalidates_before_ptbr_and_reused_asid_and_blocks_active_destroy(self):
        vm = self.vm(status=0x49)
        first, second = self.space(vm), self.space(vm, 8)
        for directory, owner, asid in ((first, 7, 1), (second, 8, 2),
                                       (first, 7, 2), (second, 8, 0), (first, 7, 255)):
            vm.events.clear()
            self.assertTrue(vm.call("mmuSwitchAddressSpace", directory, owner, asid))
            self.invalidate(vm)
            important = [e for e in vm.events if e[0] != "fence"]
            self.assertEqual(important, [("tlbi", [0, 2]), ("mtcr", [6, directory | asid << 4 | 1])])
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mmuDestroyAddressSpace", directory, owner))
            self.assertEqual(self.snapshot(vm), before)
        for directory, owner, asid in ((first, 8, 1), (0, 7, 1), (first, 7, 256)):
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mmuSwitchAddressSpace", directory, owner, asid))
            self.assertEqual(self.snapshot(vm), before)
        vm.events.clear()
        self.assertTrue(vm.call("mmuActivateKernel"))
        self.invalidate(vm)
        self.assertTrue(vm.call("mmuDestroyAddressSpace", first, 7))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", second, 8))
        self.assertEqual(vm.controls[0], 0x49)


if __name__ == "__main__":
    unittest.main()
