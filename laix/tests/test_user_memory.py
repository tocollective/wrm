"""Execute user-copy M ASTs with byte-addressed RAM; never build code.

Table walking and byte loops are the real source. CPU translation is a
fixture; every data access is checked against the active supervisor alias.
"""

import unittest

from source_m import SourceM
from test_kernel import LAIX
from test_address_space import PAGE, SUPER, USER, END, V, R, W, X, U, RW, RO, RX
from test_page_allocator import LockedWrites
from mlang import syntax as s
from mlang.typesys import size_of

EFAULT = (-14) & 0xFFFFFFFF


class UserCopyM(SourceM):
    def __init__(self):
        super().__init__(LAIX / "src/mm/mmu.m")
        self.accesses = []

    def data_access(self, address, write=False):
        # Any dereference of the user VA itself violates the copy protocol.
        assert not USER <= address < END, hex(address)
        assert not self.controls[0] & 1, "copy without memoryLock"
        leaf = self.leaf(address)
        required = V | (W if write else R)
        assert leaf & required == required, (hex(address), leaf)
        assert leaf & ~(PAGE - 1) == address & ~(PAGE - 1)
        self.accesses.append(("write" if write else "read", address))

    def expr(self, node, local):
        if isinstance(node, s.Index) and size_of(node.type) == 1:
            address = self.address(node, local)
            self.data_access(address)
            return (self.memory[address & ~3] >> ((address & 3) * 8)) & 255
        return super().expr(node, local)

    def write(self, target, value, local):
        if isinstance(target, s.Index) and size_of(target.type) == 1:
            address = self.address(target, local)
            self.data_access(address, write=True)
            shift = (address & 3) * 8
            slot = address & ~3
            self.memory[slot] = ((self.memory[slot] & ~(255 << shift)) |
                                 ((value & 255) << shift))
        else:
            super().write(target, value, local)


