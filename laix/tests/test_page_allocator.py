"""Execute the checked allocator AST; no assembly, linking or code generation."""

import unittest

from test_kernel import LAIX, check_m
from test_memory import BootstrapM, reserved_end
from mlang.typesys import size_of

PAGE = 4096
OUTPUT, PURPOSES = 0x81000, 0x82000  # trusted reserved kernel buffers


class LockedWrites(dict):
    def __init__(self, vm):
        super().__init__(vm.memory)
        self.vm = vm

    def __setitem__(self, address, value):
        if self.vm.controls[0] & 1:
            raise AssertionError(f"write with interrupts enabled: {address:#x}")
        super().__setitem__(address, value)


class AllocatorTests(unittest.TestCase):
    def vm(self, ram=0xA0123, status=0):
        vm = BootstrapM()
        vm.memory = LockedWrites(vm)
        vm.controls[0] = status
        self.assertTrue(vm.call("memoryInit", ram))
        self.assertEqual(vm.controls[0], status)
        return vm

    def snapshot(self, vm):
        return dict(vm.memory), dict(vm.globals)

    def batch(self, vm, purposes, pages=None):
        vm.memory.update({PURPOSES + 4 * i: purpose for i, purpose in enumerate(purposes)})
        vm.memory.update({OUTPUT + 4 * i: page for i, page in
                          enumerate(pages or [0] * len(purposes))})

    def outputs(self, vm, count):
        return [vm.memory[OUTPUT + 4 * i] for i in range(count)]

    def test_metadata_tracks_installed_ram_and_is_reserved_before_allocation(self):
        for ram in (0x100000, 0x200123, 0x08000000):
            vm = BootstrapM(bss_end=0x9B004)
            # Model both static bitmaps inside the real BSS reservation.
            for name, address in (("pageBitmap", 0x99000), ("spaceInitialized", 0x9A000)):
                decl = vm.decls[name]
                self.assertEqual(size_of(decl.sym.type), PAGE)
                vm.addresses[name] = vm.globals[name] = address
            names = ("pageOwners", "pagePurposes", "pageReferences", "pageAccessReferences")
            for name in names:
                self.assertEqual(size_of(vm.decls[name].sym.type), 4)  # pointers, not MAX_PAGES arrays
            self.assertTrue(vm.call("memoryInit", ram))
            records = ram // PAGE * 4
            self.assertEqual([vm.globals[n] for n in names],
                             [0x9C000 + i * records for i in range(4)])
            end = reserved_end(ram, 0x9B004)
            self.assertEqual(vm.globals["kernelReservedEnd"], end)
            for page in range(0x99000, end, PAGE):
                self.assertFalse(vm.call("physicalPageAvailable", page))
                self.assertFalse(vm.call("freePage", page, 1, 2))
            self.assertEqual(vm.call("allocPage", 1, 2), end)

    def test_missing_metadata_room_has_no_writes_or_partial_initialization(self):
        # BSS fits, but the separately reserved records do not. Also check the
        # incomplete tail and maximum-RAM case requiring 512 KiB of records.
        for ram, bss in ((0x99000, 0x98404), (0x9AFFF, 0x99001),
                         (0x08000000, 0x07FA0001)):
            vm = BootstrapM(bss_end=bss)
            before = self.snapshot(vm)
            self.assertFalse(vm.call("memoryInit", ram))
            self.assertEqual(self.snapshot(vm), before)

    def test_one_mib_static_budget_and_allocator_mmu_lifecycle(self):
        # Read declaration sizes only, without laying out or emitting code.
        # A fixed 64 KiB BSS budget catches MAX_PAGES-sized array regressions.
        modules = check_m(LAIX / "src/main.m")
        budget = sum(size_of(d.sym.type) + (d.align.const - 1 if d.align else 3)
                     for module in modules for d in module.decls
                     if hasattr(d, "mut") and not d.extern and d.init is None)
        self.assertLess(budget, 0x10000)
        # Conservative image/BSS fixture: 640 KiB, including the kernel stack.
        vm = BootstrapM(bss_end=0xA0000)
        self.assertTrue(vm.call("memoryInit", 0x100000))
        self.assertEqual(vm.globals["kernelReservedEnd"], 0xA1000)
        self.assertTrue(vm.call("mmuInit"))
        directory = vm.call("mmuCreateAddressSpace", 7)
        physical = vm.call("allocPage", 7, 5)
        self.assertNotEqual(directory, 0)
        self.assertNotEqual(physical, 0)
        self.assertTrue(vm.call("mapPage", directory, 7, 0x40000000, physical, 23))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", directory, 7))
        self.assertTrue(vm.call("physicalPageAvailable", physical))

    def test_exhaustion_unique_addresses_and_reuse_for_new_owner(self):
        # Include minimum usable RAM, an empty pool, a partial page and the
        # maximum supported RAM (all 32768 frame records, bitmap boundaries).
        for ram in (0x9A000, 0x9B000, 0xA0123, 0x08000000):
            with self.subTest(ram=hex(ram)):
                vm = self.vm(ram)
                issued = []
                while (address := vm.call("allocPage", 42, 2)) != 0:
                    issued.append(address)
                self.assertEqual(issued, list(range(reserved_end(ram), ram & ~4095, PAGE)))
                before = self.snapshot(vm)
                self.assertEqual(vm.call("allocPage", 43, 2), 0)
                self.assertEqual(self.snapshot(vm), before)
                if issued:
                    address = issued[len(issued) // 2]
                    self.assertTrue(vm.call("freePage", address, 42, 2))
                    self.assertTrue(vm.call("physicalPageAvailable", address))
                    self.assertEqual(vm.call("allocPage", 43, 3), address)
                    self.assertTrue(vm.call("physicalPageOwned", address, 43, 3))
                    self.assertFalse(vm.call("physicalPageOwned", address, 42, 2))
                    self.assertEqual(vm.call("allocPage", 44, 2), 0)

    def test_invalid_allocation_and_free_preserve_accounting(self):
        vm = self.vm()
        for owner, purpose in ((0, 2), (1, 0), (1, 1), (1, 8), (1, 0xFFFFFFFF)):
            before = self.snapshot(vm)
            self.assertEqual(vm.call("allocPage", owner, purpose), 0)
            self.assertEqual(self.snapshot(vm), before)
        address = vm.call("allocPage", 7, 4)
        for bad_address, owner, purpose in ((address, 8, 4), (address, 7, 3),
                (address, 0, 4), (address + 1, 7, 4), (0, 7, 4), (0x90000, 7, 4),
                (0x98000, 7, 4), (0xA0000, 7, 4), (0xFFFFFFFF, 7, 4)):
            before = self.snapshot(vm)
            self.assertFalse(vm.call("freePage", bad_address, owner, purpose))
            self.assertEqual(self.snapshot(vm), before)
        self.assertTrue(vm.call("freePage", address, 7, 4))
        before = self.snapshot(vm)
        self.assertFalse(vm.call("freePage", address, 7, 4))
        self.assertFalse(vm.call("memoryInit", 0x100000))
        self.assertEqual(self.snapshot(vm), before)

    def test_user_frames_clear_every_word_on_each_transfer(self):
        vm = self.vm()
        for purpose in (vm.globals["PAGE_USER"], vm.globals["PAGE_USER_STACK"]):
            address = vm.call("allocPage", 7, 2)
            vm.memory.update({address + i: 0xDEADBEEF for i in range(0, PAGE, 4)})
            vm.memory.update({address - 4: 0xAABBCCDD, address + PAGE: 0xAABBCCDD})
            self.assertTrue(vm.call("freePage", address, 7, 2))
            self.assertEqual(vm.call("allocPage", 8, purpose), address)
            self.assertEqual([vm.memory[address + i] for i in range(0, PAGE, 4)], [0] * 1024)
            self.assertEqual(vm.memory[address - 4], 0xAABBCCDD)
            self.assertEqual(vm.memory[address + PAGE], 0xAABBCCDD)
            self.assertTrue(vm.call("freePage", address, 8, purpose))

    def test_batch_rolls_back_at_each_partial_allocation_failure(self):
        for available in range(5):
            vm = self.vm(0x9A000 + (available + 1) * PAGE)
            existing = vm.call("allocPage", 9, 2)
            self.batch(vm, [3, 4, 5, 6, 7])
            before = self.snapshot(vm)
            self.assertFalse(vm.call("allocTaskPages", 9, PURPOSES, OUTPUT, 5))
            # Failed user allocations may have cleared frame contents; compare
            # the ledger and metadata, not the former free frame contents.
            self.assertEqual(vm.globals, before[1])
            for name in ("pageBitmap", "pageOwners", "pagePurposes", "pageReferences", "pageAccessReferences"):
                start = vm.globals[name]
                size = (size_of(vm.decls[name].sym.type) if name == "pageBitmap"
                        else vm.globals["kernelRamEnd"] // PAGE * 4)
                self.assertEqual({a: v for a, v in vm.memory.items() if start <= a < start + size},
                                 {a: v for a, v in before[0].items() if start <= a < start + size})
            self.assertEqual(self.outputs(vm, 5), [0] * 5)
            self.assertTrue(vm.call("physicalPageOwned", existing, 9, 2))

    def test_later_creation_failure_releases_only_its_batch(self):
        vm = self.vm(0xA1000)
        existing = vm.call("allocPage", 1, 2)
        self.batch(vm, [3, 4, 5, 6, 7])
        self.assertTrue(vm.call("allocTaskPages", 1, PURPOSES, OUTPUT, 5))
        pages = self.outputs(vm, 5)
        self.assertEqual(len(set(pages)), 5)
        for page, purpose in zip(pages, [3, 4, 5, 6, 7]):
            self.assertTrue(vm.call("physicalPageOwned", page, 1, purpose))
        # The prospective task fails after allocation (e.g. image validation).
        self.assertTrue(vm.call("freeTaskPages", 1, PURPOSES, OUTPUT, 5))
        self.assertEqual(self.outputs(vm, 5), [0] * 5)
        for page in pages:
            self.assertTrue(vm.call("physicalPageAvailable", page))
        self.assertTrue(vm.call("physicalPageOwned", existing, 1, 2))
        before = self.snapshot(vm)
        self.assertFalse(vm.call("freeTaskPages", 1, PURPOSES, OUTPUT, 5))
        self.assertEqual(self.snapshot(vm), before)

    def test_batch_validation_has_no_partial_side_effects(self):
        vm = self.vm()
        for owner, purposes, pages, count in ((0, [3], [0], 1), (1, [3, 1], [0, 0], 2),
                (1, [3, 4], [0, 0x99000], 2), (1, [3], [0], 0),
                (1, [3], [0], 32769)):
            self.batch(vm, purposes, pages)
            before = self.snapshot(vm)
            self.assertFalse(vm.call("allocTaskPages", owner, PURPOSES, OUTPUT, count))
            self.assertEqual(self.snapshot(vm), before)
        for name in ("allocTaskPages", "freeTaskPages"):
            for purposes, pages in ((0, OUTPUT), (PURPOSES, 0)):
                before = self.snapshot(vm)
                self.assertFalse(vm.call(name, 1, purposes, pages, 1))
                self.assertEqual(self.snapshot(vm), before)
        self.batch(vm, [3, 4])
        self.assertTrue(vm.call("allocTaskPages", 1, PURPOSES, OUTPUT, 2))
        original = self.outputs(vm, 2)
        for owner, purposes, pages in ((2, [3, 4], original),
                (1, [3, 2], original), (1, [3, 3], [original[0]] * 2)):
            self.batch(vm, purposes, pages)
            before = self.snapshot(vm)
            self.assertFalse(vm.call("freeTaskPages", owner, PURPOSES, OUTPUT, 2))
            self.assertEqual(self.snapshot(vm), before)

    def test_interrupt_state_preserved_on_success_failure_and_nested_calls(self):
        for status in (0, 1, 0x10, 0x1B, 0x62, 0x63):
            vm = self.vm(status=status)
            self.batch(vm, [3, 5, 6])
            for name, args, expected in (
                    ("allocTaskPages", (1, PURPOSES, OUTPUT, 3), True),
                    ("freeTaskPages", (1, PURPOSES, OUTPUT, 3), True),
                    ("allocPage", (0, 2), 0),
                    ("freePage", (0, 1, 2), False),
                    ("physicalPageAvailable", (0,), False),
                    ("physicalPageOwned", (0, 1, 2), False),
                    ("memoryInit", (0,), False)):
                self.assertEqual(vm.call(name, *args), expected)
                self.assertEqual(vm.controls[0], status)

    def test_directory_initialization_rejects_unowned_foreign_and_wrong_purpose(self):
        vm = self.vm(0x100000)
        self.assertTrue(vm.call("mmuInit"))
        free = vm.globals["kernelReservedEnd"] + 2 * PAGE
        self.assertFalse(vm.call("mmuInitAddressSpace", free, 1))
        directory = vm.call("allocPage", 1, 3)
        other = vm.call("allocPage", 1, 2)
        for address, owner in ((directory, 2), (other, 1), (directory + 1, 1)):
            before = self.snapshot(vm)
            self.assertFalse(vm.call("mmuInitAddressSpace", address, owner))
            self.assertEqual(self.snapshot(vm), before)
        self.assertTrue(vm.call("mmuInitAddressSpace", directory, 1))
        vm.ptbr = directory | 1
        before = self.snapshot(vm)
        self.assertFalse(vm.call("mmuInitAddressSpace", directory, 1))
        self.assertEqual(self.snapshot(vm), before)
        vm.ptbr = vm.globals["kernelPageDirectory"] | 1
        self.assertFalse(vm.call("freePage", directory, 1, 3))
        self.assertTrue(vm.call("mmuDestroyAddressSpace", directory, 1))
        self.assertFalse(vm.call("mmuInitAddressSpace", directory, 1))

    def test_references_reject_underflow_overflow_and_foreign_changes(self):
        vm = self.vm(status=0x63)
        address = vm.call("allocPage", 7, 5)
        before = self.snapshot(vm)
        self.assertFalse(vm.call("releasePage", address, 7, 5))
        self.assertEqual(self.snapshot(vm), before)
        for name in ("retainPage", "releasePage"):
            for page, owner, purpose in ((address, 8, 5), (address, 7, 6),
                                         (address + 1, 7, 5), (0, 7, 5)):
                before = self.snapshot(vm)
                self.assertFalse(vm.call(name, page, owner, purpose))
                self.assertEqual(self.snapshot(vm), before)
        refs = vm.globals["pageReferences"] + address // PAGE * 4
        vm.memory.update({refs: 0xFFFFFFFF})
        before = self.snapshot(vm)
        self.assertFalse(vm.call("retainPage", address, 7, 5))
        self.assertEqual(self.snapshot(vm), before)
        self.assertTrue(vm.call("releasePage", address, 7, 5))
        self.assertEqual(vm.call("physicalPageReferences", address), 0xFFFFFFFE)
        self.assertEqual(vm.controls[0], 0x63)

    def test_batch_free_refuses_live_reference_without_freeing_prior_slots(self):
        vm = self.vm()
        self.batch(vm, [5, 6])
        self.assertTrue(vm.call("allocTaskPages", 7, PURPOSES, OUTPUT, 2))
        first, second = self.outputs(vm, 2)
        self.assertTrue(vm.call("retainPage", second, 7, 6))
        before = self.snapshot(vm)
        self.assertFalse(vm.call("freeTaskPages", 7, PURPOSES, OUTPUT, 2))
        self.assertEqual(self.snapshot(vm), before)
        self.assertTrue(vm.call("physicalPageOwned", first, 7, 5))
        self.assertTrue(vm.call("releasePage", second, 7, 6))
        self.assertTrue(vm.call("freeTaskPages", 7, PURPOSES, OUTPUT, 2))


if __name__ == "__main__":
    unittest.main()
