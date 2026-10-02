"""Code generation: the checked tree to assembly for tools/asm.py.

Nothing is optimized (m/docs/COMPILER.md): every read and write in the
source is one load or store, in order, so 'volatile' holds by itself.

Values of expressions live on a stack of registers, r10-r27. They are
saved by the callee (docs/ABI.md), so a call in the middle of an
expression keeps them. Value number v is in r(10 + v mod 18): past 18
values, pushing a value spills the one 18 below it, which shares its
register, to a slot of the frame, and popping reloads it. So the top 18
values are always in registers, which is all an operation needs. A scalar is its value, normalized to its type
(7.8: UByte and UHalf zero-extended, Byte and Half sign-extended, Bool 0
or 1); a struct or an array is its address. r1-r9 are only used inside
one step: marshalling a call, a byte-wise load, a large offset (r9).

Every local variable and parameter has a slot in the frame, at a negative
offset from fp; parameters passed on the stack are above fp. The frame:

    fp - 4      ra
    fp - 8      the caller's fp
    ...         locals and temporaries
    sp + out    the saved r10-r27 that the function uses
    sp          the outgoing stack arguments
"""

import os
import re
import struct

from .diag import CompileError
from .image import Program
from .lexer import CMP_OPS
from .syntax import *
from .typesys import *

NREGS = 18  # r10-r27

ASM_RESERVED = {f"r{i}" for i in range(32)} | {f"cr{i}" for i in range(16)} | {
	"zero", "tp", "fp", "sp", "ra", "status", "epc", "ivec", "scratch", "cause",
	"badaddr", "ptbr", "cycle", "cycleh", "instret", "instreth", "cpuid",
	"taddr0", "tctrl0", "taddr1", "tctrl1"}

LABEL_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*(?::|=)", re.M)
INCLUDE_RE = re.compile(r'^\s*\.include\s+"([^"]+)"', re.M)


INVERSE = {"beqz": "bnez", "bnez": "beqz", "beq": "bne", "bne": "beq", "blt": "bge",
		   "bge": "blt", "bltu": "bgeu", "bgeu": "bltu", "bgt": "ble", "ble": "bgt",
		   "bgtu": "bleu", "bleu": "bgtu"}
BRANCH_REACH = 7000     # instructions; a branch reaches 8192 either way


def reg(i):
	"""The register of value number i of the stack."""
	return f"r{10 + i % NREGS}"


def is_aggr(t):
	return t.kind in ("struct", "array")


def scalar_bits(v, t):
	"""A constant scalar as the unsigned bits it has in memory."""
	if t is FLOAT:
		return struct.unpack("<I", struct.pack("<f", v))[0]
	return v & 0xFFFFFFFF


def lowbit(n):
	return n & -n if n else 1 << 30


def words_of(t):
	"""Registers a value of type t takes as an argument or a result:
	scalars and aggregates up to 8 bytes by value, larger ones as a
	pointer (docs/ABI.md, "Arguments")."""
	if is_aggr(t):
		size = size_of(t)
		return 1 if size <= 4 else 2 if size <= 8 else 1
	return 1


def by_reference(t):
	return is_aggr(t) and size_of(t) > 8


def classify(types, hidden):
	"""ABI locations of arguments: ('reg', first register 1-8, words) or
	('stack', offset from sp, words); and the stack bytes used."""
	nreg, stack, on_stack, out = (1 if hidden else 0), 0, False, []
	for t in types:
		words = words_of(t)
		if not on_stack and nreg + words <= 8:
			out.append(("reg", nreg + 1, words))
			nreg += words
		else:
			on_stack = True
			if words == 2:
				stack = align_up(stack, 8)
			out.append(("stack", stack, words))
			stack += 4 * words
	return out, stack


def loads(t, align=4):
	"""The load instruction for a scalar of type t."""
	size = size_of(t)
	signed = (t.base if t.kind == "enum" else t).signed if t.kind in ("int", "enum") else False
	return {1: "lb" if signed else "lbu", 2: "lh" if signed else "lhu", 4: "lw"}[size]


def signed_type(t):
	if t.kind == "enum":
		t = t.base
	return t.kind == "int" and t.signed


