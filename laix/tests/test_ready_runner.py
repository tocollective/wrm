"""Validate runtime assertions with UART fixtures; never run/build an image."""

import unittest
from pathlib import Path
import tempfile

from run_ready import check_output, check_layout, read_symbols


def symbols():
    return dict(__image_start=0x10000, __image_end=0x80000, __bss_start=0x80000,
                __bss_end=0x94000, kernelStart=0x10010, trapEntry=0x12000,
                kernelStackGuard=0x90000, kernelStackBottom=0x91000, kernelStackTop=0x93000,
                __start_text=0x10000, __stop_text=0x14C9C, __start_rodata=0x15000,
                __stop_rodata=0x7E123, __start_data=0x7F000,
                trapFaultInstruction=0x12340, stackGuardFaultInstruction=0x12344,
                nullCallReturn=0x12350, triggerTextWrite=0x12360,
                textWriteInstruction=0x12368, dataExecTarget=0x7F004,
                dataExecReturn=0x12380)


def panic_dump(guard=False):
    return ("LA/IX PANIC: unexpected exception\n" +
            ("stage=stack-guard-test origin=supervisor\ncause=0000000A (store page fault)\n"
             "epc=00012344 badaddr=00090000\n" if guard else
             "stage=trap-fault-test origin=supervisor\ncause=00000003 (misaligned load)\n"
             "epc=00012340 badaddr=00001001\n") +
            "status=00000010 ptbr=00095001 fcsr=00000000\n" +
            " ".join(f"r{i:02d}=00000000" for i in range(32)))


def fault_dump(stage, cause, epc, badaddr, ra=0):
    return ("LA/IX PANIC: unexpected exception\n"
            f"stage={stage} origin=supervisor\ncause={cause:08X} (page fault)\n"
            f"epc={epc:08X} badaddr={badaddr:08X}\n"
            "status=00000010 ptbr=00095001 fcsr=00000000\n" +
            " ".join(f"r{i:02d}={ra if i == 31 else 0:08X}" for i in range(32)))


def null_call_dump(ra=0x12350):
    return fault_dump("null-call-test", 8, 0, 0, ra)


def text_write_dump(epc=0x12368):
    return fault_dump("text-write-test", 10, epc, 0x12360)


def data_exec_dump(ra=0x12380):
    return fault_dump("data-exec-test", 8, 0x7F004, 0x7F004, ra)


def stack_overflow_dump(sp=0x90FF0, scratch=0x90FF0, r30=0x90FF0, bottom=0x91000, full=True):
    early = ("\nLA/IX EARLY PANIC: invalid kernel stack\n"
             "cause=0000000A epc=00012400 badaddr=00090FF8\n"
             f"sp={sp:08X} scratch={scratch:08X} bottom={bottom:08X} top=00093000 ra=00012410\n")
    if not full:
        return early
    regs = {30: r30, 31: 0x12410}
    return early + (f"\nLA/IX PANIC: invalid kernel stack: sp={sp:08X}, bounds {bottom:08X}..00093000\n"
                    "stage=stack-overflow-test origin=supervisor\n"
                    "cause=0000000A (store page fault)\nepc=00012400 badaddr=00090FF8\n"
                    "status=00000010 ptbr=00095001 fcsr=00000000\n" +
                    " ".join(f"r{i:02d}={regs.get(i, 0):08X}" for i in range(32)))


