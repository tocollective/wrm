"""Check the monitor probe's assertions with fixtures; never build code."""

import unittest

from probe_unexpected_traps import check_panic, USER_SP


def fixture(cause, user):
    epc = 0x410880 if user else 0x10880
    before = dict(status=0x18 if user else 0x10, fcsr=0x61,
                  badaddr=0, ptbr=0x8C001)
    before.update({f"r{i}": 0xA000 + i for i in range(32)})
    before.update(r0=0, r30=USER_SP if user else 0x8AFE0)
    reason = "unexpected breakpoint" if cause == 13 else "unexpected syscall"
    output = (f"LA/IX PANIC: {reason}\n"
              f"stage=trap-selftest origin={'user' if user else 'supervisor'}\n"
              f"cause={cause:08X}\nepc={epc:08X} badaddr=00000000\n"
              f"status={before['status']:08X} ptbr=0008C001 fcsr=00000061\n" +
              " ".join(f"r{i:02d}={before[f'r{i}']:08X}" for i in range(32)))
    return output, epc, before


class UnexpectedTrapProbeTests(unittest.TestCase):
    def test_accepts_fatal_supervisor_and_user_break_and_syscall(self):
        for cause in (12, 13):
            for user in (False, True):
                with self.subTest(cause=cause, user=user):
                    output, epc, before = fixture(cause, user)
                    check_panic(output, 254, cause, user, epc, before)

    def test_rejects_skipped_instruction_wrong_origin_and_syscall_result(self):
        output, epc, before = fixture(12, True)
        for old, new in (("epc=00410880", "epc=00410884"),
                         ("origin=user", "origin=supervisor"),
                         ("unexpected syscall", "unexpected exception"),
                         ("cause=0000000C", "cause=0000000D"),
                         ("r01=0000A001", "r01=FFFFFFDA"),
                         ("r30=FFFFFFF8", "r30=0008AFE0"),
                         ("status=00000018", "status=00000010"),
                         ("ptbr=0008C001", "ptbr=0008C000"),
                         ("fcsr=00000061", "fcsr=00000000"),
                         ("badaddr=00000000", "badaddr=00000004"),
                         ("r31=0000A01F", "")):
            with self.subTest(field=old):
                with self.assertRaises(ValueError):
                    check_panic(output.replace(old, new), 254, 12, True, epc, before)

    def test_rejects_success_exit_missing_dump_and_repeated_panic(self):
        output, epc, before = fixture(13, False)
        for text, code in ((output, 0), ("", 254), (output + "\nLA/IX PANIC:", 254)):
            with self.subTest(code=code, text=text[-20:]):
                with self.assertRaises(ValueError):
                    check_panic(text, code, 13, False, epc, before)


if __name__ == "__main__":
    unittest.main()
