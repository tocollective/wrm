#!/usr/bin/env python3
"""Assembler for the WRM.081632 CPU.

Produces a raw little-endian image whose first byte is at --base
(0xFE000000, the start of ROM, by default). The instruction set is
described in docs/INSTRUCTIONS.md, the machine in docs/SPECIFICATION.md.
"""

SYNTAX = """\
syntax:
  label:                    global label, starts a new local scope
  .local:                   local label, visible as .local until the next
                            global label (and as label.local everywhere)
  NAME = expr               constant (also .equ NAME, expr / .set NAME, expr)
  ; comment  # comment  // comment

  registers: r0-r31, zero (= r0), tp (= r28), fp (= r29), sp (= r30),
             ra (= r31)
  control registers: status, epc, ivec, scratch, cause, badaddr, ptbr,
                     cycle, cycleh, instret, instreth, cpuid (read-only),
                     cr0-cr11 or a number

  expressions: C operators | ^ & << >> + - * / % ~ and parentheses,
    numbers 42 0x2A 0b101010 0o52 'c', $ = address of the current line,
    %hi(x) = x >> 13 (for LUI), %lo(x) = x & 0x1FFF (for ORI)

  operands:
    ADD rd, rs1, rs2          ADDI rd, rs1, imm       LUI rd, imm19
    LW rd, imm(rs1)           SW rd, imm(rs1)         LW rd, (rs1)
    BEQ rd, rs1, target       JAL [rd,] target        JALR rd, rs1[, imm]
    MFCR rd, cr               MTCR cr, rs1            JALR rd, imm(rs1)
    TLBI rs1                  LL rd, (rs1)           SC rd, rs2, (rs1)
    TLBI.ASID rs1             TLBI.ALL
    FADD rd, rs1, rs2         FSQRT rd, rs1           ITOF rd, rs1
  branch and JAL targets are addresses (labels), not offsets.
  float values (fli, .float): 1.5 -2e-3 inf nan, or an integer expression

pseudo-instructions:
  li rd, value      1 or 2 instructions (LUI + ORI for 32-bit values)
  la rd, address    always LUI + ORI
  mv rd, rs         ADDI rd, rs, 0
  neg rd, rs        SUB rd, r0, rs
  seqz rd, rs       SLTIU rd, rs, 1
  snez rd, rs       SLTU rd, r0, rs
  j target          JAL r0, target
  call target       JAL r31, target
  jr rs             JALR r0, rs, 0
  ret               JALR r0, r31, 0
  beqz/bnez/bltz/bgez/bgtz/blez rs, target
  bgt/ble/bgtu/bleu rs1, rs2, target
  fli rd, float     li with the bits of a binary32 value
  fmv rd, rs        FSGNJ rd, rs, rs
  fneg rd, rs       FSGNJN rd, rs, rs
  fabs rd, rs       FSGNJX rd, rs, rs
  fgt/fge rd, rs1, rs2   FLT/FLE rd, rs2, rs1

directives:
  .org address              continue at an absolute address
  .align n[, fill]          pad to a multiple of n bytes (power of two)
  .byte / .db  values       8-bit values or strings
  .half / .dh  values       16-bit values
  .word / .dw  values       32-bit values
  .float values             binary32 values
  .ascii "str"[, ...]       string bytes
  .asciz / .string "str"    string bytes followed by a zero byte
  .space / .zero n[, fill]  n fill bytes
  .include "file.s"         include source (relative to the including file, then -I)
  .incbin "file.bin"        include raw bytes
"""

import argparse
import os
import re
import struct
import sys

ROM_BASE = 0xFE000000
ROM_SIZE = 32 * 1024 * 1024


class AsmError(Exception):
	pass


class Undefined(AsmError):
	def __init__(self, name):
		super().__init__(f"undefined symbol '{name}'")
		self.name = name


# -- encoding -------------------------------------------------------------

OP_ADDI = 0x20
OP_ORI = 0x23
OP_LUI = 0x30
OP_SUB = 0x11
OP_SLTU = 0x19
OP_SLTIU = 0x29
OP_JAL = 0x60
OP_JALR = 0x61
OP_FSGNJ = 0x79
OP_FSGNJN = 0x7A
OP_FSGNJX = 0x7B
OP_FLT = 0x81
OP_FLE = 0x82


def enc_r(op, rd, rs1, rs2):
	return op | rd << 8 | rs1 << 13 | rs2 << 18


def enc_i(op, rd, rs1, imm14):
	return op | rd << 8 | rs1 << 13 | (imm14 & 0x3FFF) << 18


def enc_u(op, rd, imm19):
	return op | rd << 8 | (imm19 & 0x7FFFF) << 13


def sign32(v):
	return v - (1 << 32) if 0x80000000 <= v <= 0xFFFFFFFF else v


def check_range(v, lo, hi, what):
	if not lo <= v <= hi:
		raise AsmError(f"{what} {v} out of range [{lo}, {hi}]")


REGS = {f"r{i}": i for i in range(32)}
REGS.update(zero=0, tp=28, fp=29, sp=30, ra=31)  # roles from docs/ABI.md

CREGS = {f"cr{i}": i for i in range(12)}
CREGS.update(status=0, epc=1, ivec=2, scratch=3, cause=4, badaddr=5, ptbr=6,
             cycle=7, cycleh=8, instret=9, instreth=10, cpuid=11)
