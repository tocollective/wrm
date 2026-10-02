"""UTF-8 frontend regression tests; run without building any code.

From the repository root: python3 -B -m unittest discover -s m/tests -p 'test_*.py'
"""

import io
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

from mlang.diag import Diagnostics
from mlang.check import Checker
from mlang.lexer import Lexer
from mlang.modules import Module, load_program, parse_module
from mlang.parser import ParseError, Parser
from mlang.typesys import UBYTE, UWORD


class UTF8Strings(unittest.TestCase):
	def lex(self, src):
		out = io.StringIO()
		diag = Diagnostics(out)
		tokens = Lexer("test.m", src, diag).run()
		return tokens, diag, out

	def parse(self, src):
		tokens, diag, out = self.lex(src)
		decls = Parser("test.m", src, tokens, diag).parse_file()
		self.assertEqual(diag.errors, 0, out.getvalue())
		return decls

	def test_utf8_bytes(self):
		for text in ("ASCII", "café", "Привет", "日本語", "😀", "e\u0301", "👩‍💻"):
			with self.subTest(text=text):
				tokens, diag, out = self.lex('"' + text + '"')
				self.assertEqual(diag.errors, 0, out.getvalue())
				self.assertEqual(tokens[0].value, text.encode("utf-8"))

	def test_escapes_remain_bytes(self):
		tokens, diag, out = self.lex(r'"é\xFF\xC3\xA9\0\n\t\r\\\""')
		self.assertEqual(diag.errors, 0, out.getvalue())
		self.assertEqual(tokens[0].value, b'\xc3\xa9\xff\xc3\xa9\0\n\t\r\\"')

	def test_source_columns_after_multibyte_characters(self):
		tokens, diag, out = self.lex('"é😀" + "日"\n"я"')
		self.assertEqual(diag.errors, 0, out.getvalue())
		self.assertEqual((tokens[1].pos, tokens[1].loc.col), (5, 6))
		self.assertEqual((tokens[3].loc.line, tokens[3].loc.col), (2, 1))

	def test_identifiers_still_ascii(self):
		_, diag, out = self.lex("имя")
		self.assertGreater(diag.errors, 0)
		self.assertIn("allowed only", out.getvalue())

	def test_unicode_character_codes(self):
		for text in ("é", "д", "э", "日", "😀", "\U0010ffff"):
			with self.subTest(text=text):
				tokens, diag, out = self.lex("'" + text + "'")
				self.assertEqual(diag.errors, 0, out.getvalue())
				self.assertEqual(tokens[0].value, ord(text))
				self.assertTrue(tokens[0].wide)

	def test_escaped_character_bytes(self):
		tokens, diag, out = self.lex(r"'\xE9'")
		self.assertEqual(diag.errors, 0, out.getvalue())
		self.assertEqual(tokens[0].value, 0xE9)
		self.assertFalse(tokens[0].wide)

	def test_character_length_counts_codes(self):
		for body in ("", "ab", "дд", "e\u0301", "👩‍💻", r"\xD0\xB4", r"д\n"):
			with self.subTest(body=body):
				_, diag, out = self.lex("'" + body + "'")
				self.assertGreater(diag.errors, 0)
				self.assertIn("exactly one character", out.getvalue())

	def check(self, src):
		tokens, diag, out = self.lex(src)
		module = Module("test.m")
		module.decls = Parser(module.path, src, tokens, diag).parse_file()
		if not diag.errors:
			Checker([module], diag, program=False).run()
		return module.decls, diag, out

	def test_character_types_and_constants(self):
		for literal, type_, value in (("'a'", UBYTE, 97), (r"'\xFF'", UBYTE, 255),
				(r"'\n'", UBYTE, 10), (r"'\0'", UBYTE, 0), (r"'\\'", UBYTE, 92),
				(r"'\''", UBYTE, 39), ("'é'", UWORD, 233), ("'д'", UWORD, 1076),
				("'😀'", UWORD, 0x1F600), ("'\U0010ffff'", UWORD, 0x10FFFF)):
			with self.subTest(literal=literal):
				decls, diag, out = self.check(f"let c: {type_} = {literal}")
				self.assertEqual(diag.errors, 0, out.getvalue())
				self.assertIs(decls[0].init.type, type_)
				self.assertEqual(decls[0].sym.const, value)

	def test_unicode_function_arguments_and_arithmetic(self):
		decls, diag, out = self.check("""
let putChar(c: UWord): Void {}
let sample(): Void {
    putChar('д')
    putChar('э' as UWord)
    putChar('😀')
    putChar('a' as UWord)
}
let next: UWord = 'д' + 1
let byte: UByte = 'é' as UByte
""")
		self.assertEqual(diag.errors, 0, out.getvalue())
		self.assertEqual(decls[2].sym.const, 0x0435)
		self.assertEqual(decls[3].sym.const, 0xE9)

	def test_unicode_character_needs_cast_to_byte(self):
		for text in ("é", "д", "😀"):
			with self.subTest(text=text):
				_, diag, out = self.check(f"let c: UByte = '{text}'")
				self.assertGreater(diag.errors, 0)
				self.assertIn("expected 'UByte', found 'UWord'", out.getvalue())

	def test_literal_errors(self):
		for src, message in (('"é\t"', "a tab"), ('"é\n"', "unclosed"),
				('"é\x01"', "control character"), (r'"é\q"', "unknown escape")):
			with self.subTest(src=src):
				_, diag, out = self.lex(src)
				self.assertGreater(diag.errors, 0)
				self.assertIn(message, out.getvalue())

	def test_import_and_assembly_text(self):
		decls = self.parse('import { value } from "модуль.m"')
		self.assertEqual(decls[0].path, "модуль.m")
		decls = self.parse('let f(): Void { asm { "; café 😀" } }')
		self.assertEqual(decls[0].body.stmts[0].lines, ["; café 😀"])

	def test_invalid_utf8_text_is_diagnostic(self):
		for src in (r'import { value } from "\xFF.m"',
				r'let f(): Void { asm { "\xFF" } }'):
			with self.subTest(src=src):
				with self.assertRaisesRegex(ParseError, "valid UTF-8 text"):
					self.parse(src)

	def test_unicode_import_path_loads(self):
		with tempfile.TemporaryDirectory() as tmp:
			root = Path(tmp)
			(root / "main.m").write_text('import { value } from "модуль.m"', encoding="utf-8")
			(root / "модуль.m").write_text('let value: *UByte = "Привет"', encoding="utf-8")
			out = io.StringIO()
			diag = Diagnostics(out)
			modules = load_program([str(root / "main.m")], [], diag)
			self.assertEqual(diag.errors, 0, out.getvalue())
			self.assertEqual(len(modules), 2)

	def test_invalid_source_utf8(self):
		with tempfile.TemporaryDirectory() as tmp:
			path = Path(tmp) / "bad.m"
			path.write_bytes(b'let s: *UByte = "\xff"')
			out = io.StringIO()
			diag = Diagnostics(out)
			self.assertIsNone(parse_module(str(path), diag).decls)
			self.assertIn("not valid UTF-8", out.getvalue())