class UserMemoryTests(unittest.TestCase):
    def fixture(self, status=0x12, second_purpose=5):
        vm = UserCopyM()
        vm.memory = LockedWrites(vm)
        vm.controls[0] = status
        self.assertTrue(vm.call("memoryInit", 0x800000))
        self.assertTrue(vm.call("mmuInit"))
        directory = vm.call("mmuCreateAddressSpace", 7)
        first = vm.call("allocPage", 7, 5)
        kernel = vm.call("allocPage", 9, 2)  # separates physical user frames
        vm.memory.update({kernel + i: 0 for i in range(0, PAGE, 4)})
        second = vm.call("allocPage", 7, second_purpose)
        base = USER + SUPER - PAGE  # cross both page and directory-slot bounds
        for virtual, physical in ((base, first), (base + PAGE, second)):
            self.assertTrue(vm.call("mapPage", directory, 7, virtual, physical, RW))
        self.assertTrue(vm.call("mmuSwitchAddressSpace", directory, 7, 3))
        return vm, directory, base, first, second, kernel

    def seed(self, vm, address, values):
        for i, value in enumerate(values):
            slot, shift = (address + i) & ~3, ((address + i) & 3) * 8
            vm.memory.update({slot: (vm.memory[slot] & ~(255 << shift)) | value << shift})

    def bytes(self, vm, address, count):
        return bytes((vm.memory[(address + i) & ~3] >> (((address + i) & 3) * 8)) & 255
                     for i in range(count))

    def slot(self, vm, directory, address):
        table = vm.memory[directory + address // SUPER * 4] & ~(PAGE - 1)
        return table + address // PAGE % 1024 * 4

    def reject_both(self, vm, directory, address, count, kernel, owner=7):
        before, ptbr, status = dict(vm.memory), vm.ptbr, vm.controls[0]
        for function, args in (
                ("copyFromUser", (directory, owner, kernel, address, count)),
                ("copyToUser", (directory, owner, address, kernel, count))):
            vm.accesses.clear()
            self.assertEqual(vm.call(function, *args), EFAULT)
            self.assertEqual(vm.accesses, [])
            self.assertEqual(dict(vm.memory), before)
            self.assertEqual(vm.ptbr, ptbr)
            self.assertEqual(vm.controls[0], status)

    def test_byte_ranges_reject_wrap_and_accept_exact_exclusive_end(self):
        vm, *_ = self.fixture()
        for address, count, expected in (
                (USER + 1, 1, True), (END - 1, 1, True),
                (USER, END - USER, True), (END - PAGE + 1, PAGE, False),
                (0, 1, False), (USER - 1, 2, False), (END, 1, False),
                (USER, 0xFFFFFFFF, False), (0xFFFFFFFE, 4, False)):
            with self.subTest(address=hex(address), count=count):
                self.assertEqual(vm.call("mmuUserByteRangeValid", address, count), expected)
        for address in (0, END, 0xFFFFFFFF):
            self.assertTrue(vm.call("mmuUserByteRangeValid", address, 0))

    def test_unaligned_copies_cross_noncontiguous_pages_and_directory_slots(self):
        for status, purpose in ((0, 5), (1, 6), (0x12, 5), (0x13, 6)):
            with self.subTest(status=status, purpose=purpose):
                vm, directory, base, first, second, kernel = self.fixture(status, purpose)
                data = bytes([0, 255, 128, 1, 17, 240, 3, 4, 5, 6, 7])
                self.seed(vm, first + PAGE - 3, data[:3])
                self.seed(vm, second, data[3:])
                before, ptbr = dict(vm.memory), vm.ptbr
                self.assertEqual(vm.call("copyFromUser", directory, 7, kernel + 1,
                                         base + PAGE - 3, len(data)), 0)
                self.assertEqual(self.bytes(vm, kernel + 1, len(data)), data)
                self.assertEqual(self.bytes(vm, kernel, 1), b"\0")
                self.assertEqual(self.bytes(vm, kernel + 1 + len(data), 1), b"\0")
                for address in range(first, first + PAGE, 4):
                    self.assertEqual(vm.memory[address], before[address])
                changed = bytes(reversed(data))
                self.seed(vm, kernel + 1, changed)
                self.assertEqual(vm.call("copyToUser", directory, 7, base + PAGE - 3,
                                         kernel + 1, len(data)), 0)
                self.assertEqual(self.bytes(vm, first + PAGE - 3, 3) +
                                 self.bytes(vm, second, len(data) - 3), changed)
                self.assertEqual(self.bytes(vm, first + PAGE - 4, 1), b"\0")
                self.assertEqual(self.bytes(vm, second + len(data) - 3, 1), b"\0")
                self.assertEqual(vm.controls[0], status)
                self.assertEqual(vm.ptbr, ptbr)

    def test_full_validation_prevents_partial_copy_on_bad_later_page(self):
        vm, directory, base, first, second, kernel = self.fixture()
        slot = self.slot(vm, directory, base + PAGE)
        good = vm.memory[slot]
        foreign = vm.call("allocPage", 8, 5)
        for leaf in (0, good & ~V, good & ~U, good & ~R,
                     foreign | RW, kernel | RW, 0xFFFFF000 | RW, good | 0x80):
            with self.subTest(leaf=hex(leaf)):
                vm.memory.update({slot: leaf})
                # The physical alias remains supervisor RW even without user U.
                self.assertEqual(vm.leaf(second) & (V | R | W), V | R | W)
                self.reject_both(vm, directory, base + PAGE - 1, 2, kernel)
        vm.memory.update({slot: good})
        # An unmapped page in the middle also rejects the complete range.
        self.reject_both(vm, directory, base, 3 * PAGE, kernel)
        vm.memory.update({slot: 0})
        third = vm.call("allocPage", 7, 5)
        self.assertTrue(vm.call("mapPage", directory, 7, base + 2 * PAGE, third, RW))
        self.reject_both(vm, directory, base, 2 * PAGE + 1, kernel)

    def test_readonly_and_executable_user_pages_can_only_be_read(self):
        vm, directory, base, first, second, kernel = self.fixture()
        for permissions in (RO, RX):
            self.assertTrue(vm.call("setPagePermissions", directory, 7, base + PAGE, permissions))
            self.assertTrue(vm.call("mmuUserBufferValid", directory, 7, base + PAGE - 1, 2, R))
            self.assertFalse(vm.call("mmuUserBufferValid", directory, 7, base + PAGE - 1, 2, W))
            self.assertEqual(vm.call("copyFromUser", directory, 7, kernel, base + PAGE - 1, 2), 0)
            before = dict(vm.memory)
            vm.accesses.clear()
            self.assertEqual(vm.call("copyToUser", directory, 7, base + PAGE - 1, kernel, 2), EFAULT)
            self.assertEqual(vm.accesses, [])
            self.assertEqual(dict(vm.memory), before)

    def test_invalid_roots_supervisor_addresses_and_overflows_never_access_data(self):
        vm, directory, base, first, second, kernel = self.fixture()
        for address, size in ((0, 1), (first, 1), (0xFD002000, 1), (base, 0xFFFFFFFF),
                              (END - 1, 2), (0xFFFFFFFE, 4), (END - PAGE - 1, 2)):
            self.reject_both(vm, directory, address, size, kernel)
        for root, owner in ((0, 7), (directory + 1, 7), (directory, 8),
                            (first, 7), (0xFFFFFFFF, 7)):
            self.reject_both(vm, root, base, 1, kernel, owner)
        fresh = vm.call("allocPage", 7, 3)  # owned but not initialized/pinned
        self.reject_both(vm, fresh, base, 1, kernel)
        self.assertTrue(vm.call("mmuActivateKernel"))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", directory, 7))
        self.reject_both(vm, directory, base, 1, kernel)

    def test_user_superpage_and_foreign_table_are_rejected_before_dereference(self):
        vm, directory, base, first, second, kernel = self.fixture()
        parent = directory + (base + PAGE) // SUPER * 4
        for entry in (second | RW, kernel | V, 0xFFFFF000 | V):
            vm.memory.update({parent: entry})
            self.reject_both(vm, directory, base + PAGE - 1, 2, kernel)

    def test_supervisor_alias_is_proven_before_copy_and_preserves_wx(self):
        vm, directory, base, first, second, kernel = self.fixture()
        slot = self.slot(vm, vm.globals["kernelPageDirectory"], second)
        good = vm.memory[slot]
        for alias in (0, good & ~R, good | U, good | X, first | V | R | W):
            vm.memory.update({slot: alias})
            self.reject_both(vm, directory, base + PAGE - 1, 2, kernel)
        vm.memory.update({slot: good & ~W})
        self.assertEqual(vm.call("copyFromUser", directory, 7, kernel, base + PAGE, 1), 0)
        vm.accesses.clear()
        self.assertEqual(vm.call("copyToUser", directory, 7, base + PAGE - 1, kernel, 2), EFAULT)
        self.assertEqual(vm.accesses, [])

    def test_empty_copy_and_last_user_byte(self):
        vm, directory, base, first, second, kernel = self.fixture(status=0x12)
        for address in (0, END, 0xFFFFFFFF):
            self.assertEqual(vm.call("copyFromUser", directory, 7, 0, address, 0), 0)
            self.assertEqual(vm.call("copyToUser", directory, 7, address, 0, 0), 0)
        self.assertEqual(vm.accesses, [])
        self.assertTrue(vm.call("mapPage", directory, 7, END - PAGE, first, RW))
        self.seed(vm, kernel, b"\xff")
        self.assertEqual(vm.call("copyToUser", directory, 7, END - 1, kernel, 1), 0)
        self.assertEqual(self.bytes(vm, first + PAGE - 1, 1), b"\xff")
        self.assertEqual(vm.controls[0], 0x12)
        for access in (0, X, U, V | R, 0xFFFFFFFF):
            self.assertFalse(vm.call("mmuUserBufferValid", directory, 7, base, 1, access))


if __name__ == "__main__":
    unittest.main()