CREGS_READONLY = {7, 8, 9, 10, 11}  # MTCR to them is an illegal instruction
TLBI_PAGE, TLBI_ASID, TLBI_ALL = 0, 1, 2  # TLBI modes, in imm14


# -- lexing ---------------------------------------------------------------

SYMBOL_RE = re.compile(r"[A-Za-z_.][\w.$]*")
LABEL_RE = re.compile(r"\s*([A-Za-z_.][\w.$]*)\s*:")
EQU_RE = re.compile(r"([A-Za-z_.][\w.$]*)\s*=(.*)$")
STRING_RE = re.compile(r'"((?:\\.|[^"\\])*)"')

TOKEN_RE = re.compile(r"""
	  (?P<ws>\s+)
	| (?P<num>0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*)
	| (?P<chr>'(?:\\x[0-9a-fA-F]{2}|\\.|[^'\\])')
	| (?P<func>%[A-Za-z_]+(?=\s*\())
	| (?P<id>[A-Za-z_.][\w.$]*)
	| (?P<op><<|>>|[-+*/%&|^~()$])
""", re.X)

ESCAPES = {
	"n": 10, "t": 9, "r": 13, "0": 0, "a": 7, "b": 8, "f": 12, "v": 11,
	"e": 27, "\\": 92, "'": 39, '"': 34,
}


def unescape(body):
	out = bytearray()
	i = 0
	while i < len(body):
		c = body[i]
		if c != "\\":
			out += c.encode("utf-8")
			i += 1
			continue
		if i + 1 >= len(body):
			raise AsmError("dangling backslash")
		c = body[i + 1]
		if c == "x":
			digits = body[i + 2:i + 4]
			if not re.fullmatch(r"[0-9a-fA-F]{2}", digits):
				raise AsmError("\\x needs two hex digits")
			out.append(int(digits, 16))
			i += 4
		elif c in ESCAPES:
			out.append(ESCAPES[c])
			i += 2
		else:
			raise AsmError(f"unknown escape '\\{c}'")
	return bytes(out)


def is_string(text):
	return text.startswith('"')


def parse_string(text):
	m = STRING_RE.fullmatch(text)
	if not m:
		raise AsmError(f"malformed string {text}")
	return unescape(m.group(1))


def parse_number(text):
	text = text.replace("_", "")
	prefix = text[:2].lower()
	base = {"0x": 16, "0b": 2, "0o": 8}.get(prefix)
	return int(text[2:], base) if base else int(text, 10)


def tokenize(text):
	toks = []
	pos = 0
	while pos < len(text):
		m = TOKEN_RE.match(text, pos)
		if not m:
			raise AsmError(f"unexpected character '{text[pos]}' in expression")
		pos = m.end()
		if m.lastgroup != "ws":
			toks.append((m.lastgroup, m.group()))
	return toks


def strip_comment(line):
	quote = None
	i = 0
	while i < len(line):
		c = line[i]
		if quote:
			if c == "\\":
				i += 1
			elif c == quote:
				quote = None
		elif c in "\"'":
			quote = c
		elif c in ";#" or line.startswith("//", i):
			return line[:i]
		i += 1
	return line


def split_operands(text):
	parts, cur = [], []
	depth, quote = 0, None
	i = 0
	while i < len(text):
		c = text[i]
		if quote:
			if c == "\\" and i + 1 < len(text):
				cur.append(c)
				i += 1
				c = text[i]
			elif c == quote:
				quote = None
		elif c in "\"'":
			quote = c
		elif c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
		elif c == "," and depth == 0:
			parts.append("".join(cur).strip())
			cur = []
			i += 1
			continue
		cur.append(c)
		i += 1
	if quote:
		raise AsmError("unterminated string")
	last = "".join(cur).strip()
	if last or parts:
		parts.append(last)
	if any(not p for p in parts):
		raise AsmError("empty operand")
	return parts


# -- expressions ----------------------------------------------------------

FUNCS = {
	"%hi": lambda v: (v >> 13) & 0x7FFFF,
	"%lo": lambda v: v & 0x1FFF,
}


def c_div(a, b):
	if b == 0:
		raise AsmError("division by zero")
	q = abs(a) // abs(b)
	return q if (a < 0) == (b < 0) else -q


def apply_binary(op, a, b):
	if op == "+": return a + b
	if op == "-": return a - b
	if op == "*": return a * b
	if op == "/": return c_div(a, b)
	if op == "%": return a - b * c_div(a, b)
	if op == "&": return a & b
	if op == "|": return a | b
	if op == "^": return a ^ b
	if not 0 <= b <= 64:
		raise AsmError(f"shift amount {b} out of range [0, 64]")
	return a << b if op == "<<" else a >> b


