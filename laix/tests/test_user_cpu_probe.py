"""Check CPU-probe context oracles, without a build or CPU simulation."""

import unittest

from probe_user_cpu import check_user_context, TaskProbe, USER_STATUS, EXL, PUM
from probe_unexpected_traps import LAYOUT


def context():
    registers = {f"r{i}": 0xA5010000 + i * 0x101 for i in range(32)}
    registers.update(r0=0, r30=0, pc=0x40002000, status=USER_STATUS,
                     fcsr=0x61, ptbr=0x9D001)
    return registers


class UserCpuProbeTests(unittest.TestCase):
    def test_accepts_cpu_trap_and_exact_syscall_return(self):
        before = context()
        check_user_context(before, dict(before, status=EXL | PUM), trapped=True)
        check_user_context(before, dict(before, pc=before["pc"] + 4, r1=0xFFFFFFDA), 0xFFFFFFDA)

    def test_rejects_changed_gprs_fcsr_and_ptbr_in_trap_and_return(self):
        before = context()
        for trapped in (False, True):
            after = dict(before, status=EXL | PUM if trapped else USER_STATUS)
            if not trapped:
                after.update(pc=before["pc"] + 4, r1=0xFFFFFFDA)
            for name in [f"r{i}" for i in range(32)] + ["fcsr", "ptbr", "status"]:
                with self.subTest(trapped=trapped, register=name):
                    bad = dict(after)
                    bad[name] ^= 1
                    with self.assertRaises(ValueError):
                        check_user_context(before, bad, None if trapped else 0xFFFFFFDA, trapped)

    def test_rejects_wrong_cpu_mode_and_skipped_or_repeated_syscall(self):
        before = context()
        after = dict(before, pc=before["pc"] + 4, r1=0xFFFFFFDA)
        for status in (0, EXL, EXL | PUM, USER_STATUS | 1, USER_STATUS | EXL):
            with self.assertRaises(ValueError):
                check_user_context(dict(before, status=status), after, 0xFFFFFFDA)
        for pc in (before["pc"], before["pc"] + 8):
            with self.assertRaises(ValueError):
                check_user_context(before, dict(after, pc=pc), 0xFFFFFFDA)

    def test_saved_frame_requires_every_gpr_control_field_and_task_stack(self):
        before = context()
        frame, top = 0x93000 - LAYOUT["TF_SIZE"], 0x93000
        words = [before[f"r{i}"] for i in range(32)] + [before["pc"], EXL | PUM, 12, 0,
                                                       before["fcsr"], before["ptbr"], 0, 0]
        probe = TaskProbe.__new__(TaskProbe)
        probe.s = dict(taskKernelStackBottom=0x91000, taskKernelStackTop=top)
        probe.frame_words = lambda _: list(words)
        probe.check_frame(frame, before, 12, before["pc"], badaddr=0)
        for index in range(38):
            with self.subTest(field=index):
                words[index] ^= 1
                with self.assertRaises(ValueError):
                    probe.check_frame(frame, before, 12, before["pc"], badaddr=0)
                words[index] ^= 1
        for bad_frame in (0, 0x8F000 - LAYOUT["TF_SIZE"], frame - 8, frame + 8):
            with self.assertRaises(ValueError):
                probe.check_frame(bad_frame, before, 12, before["pc"])


if __name__ == "__main__":
    unittest.main()