class CodeGen:
	"""Labels of every module loaded; the code of one module at a time
	(run), for an object file of its own."""

	def __init__(self, modules, diag):
		self.modules = modules
		self.diag = diag
		self.program = None
		self.strings = {}       # bytes -> label, of the module being made
		self.assign_labels()

	def run(self, m):
		"""The Program of module m."""
		self.program = Program(m.path)
		self.strings = {}
		for d in m.decls:
			if isinstance(d, FuncDecl) and d.body is not None:
				try:
					self.program.code.append(FuncGen(self, d).gen())
				except CompileError as e:
					self.diag.error(e.loc, e.msg)
			elif isinstance(d, VarDecl) and not d.extern:
				self.global_var(d.sym)
		path = os.path.splitext(m.path)[0] + ".asm"
		asm_defined = set()
		if os.path.isfile(path):
			self.program.includes.append(path)
			asm_defined = self.asm_labels(path, set())
		for sym in m.scope.values():
			if sym.kind not in ("var", "func"):
				continue
			if sym.extern:
				# defined by the module's .asm: other modules may call it
				if sym.label in asm_defined:
					self.program.globals.append(sym.label)
				continue
			self.program.globals += sym.export_names
			for name in sym.export_names[1:]:
				self.program.code.append(f"{name} = {sym.label}\n")
		self.program.globals = list(dict.fromkeys(self.program.globals))
		for data, label in self.strings.items():
			self.program.rodata.append(f"{label}:\n" + self.bytes_lines(list(data) + [0]))
		return self.program

	def assign_labels(self):
		stems = set()
		for m in self.modules:
			stem = re.sub(r"\W", "_", os.path.splitext(os.path.basename(m.path))[0])
			base, n = stem, 1
			while stem in stems:
				n += 1
				stem = f"{base}{n}"
			stems.add(stem)
			for sym in m.scope.values():
				if sym.kind not in ("var", "func"):
					continue
				if sym.extern:
					sym.label = sym.name
				elif sym.export_names:
					sym.label = sym.export_names[0]
				else:
					sym.label = f"{stem}__{sym.name}"
				for name in dict.fromkeys([sym.label] + sym.export_names):
					if name in ASM_RESERVED:
						self.diag.error(sym.decl.loc, f"'{name}' can't be a symbol: the assembler "
													  f"reads it as a register")

	def string(self, data):
		if data not in self.strings:
			self.strings[data] = f"__str{len(self.strings)}"
		return self.strings[data]

	# -- global data

	def global_var(self, sym):
		d, t = sym.decl, sym.type
		size, align = size_of(t), max(align_of(t), getattr(d, "align_value", None) or 1)
		if d.init is None:
			self.program.bss.append((sym.label, size, align))
			return
		image = [0] * size
		self.static(d.init, t, image, 0)
		if d.mut and all(b == 0 for b in image):
			self.program.bss.append((sym.label, size, align))
			return
		if d.mut:
			self.program.data.append((sym.label, size, align, self.bytes_lines(image)))
		else:
			self.program.rodata.append(f"\t.align {align}\n{sym.label}:\n" + self.bytes_lines(image))

	def static(self, e, t, image, off):
		"""Writes the value of a constant initializer into image: bytes,
		and (label, offset) tuples for words the assembler fills in."""
		if e.const is not None and not is_aggr(t):
			bits = scalar_bits(e.const, t)
			for i in range(size_of(t)):
				image[off + i] = bits >> 8 * i & 0xFF
		elif isinstance(e, StringLit):
			self.reloc(image, off, (self.string(e.value), 0))
		elif isinstance(e, NullLit):
			pass
		elif isinstance(e, Name):
			if e.sym.kind == "func":
				self.reloc(image, off, (e.sym.label, 0))
			else:
				self.static(e.sym.decl.init, t, image, off)
		elif isinstance(e, Unary) and e.op in ("&", "&mut"):
			self.reloc(image, off, self.static_addr(e.operand))
		elif isinstance(e, Cast):
			self.static(e.expr, e.expr.type, image, off)
		elif isinstance(e, StructLit):
			for fi in e.fields:
				self.static(fi.value, fi.field.type, image, off + fi.field.offset)
		elif isinstance(e, ArrayLit):
			for i, x in enumerate(e.elems):
				self.static(x, t.elem, image, off + i * size_of(t.elem))
		else:
			raise AssertionError(f"not a static initializer: {e}")

	def static_addr(self, e):
		if isinstance(e, Name):
			return e.sym.label, 0
		if isinstance(e, Member):
			label, off = self.static_addr(e.obj)
			return label, off + e.field.offset
		label, off = self.static_addr(e.obj)
		return label, off + e.index.const * size_of(e.type)

	@staticmethod
	def reloc(image, off, target):
		image[off] = target
		for i in range(1, 4):
			image[off + i] = None

	@staticmethod
	def bytes_lines(image):
		out, run = [], []

		def flush():
			if run:
				out.append("\t.byte " + ", ".join(f"0x{b:02X}" for b in run) + "\n")
				run.clear()

		for b in image:
			if b is None:
				continue
			if isinstance(b, tuple):
				flush()
				label, off = b
				out.append(f"\t.word {label}" + (f" + {off}" if off else "") + "\n")
				continue
			run.append(b)
			if len(run) == 16:
				flush()
		flush()
		return "".join(out)

	# -- symbols defined outside M

	def asm_labels(self, path, seen):
		path = os.path.realpath(path)
		if path in seen:
			return set()
		seen.add(path)
		try:
			with open(path, encoding="utf-8", errors="replace") as f:
				text = f.read()
		except OSError:
			return set()
		labels = set(LABEL_RE.findall(text))
		for inc in INCLUDE_RE.findall(text):
			labels |= self.asm_labels(os.path.join(os.path.dirname(path), inc), seen)
		return labels