class ExprParser:
	LEVELS = [("|",), ("^",), ("&",), ("<<", ">>"), ("+", "-"), ("*", "/", "%")]

	def __init__(self, text, lookup):
		self.toks = tokenize(text)
		self.pos = 0
		self.lookup = lookup

	def peek(self):
		return self.toks[self.pos] if self.pos < len(self.toks) else (None, None)

	def take(self):
		tok = self.peek()
		self.pos += 1
		return tok

	def expect(self, text):
		kind, got = self.take()
		if got != text:
			raise AsmError(f"expected '{text}' in expression")

	def parse(self):
		if not self.toks:
			raise AsmError("expected an expression")
		v = self.binary(0)
		if self.pos < len(self.toks):
			raise AsmError(f"unexpected '{self.toks[self.pos][1]}' in expression")
		return v

	def binary(self, level):
		if level == len(self.LEVELS):
			return self.unary()
		v = self.binary(level + 1)
		while True:
			kind, text = self.peek()
			if kind != "op" or text not in self.LEVELS[level]:
				return v
			self.pos += 1
			v = apply_binary(text, v, self.binary(level + 1))

	def unary(self):
		kind, text = self.take()
		if kind == "op":
			if text == "-": return -self.unary()
			if text == "+": return self.unary()
			if text == "~": return ~self.unary()
			if text == "$": return self.lookup("$")
			if text == "(":
				v = self.binary(0)
				self.expect(")")
				return v
		if kind == "num":
			return parse_number(text)
		if kind == "chr":
			value = unescape(text[1:-1])
			if len(value) != 1:
				raise AsmError(f"character {text} is not a single byte")
			return value[0]
		if kind == "id":
			return self.lookup(text)
		if kind == "func":
			func = FUNCS.get(text.lower())
			if not func:
				raise AsmError(f"unknown function '{text}'")
			self.expect("(")
			v = self.binary(0)
			self.expect(")")
			return func(v)
		if kind is None:
			raise AsmError("unexpected end of expression")
		raise AsmError(f"unexpected '{text}' in expression")


# -- instructions ---------------------------------------------------------
# Each entry is (size, encoder). size is a byte count or a function
# (asm, stmt, pc) called in the first pass; the encoder returns words.

INSTRUCTIONS = {}


def fmt_n(op):
	def enc(a, st, pc):
		a.nargs(st, 0)
		return [op]
	return enc


def fmt_r(op):
	def enc(a, st, pc):
		rd, rs1, rs2 = a.nargs(st, 3)
		return [enc_r(op, a.reg(rd), a.reg(rs1), a.reg(rs2))]
	return enc


def fmt_r1(op):
	def enc(a, st, pc):
		rd, rs1 = a.nargs(st, 2)
		return [enc_r(op, a.reg(rd), a.reg(rs1), 0)]
	return enc


def fmt_r_swap(op):
	def enc(a, st, pc):
		rd, rs1, rs2 = a.nargs(st, 3)
		return [enc_r(op, a.reg(rd), a.reg(rs2), a.reg(rs1))]
	return enc


def fmt_atomic(op, load=False):
	def enc(a, st, pc):
		args = a.nargs(st, 2 if load else 3)
		rd = a.reg(args[0])
		value = 0 if load else a.reg(args[1])
		mem = args[1] if load else args[2]
		match = re.fullmatch(r"\s*\(\s*([A-Za-z][\w]*)\s*\)\s*", mem)
		if not match:
			raise AsmError("atomic address must be (rs1)")
		return [enc_r(op, rd, a.reg(match.group(1)), value)]
	return enc


def fmt_alu_i(op, kind):
	def enc(a, st, pc):
		rd, rs1, imm = a.nargs(st, 3)
		return [enc_i(op, a.reg(rd), a.reg(rs1), a.imm14(st, imm, pc, kind))]
	return enc


def fmt_upper(op):
	def enc(a, st, pc):
		rd, imm = a.nargs(st, 2)
		v = a.eval(st, imm, pc)
		check_range(v, -0x40000, 0x7FFFF, "imm19")
		return [enc_u(op, a.reg(rd), v)]
	return enc


def fmt_mem(op):
	def enc(a, st, pc):
		rd, mem = a.nargs(st, 2)
		off, rs1 = a.mem(st, mem, pc)
		check_range(off, -8192, 8191, "offset")
		return [enc_i(op, a.reg(rd), rs1, off)]
	return enc


def fmt_branch(op, swap=False):
	def enc(a, st, pc):
		rd, rs1, target = a.nargs(st, 3)
		if swap:
			rd, rs1 = rs1, rd
		return [enc_i(op, a.reg(rd), a.reg(rs1), a.pcrel(st, target, pc, 14))]
	return enc


def fmt_branch_zero(op, zero_first=False):
	def enc(a, st, pc):
		rs, target = a.nargs(st, 2)
		rd, rs1 = (0, a.reg(rs)) if zero_first else (a.reg(rs), 0)
		return [enc_i(op, rd, rs1, a.pcrel(st, target, pc, 14))]
	return enc


def enc_jal(a, st, pc):
	args = a.nargs(st, 1, 2)
	rd = a.reg(args[0]) if len(args) == 2 else 31
	return [enc_u(OP_JAL, rd, a.pcrel(st, args[-1], pc, 19))]


def enc_jalr(a, st, pc):
	args = a.nargs(st, 1, 3)
	if len(args) == 1:
		rd, rs1, imm = 31, a.reg(args[0]), 0
	elif len(args) == 2 and args[1].lower() not in REGS:
		rd = a.reg(args[0])
		imm, rs1 = a.mem(st, args[1], pc)
	else:
		rd, rs1 = a.reg(args[0]), a.reg(args[1])
		imm = a.eval(st, args[2], pc) if len(args) == 3 else 0
	imm = sign32(imm)
	check_range(imm, -8192, 8191, "offset")
	return [enc_i(OP_JALR, rd, rs1, imm)]


