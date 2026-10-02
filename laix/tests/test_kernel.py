"""Static kernel ABI checks. No code generation, assembly or linking."""

import io
from pathlib import Path
import re
import sys
import unittest

LAIX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAIX.parent / "tools"))
import asm
from mlang.check import Checker
from mlang.diag import Diagnostics
from mlang.modules import load_program
from mlang.syntax import Block, Break, Return, Switch


def check_m(root):
    messages = io.StringIO()
    diag = Diagnostics(messages)
    modules = load_program([str(root)], [], diag)
    if not diag.errors:
        Checker(modules, diag, program=False).run()
    if diag.errors:
        raise AssertionError(messages.getvalue())
    return modules


def parse_asm(path):
    # Parse includes and syntax only. Never call layout/emit/object_file.
    parser = asm.Assembler(0, obj=True)
    parser.parse_file(str(path))
    parser.check()
    return parser


def asm_constants(parser):
    # Evaluate only constant expressions; never assign code addresses or emit.
    constants = {}
    for statement in parser.stmts:
        if statement.op == "=":
            name, expression = statement.args
            if name in constants:
                raise AssertionError(f"duplicate assembly constant: {name}")
            constants[name] = asm.ExprParser(expression, constants.__getitem__).parse()
    return constants


class KernelContractTests(unittest.TestCase):
    def test_m_and_assembly_constants_match(self):
        for m_name, asm_name in (("defs.m", "defs.inc"),
                                 ("trap_frame.m", "trap_layout.inc")):
            with self.subTest(module=m_name):
                module = check_m(LAIX / "src" / m_name)[0]
                constants = asm_constants(parse_asm(LAIX / "src" / asm_name))
                for name, symbol in module.scope.items():
                    if symbol.kind == "var" and symbol.const is not None:
                        self.assertEqual(constants[name], symbol.const, name)

    def test_handled_traps_do_not_fall_through(self):
        # M switches have C-style fallthrough. BREAK must neither overwrite
        # r1 with -ENOSYS nor reach panic; SYSCALL must also return normally.
        module = check_m(LAIX / "src/trap.m")[0]
        handler = module.scope["trapDispatch"].decl
        dispatch = next(st for st in handler.body.stmts if isinstance(st, Switch))
        handled = [case for case in dispatch.cases if case.value is not None]
        self.assertEqual({case.value.const for case in handled}, {12, 13})
        for case in handled:
            with self.subTest(cause=case.value.const):
                last = case.body[-1]
                while isinstance(last, Block):
                    last = last.stmts[-1]
                self.assertIsInstance(last, (Return, Break))

    def test_frame_layout_matches_m_type_checker(self):
        module = check_m(LAIX / "src/trap_frame.m")[0]
        frame = module.scope["TrapFrame"].type
        constants = asm_constants(parse_asm(LAIX / "src/trap_layout.inc"))
        self.assertEqual(frame.size, constants["TF_SIZE"])
        self.assertEqual(frame.size % 8, 0)
        for field in frame.fields:
            self.assertEqual(field.offset, constants["TF_" + field.name.upper()])
        self.assertEqual(frame.field("regs").type.n, 32)

    def test_build_includes_every_imported_module(self):
        modules = check_m(LAIX / "src/main.m")
        script = (LAIX / "build.sh").read_text()
        names = re.search(r"for module in (.*); do", script).group(1).split()
        linked = {(LAIX / "src" / (name + ".m")).resolve() for name in names}
        linked.add((LAIX / "src/main.m").resolve())
        # The demo may stop importing a module that is still linked by the
        # build script. Require every dependency, but allow unused modules.
        self.assertLessEqual({Path(module.path).resolve() for module in modules}, linked)
        self.assertIn('set -- "$obj_dir/start.o"', script)
        self.assertIn('"$repo_dir/m/runtime/mem.asm"', script)

    def test_runtime_test_programs_type_check(self):
        for path in sorted((LAIX / "tests").glob("*.m")):
            with self.subTest(name=path.name):
                check_m(path)

    def test_assembly_opcodes_and_jump_targets(self):
        paths = (LAIX / "src/start.asm", LAIX / "src/trap.asm", LAIX / "src/font/data.asm",
                 LAIX / "tests/trap_fault.asm", LAIX / "tests/stack_guard.asm",
                 LAIX / "tests/null_call.asm", LAIX / "tests/text_write.asm",
                 LAIX / "tests/data_exec.asm")
        parsers = [parse_asm(path) for path in paths]
        labels = {label for parser in parsers for statement in parser.stmts
                  for label in statement.labels}
        labels.update(("main", "trapDispatch", "trapExpect", "trapBadStack"))
        jumps = {"j", "call", "beq", "bne", "blt", "bge", "bltu", "bgeu",
                 "beqz", "bnez", "bltz", "bgez", "bgtz", "blez"}
        for parser in parsers:
            for statement in parser.stmts:
                with self.subTest(location=statement.loc):
                    op = statement.op
                    self.assertTrue(op in (None, "=", ".section") or
                                    op in asm.INSTRUCTIONS or op in asm.DIRECTIVES)
                    if op in jumps:
                        target = parser.qualify(statement.args[-1], statement.scope)
                        self.assertIn(target, labels)

    def test_complete_gpr_save_restore_and_sp_last(self):
        statements = parse_asm(LAIX / "src/trap.asm").stmts
        # Limit to the entry body, excluding the boot-time self-test.
        begin = next(i for i, st in enumerate(statements) if "trapEntry" in st.labels)
        end = next(i for i, st in enumerate(statements[begin:], begin) if st.op == "iret")
        body = statements[begin:end + 1]
        call = next(i for i, st in enumerate(body) if st.op == "call")
        self.assertEqual(body[call].args, ["trapDispatch"])
        saved = {(st.args[0], st.args[1]) for st in body[:call] if st.op == "sw"}
        restored = {(st.args[0], st.args[1]) for st in body[call:] if st.op == "lw"}
        for register in range(1, 32):
            name = {30: "sp", 31: "ra"}.get(register, f"r{register}")
            slot = f"TF_R{register}(sp)"
            if register == 30:
                # Original SP was copied from SCRATCH via r1.
                self.assertIn(("r1", slot), saved)
            else:
                self.assertIn((name, slot), saved)
            self.assertIn((name, slot), restored)
        self.assertEqual((body[-2].op, body[-2].args), ("lw", ["sp", "TF_R30(sp)"]))
        for field in ("EPC", "STATUS", "CAUSE", "BADADDR", "FCSR", "PTBR"):
            self.assertIn(("r1", f"TF_{field}(sp)"), saved)
        self.assertFalse(any(st.op in ("ret", "tlbi", "tlbi.all") for st in body))
        # Origin must be checked before any memory access.
        branch = next(i for i, st in enumerate(body) if st.op == "beqz")
        self.assertEqual(body[branch].args, ["sp", ".kernel_stack"])
        self.assertEqual((body[branch - 1].op, body[branch - 1].args),
                         ("andi", ["sp", "sp", "STATUS_PUM"]))
        self.assertLess(branch, next(i for i, st in enumerate(body) if st.op == "lw"))
        self.assertLess(branch, next(i for i, st in enumerate(body) if st.op == "sw"))

    def test_fatal_output_has_no_screen_or_disk_dependency(self):
        modules = check_m(LAIX / "src/panic.m")
        self.assertEqual({Path(module.path).name for module in modules},
                         {"panic.m", "trap_frame.m", "debug_uart.m", "defs.m"})
        start = parse_asm(LAIX / "src/start.asm")
        begin = next(i for i, st in enumerate(start.stmts) if "earlyTrapEntry" in st.labels)
        early = start.stmts[begin:]
        self.assertFalse(any(st.op == "call" for st in early))
        self.assertFalse(any("sp" in arg for st in early for arg in st.args))

    def test_early_panic_prints_trap_registers_only_after_a_trap(self):
        start = parse_asm(LAIX / "src/start.asm")
        statements = [st for st in start.stmts if st.op or st.labels]
        def block(label):
            # A routine runs to the next global label, a local label to the next label.
            begin = next(i for i, st in enumerate(statements) if label in st.labels)
            ends = (lambda st: st.labels) if "." in label else (
                lambda st: any("." not in name for name in st.labels))
            end = next(i for i, st in enumerate(statements[begin + 1:], begin + 1) if ends(st))
            return [st for st in statements[begin:end] if st.op]
        # Boot info and RAM failures have no trap: CAUSE, EPC and BADADDR are
        # stale there.
        self.assertFalse(any(st.op == "mfcr" for st in block("earlyPanic")))
        self.assertEqual((block("earlyPanic")[-1].op, block("earlyPanic")[-1].args),
                         ("j", ["earlyString"]))
        for label in ("kernelStart.bad_info", "kernelStart.bad_ram"):
            jump = block(label)
            self.assertEqual(len(jump), 2, label)
            self.assertEqual((jump[-1].op, jump[-1].args), ("j", ["earlyPanic"]))
        self.assertEqual((block("earlyTrapEntry")[-1].op, block("earlyTrapEntry")[-1].args),
                         ("j", ["earlyTrapPanic"]))
        reported = {st.args[1] for st in block("earlyTrapReport") if st.op == "mfcr"}
        self.assertEqual(reported, {"cause", "epc", "badaddr"})

    def test_stack_bounds_checked_before_frame_allocation(self):
        statements = parse_asm(LAIX / "src/trap.asm").stmts
        allocate = next(i for i, st in enumerate(statements)
                        if st.op == "addi" and st.args == ["sp", "sp", "-TF_SIZE"])
        checks = [st for st in statements[:allocate] if st.op in ("bltu", "bnez")
                  and st.args[-1] == ".bad_stack"]
        self.assertEqual([st.op for st in checks], ["bltu", "bltu", "bnez"])
        self.assertTrue(any(st.op == "lw" and st.args == ["r1", "KERNEL_STACK_BOTTOM(r0)"]
                            for st in statements[:allocate]))
        self.assertTrue(any(st.op == "lw" and st.args == ["r1", "KERNEL_STACK_TOP(r0)"]
                            for st in statements[:allocate]))

    def test_start_page_aligns_rodata_and_data_for_wx(self):
        # start.o is linked first, so the alignment of its own sections starts
        # the .rodata and .data output sections on fresh pages (mmu.m W^X).
        script = (LAIX / "build.sh").read_text()
        self.assertIn('set -- "$obj_dir/start.o"', script)
        statements = [st for st in parse_asm(LAIX / "src/start.asm").stmts if st.op]
        for name in (".rodata", ".data"):
            with self.subTest(section=name):
                i = next(i for i, st in enumerate(statements)
                         if st.op == ".section" and st.section_spec[0] == name)
                self.assertEqual((statements[i + 1].op, statements[i + 1].args),
                                 (".align", ["PAGE_SIZE"]))

    def test_low_entry_state_reserved_and_initialized_before_ivec(self):
        parser = parse_asm(LAIX / "src/start.asm")
        constants = asm_constants(parser)
        slots = [constants[name] for name in ("KERNEL_SP", "KERNEL_STACK_BOTTOM",
                                              "KERNEL_STACK_TOP", "TRAP_SAVED_R1")]
        end = constants["BOOT_INFO_END"]
        self.assertEqual(slots, list(range(end - 16, end, 4)))
        # Reachable by signed offset(r0), outside the unmapped NULL page and
        # above everything boot info and its device table may use.
        self.assertTrue(all(constants["PAGE_SIZE"] <= slot < 8192 and slot % 4 == 0
                            for slot in slots))
        self.assertEqual(min(slots), constants["BOOT_INFO_LIMIT"])
        statements = parser.stmts
        install = next(i for i, st in enumerate(statements)
                       if st.op == "la" and st.args == ["r1", "trapEntry"])
        stores = {(st.args[0], st.args[1]) for st in statements[:install] if st.op == "sw"}
        for pair in (("sp", "KERNEL_SP(r0)"), ("sp", "KERNEL_STACK_TOP(r0)"),
                     ("r1", "KERNEL_STACK_BOTTOM(r0)"), ("r0", "TRAP_SAVED_R1(r0)")):
            self.assertIn(pair, stores)


if __name__ == "__main__":
    unittest.main()
