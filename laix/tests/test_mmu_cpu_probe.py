"""Check CPU-probe fault oracles with fixtures; no building or CPU simulation."""

import unittest

from probe_mmu_cpu import check_fault


def fixture(user=False):
    registers = {f"r{i}": 0xA5010000 + i for i in range(32)}
    registers.update(r0=0, status=24 if user else 16, cause=10,
                     badaddr=0x40000000, epc=0x40000040 if user else 0x18BA8,
                     ptbr=0x99071, fcsr=0x61)
    output = ("LA/IX PANIC: unexpected exception\n"
              f"stage=probe-test origin={'user' if user else 'supervisor'}\n" +
              " ".join(f"{name}={registers[name]:08X}" for name in
                       ("cause", "badaddr", "epc", "status", "ptbr", "fcsr")) + "\n" +
              " ".join(f"r{i:02d}={registers[f'r{i}']:08X}" for i in range(32)))
    return registers, output


class MmuCpuProbeTests(unittest.TestCase):
    def verify(self, registers, output, user=False, code=254):
        check_fault(output, code, "probe-test", 10, 0x40000000,
                    0x40000040 if user else 0x18BA8, user, registers)

    def test_accepts_exact_supervisor_and_user_fault_contexts(self):
        for user in (False, True):
            self.verify(*fixture(user), user)

    def test_rejects_every_changed_register_and_control_field(self):
        for user in (False, True):
            registers, output = fixture(user)
            for name in ("cause", "badaddr", "epc", "status", "ptbr", "fcsr") + tuple(
                    f"r{i:02d}" for i in range(32)):
                with self.subTest(user=user, field=name):
                    original = f"{name}=" + output.split(f"{name}=")[1][:8]
                    wrong = output.replace(original, f"{name}=FFFFFFFF")
                    with self.assertRaises(ValueError):
                        self.verify(registers, wrong, user)

    def test_rejects_missing_or_duplicate_dump_wrong_origin_and_clean_hlt(self):
        registers, output = fixture()
        for wrong, code in (("", 0), (output, 0), (output + output, 254),
                            (output.replace("origin=supervisor", "origin=user"), 254),
                            (output.replace("stage=probe-test", "stage=boot-info"), 254),
                            (output.replace("r28=A501001C", ""), 254),
                            (output.replace("unexpected exception", "unexpected breakpoint"), 254)):
            with self.assertRaises(ValueError):
                self.verify(registers, wrong, code=code)


if __name__ == "__main__":
    unittest.main()