def fixed(words):
	def enc(a, st, pc):
		a.nargs(st, 0)
		return words
	return enc


def enc_mfcr(a, st, pc):
	rd, cr = a.nargs(st, 2)
	return [enc_i(0x04, a.reg(rd), 0, a.creg(st, cr, pc))]


def enc_mtcr(a, st, pc):
	cr, rs1 = a.nargs(st, 2)
	n = a.creg(st, cr, pc)
	if n in CREGS_READONLY:
		raise AsmError(f"control register {cr.strip()} is read-only")
	return [enc_i(0x05, 0, a.reg(rs1), n)]


def enc_tlbi(mode):
	def enc(a, st, pc):
		if mode == TLBI_ALL:
			a.nargs(st, 0)
			return [enc_i(0x06, 0, 0, mode)]
		rs1, = a.nargs(st, 1)
		return [enc_i(0x06, 0, a.reg(rs1), mode)]
	return enc


def pseudo_rr(build):
	def enc(a, st, pc):
		rd, rs = a.nargs(st, 2)
		return [build(a.reg(rd), a.reg(rs))]
	return enc


def jump_to(rd):
	def enc(a, st, pc):
		target, = a.nargs(st, 1)
		return [enc_u(OP_JAL, rd, a.pcrel(st, target, pc, 19))]
	return enc


def check_value32(v):
	check_range(v, -(1 << 31), (1 << 32) - 1, "value")


def load_full(rd, v):
	u = v & 0xFFFFFFFF
	return [enc_u(OP_LUI, rd, u >> 13), enc_i(OP_ORI, rd, rd, u & 0x1FFF)]


def load_short(rd, v):
	u = v & 0xFFFFFFFF
	s = sign32(u)
	if -8192 <= s <= 8191:
		return [enc_i(OP_ADDI, rd, 0, s)]
	if u <= 0x3FFF:
		return [enc_i(OP_ORI, rd, 0, u)]
	if not u & 0x1FFF:
		return [enc_u(OP_LUI, rd, u >> 13)]
	return load_full(rd, v)


def size_li(a, st, pc, value=None):
	# The short form is used only when the value is known in the first
	# pass, so the size never changes between passes.
	if len(st.args) != 2:
		return 8
	try:
		v = (value or a.try_eval)(st, st.args[1], pc)
	except AsmError:
		return 8
	if v is None or not -(1 << 31) <= v < (1 << 32):
		return 8
	return 4 * len(load_short(0, v))


def enc_li(a, st, pc, value=None):
	rd, text = a.nargs(st, 2)
	v = (value or a.eval)(st, text, pc)
	check_value32(v)
	return load_full(a.reg(rd), v) if st.size == 8 else load_short(a.reg(rd), v)


def enc_la(a, st, pc):
	rd, value = a.nargs(st, 2)
	v = a.eval(st, value, pc)
	check_value32(v)
	return load_full(a.reg(rd), v)


