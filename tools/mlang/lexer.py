"""Tokens of M (m/docs/spec/01-lexical.md)."""

from .diag import Loc


KEYWORDS = {
	"align", "as", "asm", "break", "by", "case", "continue", "default",
	"else", "enum", "export", "extern", "false", "for", "from", "if",
	"import", "in", "let", "mut", "null", "packed", "return", "switch",
	"true", "type", "volatile", "while",
}
BUILTIN_TYPES = {"Byte", "UByte", "Half", "UHalf", "Word", "UWord", "Bool", "Float", "Void"}
BUILTIN_FUNCS = {
	"mfcr", "mtcr", "syscall", "wfi", "hlt", "tlbi", "fence", "breakpoint",
	"clz", "ctz", "popcount", "bswap", "rotl", "rotr",
	"atomicLoad", "atomicStore", "atomicSwap", "atomicAdd", "atomicCompareSwap",
	"sizeof", "alignof", "offsetof",
}

# Longest first: the lexer takes the longest operator that matches
OPERATORS = sorted("""
	+ - * / % +| -| *| & | ^ ~ << >> == != < <= > >= && || !
	= += -= *= /= %= &= |= ^= <<= >>= ++ -- . .. ... , : ( ) [ ] { }
""".split(), key=len, reverse=True)

ASSIGN_OPS = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}
CMP_OPS = {"==", "!=", "<", "<=", ">", ">="}
# Tokens that can continue an expression: after a condition in
# parentheses they mean the condition was meant to go on (5.5)
CONTINUES_EXPR = {
	"+", "-", "*", "/", "%", "+|", "-|", "*|", "&", "|", "^", "<<", ">>",
	"&&", "||", "as", ".", "[", "(",
} | CMP_OPS

ESCAPES = {"n": 0x0A, "r": 0x0D, "t": 0x09, "0": 0x00, "\\": 0x5C, "'": 0x27, '"': 0x22}


class Token:
	def __init__(self, kind, value, loc, pos, end):
		self.kind = kind    # id kw op int float char str eof
		self.value = value  # the text for id, kw and op; the value for literals
		self.loc = loc
		self.pos = pos      # source offsets of the token text
		self.end = end
		self.doc = None     # Loc of a /// comment right before the token

	def is_(self, text):
		return self.kind in ("op", "kw") and self.value == text

	def __str__(self):
		if self.kind == "eof":
			return "the end of the file"
		if self.kind in ("op", "kw", "id"):
			return f"'{self.value}'"
		return {"int": "a number", "float": "a number", "char": "a character",
				"str": "a string"}[self.kind]


def digits_ok(text, allowed):
	"""'_' only between digits, at least one digit."""
	return (text != "" and text[0] != "_" and text[-1] != "_" and "__" not in text
			and all(c in allowed or c == "_" for c in text))


