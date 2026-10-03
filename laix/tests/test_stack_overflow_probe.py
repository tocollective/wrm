"""Verify stack-overflow monitor assertions; never build or execute code."""

import unittest

from probe_stack_overflow import check_prologue, check_saved_frame


class StackOverflowProbeTests(unittest.TestCase):
    def test_fixture_requires_stack_allocation_followed_by_the_ra_store(self):
        # Existing ISA encodings used only as decoder input.
        prologue = bytes.fromhex("20DE E3FF 4ADF 1300")
        check_prologue(b"\0" * 16 + prologue, 0x10010)
        for wrong in (prologue[:4] + b"\0" * 4, b"\0" * 4 + prologue[4:]):
            with self.subTest(wrong=wrong):
                with self.assertRaises(ValueError):
                    check_prologue(b"\0" * 16 + wrong, 0x10010)

    def test_static_frame_requires_every_original_register_and_control(self):
        before = {f"r{i}": 0xA5010000 + i for i in range(32)}
        before.update(r0=0, r30=0x88FF8, epc=0x10218, status=16, cause=10,
                      badaddr=0x88FFC, fcsr=0x61, ptbr=0x8C001)
        words = [before[f"r{i}"] for i in range(32)] + [0x10218, 16, 10, 0x88FFC, 0x61, 0x8C001, 0, 0]
        check_saved_frame(words, before)
        for index in range(len(words)):
            with self.subTest(index=index):
                wrong = list(words)
                wrong[index] ^= 4
                with self.assertRaises(ValueError):
                    check_saved_frame(wrong, before)


if __name__ == "__main__":
    unittest.main()