def define_instructions():
	ins = INSTRUCTIONS
	for name, op in (("hlt", 0x00), ("nop", 0x01), ("wfi", 0x02), ("iret", 0x03),
					 ("syscall", 0x07), ("fence", 0x08), ("break", 0x09)):
		ins[name] = (4, fmt_n(op))
	ins["mfcr"] = (4, enc_mfcr)
	ins["mtcr"] = (4, enc_mtcr)
	ins["tlbi"] = (4, enc_tlbi(TLBI_PAGE))
	ins["tlbi.asid"] = (4, enc_tlbi(TLBI_ASID))
	ins["tlbi.all"] = (4, enc_tlbi(TLBI_ALL))

	for i, name in enumerate(("add", "sub", "and", "or", "xor", "shl", "shr", "sar",
							  "slt", "sltu", "mul", "div", "divu", "rem", "remu")):
		ins[name] = (4, fmt_r(0x10 + i))
	for name, op in (("mulh", 0x1F), ("mulhu", 0x2A), ("mulhsu", 0x2B)):
		ins[name] = (4, fmt_r(op))

	for name, op, kind in (("addi", 0x20, "signed"), ("andi", 0x22, "unsigned"),
						   ("ori", 0x23, "unsigned"), ("xori", 0x24, "unsigned"),
						   ("shli", 0x25, "shift"), ("shri", 0x26, "shift"),
						   ("sari", 0x27, "shift"), ("slti", 0x28, "signed"),
						   ("sltiu", 0x29, "signed")):
		ins[name] = (4, fmt_alu_i(op, kind))

	ins["lui"] = (4, fmt_upper(0x30))
	ins["auipc"] = (4, fmt_upper(0x31))

	for name, op in (("lb", 0x40), ("lbu", 0x41), ("lh", 0x42), ("lhu", 0x43), ("lw", 0x44),
					 ("sb", 0x48), ("sh", 0x49), ("sw", 0x4A)):
		ins[name] = (4, fmt_mem(op))
	for name, op in (("ll", 0x4B), ("sc", 0x4C)):
		ins[name] = (4, fmt_atomic(op, name == "ll"))

	for i, name in enumerate(("beq", "bne", "blt", "bge", "bltu", "bgeu")):
		ins[name] = (4, fmt_branch(0x50 + i))

	ins["jal"] = (4, enc_jal)
	ins["jalr"] = (4, enc_jalr)

	for i, name in enumerate(("fadd", "fsub", "fmul", "fdiv", "fsqrt", "fmin", "fmax",
							  "fmadd", "fmsub", "fsgnj", "fsgnjn", "fsgnjx")):
		ins[name] = (4, (fmt_r1 if name == "fsqrt" else fmt_r)(0x70 + i))
	for name, op in (("feq", 0x80), ("flt", 0x81), ("fle", 0x82)):
		ins[name] = (4, fmt_r(op))
	for name, op in (("fclass", 0x83), ("ftoi", 0x84), ("ftou", 0x85), ("itof", 0x86),
					 ("utof", 0x87)):
		ins[name] = (4, fmt_r1(op))

	# pseudo-instructions
	ins["li"] = (size_li, enc_li)
	ins["la"] = (8, enc_la)
	ins["mv"] = (4, pseudo_rr(lambda rd, rs: enc_i(OP_ADDI, rd, rs, 0)))
	ins["neg"] = (4, pseudo_rr(lambda rd, rs: enc_r(OP_SUB, rd, 0, rs)))
	ins["seqz"] = (4, pseudo_rr(lambda rd, rs: enc_i(OP_SLTIU, rd, rs, 1)))
	ins["snez"] = (4, pseudo_rr(lambda rd, rs: enc_r(OP_SLTU, rd, 0, rs)))
	ins["j"] = (4, jump_to(0))
	ins["call"] = (4, jump_to(31))
	ins["jr"] = (4, lambda a, st, pc: [enc_i(OP_JALR, 0, a.reg(a.nargs(st, 1)[0]), 0)])
	ins["ret"] = (4, fixed([enc_i(OP_JALR, 0, 31, 0)]))
	ins["beqz"] = (4, fmt_branch_zero(0x50))
	ins["bnez"] = (4, fmt_branch_zero(0x51))
	ins["bltz"] = (4, fmt_branch_zero(0x52))
	ins["bgez"] = (4, fmt_branch_zero(0x53))
	ins["bgtz"] = (4, fmt_branch_zero(0x52, zero_first=True))
	ins["blez"] = (4, fmt_branch_zero(0x53, zero_first=True))
	ins["bgt"] = (4, fmt_branch(0x52, swap=True))
	ins["ble"] = (4, fmt_branch(0x53, swap=True))
	ins["bgtu"] = (4, fmt_branch(0x54, swap=True))
	ins["bleu"] = (4, fmt_branch(0x55, swap=True))
	ins["fli"] = (lambda a, st, pc: size_li(a, st, pc, a.try_float),
				  lambda a, st, pc: enc_li(a, st, pc, a.float))
	ins["fmv"] = (4, pseudo_rr(lambda rd, rs: enc_r(OP_FSGNJ, rd, rs, rs)))
	ins["fneg"] = (4, pseudo_rr(lambda rd, rs: enc_r(OP_FSGNJN, rd, rs, rs)))
	ins["fabs"] = (4, pseudo_rr(lambda rd, rs: enc_r(OP_FSGNJX, rd, rs, rs)))
	ins["fgt"] = (4, fmt_r_swap(OP_FLT))
	ins["fge"] = (4, fmt_r_swap(OP_FLE))


define_instructions()


# -- directives -----------------------------------------------------------
# Each entry is (size, emitter): size(asm, stmt, pc) runs in the first
# pass, emitter(asm, stmt, pc) returns the bytes in the second.

def dir_data(width):
	lo, hi = -(1 << (8 * width - 1)), (1 << (8 * width)) - 1

	def size(a, st, pc):
		a.nargs(st, 1, None)
		n = 0
		for arg in st.args:
			if is_string(arg):
				if width != 1:
					raise AsmError(f"strings are not allowed in '{st.op}'")
				n += len(parse_string(arg))
			else:
				n += width
		return n

	def emit(a, st, pc):
		out = bytearray()
		for arg in st.args:
			if is_string(arg):
				out += parse_string(arg)
				continue
			v = a.eval(st, arg, pc)
			if not lo <= v <= hi:
				raise AsmError(f"value {v} does not fit in {8 * width} bits")
			out += (v & hi).to_bytes(width, "little")
		return bytes(out)

	return size, emit


def emit_float(a, st, pc):
	return b"".join(a.float(st, arg, pc).to_bytes(4, "little") for arg in st.args)


def dir_ascii(zero):
	def strings(a, st):
		a.nargs(st, 1, None)
		out = bytearray()
		for arg in st.args:
			if not is_string(arg):
				raise AsmError(f"'{st.op}' expects strings, got '{arg}'")
			out += parse_string(arg)
			if zero:
				out.append(0)
		return bytes(out)

	return (lambda a, st, pc: len(strings(a, st))), (lambda a, st, pc: strings(a, st))


def fill_byte(a, st, pc):
	if len(st.args) < 2:
		return a.fill
	v = a.eval(st, st.args[1], pc)
	check_range(v, -128, 255, "fill byte")
	return v & 0xFF


def size_space(a, st, pc):
	a.nargs(st, 1, 2)
	n = a.const(st, st.args[0], pc)
	if n < 0:
		raise AsmError(f"negative size {n}")
	return n