class Lexer:
	def __init__(self, path, src, diag):
		self.path = path
		self.src = src
		self.diag = diag
		self.i = 0
		self.line = 1
		self.line_start = 0
		self.tokens = []
		self.doc = None

	def loc(self, pos=None):
		pos = self.i if pos is None else pos
		return Loc(self.path, self.line, pos - self.line_start + 1)

	def error(self, loc, msg):
		self.diag.error(loc, msg)

	def newline(self, pos):
		self.line += 1
		self.line_start = pos + 1

	def run(self):
		src, n = self.src, len(self.src)
		while True:
			self.skip_space()
			if self.i >= n:
				break
			c = src[self.i]
			start, loc = self.i, self.loc()
			if c.isascii() and (c.isalpha() or c == "_"):
				while self.i < n and src[self.i].isascii() and (src[self.i].isalnum() or src[self.i] == "_"):
					self.i += 1
				word = src[start:self.i]
				self.add("kw" if word in KEYWORDS else "id", word, loc, start)
			elif c.isascii() and c.isdigit():
				self.number(start, loc)
			elif c == "'":
				self.char(start, loc)
			elif c == '"':
				self.string(start, loc)
			else:
				for op in OPERATORS:
					if src.startswith(op, self.i):
						self.i += len(op)
						self.add("op", op, loc, start)
						break
				else:
					self.i += 1
					if c.isascii():
						self.error(loc, f"unexpected character '{c}'")
					else:
						self.error(loc, "characters outside ASCII are allowed only in comments and literals")
		self.add("eof", None, self.loc(), self.i)
		return self.tokens

	def add(self, kind, value, loc, start):
		tok = Token(kind, value, loc, start, self.i)
		tok.doc, self.doc = self.doc, None
		self.tokens.append(tok)

	def skip_space(self):
		src, n = self.src, len(self.src)
		while self.i < n:
			c = src[self.i]
			if c == "\n":
				self.newline(self.i)
				self.i += 1
			elif c in " \t\r":
				self.i += 1
			elif src.startswith("//", self.i):
				if src.startswith("///", self.i) and not src.startswith("////", self.i):
					if self.doc is None:
						self.doc = self.loc()
				end = src.find("\n", self.i)
				self.i = n if end < 0 else end
			elif src.startswith("/*", self.i):
				self.block_comment()
			else:
				break

	def block_comment(self):
		src, n = self.src, len(self.src)
		loc, depth = self.loc(), 0
		while self.i < n:
			if src.startswith("/*", self.i):
				depth += 1
				self.i += 2
			elif src.startswith("*/", self.i):
				depth -= 1
				self.i += 2
				if depth == 0:
					return
			else:
				if src[self.i] == "\n":
					self.newline(self.i)
				self.i += 1
		self.error(loc, "unclosed '/*'")

	def number(self, start, loc):
		src, n = self.src, len(self.src)
		while self.i < n and src[self.i].isascii() and (src[self.i].isalnum() or src[self.i] == "_"):
			self.i += 1
		word = src[start:self.i]
		if (word[0] != "0" or len(word) == 1 or word[1] not in "xXbB") and \
				self.i + 1 < n and src[self.i] == "." and src[self.i + 1].isdigit():
			self.i += 1
			while self.i < n and src[self.i].isascii() and (src[self.i].isalnum() or src[self.i] == "_"):
				self.i += 1
			whole, frac = word, src[start + len(word) + 1:self.i]
			if not digits_ok(whole, "0123456789") or not digits_ok(frac, "0123456789"):
				self.error(loc, f"bad number '{src[start:self.i]}'")
				value = 0.0
			else:
				if len(whole.replace("_", "")) > 1 and whole[0] == "0":
					self.error(loc, f"a decimal number can't start with 0: '{src[start:self.i]}'")
				value = float(whole.replace("_", "") + "." + frac.replace("_", ""))
			self.add("float", value, loc, start)
			return
		value = 0
		if word[:2] in ("0X", "0B"):
			self.error(loc, f"number prefixes are lowercase: '{word[:2].lower()}'")
		elif word[:2] == "0x":
			if digits_ok(word[2:], "0123456789abcdefABCDEF"):
				value = int(word[2:].replace("_", ""), 16)
			else:
				self.error(loc, f"bad number '{word}'" + ("; '_' goes only between digits" if "_" in word else ""))
		elif word[:2] == "0b":
			if digits_ok(word[2:], "01"):
				value = int(word[2:].replace("_", ""), 2)
			else:
				self.error(loc, f"bad number '{word}'" + ("; '_' goes only between digits" if "_" in word else ""))
		elif digits_ok(word, "0123456789"):
			value = int(word.replace("_", ""))
			if len(word) > 1 and word[0] == "0":
				self.error(loc, f"a decimal number can't start with 0: '{word}' (there are no octal numbers)")
		else:
			self.error(loc, f"bad number '{word}'" + ("; '_' goes only between digits" if "_" in word else ""))
		self.add("int", value, loc, start)

	def literal_body(self, quote, loc):
		"""Reads the body of a character or string literal up to the closing
		quote; returns character codes or UTF-8 bytes, or None if unclosed."""
		src, n = self.src, len(self.src)
		out = [] if quote == "'" else bytearray()
		what = "character" if quote == "'" else "string"
		while True:
			if self.i >= n or src[self.i] == "\n":
				self.error(loc, f"unclosed {what} literal")
				return None
			c = src[self.i]
			if c == quote:
				self.i += 1
				return out if quote == "'" else bytes(out)
			if c == "\\":
				eloc = self.loc()
				e = src[self.i + 1:self.i + 2]
				if e in ESCAPES:
					out.append(ESCAPES[e])
					self.i += 2
				elif e == "x":
					hexd = src[self.i + 2:self.i + 4]
					if len(hexd) == 2 and all(h in "0123456789abcdefABCDEF" for h in hexd):
						out.append(int(hexd, 16))
						self.i += 4
					else:
						self.error(eloc, "'\\x' needs exactly two hex digits")
						self.i += 2
				else:
					self.error(eloc, f"unknown escape '\\{e}'")
					self.i += 2 if e and e != "\n" else 1
			else:
				if c == "\t":
					self.error(self.loc(), "a tab inside a literal; write '\\t'")
				elif c.isascii() and not c.isprintable():
					self.error(self.loc(), f"a control character inside a literal; write it as '\\x{ord(c):02X}'")
				if quote == '"':
					out.extend(c.encode("utf-8"))
				else:
					out.append(ord(c))
				self.i += 1

	def char(self, start, loc):
		self.i += 1
		body = self.literal_body("'", loc)
		value = 0
		if body is not None:
			if len(body) != 1:
				self.error(loc, "a character literal holds exactly one character")
			else:
				value = body[0]
		self.add("char", value, loc, start)
		# Keep ASCII and escaped byte literals compatible with existing code.
		self.tokens[-1].wide = any(not c.isascii() for c in self.src[start:self.i])

	def string(self, start, loc):
		self.i += 1
		body = self.literal_body('"', loc)
		self.add("str", body or b"", loc, start)
