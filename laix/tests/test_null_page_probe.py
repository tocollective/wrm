"""Verify low-page probe assertions without running or building an image."""

import unittest

from probe_null_page import check_entry_state, check_low_mapping, rom_call_offset


class NullPageProbeTests(unittest.TestCase):
    def test_entry_state_requires_trusted_stack_and_zero_scratch(self):
        symbols = dict(kernelStackBottom=0x89000, kernelStackTop=0x8B000)
        words = [0x8B000, 0x89000, 0x8B000, 0]
        check_entry_state(words, symbols)
        for index in range(4):
            with self.subTest(index=index):
                wrong = list(words)
                wrong[index] ^= 4
                with self.assertRaises(ValueError):
                    check_entry_state(wrong, symbols)

    def test_page_zero_is_absent_and_page_one_is_supervisor_identity_rw(self):
        check_low_mapping(0x8D001, [0, 0x1007])
        check_low_mapping(0x8D001, [0, 0x1067])  # hardware A/D bits are allowed
        for directory, leaves in ((0x8D000, [0, 0x1007]),
                                  (0x00007, [0, 0x1007]),  # low superpage exposes NULL
                                  (0x8D001, [7, 0x1007]),
                                  (0x8D001, [0, 0x2007]),  # wrong physical page
                                  (0x8D001, [0, 0x1017]),  # user access
                                  (0x8D001, [0, 0x100F]),  # executable
                                  (0x8D001, [0, 0x1003]),  # not writable
                                  (0x8D001, [0, 0x1006])):  # invalid
            with self.subTest(directory=directory, leaves=leaves):
                with self.assertRaises(ValueError):
                    check_low_mapping(directory, leaves)

    def test_rom_fixture_requires_a_real_indirect_call_with_link(self):
        # Existing ISA encodings, used only as decoder fixtures.
        call = bytes.fromhex("613F0000")  # jalr r31, r1, 0
        jump = bytes.fromhex("61200000")  # jalr r0, r1, 0
        self.assertEqual(rom_call_offset(b"\0" * 8 + call), 8)
        for data in (b"", b"\0" * 16, jump, call[:3]):
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    rom_call_offset(data)


if __name__ == "__main__":
    unittest.main()