def emit_space(a, st, pc):
	return bytes([fill_byte(a, st, pc)]) * st.size


def align_to(a, st, pc):
	a.nargs(st, 1, 2)
	n = a.const(st, st.args[0], pc)
	if n <= 0 or n & (n - 1):
		raise AsmError(f"alignment {n} is not a power of two")
	return (pc + n - 1) & ~(n - 1)


DIRECTIVES = {
	".byte": dir_data(1), ".db": dir_data(1),
	".half": dir_data(2), ".dh": dir_data(2),
	".word": dir_data(4), ".dw": dir_data(4),
	".float": (lambda a, st, pc: 4 * len(a.nargs(st, 1, None)), emit_float),
	".ascii": dir_ascii(False),
	".asciz": dir_ascii(True), ".string": dir_ascii(True),
	".space": (size_space, emit_space), ".zero": (size_space, emit_space),
	".align": (lambda a, st, pc: align_to(a, st, pc) - pc, emit_space),
	".incbin": (lambda a, st, pc: len(st.data), lambda a, st, pc: st.data),
}


# -- assembler ------------------------------------------------------------

class Stmt:
	def __init__(self, loc, text, scope, labels, op, args):
		self.loc = loc
		self.text = text
		self.scope = scope
		self.labels = labels
		self.op = op
		self.args = args
		self.addr = 0
		self.size = 0
		self.data = None  # .incbin contents
		self.out = b""
		self.is_insn = False


