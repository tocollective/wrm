"""Variadic frontend and ABI layout checks. Never generate or build code."""

import io
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

from mlang.check import Checker
from mlang.codegen import by_reference, classify, words_of
from mlang.diag import Diagnostics
from mlang.lexer import Lexer
from mlang.modules import Module
from mlang.parser import ParseError, Parser
from mlang.syntax import Call, VaArg, VariadicType
from mlang.typesys import (BOOL, BYTE, FLOAT, UBYTE, UWORD, VOID, WORD,
                          FuncT, PtrT, VARARGS, align_of, size_of)


class VariadicTests(unittest.TestCase):
    def check(self, source, program=False):
        output = io.StringIO()
        diag = Diagnostics(output)
        module = Module("test.m")
        tokens = Lexer(module.path, source, diag).run()
        try:
            module.decls = Parser(module.path, source, tokens, diag).parse_file()
        except ParseError as error:
            diag.error(error.loc, error.msg)
        if not diag.errors:
            Checker([module], diag, program=program).run()
        return module, diag, output.getvalue()

    def valid(self, source):
        module, diag, output = self.check(source)
        self.assertEqual(diag.errors, 0, output)
        return module

    def invalid(self, source, message, program=False):
        _, diag, output = self.check(source, program)
        self.assertGreater(diag.errors, 0, output)
        self.assertIn(message, output)

    def test_mixed_arguments_and_default_literal_types(self):
        module = self.valid('''
let consume(prefix: *UByte, args: ...): Void {}
let sample(): Void {
    consume("", 42, 42.0, 0xFFFFFFFF, "correct", -42, true, null, 'A')
}
''')
        function = module.scope["consume"].decl
        self.assertIsInstance(function.params[-1].type, VariadicType)
        self.assertTrue(function.sym.type.variadic)
        self.assertEqual(function.sym.type.fixed_params, [PtrT(UBYTE)])
        call = module.scope["sample"].decl.body.stmts[0].expr
        self.assertIsInstance(call, Call)
        self.assertFalse(call.va_forward)
        self.assertEqual([arg.type for arg in call.args[1:]],
                         [WORD, FLOAT, UWORD, PtrT(UBYTE), WORD, BOOL, PtrT(VOID), UBYTE])

    def test_typed_reads_and_count(self):
        module = self.valid('''
type Handler = (code: UWord): Void
enum Flag: UByte { Off, On }
let consume(args: ...): Float {
    let count: UWord = vaCount(args)
    let i: Word = vaArg(args, 0, Word)
    let s: *UByte = vaArg(args, 1, *UByte)
    let b: Bool = vaArg(args, 2, Bool)
    let handler: Handler = vaArg(args, 3, Handler)
    let flag: Flag = vaArg(args, 4, Flag)
    return vaArg(args, count - 1, Float)
}
''')
        function = module.scope["consume"].decl
        self.assertTrue(function.params[0].var.read)
        read = function.body.stmts[-1].value
        self.assertIsInstance(read, VaArg)
        self.assertIs(read.type, FLOAT)

    def test_empty_tail_and_pack_forwarding(self):
        module = self.valid('''
let consume(prefix: Word, args: ...): Void {}
let wrapper(args: ...): Void {
    consume(1)
    consume(2, args)
}
let sample(): Void { wrapper() }
''')
        calls = [stmt.expr for stmt in module.scope["wrapper"].decl.body.stmts]
        self.assertFalse(calls[0].va_forward)
        self.assertTrue(calls[1].va_forward)

    def test_function_values_nested_functions_and_literals(self):
        module = self.valid('''
type Sink = (prefix: Word, args: ...): Void
let consume(prefix: Word, args: ...): Void {}
let sample(): Void {
    let sink: Sink = consume
    sink(1, 2.0, "text")
    let nested(args: ...): Void { consume(0, args) }
    nested(1, 2)
    let literal: Sink = (prefix: Word, args: ...): Void { consume(prefix, args) }
    literal(3, 4.0)
}
let mut changeable(args: ...): Void { consume(0, args) }
''')
        self.assertTrue(module.scope["Sink"].type.variadic)
        self.assertTrue(module.scope["changeable"].type.variadic)

    def test_extern_uses_the_same_function_type(self):
        self.valid('''
extern let sink(prefix: Word, args: ...): Void
let sample(): Void { sink(1, 2.0, "text") }
''')

    def test_small_scalars_keep_their_types(self):
        module = self.valid('''
enum Flag: UByte { Off, On }
let consume(args: ...): Void {}
let sample(value: Byte): Void { consume(value, Flag.On) }
''')
        call = module.scope["sample"].decl.body.stmts[0].expr
        self.assertIs(call.args[0].type, BYTE)
        self.assertEqual(call.args[1].type.kind, "enum")

    def test_variadic_parameter_must_be_last_and_unique(self):
        for signature in ("args: ..., value: Word", "args: ..., more: ..."):
            with self.subTest(signature=signature):
                self.invalid(f"let bad({signature}): Void {{}}", "must be last")
                self.invalid(f"type Bad = ({signature}): Void", "must be last")
        self.invalid("let bad(args: ..., args: Word): Void {}", "already declared")

    def test_marker_cannot_be_used_as_an_ordinary_type(self):
        for source in ("let value: ... = 0", "type Pack = ...",
                       "let bad(): ... {}", "let bad(args: mut ...): Void {}"):
            with self.subTest(source=source):
                self.invalid(source, "expected a type")

    def test_fixed_argument_checks_still_apply(self):
        self.invalid("let f(x: Word, args: ...): Void {}\nlet g(): Void { f() }",
                     "takes at least 1 argument")
        self.invalid('let f(x: Word, args: ...): Void {}\nlet g(): Void { f("x") }',
                     "expected 'Word'")
        self.invalid("let f(x: Word): Void {}\nlet g(): Void { f(1, 2) }",
                     "takes 1 argument")

    def test_aggregates_and_void_cannot_be_variadic_values(self):
        for declaration, argument in (("let value: UWord[2] = [1, 2]", "value"),
                                      ("type Pair { x: Word }\nlet value: Pair = {}", "value"),
                                      ("let nothing(): Void {}", "nothing()")):
            with self.subTest(argument=argument, declaration=declaration):
                self.invalid(f"{declaration}\nlet f(args: ...): Void {{}}\n"
                             f"let g(): Void {{ f({argument}) }}", "must be a scalar")

    def test_pack_forwarding_cannot_be_mixed_with_other_tail_values(self):
        self.invalid("let f(args: ...): Void {}\nlet g(args: ...): Void { f(1, args) }",
                     "sole trailing argument")

    def test_invalid_variadic_builtins(self):
        for statement, message in (("vaCount()", "takes 1 argument"),
                                   ("vaCount(args, args)", "takes 1 argument"),
                                   ("vaCount(0)", "needs a variadic parameter"),
                                   ("vaArg(0, 0, Word)", "needs a variadic parameter"),
                                   ("vaArg(args, -1, Word)", "doesn't fit"),
                                   ("vaArg(args, 0, UWord[2])", "scalar result type"),
                                   ("vaArg(args, 0, Void)", "'Void' is only")):
            with self.subTest(statement=statement):
                self.invalid(f"let f(args: ...): Void {{ {statement} }}", message)

    def test_lost_result_is_a_warning(self):
        _, diag, output = self.check("let f(args: ...): Void { vaArg(args, 0, Word) }")
        self.assertEqual(diag.errors, 0, output)
        self.assertIn("the result of 'vaArg' is lost", output)

    def test_integer_literals_are_limited_to_32_bits(self):
        for value in ("4294967296", "-2147483649"):
            with self.subTest(value=value):
                self.invalid(f"let f(args: ...): Void {{}}\nlet g(): Void {{ f({value}) }}",
                             "doesn't fit")

    def test_variadic_main_is_rejected(self):
        self.invalid("let main(args: ...): Word { return 0 }", "'main' must be", program=True)

    def test_function_type_identity_includes_variadic_marker(self):
        self.assertNotEqual(FuncT([WORD], VOID), FuncT([WORD, VARARGS], VOID))
        self.invalid("let f(x: Word, args: ...): Void {}\n"
                     "let g(): Void { let sink: (x: Word): Void = f }", "expected")

    def test_pack_abi_is_two_words_and_never_split(self):
        self.assertEqual((size_of(VARARGS), align_of(VARARGS), words_of(VARARGS)), (8, 4, 2))
        self.assertFalse(by_reference(VARARGS))
        for fixed, hidden, location, stack_bytes in ((6, False, ("reg", 7, 2), 0),
                                                     (7, False, ("stack", 0, 2), 8),
                                                     (6, True, ("stack", 0, 2), 8),
                                                     (9, False, ("stack", 8, 2), 16)):
            with self.subTest(fixed=fixed, hidden=hidden):
                locations, stack = classify([WORD] * fixed + [VARARGS], hidden)
                self.assertEqual(locations[-1], location)
                self.assertEqual(stack, stack_bytes)


if __name__ == "__main__":
    unittest.main()