class FuncGen:
	"""One function."""

	def __init__(self, cg, decl, far=False, spills=0):
		self.cg = cg
		self.far = far          # conditional branches may not reach: invert them around a 'j'
		self.spills = spills    # frame slots for values past NREGS, see push
		self.decl = decl
		self.sym = decl.sym
		self.ft = decl.sym.type
		self.lines = []
		self.depth = 0
		self.max_depth = 0
		self.locals = 8         # bytes below fp in use: ra and fp
		self.max_locals = 8
		self.outgoing = 0
		self.nlabels = 0
		self.targets = {}       # loop or switch node -> (continue label, break label)
		self.ret_slot = None    # the hidden result pointer
		self.loc = decl.loc

	# -- output

	def emit(self, text):
		self.lines.append("\t" + text)

	def label(self, name):
		self.lines.append(name + ":")

	def cbranch(self, op, args, label):
		"""A conditional branch to a label of the function's statements."""
		if self.far:
			skip = self.new_label()
			self.emit(f"{INVERSE[op]} {args}, {skip}")
			self.emit(f"j {label}")
			self.label(skip)
		else:
			self.emit(f"{op} {args}, {label}")

	def new_label(self):
		self.nlabels += 1
		return f".L{self.nlabels}"

	def push(self):
		"""A register for a new value on top of the stack. Past NREGS values
		it is the register of the value NREGS below, which is spilled."""
		v = self.depth
		r = reg(v)
		if v >= NREGS and self.spills:
			self.mem("sw", r, "fp", self.spill_slot(v - NREGS))
		self.depth += 1
		self.max_depth = max(self.max_depth, self.depth)
		return r

	def pop(self, n=1):
		"""Drops the top n values, reloading those they had spilled."""
		for _ in range(n):
			self.depth -= 1
			v = self.depth
			assert v >= 0
			if v >= NREGS and self.spills:
				self.mem("lw", reg(v), "fp", self.spill_slot(v - NREGS))

	def spill_slot(self, v):
		return self.spill_area + 4 * v

	def slot(self, size, align):
		"""Frame bytes for a variable or a temporary; returns the offset
		from fp."""
		self.locals = align_up(self.locals + size, max(align, 4))
		self.max_locals = max(self.max_locals, self.locals)
		return -self.locals

	def li(self, r, v):
		self.emit(f"li {r}, {v & 0xFFFFFFFF if v >= 1 << 31 else v}")

	def mem(self, op, r, base, off):
		"""A load or a store at base + off, for any offset."""
		if -8192 <= off <= 8191:
			self.emit(f"{op} {r}, {off}({base})")
		else:
			self.li("r9", off)
			self.emit(f"add r9, {base}, r9")
			self.emit(f"{op} {r}, 0(r9)")

	def addi(self, r, base, off):
		if off == 0:
			if r != base:
				self.emit(f"mv {r}, {base}")
		elif -8192 <= off <= 8191:
			self.emit(f"addi {r}, {base}, {off}")
		else:
			self.li("r9", off)
			self.emit(f"add {r}, {base}, r9")

	# -- the function

	def gen(self):
		d, ft = self.decl, self.ft
		hidden = by_reference(ft.result)
		locs, _ = classify(ft.params, hidden)
		if self.spills:
			self.spill_area = self.slot(4 * self.spills, 4)
		entry = []
		if hidden:
			self.ret_slot = self.slot(4, 4)
			entry.append(("sw", "r1", self.ret_slot))
		for p, pt, (where, n, words) in zip(d.params, ft.params, locs):
			var = p.var
			var.indirect = by_reference(pt)
			if where == "reg":
				var.offset = self.slot(4 * words, 8 if words == 2 else 4)
				for i in range(words):
					entry.append(("sw", f"r{n + i}", var.offset + 4 * i))
			else:
				var.offset = n     # the caller's sp is our fp
			var.align = 4
		self.ret_label = self.new_label()
		self.block(d.body)
		body = self.lines
		size = sum(2 if l.startswith(("\tli ", "\tla ")) else 1 for l in body if l.startswith("\t"))
		far = self.far or size > BRANCH_REACH
		spills = max(self.spills, self.max_depth - NREGS)
		if far != self.far or spills != self.spills:
			# redo with long branches or slots for spills: the first pass
			# only measured
			return FuncGen(self.cg, self.decl, far, spills).gen()

		nsaved = min(self.max_depth, NREGS)
		frame = align_up(self.max_locals + 4 * nsaved + self.outgoing, 8)
		label = self.sym.label
		out = [f"\n; {d.name} ({self.decl.loc.path}:{d.loc.line})", f"{label}:"]
		self.lines = out
		self.emit("addi sp, sp, -8")
		self.emit("sw ra, 4(sp)")
		self.emit("sw fp, 0(sp)")
		self.emit("addi fp, sp, 8")
		if frame > 8:
			self.addi("sp", "sp", -(frame - 8))
		for i in range(nsaved):
			self.emit(f"sw {reg(i)}, {self.outgoing + 4 * i}(sp)")
		for op, r, off in entry:
			self.mem(op, r, "fp", off)
		out += body
		self.label(self.ret_label)
		for i in range(nsaved):
			self.emit(f"lw {reg(i)}, {self.outgoing + 4 * i}(sp)")
		self.emit("lw ra, -4(fp)")
		self.emit("mv sp, fp")
		self.emit("lw fp, -8(sp)")
		self.emit("ret")
		return "\n".join(out) + "\n"

	# -- statements

	def block(self, b):
		for s in b.stmts:
			self.stmt(s)

	def stmt(self, s):
		assert self.depth == 0
		self.loc = s.loc
		saved = self.locals
		getattr(self, "st_" + type(s).__name__)(s)
		if not isinstance(s, VarDecl):
			self.locals = saved     # temporaries and inner variables are free again

	def st_Block(self, s):
		self.block(s)

	def st_VarDecl(self, s):
		var, t = s.var, s.var.type
		var.indirect = False
		var.align = max(align_of(t), 4)
		var.offset = self.slot(size_of(t), var.align)
		if s.init is None:
			return
		saved = self.locals
		r = self.push()
		self.addi(r, "fp", var.offset)
		self.init_into(r, 0, var.align, s.init, t)
		self.pop()
		self.locals = saved

	def st_Assign(self, s):
		t = s.target.type
		d, off, al = self.addr(s.target)
		if s.op == "=":
			if is_aggr(t):
				if isinstance(s.value, (StructLit, ArrayLit)):
					src, soff, sal = self.temp_aggr(s.value, t)
				else:
					src, soff, sal = self.aggr(s.value)
				self.copy(d, off, al, src, soff, sal, t,
						  getattr(s.target, "volatile", False), getattr(s.value, "volatile", False))
				self.pop()
			else:
				v = self.expr(s.value)
				self.store(v, d, off, t, al)
				self.pop()
		else:
			old = self.push()
			self.load(old, d, off, t, al)
			v = self.expr(s.value)
			self.binop(s.op[:-1], old, v, t)
			self.pop()
			self.store(old, d, off, t, al)
			self.pop()
		self.pop()

	def st_IncDec(self, s):
		t = s.target.type
		d, off, al = self.addr(s.target)
		v = self.push()
		self.load(v, d, off, t, al)
		self.emit(f"addi {v}, {v}, {1 if s.op == '++' else -1}")
		self.norm(v, t)
		self.store(v, d, off, t, al)
		self.pop(2)

	def st_ExprStmt(self, s):
		self.expr(s.expr)
		self.pop()

	def st_If(self, s):
		r = self.expr(s.cond)
		other = self.new_label()
		self.cbranch("beqz", r, other)
		self.pop()
		self.body(s.then)
		if s.else_ is None:
			self.label(other)
			return
		end = self.new_label()
		self.emit(f"j {end}")
		self.label(other)
		self.body(s.else_)
		self.label(end)

	def body(self, s):
		saved = self.locals
		self.stmt(s)
		self.locals = saved

	def st_While(self, s):
		top, end = self.new_label(), self.new_label()
		self.targets[s] = (top, end)
		self.label(top)
		if s.cond.const != 1:
			r = self.expr(s.cond)
			self.cbranch("beqz", r, end)
			self.pop()
		self.body(s.body)
		self.emit(f"j {top}")
		self.label(end)

	def st_For(self, s):
		"""5.7: never steps past the end and never wraps the variable."""
		var, t = s.var, s.var.type
		var.indirect, var.align = False, 4
		var.offset = self.slot(4, 4)
		end_slot = self.slot(4, 4)
		r = self.expr(s.start)
		self.mem("sw", r, "fp", var.offset)
		self.pop()
		r = self.expr(s.end)
		self.mem("sw", r, "fp", end_slot)
		self.pop()
		k = s.step_value
		up, inclusive, step = k > 0, s.inclusive, abs(k)
		signed = signed_type(t)
		body, cont, done = self.new_label(), self.new_label(), self.new_label()
		self.targets[s] = (cont, done)
		i, e = self.push(), self.push()

		def past_end():
			"""Jumps to done if i is outside the range."""
			self.mem(loads(t), i, "fp", var.offset)
			self.mem(loads(t), e, "fp", end_slot)
			if up:
				self.branch(">=" if not inclusive else ">", i, e, signed, done)
			else:
				self.branch("<=" if not inclusive else "<", i, e, signed, done)

		past_end()
		self.pop(2)
		self.label(body)
		self.body(s.body)
		self.label(cont)
		self.push()
		self.push()
		past_end()
		self.emit(f"sub r9, {e}, {i}" if up else f"sub r9, {i}, {e}")
		self.li(e, step)
		self.branch("<=" if not inclusive else "<", "r9", e, False, done)
		self.emit(f"{'add' if up else 'sub'} {i}, {i}, {e}")
		self.norm(i, t)
		self.mem({1: "sb", 2: "sh", 4: "sw"}[size_of(t)], i, "fp", var.offset)
		self.pop(2)
		self.emit(f"j {body}")
		self.label(done)

	def st_Switch(self, s):
		r = self.expr(s.value)
		labels = [self.new_label() for _ in s.cases]
		end = self.new_label()
		default = end
		for case, label in zip(s.cases, labels):
			if case.value is None:
				default = label
				continue
			self.li("r9", case.value.const)
			self.cbranch("beq", f"{r}, r9", label)
		self.emit(f"j {default}")
		self.pop()
		self.targets[s] = (None, end)
		for case, label in zip(s.cases, labels):
			self.label(label)
			saved = self.locals
			for x in case.body:
				self.stmt(x)
			self.locals = saved
		self.label(end)

	def st_Break(self, s):
		self.emit(f"j {self.targets[s.target][1]}")

	def st_Continue(self, s):
		self.emit(f"j {self.targets[s.target][0]}")

	def st_Return(self, s):
		t = self.ft.result
		if s.value is not None:
			if not is_aggr(t):
				r = self.expr(s.value)
				self.emit(f"mv r1, {r}")
				self.pop()
			elif by_reference(t):
				src, soff, sal = self.aggr(s.value)
				d = self.push()
				self.mem("lw", d, "fp", self.ret_slot)
				self.copy(d, 0, align_of(t), src, soff, sal, t, False, getattr(s.value, "volatile", False))
				self.emit(f"mv r1, {d}")
				self.pop(2)
			else:
				src, soff, sal = self.aggr(s.value)
				self.to_regs(1, src, soff, sal, t)
				self.pop()
		self.emit(f"j {self.ret_label}")

	def st_Asm(self, s):
		for line in s.lines:
			self.emit(line)

	# -- places

	def addr(self, e):
		"""Pushes a register r with an address; returns (r, offset, align):
		e is at r + offset, and r is aligned to align."""
		if isinstance(e, Name):
			sym = e.sym
			r = self.push()
			if sym.kind == "func" or sym.storage == "global":
				self.emit(f"la {r}, {sym.label}")
				return r, 0, align_of(sym.type) if sym.kind == "var" else 4
			if sym.indirect:
				self.mem("lw", r, "fp", sym.offset)
				return r, 0, align_of(sym.type)
			self.addi(r, "fp", sym.offset)
			return r, 0, sym.align
		if isinstance(e, Member):
			if e.obj.type.kind == "ptr":
				r = self.expr(e.obj)
				return r, e.field.offset, align_of(e.obj.type.target)
			r, off, al = self.aggr(e.obj)
			return r, off + e.field.offset, al
		if isinstance(e, Index):
			size = size_of(e.type)
			if e.obj.type.kind == "ptr":
				r, off, al = self.expr(e.obj), 0, align_of(e.obj.type.target)
			else:
				r, off, al = self.aggr(e.obj)
			if e.index.const is not None:
				return r, off + e.index.const * size, al
			i = self.expr(e.index)
			self.scale(i, size)
			self.emit(f"add {r}, {r}, {i}")
			self.pop()
			return r, off, min(al, lowbit(size))
		if isinstance(e, Unary) and e.op == "*":
			return self.expr(e.operand), 0, align_of(e.type)
		raise AssertionError(f"not a place: {e}")

	def aggr(self, e):
		"""Like addr, for any struct or array value, also a temporary one
		(a literal, the result of a call)."""
		if isinstance(e, (Name, Member, Index)) or isinstance(e, Unary) and e.op == "*":
			return self.addr(e)
		if isinstance(e, (StructLit, ArrayLit)):
			return self.temp_aggr(e, e.type)
		return self.expr(e), 0, 4     # a call result, in an aligned temporary

	def temp_aggr(self, e, t):
		al = max(align_of(t), 4)
		off = self.slot(size_of(t), al)
		r = self.push()
		self.addi(r, "fp", off)
		self.init_into(r, 0, al, e, t)
		return r, 0, al

	def scale(self, r, size):
		if size == 1:
			return
		if size & (size - 1) == 0:
			self.emit(f"shli {r}, {r}, {size.bit_length() - 1}")
		else:
			self.li("r9", size)
			self.emit(f"mul {r}, {r}, r9")

	def load(self, dst, base, off, t, align):
		size = size_of(t)
		if min(align, lowbit(off)) >= size:
			self.mem(loads(t), dst, base, off)
			return
		# an unaligned field of a packed struct: byte by byte
		self.assemble("r8", base, off, size)
		self.emit(f"mv {dst}, r8")
		if signed_type(t) and size < 4:
			self.emit(f"shli {dst}, {dst}, {32 - 8 * size}")
			self.emit(f"sari {dst}, {dst}, {32 - 8 * size}")

	def assemble(self, dst, base, off, n):
		"""dst = n bytes at base + off, little-endian, any alignment; uses r9
		for the bytes (and a register of the stack for a far address)."""
		if not -8192 <= off <= 8191 - n:
			t = self.push()
			self.addi(t, base, off)
			self.assemble(dst, t, 0, n)
			self.pop()
			return
		self.emit(f"lbu {dst}, {off}({base})")
		for b in range(1, n):
			self.emit(f"lbu r9, {off + b}({base})")
			self.emit(f"shli r9, r9, {8 * b}")
			self.emit(f"or {dst}, {dst}, r9")

	def store(self, src, base, off, t, align):
		size = size_of(t)
		op = {1: "sb", 2: "sh", 4: "sw"}[size]
		if min(align, lowbit(off)) >= size:
			self.mem(op, src, base, off)
			return
		for b in range(size):    # r8: mem() may need r9 for a far address
			if b:
				self.emit(f"shri r8, {src}, {8 * b}")
			self.mem("sb", src if b == 0 else "r8", base, off + b)

	# -- copies

	def init_into(self, d, off, al, e, t):
		"""Writes the value of e (of type t) to d + off."""
		if isinstance(e, StructLit):
			self.zero(d, off, al, size_of(t))
			for fi in e.fields:
				self.init_into(d, off + fi.field.offset, al, fi.value, fi.field.type)
		elif isinstance(e, ArrayLit):
			self.zero(d, off, al, size_of(t))
			esize = size_of(t.elem)
			for i, x in enumerate(e.elems):
				self.init_into(d, off + i * esize, al, x, t.elem)
		elif is_aggr(t):
			src, soff, sal = self.aggr(e)
			self.copy(d, off, al, src, soff, sal, t, False, getattr(e, "volatile", False))
			self.pop()
		else:
			v = self.expr(e)
			self.store(v, d, off, t, al)
			self.pop()

	def zero(self, d, off, al, size):
		if size > 32:
			self.addi("r1", d, off)
			self.emit("li r2, 0")
			self.li("r3", size)
			self.emit("call memset")
			return
		i = 0
		while i < size:
			w = 4 if size - i >= 4 and min(al, lowbit(off + i)) >= 4 else \
				2 if size - i >= 2 and min(al, lowbit(off + i)) >= 2 else 1
			self.mem({1: "sb", 2: "sh", 4: "sw"}[w], "r0", d, off + i)
			i += w

	def copy(self, d, doff, dal, s, soff, sal, t, dvol, svol):
		"""Copies a struct or an array of type t from s + soff to d + doff.
		A volatile side is copied field by field, each with its own width
		(7.1)."""
		if dvol or svol:
			for ft, off in self.scalar_fields(t, 0):
				v = self.push()
				self.load(v, s, soff + off, ft, sal)
				self.store(v, d, doff + off, ft, dal)
				self.pop()
			return
		size = size_of(t)
		if size > 32:
			self.addi("r1", d, doff)
			self.addi("r2", s, soff)
			self.li("r3", size)
			self.emit("call memcpy")
			return
		i = 0
		while i < size:
			a = min(dal, sal, lowbit(doff + i), lowbit(soff + i))
			w = 4 if size - i >= 4 and a >= 4 else 2 if size - i >= 2 and a >= 2 else 1
			op = {1: "b", 2: "h", 4: "w"}[w]
			# r8: mem() may need r9 for a far address
			self.mem(f"l{op}" if w == 4 else f"l{op}u", "r8", s, soff + i)
			self.mem(f"s{op}", "r8", d, doff + i)
			i += w

	def scalar_fields(self, t, off):
		if t.kind == "struct":
			for f in t.fields:
				yield from self.scalar_fields(f.type, off + f.offset)
		elif t.kind == "array":
			for i in range(t.n):
				yield from self.scalar_fields(t.elem, off + i * size_of(t.elem))
		else:
			yield t, off

	def to_regs(self, first, src, off, al, t):
		"""Puts an aggregate of up to 8 bytes into r<first>, r<first+1> in
		its memory image, as if loaded with LW (docs/ABI.md)."""
		size = size_of(t)
		for w in range((size + 3) // 4):
			r = f"r{first + w}"
			n = min(4, size - 4 * w)
			if min(al, lowbit(off + 4 * w)) >= 4 and n == 4:
				self.mem("lw", r, src, off + 4 * w)
			else:
				self.assemble(r, src, off + 4 * w, n)

	# -- expressions

	def expr(self, e):
		"""Pushes a register with the value of e: a scalar, or the address
		of a struct or an array."""
		t = e.type
		if e.const is not None and not is_aggr(t) and t is not VOID:
			r = self.push()
			self.li(r, scalar_bits(e.const, t) if t is FLOAT else e.const)
			return r
		return getattr(self, "ex_" + type(e).__name__)(e)

	def place_value(self, e):
		r, off, al = self.addr(e)
		if is_aggr(e.type):
			self.addi(r, r, off)
		else:
			self.load(r, r, off, e.type, al)
		return r

	def ex_Name(self, e):
		sym = e.sym
		if sym.kind == "func":
			r = self.push()
			self.emit(f"la {r}, {sym.label}")
			return r
		if sym.storage != "global" and not is_aggr(sym.type):
			r = self.push()
			self.mem(loads(sym.type), r, "fp", sym.offset)
			return r
		return self.place_value(e)

	def ex_Member(self, e):
		return self.place_value(e)

	def ex_Index(self, e):
		return self.place_value(e)

	def ex_StringLit(self, e):
		r = self.push()
		self.emit(f"la {r}, {self.cg.string(e.value)}")
		return r

	def ex_NullLit(self, e):
		r = self.push()
		self.emit(f"li {r}, 0")
		return r

	def ex_StructLit(self, e):
		r, off, al = self.temp_aggr(e, e.type)
		return r

	ex_ArrayLit = ex_StructLit

	def ex_Unary(self, e):
		op, t = e.op, e.type
		if op == "*":
			return self.place_value(e)
		if op in ("&", "&mut"):
			r, off, al = self.addr(e.operand)
			self.addi(r, r, off)
			return r
		r = self.expr(e.operand)
		if op == "!":
			self.emit(f"xori {r}, {r}, 1")
		elif op == "-" and t is FLOAT:
			self.emit(f"fneg {r}, {r}")
		elif op == "-":
			self.emit(f"neg {r}, {r}")
			self.norm(r, t)
		else:   # ~x = -x - 1; XORI zero-extends its immediate
			self.emit(f"neg {r}, {r}")
			self.emit(f"addi {r}, {r}, -1")
			self.norm(r, t)
		return r

	def ex_Binary(self, e):
		op = e.op
		if op in ("&&", "||"):
			r = self.expr(e.left)
			end = self.new_label()
			self.cbranch("beqz" if op == "&&" else "bnez", r, end)
			self.pop()
			r2 = self.expr(e.right)
			assert r2 == r
			self.label(end)
			return r
		a = self.expr(e.left)
		b = self.expr(e.right)
		if op in CMP_OPS:
			self.compare(op, a, b, e.left.type)
		else:
			self.binop(op, a, b, e.type)
		self.pop()
		return a

	def compare(self, op, a, b, t):
		"""a = a op b, 0 or 1."""
		if t is FLOAT:
			if op in ("==", "!="):
				self.emit(f"feq {a}, {a}, {b}")
				if op == "!=":
					self.emit(f"xori {a}, {a}, 1")
			else:
				name = {"<": "flt", "<=": "fle", ">": "fgt", ">=": "fge"}[op]
				self.emit(f"{name} {a}, {a}, {b}")
			return
		if op in ("==", "!="):
			self.emit(f"xor {a}, {a}, {b}")
			self.emit(f"{'seqz' if op == '==' else 'snez'} {a}, {a}")
			return
		slt = "slt" if signed_type(t) else "sltu"
		if op == "<":
			self.emit(f"{slt} {a}, {a}, {b}")
		elif op == ">":
			self.emit(f"{slt} {a}, {b}, {a}")
		elif op == "<=":
			self.emit(f"{slt} {a}, {b}, {a}")
			self.emit(f"xori {a}, {a}, 1")
		else:
			self.emit(f"{slt} {a}, {a}, {b}")
			self.emit(f"xori {a}, {a}, 1")

	def branch(self, op, a, b, signed, label):
		"""Jumps to label if a op b."""
		s = "" if signed else "u"
		name = {"<": f"blt{s}", ">=": f"bge{s}", ">": f"bgt{s}", "<=": f"ble{s}"}[op]
		self.cbranch(name, f"{a}, {b}", label)

	def binop(self, op, a, b, t):
		"""a = a op b in type t (4.7, 4.8)."""
		if t is FLOAT:
			self.emit(f"{ {'+': 'fadd', '-': 'fsub', '*': 'fmul', '/': 'fdiv'}[op]} {a}, {a}, {b}")
			return
		signed = signed_type(t)
		simple = {"+": "add", "-": "sub", "*": "mul", "&": "and", "|": "or", "^": "xor",
				  "<<": "shl", "/": "div" if signed else "divu", "%": "rem" if signed else "remu",
				  ">>": "sar" if signed else "shr"}
		if op in simple:
			self.emit(f"{simple[op]} {a}, {a}, {b}")
			if op not in ("&", "|", "^", ">>"):
				self.norm(a, t)
			return
		self.saturate(op, a, b, t)

	def saturate(self, op, a, b, t):
		"""+| -| *|: the result is clamped to the range of t."""
		signed, size = signed_type(t), size_of(t)
		lo, hi = int_range(t.base if t.kind == "enum" else t)
		done = self.new_label()
		if size < 4:
			# the exact result fits in 32 bits: compute it, then clamp
			self.emit(f"{ {'+|': 'add', '-|': 'sub', '*|': 'mul'}[op]} {a}, {a}, {b}")
			if signed:
				above = self.new_label()
				self.li("r9", lo)
				self.emit(f"bge {a}, r9, {above}")
				self.emit(f"mv {a}, r9")
				self.label(above)
				self.li("r9", hi)
				self.emit(f"ble {a}, r9, {done}")
				self.emit(f"mv {a}, r9")
			else:
				if op == "-|":
					self.emit(f"bgez {a}, {done}")
					self.emit(f"li {a}, 0")
				else:
					self.li("r9", hi)
					self.emit(f"bleu {a}, r9, {done}")
					self.emit(f"mv {a}, r9")
			self.label(done)
			return
		if not signed:
			if op == "+|":
				self.emit(f"add {a}, {a}, {b}")
				self.emit(f"sltu r9, {a}, {b}")           # carry
			elif op == "-|":
				self.emit(f"sltu r9, {a}, {b}")           # borrow
				self.emit(f"sub {a}, {a}, {b}")
				self.emit("addi r9, r9, -1")              # 0 on borrow, else all ones
				self.emit(f"and {a}, {a}, r9")
				return
			else:
				self.emit(f"mulhu r9, {a}, {b}")
				self.emit(f"mul {a}, {a}, {b}")
				self.emit("snez r9, r9")
			self.emit("neg r9, r9")
			self.emit(f"or {a}, {a}, r9")
			return
		# Word: on overflow, MIN or MAX by the sign of the exact result
		if op == "*|":
			# no overflow if the high word is the sign of the low one
			self.emit(f"mulh r8, {a}, {b}")
			self.emit(f"xor r9, {a}, {b}")            # the sign of the exact product
			self.emit(f"mul {a}, {a}, {b}")
			t2 = self.push()
			self.emit(f"sari {t2}, {a}, 31")
			self.emit(f"beq r8, {t2}, {done}")
			self.pop()
		else:
			t2 = self.push()
			self.emit(f"mv {t2}, {a}")
			self.emit(f"{'add' if op == '+|' else 'sub'} {a}, {a}, {b}")
			# overflow: + when both signs differ from the result's; - when
			# the operands differ in sign and the result's differs from a's
			if op == "+|":
				self.emit(f"xor r8, {t2}, {a}")
				self.emit(f"xor r9, {b}, {a}")
			else:
				self.emit(f"xor r8, {t2}, {b}")
				self.emit(f"xor r9, {t2}, {a}")
			self.emit("and r8, r8, r9")
			self.emit(f"bgez r8, {done}")
			self.emit(f"mv r9, {t2}")
			self.pop()
		self.emit("sari r9, r9, 31")                      # 0 or -1: the sign
		self.li("r8", 0x7FFFFFFF)
		self.emit(f"xor {a}, r9, r8")                     # MAX or MIN
		self.label(done)

	def norm(self, r, t):
		"""Brings a 32-bit result back to the range of t (7.8)."""
		if t.kind == "enum":
			t = t.base
		if t.kind != "int" or t.size == 4:
			return
		if t is UBYTE:
			self.emit(f"andi {r}, {r}, 0xFF")
			return
		shift = 32 - 8 * t.size
		self.emit(f"shli {r}, {r}, {shift}")
		self.emit(f"{'sari' if t.signed else 'shri'} {r}, {r}, {shift}")

	def ex_Cast(self, e):
		src, to = e.expr.type, e.type
		r = self.expr(e.expr)
		if to is FLOAT and src is not FLOAT:
			self.emit(f"{'itof' if signed_type(src) else 'utof'} {r}, {r}")
		elif src is FLOAT and to is not FLOAT:
			t = to.base if to.kind == "enum" else to
			self.emit(f"{'ftoi' if t.signed else 'ftou'} {r}, {r}")
			if t.size < 4:
				lo, hi = int_range(t)
				done = self.new_label()
				if t.signed:
					above = self.new_label()
					self.li("r9", lo)
					self.emit(f"bge {r}, r9, {above}")
					self.emit(f"mv {r}, r9")
					self.label(above)
				self.li("r9", hi)
				self.emit(f"{'ble' if t.signed else 'bleu'} {r}, r9, {done}")
				self.emit(f"mv {r}, r9")
				self.label(done)
		else:
			self.norm(r, to)
		return r

	def ex_TypeQuery(self, e):
		raise AssertionError("sizeof is a constant")

	# -- calls

	def ex_Call(self, e):
		ft = e.func.type
		direct = isinstance(e.func, Name) and e.func.sym.kind == "func"
		hidden = by_reference(ft.result)
		base = self.depth
		f = None if direct else self.expr(e.func)
		buf = None
		if hidden:
			buf = self.slot(size_of(ft.result), max(align_of(ft.result), 4))
			self.addi(self.push(), "fp", buf)
		args = []               # (type, alignment of its address); the values are on the stack
		for a, pt in zip(e.args, ft.params):
			decay = getattr(a, "decay", None)
			if decay is not None:
				r, off, al = self.addr(a)
				self.addi(r, r, off)
				args.append((pt, 4))
			elif is_aggr(pt):
				r, off, al = self.aggr(a)
				if by_reference(pt):
					# the callee gets a copy it may change
					cal = max(align_of(pt), 4)
					tmp = self.slot(size_of(pt), cal)
					c = self.push()
					self.addi(c, "fp", tmp)
					self.copy(c, 0, cal, r, off, al, pt, False, getattr(a, "volatile", False))
					self.emit(f"mv {r}, {c}")
					self.pop()
					args.append((pt, 4))
				else:
					self.addi(r, r, off)
					args.append((pt, al if off == 0 else min(al, lowbit(off))))
			else:
				self.expr(a)
				args.append((pt, 4))
		locs, stack = classify(ft.params, hidden)
		self.outgoing = max(self.outgoing, stack)
		# Place the arguments from the last one: each is on top of the stack,
		# so in a register, when its turn comes, however many there are.
		# The stack arguments come last, so r1 and r2 are still free for
		# the struct ones.
		for (pt, al), (where, n, words) in reversed(list(zip(args, locs))):
			r = reg(self.depth - 1)
			small = is_aggr(pt) and not by_reference(pt)
			if where == "stack" and small:
				self.to_regs(1, r, 0, al, pt)
				for w in range(words):
					self.emit(f"sw r{1 + w}, {n + 4 * w}(sp)")
			elif where == "stack":
				self.emit(f"sw {r}, {n}(sp)")
			elif small:
				self.to_regs(n, r, 0, al, pt)
			else:
				self.emit(f"mv r{n}, {r}")
			self.pop()
		if hidden:
			self.emit(f"mv r1, {reg(base + (0 if direct else 1))}")
		if direct:
			self.emit(f"call {e.func.sym.label}")
		else:
			self.emit(f"jalr ra, {f}, 0")
		self.pop(self.depth - base)
		r = self.push()
		t = ft.result
		if t is VOID:
			pass
		elif hidden:
			self.addi(r, "fp", buf)
		elif is_aggr(t):
			tmp = self.slot(8, 4)
			self.mem("sw", "r1", "fp", tmp)
			if size_of(t) > 4:
				self.mem("sw", "r2", "fp", tmp + 4)
			self.addi(r, "fp", tmp)
		else:
			self.emit(f"mv {r}, r1")
			self.norm(r, t)
		return r

	def ex_BuiltinCall(self, e):
		name, args = e.name, e.args
		if name in ("wfi", "hlt", "fence", "breakpoint"):
			self.emit("break" if name == "breakpoint" else name)
			return self.push()
		if name == "mfcr":
			r = self.push()
			self.emit(f"mfcr {r}, {args[0].const}")
			return r
		if name == "mtcr":
			r = self.expr(args[1])
			self.emit(f"mtcr {args[0].const}, {r}")
			return r
		if name == "tlbi":
			r = self.expr(args[0])
			mode = args[1].const if len(args) == 2 else 0
			if mode == 2:
				self.emit("tlbi.all")       # the address is unused
			else:
				self.emit(f"tlbi{'.asid' if mode == 1 else ''} {r}")
			return r
		if name == "syscall":
			regs = [self.expr(a) for a in args]
			for i, r in enumerate(regs[1:]):
				self.emit(f"mv r{i + 1}, {r}")
			self.emit(f"mv r9, {regs[0]}")
			self.emit("syscall")
			self.pop(len(regs))
			r = self.push()
			self.emit(f"mv {r}, r1")
			return r
		# atomics (7.5): an LL/SC loop
		regs = [self.expr(a) for a in args]
		p = regs[0]
		if name == "atomicLoad":
			self.emit(f"lw {p}, 0({p})")
			return p
		if name == "atomicStore":
			self.emit(f"sw {regs[1]}, 0({p})")
			self.pop()
			return p
		old = self.push()
		again, done = self.new_label(), self.new_label()
		self.label(again)
		self.emit(f"ll {old}, ({p})")
		if name == "atomicSwap":
			self.emit(f"sc r9, {regs[1]}, ({p})")
		elif name == "atomicAdd":
			self.emit(f"add r8, {old}, {regs[1]}")
			self.emit(f"sc r9, r8, ({p})")
		else:
			self.emit(f"bne {old}, {regs[1]}, {done}")
			self.emit(f"sc r9, {regs[2]}, ({p})")
		self.emit(f"bnez r9, {again}")
		self.label(done)
		self.emit(f"mv {p}, {old}")
		self.pop(len(regs))
		return p