class Assembler:
	def __init__(self, base, include_dirs=(), fill=0):
		self.base = base
		self.include_dirs = list(include_dirs)
		self.fill = fill
		self.stmts = []
		self.symbols = {}
		self.defined_at = {}
		self.errors = []
		self.scope = None

	def error(self, loc, msg):
		self.errors.append(f"{loc[0]}:{loc[1]}: error: {msg}" if loc else f"error: {msg}")

	def check(self):
		if self.errors:
			for e in self.errors:
				print(e, file=sys.stderr)
			sys.exit(1)

	# -- symbols

	def qualify(self, name, scope):
		if not name.startswith("."):
			return name
		if not scope:
			raise AsmError(f"local symbol '{name}' has no enclosing global label")
		return scope + name

	def define(self, loc, name, value):
		if name in self.symbols:
			where = self.defined_at[name]
			self.error(loc, f"'{name}' is already defined at {where[0]}:{where[1]}")
			return
		self.symbols[name] = value
		self.defined_at[name] = loc

	def predefine(self, text):
		name, _, value = text.partition("=")
		if not SYMBOL_RE.fullmatch(name) or name.startswith("."):
			raise AsmError(f"invalid symbol name '{name}'")
		def lookup(n):
			raise Undefined(n)
		v = ExprParser(value, lookup).parse() if value else 1
		self.define(("<command line>", 0), name, v)

	# -- operands

	def eval(self, st, text, pc):
		def lookup(name):
			if name == "$":
				return pc
			full = self.qualify(name, st.scope)
			if full not in self.symbols:
				raise Undefined(full)
			return self.symbols[full]
		return ExprParser(text, lookup).parse()

	def try_eval(self, st, text, pc):
		try:
			return self.eval(st, text, pc)
		except Undefined:
			return None

	def const(self, st, text, pc):
		try:
			return self.eval(st, text, pc)
		except Undefined as e:
			raise AsmError(f"{e} (must be defined before this line)") from None

	def float(self, st, text, pc):
		"""Bits of the binary32 value of a float literal or an integer expression."""
		try:
			v = float(text)
		except ValueError:
			v = self.eval(st, text, pc)
		try:
			return struct.unpack("<I", struct.pack("<f", v))[0]
		except OverflowError:
			raise AsmError(f"'{text.strip()}' is out of range for a float") from None

	def try_float(self, st, text, pc):
		try:
			return self.float(st, text, pc)
		except Undefined:
			return None

	def nargs(self, st, lo, hi=-1):
		hi = lo if hi == -1 else hi
		n = len(st.args)
		if n < lo or (hi is not None and n > hi):
			want = str(lo) if lo == hi else f"{lo}+" if hi is None else f"{lo}-{hi}"
			raise AsmError(f"'{st.op}' expects {want} operand(s), got {n}")
		return st.args

	def reg(self, text):
		r = REGS.get(text.strip().lower())
		if r is None:
			raise AsmError(f"expected a register, got '{text}'")
		return r

	def creg(self, st, text, pc):
		cr = CREGS.get(text.strip().lower())
		if cr is None:
			cr = self.eval(st, text, pc)
			if cr not in CREGS.values():
				raise AsmError(f"no control register {cr}")
		return cr

	def mem(self, st, text, pc):
		"""Parses 'offset(reg)' or '(reg)', returns (offset, reg)."""
		text = text.strip()
		if text.endswith(")"):
			depth = 0
			for i in range(len(text) - 1, -1, -1):
				depth += {")": 1, "(": -1}.get(text[i], 0)
				if depth == 0:
					break
			inner, prefix = text[i + 1:-1].strip(), text[:i].strip()
			if inner.lower() in REGS:
				off = sign32(self.eval(st, prefix, pc)) if prefix else 0
				return off, REGS[inner.lower()]
		raise AsmError(f"expected a memory operand 'offset(reg)', got '{text}'")

	def imm14(self, st, text, pc, kind):
		v = self.eval(st, text, pc)
		if kind == "signed":
			check_range(sign32(v), -8192, 8191, "immediate")
		elif kind == "unsigned":
			check_range(v, 0, 0x3FFF, "immediate")
		else:
			check_range(v, 0, 31, "shift amount")
		return v & 0x3FFF

	def pcrel(self, st, text, pc, bits):
		target = self.eval(st, text, pc)
		off = target - pc
		if off % 4:
			raise AsmError(f"target 0x{target & 0xFFFFFFFF:08X} is not 4-byte aligned")
		limit = 1 << (bits - 1)
		if not -limit <= off >> 2 < limit:
			raise AsmError(f"target 0x{target & 0xFFFFFFFF:08X} is out of range "
						   f"(offset {off} bytes, max ±{limit * 4})")
		return (off >> 2) & ((1 << bits) - 1)

	# -- parsing

	def parse_file(self, path, stack=()):
		with open(path, encoding="utf-8") as f:
			lines = f.read().splitlines()
		stack = stack + (os.path.realpath(path),)
		saved_scope, self.scope = self.scope, None
		for n, raw in enumerate(lines, 1):
			try:
				self.parse_line((path, n), raw, stack)
			except AsmError as e:
				self.error((path, n), e)
		self.scope = saved_scope

	def label_name(self, name):
		if name.lower() in REGS:
			raise AsmError(f"'{name}' is a register name")
		if name.startswith("."):
			return self.qualify(name, self.scope)
		self.scope = name
		return name

	def parse_line(self, loc, raw, stack):
		line = strip_comment(raw)
		labels = []
		while True:
			m = LABEL_RE.match(line)
			if not m:
				break
			labels.append(self.label_name(m.group(1)))
			line = line[m.end():]
		line = line.strip()

		op, args = None, []
		if line:
			m = EQU_RE.match(line)
			if m:
				op, args = "=", [m.group(1), m.group(2).strip()]
			else:
				parts = line.split(None, 1)
				op = parts[0].lower()
				args = split_operands(parts[1]) if len(parts) > 1 else []
				if op in (".equ", ".set"):
					if len(args) != 2:
						raise AsmError(f"'{op}' expects a name and a value")
					op = "="
		if op == "=":
			name = args[0]
			if not SYMBOL_RE.fullmatch(name) or name.lower() in REGS:
				raise AsmError(f"invalid symbol name '{name}'")
			if not args[1]:
				raise AsmError(f"missing value for '{name}'")
			args[0] = self.qualify(name, self.scope)

		st = Stmt(loc, raw.rstrip().expandtabs(4), self.scope, labels, op, args)
		if op == ".include":
			path = self.find_file(st)
			if os.path.realpath(path) in stack:
				raise AsmError(f"'{path}' includes itself")
			if labels:
				st.op = None
				self.stmts.append(st)
			try:
				self.parse_file(path, stack)
			except OSError as e:
				raise AsmError(f"cannot read '{path}': {e.strerror}") from None
			return
		if op == ".incbin":
			path = self.find_file(st)
			try:
				with open(path, "rb") as f:
					st.data = f.read()
			except OSError as e:
				raise AsmError(f"cannot read '{path}': {e.strerror}") from None
		if labels or op:
			self.stmts.append(st)

	def find_file(self, st):
		self.nargs(st, 1)
		name = parse_string(st.args[0]).decode("utf-8")
		for d in [os.path.dirname(st.loc[0])] + self.include_dirs:
			path = os.path.join(d, name)
			if os.path.isfile(path):
				return path
		raise AsmError(f"cannot find '{name}'")

	# -- passes

	def layout(self):
		"""First pass: assigns addresses and defines symbols."""
		pc = self.base
		pending = []
		for st in self.stmts:
			st.addr = label_pc = pc
			try:
				if st.op == ".org":
					self.nargs(st, 1)
					st.addr = label_pc = pc = self.const(st, st.args[0], pc)
				elif st.op == ".align":
					label_pc = align_to(self, st, pc)
					st.size = label_pc - pc
				elif st.op == "=":
					pass
				elif st.op is not None:
					st.size = self.size_of(st, pc)
			except AsmError as e:
				self.error(st.loc, e)
			for name in st.labels:
				self.define(st.loc, name, label_pc)
			if st.op == "=":
				try:
					v = self.try_eval(st, st.args[1], pc)
				except AsmError as e:
					self.error(st.loc, e)
				else:
					if v is None:
						pending.append(st)
					else:
						self.define(st.loc, st.args[0], v)
			pc += st.size

		# constants may refer to labels and constants defined later
		while pending:
			left = []
			for st in pending:
				try:
					v = self.try_eval(st, st.args[1], st.addr)
				except AsmError as e:
					self.error(st.loc, e)
					continue
				if v is None:
					left.append(st)
				else:
					self.define(st.loc, st.args[0], v)
			if len(left) == len(pending):
				for st in left:
					try:
						self.eval(st, st.args[1], st.addr)
					except AsmError as e:
						self.error(st.loc, e)
				break
			pending = left

	def size_of(self, st, pc):
		if st.op in DIRECTIVES:
			return DIRECTIVES[st.op][0](self, st, pc)
		if st.op in INSTRUCTIONS:
			size = INSTRUCTIONS[st.op][0]
			return size(self, st, pc) if callable(size) else size
		kind = "directive" if st.op.startswith(".") else "instruction"
		raise AsmError(f"unknown {kind} '{st.op}'")

	def emit(self):
		"""Second pass: encodes every statement."""
		for st in self.stmts:
			if st.op in (None, "=", ".org"):
				continue
			try:
				if st.op in DIRECTIVES:
					out = DIRECTIVES[st.op][1](self, st, st.addr)
				else:
					if st.addr % 4:
						raise AsmError(f"instruction at unaligned address 0x{st.addr:08X}")
					words = INSTRUCTIONS[st.op][1](self, st, st.addr)
					out = b"".join(w.to_bytes(4, "little") for w in words)
					st.is_insn = True
			except AsmError as e:
				self.error(st.loc, e)
				continue
			assert len(out) == st.size, f"{st.loc}: size changed between passes"
			st.out = out

	def link(self, max_size):
		chunks = sorted((st for st in self.stmts if st.out), key=lambda st: st.addr)
		end = self.base
		prev = None
		for st in chunks:
			stop = st.addr + len(st.out)
			if st.addr < self.base:
				self.error(st.loc, f"address 0x{st.addr & 0xFFFFFFFF:08X} is below the image base 0x{self.base:08X}")
			elif stop > 1 << 32:
				self.error(st.loc, "past the end of the address space")
			elif prev and st.addr < prev.addr + len(prev.out):
				self.error(st.loc, f"overlaps output of {prev.loc[0]}:{prev.loc[1]}")
			prev = st
			end = max(end, stop)
		size = end - self.base
		if size > max_size:
			self.error(None, f"image is {size} bytes, over the {max_size}-byte limit")
		self.check()

		image = bytearray([self.fill]) * size
		for st in chunks:
			image[st.addr - self.base:st.addr - self.base + len(st.out)] = st.out
		return bytes(image)

	def listing(self):
		lines = []
		cur_file = None
		for st in self.stmts:
			if st.loc[0] != cur_file:
				cur_file = st.loc[0]
				lines.append(f"; {cur_file}")
			if st.is_insn:
				cells = [(i, f"{int.from_bytes(st.out[i:i + 4], 'little'):08X}")
						 for i in range(0, len(st.out), 4)]
			else:
				cells = [(i, " ".join(f"{b:02X}" for b in st.out[i:i + 8]))
						 for i in range(0, len(st.out), 8)]
			src = f"{st.loc[1]:5}  {st.text}"
			if not cells:
				addr = f"{st.addr:08X}" if st.labels or st.op == ".org" else ""
				lines.append(f"{addr:8}  {'':23}  {src}")
			for n, (off, cell) in enumerate(cells):
				lines.append(f"{st.addr + off:08X}  {cell:23}  {src if n == 0 else ''}".rstrip())
		lines += ["", "; symbols"]
		for name, v in sorted(self.symbols.items(), key=lambda kv: (kv[1], kv[0])):
			lines.append(f"{v & 0xFFFFFFFF:08X}  {name}")
		return "\n".join(lines) + "\n"