class ReadyRunnerTests(unittest.TestCase):
    def test_map_reader_ignores_duplicate_object_local_symbols(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "kernel.map"
            path.write_text("00011000 __str0\n00012000 __str0\n00010010 kernelStart\n")
            self.assertEqual(read_symbols(path), {"kernelStart": 0x10010})
            path.write_text("00010010 kernelStart\n00010020 kernelStart\n")
            with self.assertRaisesRegex(ValueError, "duplicate map symbol"):
                read_symbols(path)

    def test_accepts_complete_success_and_expected_fault_dumps(self):
        check_layout(symbols())
        check_output("trap", symbols(), "MMU enabled, kernel stack guard active, kernel W^X\n"
                     "TrapFrame and syscall self-tests passed\ntrap runtime OK\n", 0)
        check_output("trap_fault", symbols(), panic_dump(), 254)
        check_output("stack_guard", symbols(), panic_dump(True), 254)
        check_output("null_call", symbols(), null_call_dump(), 254)
        check_output("text_write", symbols(), text_write_dump(), 254)
        check_output("data_exec", symbols(), data_exec_dump(), 254)

    def test_stack_overflow_needs_early_line_and_matching_full_dump(self):
        check_output("stack_overflow", symbols(), stack_overflow_dump(), 254)
        for output, code in ((stack_overflow_dump(), 0),
                             (stack_overflow_dump(full=False), 254),  # M dump failed
                             (stack_overflow_dump(sp=0x91010, scratch=0x91010, r30=0x91010), 254),
                             (stack_overflow_dump(scratch=0x90FE0), 254),
                             (stack_overflow_dump(r30=0x90FE0), 254),
                             (stack_overflow_dump(bottom=0x92000), 254),
                             (stack_overflow_dump().replace("stage=stack-overflow-test", "stage=running"), 254)):
            with self.subTest(output=output[-60:], code=code):
                with self.assertRaises(ValueError):
                    check_output("stack_overflow", symbols(), output, code)

    def test_wx_cases_reject_success_exit_and_wrong_fault(self):
        # Without W^X the store returns (panic "unexpectedly returned") and
        # the data call runs its HLT word and exits 0.
        for case, output, code in (
                ("text_write", "LA/IX PANIC: store to kernel code unexpectedly returned", 254),
                ("text_write", text_write_dump(epc=0x12364), 254),
                ("data_exec", "", 0),
                ("data_exec", data_exec_dump(), 0),
                ("data_exec", data_exec_dump(ra=0x12384), 254)):
            with self.subTest(case=case, output=output[:40], code=code):
                with self.assertRaises(ValueError):
                    check_output(case, symbols(), output, code)

    def test_null_call_rejects_hlt_exit_wrong_fault_and_return_address(self):
        # Before page zero was unmapped, a NULL call ran HLT and exited 0.
        for output, code in (("", 0), (null_call_dump(), 0),
                             (null_call_dump().replace("cause=00000008", "cause=00000001"), 254),
                             (null_call_dump().replace("epc=00000000", "epc=00000004"), 254),
                             (null_call_dump(ra=0x12354), 254)):
            with self.subTest(output=output[:40], code=code):
                with self.assertRaises(ValueError):
                    check_output("null_call", symbols(), output, code)

    def test_rejects_wrong_cause_badaddr_epc_and_missing_registers(self):
        for old, new in (("cause=00000003", "cause=0000000A"),
                         ("badaddr=00001001", "badaddr=00001000"),
                         ("epc=00012340", "epc=00012344"),
                         ("r28=00000000", ""),
                         ("ptbr=00095001", "ptbr=00000000"),
                         ("status=00000010", "status=00000011")):
            with self.subTest(field=old):
                with self.assertRaises(ValueError):
                    check_output("trap_fault", symbols(), panic_dump().replace(old, new), 254)

    def test_rejects_hlt_success_early_panic_and_wrong_test_image(self):
        for output, code in (("", 0), (panic_dump(), 0), ("EARLY PANIC", 254)):
            with self.assertRaises(ValueError):
                check_output("trap_fault", symbols(), output, code)
        with self.assertRaises(ValueError):
            check_output("trap", symbols(), "TrapFrame and syscall self-tests passed", 0)

    def test_rejects_old_or_overlapping_stack_layouts(self):
        old = symbols()
        del old["kernelStackGuard"]
        with self.assertRaisesRegex(ValueError, "lacks current kernel symbols"):
            check_layout(old)
        for name, value in (("kernelStackGuard", 0x7F000), ("kernelStackBottom", 0x90000),
                            ("kernelStackTop", 0x95000), ("trapEntry", 0x80000),
                            ("__start_rodata", 0x14C9C), ("__start_data", 0x7E124),
                            ("__stop_text", 0x15004), ("__bss_end", 0x400004)):
            bad = symbols()
            bad[name] = value
            with self.assertRaises(ValueError):
                check_layout(bad)


if __name__ == "__main__":
    unittest.main()
