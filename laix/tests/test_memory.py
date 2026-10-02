"""Interpret bootstrap M source directly: no code generation or building.

This small evaluator covers only the integer/array subset used by memory.m
and mmu.m. It tests the actual mapping algorithm at synthetic link addresses;
it does not simulate CPU exceptions or replace WRM runtime testing.
"""

import operator
import unittest

from test_kernel import LAIX, check_m, parse_asm, asm_constants
from mlang import syntax as s
from mlang.typesys import size_of


class Returned(Exception):
    def __init__(self, value):
        self.value = value


class Continued(Exception):
    pass


# Synthetic page-aligned kernel sections, as start.asm makes ld lay them out.
SECTIONS = {"__start_text": 0x10000, "__stop_text": 0x14C9C,
            "__start_rodata": 0x15000, "__stop_rodata": 0x7E123,
            "__start_data": 0x7F000}
V, R, W, X = 1, 2, 4, 8
SYNTHETIC_ARRAYS = 0x0A000000


def kernel_permissions(address, guard):
    """Expected W^X identity-map permissions of a RAM page, 0 if unmapped."""
    if address < 0x1000 or 0x2000 <= address < 0x10000 or address == guard:
        return 0  # NULL page, old firmware stack, stack guard
    if address < 0x2000:
        return V | R | W  # boot info and trap entry state
    if address < SECTIONS["__start_rodata"]:
        return V | R | X
    if address < SECTIONS["__start_data"]:
        return V | R
    return V | R | W


class BootstrapM:
    binary = {
        "+": operator.add, "-": operator.sub, "*": operator.mul,
        "/": operator.floordiv, "&": operator.and_, "|": operator.or_,
        "==": operator.eq, "!=": operator.ne, "<": operator.lt,
        "<=": operator.le, ">": operator.gt, ">=": operator.ge,
    }

    def __init__(self, guard=0x90000, bss_end=0x98404, root=None):
        modules = check_m(root or LAIX / "src/mmu.m")
        self.decls = {d.name: d for m in modules for d in m.decls
                      if isinstance(d, (s.VarDecl, s.FuncDecl))}
        self.addresses = {"kernelStackGuard": guard, "__bss_end": bss_end,
                          "kernelLowTable": bss_end - 0x4404,
                          "kernelPageDirectory": bss_end - 0x3404,
                          "kernelTailTable": bss_end - 0x1404}
        self.addresses.update(SECTIONS)
        self.globals, self.memory, self.events = {}, {}, []
        self.ptbr = 0
        for name, decl in self.decls.items():
            if not isinstance(decl, s.VarDecl) or decl.extern:
                continue
            if isinstance(decl.type, s.ArrayType):
                # Arrays of modules a test doesn't place get their own pages.
                if name not in self.addresses:
                    self.addresses[name] = SYNTHETIC_ARRAYS + 0x1000 * len(self.addresses)
                self.globals[name] = self.addresses[name]
                for i in range(1024):
                    self.memory[self.addresses[name] + 4 * i] = 0
            else:
                self.globals[name] = decl.sym.const if decl.sym.const is not None else 0

    def address(self, node, local):
        if isinstance(node, s.Name):
            return self.addresses[node.name]
        if isinstance(node, s.Index):
            return self.expr(node.obj, local) + 4 * self.expr(node.index, local)
        raise AssertionError(type(node).__name__)

    def expr(self, node, local):
        if isinstance(node, (s.IntLit, s.BoolLit)):
            return node.value
        if isinstance(node, s.Name):
            return local[node.name] if node.name in local else self.globals[node.name]
        if isinstance(node, s.Index):
            return self.memory[self.address(node, local)]
        if isinstance(node, s.Cast):
            return self.expr(node.expr, local)
        if isinstance(node, s.Unary):
            if node.op in ("&", "&mut"):
                return self.address(node.operand, local)
            value = self.expr(node.operand, local)
            if node.op == "!":
                return not value
            if node.op == "~":
                return ~value & 0xFFFFFFFF
        if isinstance(node, s.Binary):
            left = self.expr(node.left, local)
            if node.op == "&&":
                return bool(left and self.expr(node.right, local))
            if node.op == "||":
                return bool(left or self.expr(node.right, local))
            return self.binary[node.op](left, self.expr(node.right, local)) & 0xFFFFFFFF
        if isinstance(node, s.Call):
            return self.call(node.func.name, *(self.expr(a, local) for a in node.args))
        if isinstance(node, s.BuiltinCall):
            args = [self.expr(a, local) for a in node.args]
            if node.name == "mfcr":
                assert args == [6]
                return self.ptbr
            assert node.name in ("mtcr", "fence", "tlbi")
            self.events.append((node.name, args))
            if node.name == "mtcr":
                assert args[0] == 6
                self.ptbr = args[1]
            return None
        raise AssertionError(f"unsupported expression: {type(node).__name__}")

    def statement(self, node, local):
        if isinstance(node, s.Block):
            for st in node.stmts:
                self.statement(st, local)
        elif isinstance(node, s.VarDecl):
            local[node.name] = self.expr(node.init, local)
        elif isinstance(node, s.Assign):
            assert node.op == "="
            value = self.expr(node.value, local)
            if isinstance(node.target, s.Index):
                self.memory[self.address(node.target, local)] = value
            else:
                target = local if node.target.name in local else self.globals
                target[node.target.name] = value
        elif isinstance(node, s.If):
            body = node.then if self.expr(node.cond, local) else node.else_
            if body:
                self.statement(body, local)
        elif isinstance(node, s.For):
            assert not node.inclusive and node.step is None
            for i in range(self.expr(node.start, local), self.expr(node.end, local)):
                local[node.name] = i
                try:
                    self.statement(node.body, local)
                except Continued:
                    pass
        elif isinstance(node, s.Continue):
            raise Continued()
        elif isinstance(node, s.Return):
            raise Returned(self.expr(node.value, local) if node.value is not None else None)
        elif isinstance(node, s.ExprStmt):
            self.expr(node.expr, local)
        else:
            raise AssertionError(f"unsupported statement: {type(node).__name__}")

    def call(self, name, *args):
        decl = self.decls[name]
        assert len(args) == len(decl.params)
        try:
            self.statement(decl.body, dict(zip((p.name for p in decl.params), args)))
        except Returned as ret:
            return ret.value

    def leaf(self, address, directory=None):
        if directory is None:
            directory = self.ptbr & ~4095
        entry = self.memory.get(directory + (address >> 22) * 4, 0)
        if not entry & 1:
            return 0
        if entry & 14:
            return (entry & ~0x3FFFFF) | (address & 0x3FF000) | (entry & 4095)
        return self.memory.get((entry & ~4095) + ((address >> 12) & 1023) * 4, 0)


