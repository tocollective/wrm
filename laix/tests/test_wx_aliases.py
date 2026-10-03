"""Physical-frame W^X and PTE/TLBI ordering in the checked M AST, no build."""

import unittest

import test_address_space as address_spaces
from test_address_space import PAGE, SUPER, USER, RW, RO, RX, W, X, U
from test_page_allocator import LockedWrites


class WatchedWrites(LockedWrites):
    def __init__(self, vm, addresses):
        super().__init__(vm)
        self.addresses = set(addresses)

    def __setitem__(self, address, value):
        super().__setitem__(address, value)
        if address in self.addresses:
            self.vm.events.append(("pte", [address, value]))


class PhysicalWXTests(unittest.TestCase):
    vm = address_spaces.AddressSpaceTests.vm
    space = address_spaces.AddressSpaceTests.space
    snapshot = address_spaces.AddressSpaceTests.snapshot

    def access(self, vm, physical):
        return vm.memory[vm.globals["pageAccessReferences"] + physical // PAGE * 4]

    def identity_slot(self, vm, physical):
        root = vm.globals["kernelPageDirectory"]
        table = vm.memory[root + physical // SUPER * 4] & ~(PAGE - 1)
        return table + physical // PAGE % 1024 * 4

    def user_slot(self, vm, directory, virtual=USER):
        table = vm.memory[directory + virtual // SUPER * 4] & ~(PAGE - 1)
        return table + virtual // PAGE % 1024 * 4

    def important(self, vm):
        return [event for event in vm.events if event[0] in ("pte", "tlbi")]

    def test_conflicting_aliases_and_permission_upgrades_are_atomic_across_spaces(self):
        for initial, conflict in ((RW, RX), (RX, RW)):
            vm = self.vm(status=0x49)
            first, second = self.space(vm), self.space(vm)
            physical = vm.call("allocPage", 7, 5)
            self.assertTrue(vm.call("mapPage", first, 7, USER, physical, initial))
            self.assertTrue(vm.call("mapPage", second, 7, USER, physical, RO))
            for directory, virtual in ((first, USER + PAGE), (second, USER + SUPER)):
                before = self.snapshot(vm)
                vm.events.clear()
                self.assertFalse(vm.call("mapPage", directory, 7, virtual, physical, conflict))
                self.assertEqual(self.snapshot(vm), before)
                self.assertFalse(self.important(vm))
            before = self.snapshot(vm)
            self.assertFalse(vm.call("setPagePermissions", second, 7, USER, conflict))
            self.assertEqual(self.snapshot(vm), before)
            self.assertTrue(vm.call("mapPage", second, 7, USER + PAGE, physical, initial))
            before = self.snapshot(vm)
            self.assertFalse(vm.call("setPagePermissions", first, 7, USER, conflict))
            self.assertEqual(self.snapshot(vm), before)
            self.assertEqual(vm.controls[0], 0x49)

    def test_executable_frame_has_only_ro_kernel_alias_in_existing_and_future_spaces(self):
        vm = self.vm()
        first, second = self.space(vm), self.space(vm)
        # Exercise a region that previously inherited a supervisor RW superpage.
        vm.globals["nextFreePage"] = SUPER // PAGE
        physical = vm.call("allocPage", 7, 5)
        self.assertEqual(physical, SUPER)
        self.assertFalse(vm.call("mmuSplitSuperpage", first, 7, physical))
        slot = self.identity_slot(vm, physical)
        vm.memory.update({slot: vm.memory[slot] | 0x60})  # hardware A/D
        vm.memory = WatchedWrites(vm, [slot])
        vm.events.clear()
        self.assertTrue(vm.call("mapPage", first, 7, USER, physical, RX))
        events = self.important(vm)
        self.assertEqual(events[0], ("pte", [slot, physical | 3 | 0x60]))
        self.assertEqual(events[1], ("tlbi", [0, 2]))
        third = self.space(vm, 8)
        for directory in (vm.globals["kernelPageDirectory"], first, second, third):
            self.assertEqual(vm.leaf(physical, directory), physical | 3 | 0x60)
            self.assertEqual(vm.leaf(physical + PAGE, directory) & 31, 7)
        self.assertTrue(vm.call("mapPage", second, 7, USER, physical, RX))
        self.assertEqual(self.access(vm, physical), 0x80000002)
        self.assertTrue(vm.call("unmapPage", first, 7, USER))
        self.assertEqual(self.access(vm, physical), 0x80000001)
        self.assertEqual(vm.leaf(physical) & 31, 3)
        vm.events.clear()
        self.assertTrue(vm.call("unmapPage", second, 7, USER))
        self.assertEqual(self.important(vm), [
            ("tlbi", [0, 2]), ("pte", [slot, physical | 7 | 0x60]), ("tlbi", [0, 2])])
        self.assertEqual(self.access(vm, physical), 0)
        for directory in (first, second, third):
            self.assertEqual(vm.leaf(physical, directory) & 31, 7)
        self.assertTrue(vm.call("freePage", physical, 7, 5))
        reused = vm.call("allocPage", 8, 5)
        self.assertEqual(reused, physical)
        self.assertEqual([vm.memory[physical + i * 4] for i in range(1024)], [0] * 1024)
        self.assertTrue(vm.call("mapPage", third, 8, USER, physical, RW))

    def test_break_before_make_flushes_both_user_and_kernel_aliases(self):
        vm = self.vm(status=0x49)
        directory = self.space(vm)
        physical = vm.call("allocPage", 7, 5)
        self.assertTrue(vm.call("mapPage", directory, 7, USER, physical, RW))
        user, identity = self.user_slot(vm, directory), self.identity_slot(vm, physical)
        vm.memory.update({user: vm.memory[user] | 0x60})
        vm.memory = WatchedWrites(vm, [user, identity])
        for permissions, kernel_flags in ((RX, 3), (RW, 7)):
            vm.events.clear()
            self.assertTrue(vm.call("setPagePermissions", directory, 7, USER, permissions))
            self.assertEqual(self.important(vm), [
                ("pte", [user, 0]), ("tlbi", [0, 2]),
                ("pte", [identity, physical | kernel_flags]), ("tlbi", [0, 2]),
                ("pte", [user, physical | permissions | 0x60]), ("tlbi", [0, 2])])
            self.assertEqual(vm.controls[0], 0x49)

    def test_destroy_preserves_other_executable_alias_then_restores_w_before_reuse(self):
        vm = self.vm()
        first, second = self.space(vm), self.space(vm)
        physical = vm.call("allocPage", 7, 5)
        for directory in (first, second):
            self.assertTrue(vm.call("mapPage", directory, 7, USER, physical, RX))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", first, 7))
        self.assertEqual(self.access(vm, physical), 0x80000001)
        self.assertEqual(vm.leaf(physical) & 31, 3)
        identity = self.identity_slot(vm, physical)
        parent = second + USER // SUPER * 4
        old = vm.memory[parent]
        vm.memory = WatchedWrites(vm, [parent, identity])
        vm.events.clear()
        self.assertTrue(vm.call("mmuDestroyAddressSpace", second, 7))
        self.assertEqual(self.important(vm), [
            ("pte", [parent, old & ~1]), ("tlbi", [0, 2]), ("pte", [parent, 0]),
            ("pte", [identity, physical | 7]), ("tlbi", [0, 2])])
        self.assertTrue(vm.call("physicalPageAvailable", physical))
        self.assertEqual(self.access(vm, physical), 0)

    def test_protected_frames_stacks_and_devices_cannot_acquire_forbidden_aliases(self):
        vm = self.vm()
        directory = self.space(vm)
        stack = vm.call("allocPage", 7, 6)
        for physical in (0, PAGE, 0x10000, 0x15000, 0x7F000, 0x90000,
                         vm.globals["pageAccessReferences"] & ~(PAGE - 1),
                         0xFC000000, 0xFC3FF000, 0xFD000000, 0xFD002000):
            for flags in (RW, RX):
                before = self.snapshot(vm)
                self.assertFalse(vm.call("mapPage", directory, 7, USER, physical, flags))
                self.assertEqual(self.snapshot(vm), before)
        before = self.snapshot(vm)
        self.assertFalse(vm.call("mapPage", directory, 7, USER, stack, RX))
        self.assertEqual(self.snapshot(vm), before)
        self.assertTrue(vm.call("mapPage", directory, 7, USER, stack, RW))
        before = self.snapshot(vm)
        self.assertFalse(vm.call("setPagePermissions", directory, 7, USER, RX))
        self.assertEqual(self.snapshot(vm), before)
        for base in (0xFC000000, 0xFD000000):
            self.assertTrue(vm.call("mmuSplitSuperpage", directory, 7, base))
            for offset in range(0, SUPER, PAGE):
                self.assertEqual(vm.leaf(base + offset, directory) & (W | X | U), W)

    def test_executable_map_allocation_failure_does_not_change_window_or_counts(self):
        vm = self.vm(0x9E000)
        directory = self.space(vm)
        physical = vm.call("allocPage", 7, 5)
        before = self.snapshot(vm)
        self.assertFalse(vm.call("mapPage", directory, 7, USER, physical, RX))
        self.assertEqual(self.snapshot(vm), before)
        self.assertEqual(vm.leaf(physical) & 31, 7)
        self.assertEqual(self.access(vm, physical), 0)

    def test_access_count_overflow_is_rejected_without_mutation(self):
        for flags, access in ((RW, 0x7FFFFFFF), (RX, 0xFFFFFFFF)):
            vm = self.vm()
            directory = self.space(vm)
            physical = vm.call("allocPage", 7, 5)
            counter = vm.globals["pageAccessReferences"] + physical // PAGE * 4
            vm.memory.update({counter: access})  # boundary injection
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mapPage", directory, 7, USER, physical, flags))
            self.assertEqual(self.snapshot(vm), before)


if __name__ == "__main__":
    unittest.main()
