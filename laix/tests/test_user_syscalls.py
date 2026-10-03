"""Evaluate user wrapper ASTs without generating code or entering the kernel."""

import unittest

from source_m import SourceM, LAYOUT
from test_kernel import LAIX


class UserExited(Exception):
    pass


class UserM(SourceM):
    def __init__(self):
        super().__init__(LAIX / "user/syscalls.m")
        self.calls = []

    def trap(self, cause, args=()):
        self.calls.append((cause, tuple(args)))
        if args[0] == 1:
            raise UserExited()
        return 0xFFFFFFDA  # Arbitrary kernel error, forwarded unchanged.


class UserWrapperTests(unittest.TestCase):
    def test_debug_wrapper_passes_number_and_word_and_returns_kernel_result(self):
        vm = UserM()
        for code in (0, 65, 255, 256, 0xFFFFFFFF):
            self.assertEqual(vm.call("debugPutChar", code), 0xFFFFFFDA)
            self.assertEqual(vm.calls[-1], (LAYOUT["CAUSE_SYSCALL"], (0, code)))

    def test_exit_wrapper_passes_entire_signed_code(self):
        for code in (0, 127, 0xFFFFFF85, 0x80000000):
            vm = UserM()
            with self.assertRaises(UserExited):
                vm.call("exit", code)
            self.assertEqual(vm.calls, [(LAYOUT["CAUSE_SYSCALL"], (1, code))])


if __name__ == "__main__":
    unittest.main()