class BootstrapMemoryTests(unittest.TestCase):
    def test_stack_layout_reserves_three_whole_pages(self):
        statements = parse_asm(LAIX / "src/start.asm").stmts
        constants = asm_constants(parse_asm(LAIX / "src/start.asm"))
        guard = next(i for i, st in enumerate(statements) if "kernelStackGuard" in st.labels)
        bottom = next(i for i, st in enumerate(statements) if "kernelStackBottom" in st.labels)
        top = next(i for i, st in enumerate(statements) if "kernelStackTop" in st.labels)
        self.assertEqual((statements[guard - 1].op, statements[guard - 1].args),
                         (".align", ["PAGE_SIZE"]))
        self.assertEqual([(st.op, st.args) for st in statements[guard:bottom] if st.op],
                         [(".space", ["PAGE_SIZE"])])
        self.assertEqual([(st.op, st.args) for st in statements[bottom:top] if st.op],
                         [(".space", ["KERNEL_STACK_BYTES"])])
        self.assertEqual(constants["PAGE_SIZE"], 4096)
        self.assertEqual(constants["KERNEL_STACK_BYTES"], 8192)
        module = check_m(LAIX / "src/mmu.m")[0]
        for name in ("kernelPageDirectory", "kernelLowTable", "kernelTailTable"):
            self.assertEqual(module.scope[name].decl.align.const, 4096)
            self.assertEqual(size_of(module.scope[name].type), 4096)

    def test_free_pages_exclude_boot_image_bss_stack_and_guard(self):
        vm = BootstrapM()
        self.assertFalse(vm.call("physicalPageAvailable", 0x100000))
        self.assertTrue(vm.call("memoryInit", 0x200123))
        self.assertEqual(vm.globals["kernelReservedEnd"], 0x99000)
        self.assertEqual(vm.globals["kernelRamEnd"], 0x200000)
        for address in range(0, 0x201000, 4096):
            self.assertEqual(vm.call("physicalPageAvailable", address),
                             0x99000 <= address < 0x200000, hex(address))
        for address in (0x99001, 0x200001, 0xFFFFFFFF):
            self.assertFalse(vm.call("physicalPageAvailable", address))

    def test_invalid_ram_and_no_free_pages(self):
        for ram in (0, 0x98000, 0x98404, 0x08000001, 0xFFFFFFFF):
            vm = BootstrapM()
            self.assertFalse(vm.call("memoryInit", ram), hex(ram))
            self.assertFalse(vm.call("physicalPageAvailable", 0x99000))
        vm = BootstrapM()
        self.assertTrue(vm.call("memoryInit", 0x99000))
        self.assertFalse(vm.call("physicalPageAvailable", 0x99000))

    def test_identity_map_is_wx_without_null_guard_or_ram_tail_mapping(self):
        # A guard near the end of the kernel superpage, a RAM tail in its own
        # region, full superpages and maximum RAM.
        for guard, ram in ((0x90000, 0x100000), (0x90000, 0x500123),
                           (0x3F7000, 0x800000), (0x90000, 0x08000000)):
            with self.subTest(guard=hex(guard), ram=hex(ram)):
                vm = BootstrapM(guard, guard + 0x8404)
                self.assertTrue(vm.call("memoryInit", ram))
                self.assertTrue(vm.call("mmuInit"))
                self.assertEqual(vm.events, [("fence", []), ("tlbi", [0, 2]),
                    ("mtcr", [6, vm.addresses["kernelPageDirectory"] | 1])])
                for address in range(0, ram & ~4095, 4096):
                    entry = vm.leaf(address)
                    expected = kernel_permissions(address, guard)
                    self.assertEqual(entry & 31, expected, hex(address))  # never U
                    if expected:
                        self.assertEqual(entry & ~4095, address)
                    # W^X: nothing writable is executable, code only in .text.
                    self.assertNotEqual(entry & (W | X), W | X, hex(address))
                    if entry & X:
                        self.assertLess(address, SECTIONS["__start_rodata"])
                self.assertEqual(vm.leaf(ram & ~4095), 0)
                for address in (0xFC000000, 0xFC3FF000, 0xFD002000, 0xFD010000):
                    self.assertEqual(vm.leaf(address), address | 7)  # RW, no X/U
                for address in (0xFC400000, 0xFD400000, 0xFE000000, 0xFFFFF000):
                    self.assertEqual(vm.leaf(address), 0)
                self.assertFalse(vm.call("mmuInit"))  # never rewrite live tables

    def test_mmu_rejects_sections_unfit_for_wx(self):
        for name, value in (("__start_text", 0x11000), ("__start_rodata", 0x14C9C),
                            ("__start_data", 0x7E124), ("__stop_text", 0x15004),
                            ("__stop_rodata", 0x7F004), ("kernelStackGuard", 0x7E000),
                            ("__bss_end", 0x400004)):
            with self.subTest(name=name):
                vm = BootstrapM()
                vm.addresses[name] = value
                self.assertTrue(vm.call("memoryInit", 0x800000))
                self.assertFalse(vm.call("mmuInit"))
                self.assertEqual(vm.events, [])
        # The whole kernel must fit in the page-mapped first superpage.
        vm = BootstrapM(0x3FF000, 0x3FF000 + 0x8404)
        self.assertTrue(vm.call("memoryInit", 0x800000))
        self.assertFalse(vm.call("mmuInit"))

    def test_mmu_rejects_missing_accounting_and_invalid_guard(self):
        vm = BootstrapM()
        self.assertFalse(vm.call("mmuInit"))
        for guard in (0x90001, 0x200000):
            vm = BootstrapM(guard)
            self.assertTrue(vm.call("memoryInit", 0x200000))
            self.assertFalse(vm.call("mmuInit"))
            self.assertEqual(vm.events, [])

    def test_task_directories_keep_entry_state_code_and_stacks_supervisor(self):
        vm = BootstrapM()
        self.assertTrue(vm.call("memoryInit", 0x800000))
        self.assertTrue(vm.call("mmuInit"))
        active = vm.ptbr
        constants = asm_constants(parse_asm(LAIX / "src/defs.inc"))
        for directory in (0x100000, 0x101000):
            vm.memory[directory] = 0xDEADBEEF
            self.assertTrue(vm.call("mmuInitAddressSpace", directory))
            for address in range(0, 0x800000, 4096):
                entry = vm.leaf(address, directory)
                self.assertEqual(entry, vm.leaf(address))
                self.assertEqual(entry & 16, 0)  # no U, including kernel stacks
            for name in ("KERNEL_SP", "KERNEL_STACK_BOTTOM", "KERNEL_STACK_TOP", "TRAP_SAVED_R1"):
                self.assertEqual(vm.leaf(constants[name], directory) & 31, V | R | W)
            self.assertEqual(vm.leaf(0x90000, directory), 0)  # guard
            self.assertEqual(vm.leaf(0, directory), 0)  # NULL page
            self.assertEqual(vm.leaf(0xFD002000, directory) & 31, 7)  # panic UART
            self.assertEqual(vm.memory[directory + (0x800000 >> 22) * 4], 0)
        self.assertEqual(vm.ptbr, active)
        for directory in (0, 0x90000, active & ~4095, 0x100001, 0x800000):
            before = dict(vm.memory)
            self.assertFalse(vm.call("mmuInitAddressSpace", directory))
            self.assertEqual(vm.memory, before)
        vm.ptbr = 0x100000 | 1
        before = dict(vm.memory)
        self.assertFalse(vm.call("mmuInitAddressSpace", 0x100000))
        self.assertEqual(vm.memory, before)
        vm.ptbr = 0
        self.assertFalse(vm.call("mmuInitAddressSpace", 0x102000))


if __name__ == "__main__":
    unittest.main()
