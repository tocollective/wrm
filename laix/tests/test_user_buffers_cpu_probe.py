"""Check buffer CPU-probe preflight and result oracles; never build code."""

import unittest
from unittest.mock import patch

from probe_user_buffers_cpu import EFAULT, EXL, HELPERS, check_copy_return, missing_helpers, trampoline_sources


class BufferCpuProbeTests(unittest.TestCase):
    def context(self):
        result = {f"r{i}": 0xA5010000 + i * 0x101 for i in range(32)}
        result.update(status=EXL, r30=0x8EF88, ptbr=0x9E071, fcsr=0x61)
        return result

    def test_preflight_requires_all_actual_copy_helpers(self):
        self.assertEqual(missing_helpers({}), sorted(HELPERS))
        complete = {name: 0x10000 + i * 4 for i, name in enumerate(sorted(HELPERS))}
        self.assertEqual(missing_helpers(complete), [])
        for name in HELPERS:
            incomplete = {key: value for key, value in complete.items() if key != name}
            self.assertEqual(missing_helpers(incomplete), [name])

    def test_accepts_success_and_efault_only_inside_exl(self):
        before = self.context()
        for result in (0, EFAULT):
            check_copy_return(before, dict(before, r1=result), result)
        for status in (0, 4, 24, EXL | 1):
            with self.assertRaises(ValueError):
                check_copy_return(dict(before, status=status), dict(before, r1=EFAULT), EFAULT)

    def test_rejects_wrong_error_mode_stack_ptbr_fcsr_and_saved_registers(self):
        before = self.context()
        after = dict(before, r1=EFAULT)
        for name in ["r1", "status", "r30", "ptbr", "fcsr"] + [f"r{i}" for i in range(10, 30)]:
            with self.subTest(register=name):
                bad = dict(after)
                bad[name] ^= 1
                with self.assertRaises(ValueError):
                    check_copy_return(before, bad, EFAULT)

    def test_trampoline_selects_existing_instructions_in_required_order(self):
        instructions = {0x10000: "break", 0x10004: "mtcr status, r0",
                        0x10008: "jalr r0, r12, 0", 0x1000C: "mtcr status, r10"}
        symbols = dict(__start_text=0x10000, __stop_text=0x10010)
        with patch("probe_user_buffers_cpu.instruction", side_effect=lambda data, pc: pc), \
                patch("probe_user_buffers_cpu.disassemble", side_effect=lambda word, pc: instructions[pc]):
            self.assertEqual(trampoline_sources(b"", symbols), [0x1000C, 0x10008, 0x10004, 0x10000])
            instructions[0x10000] = "syscall"
            with self.assertRaises(ValueError):
                trampoline_sources(b"", symbols)


if __name__ == "__main__":
    unittest.main()