def auto_int(text):
	return int(text, 0)


def main(argv=None):
	p = argparse.ArgumentParser(
		prog="asm.py", description="WRM.081632 assembler", epilog=SYNTAX,
		formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("input", help="source file")
	p.add_argument("-o", "--output", help="output image (default: input with .rom extension)")
	p.add_argument("-l", "--listing", help="write a listing with addresses, code and symbols")
	p.add_argument("-I", dest="include", action="append", default=[], metavar="DIR",
				   help="add a directory to search for .include/.incbin files")
	p.add_argument("-D", dest="defines", action="append", default=[], metavar="NAME[=VALUE]",
				   help="define a constant (default value 1)")
	p.add_argument("--base", type=auto_int, default=ROM_BASE,
				   help="address of the first image byte (default: 0x%(default)X)")
	p.add_argument("--max-size", type=auto_int, default=ROM_SIZE,
				   help="maximum image size in bytes (default: %(default)d)")
	p.add_argument("--fill", type=auto_int, default=0,
				   help="byte used for gaps and padding (default: 0)")
	args = p.parse_args(argv)

	if not 0 <= args.fill <= 0xFF:
		p.error("--fill must be a byte")
	if not 0 <= args.base <= 0xFFFFFFFF:
		p.error("--base must be a 32-bit address")
	output = args.output or os.path.splitext(args.input)[0] + ".rom"

	asm = Assembler(args.base, args.include, args.fill)
	for d in args.defines:
		try:
			asm.predefine(d)
		except AsmError as e:
			asm.error(("<command line>", 0), e)
	try:
		asm.parse_file(args.input)
	except OSError as e:
		asm.error(None, f"cannot read '{args.input}': {e.strerror}")
	asm.check()
	asm.layout()
	asm.check()
	asm.emit()
	asm.check()
	image = asm.link(args.max_size)

	with open(output, "wb") as f:
		f.write(image)
	if args.listing:
		with open(args.listing, "w", encoding="utf-8") as f:
			f.write(asm.listing())
	print(f"{output}: {len(image)} bytes")


if __name__ == "__main__":
	main()
