"""Types after aliases are resolved, and constant folding."""

import math
import struct


def align_up(n, a):
	return (n + a - 1) // a * a


class Ty:
	"""A type after aliases are resolved. Scalars are singletons, structs
	and enums compare by declaration, the rest by structure."""
	kind = None
	size = 0
	align = 1

	def __ne__(self, other):
		return not self == other

	def __hash__(self):
		return hash(str(self))


class ScalarT(Ty):
	def __init__(self, name, size, kind, signed=False):
		self.name = name
		self.size = self.align = size
		self.kind = kind    # int bool float void, or untyped null error
		self.signed = signed

	def __eq__(self, other):
		return self is other

	def __str__(self):
		return self.name


BYTE = ScalarT("Byte", 1, "int", True)
UBYTE = ScalarT("UByte", 1, "int")
HALF = ScalarT("Half", 2, "int", True)
UHALF = ScalarT("UHalf", 2, "int")
WORD = ScalarT("Word", 4, "int", True)
UWORD = ScalarT("UWord", 4, "int")
BOOL = ScalarT("Bool", 1, "bool")
FLOAT = ScalarT("Float", 4, "float")
VOID = ScalarT("Void", 0, "void")
UNTYPED = ScalarT("integer literal", 0, "untyped")  # exact, until the context gives a type
NULL = ScalarT("null", 4, "null")
ERROR = ScalarT("<error>", 0, "error")              # already reported
SCALARS = {t.name: t for t in (BYTE, UBYTE, HALF, UHALF, WORD, UWORD, BOOL, FLOAT, VOID)}


class VariadicT(Ty):
	"""An opaque, borrowed argument pack: data pointer followed by count.
	Only a trailing named variadic parameter can introduce this type."""
	kind = "varargs"
	size = 8
	align = 4

	def __eq__(self, other):
		return self is other

	def __str__(self):
		return "..."


VARARGS = VariadicT()


class PtrT(Ty):
	kind = "ptr"
	size = align = 4

	def __init__(self, target, mut=False, volatile=False):
		self.target = target
		self.mut = mut
		self.volatile = volatile

	def __eq__(self, other):
		return isinstance(other, PtrT) and self.target == other.target and \
			self.mut == other.mut and self.volatile == other.volatile

	def __str__(self):
		inner = str(self.target)
		if isinstance(self.target, (ArrT, FuncT)):
			inner = f"({inner})"
		return "*" + ("volatile " if self.volatile else "") + ("mut " if self.mut else "") + inner


class ArrT(Ty):
	kind = "array"

	def __init__(self, elem, n):
		self.elem = elem
		self.n = n

	def __eq__(self, other):
		return isinstance(other, ArrT) and self.elem == other.elem and self.n == other.n

	def __str__(self):
		inner = f"({self.elem})" if isinstance(self.elem, FuncT) else str(self.elem)
		return f"{inner}[{self.n}]"


class FuncT(Ty):
	kind = "func"
	size = align = 4

	def __init__(self, params, result):
		self.params = params
		self.result = result

	@property
	def variadic(self):
		return bool(self.params) and self.params[-1] is VARARGS

	@property
	def fixed_params(self):
		return self.params[:-1] if self.variadic else self.params

	def __eq__(self, other):
		return isinstance(other, FuncT) and self.params == other.params and self.result == other.result

	def __str__(self):
		return "(" + ", ".join(map(str, self.params)) + f"): {self.result}"


class FieldInfo:
	def __init__(self, name, type, offset, unaligned):
		self.name = name
		self.type = type
		self.offset = offset
		self.unaligned = unaligned  # in a packed struct, off its natural alignment


class StructT(Ty):
	kind = "struct"

	def __init__(self, name, decl, module):
		self.name = name
		self.decl = decl
		self.module = module
		self.state = None   # busy while its layout is computed, then done
		self.fields = []
		self.packed = decl.packed

	def field(self, name):
		return next((f for f in self.fields if f.name == name), None)

	def __eq__(self, other):
		return self is other

	def __hash__(self):
		return id(self)

	def __str__(self):
		return self.name


class EnumT(Ty):
	kind = "enum"

	def __init__(self, name, decl, module):
		self.name = name
		self.decl = decl
		self.module = module
		self.state = None
		self.base = ERROR
		self.items = {}     # name -> value

	def __eq__(self, other):
		return self is other

	def __hash__(self):
		return id(self)

	def __str__(self):
		return self.name


def is_int(t):
	return t.kind == "int"


def int_range(t):
	bits = t.size * 8
	return (-(1 << bits - 1), (1 << bits - 1) - 1) if t.signed else (0, (1 << bits) - 1)


def fits(v, t):
	lo, hi = int_range(t)
	return lo <= v <= hi


def wrap(v, t):
	"""v modulo 2^n, as the value of integer type t."""
	bits = t.size * 8
	v &= (1 << bits) - 1
	return v - (1 << bits) if t.signed and v >> bits - 1 else v


def f32(x):
	"""x rounded to binary32."""
	try:
		return struct.unpack("<f", struct.pack("<f", x))[0]
	except OverflowError:
		return math.copysign(math.inf, x)


def fold_binary(op, a, b, t):
	"""The value of 'a op b' in type t (integer or Float), as the machine
	computes it (4.7, 4.8). t None: exact, for untyped literals; returns
	None if that has no value (a division by zero)."""
	if t is None:
		if op in ("/", "%") and b == 0:
			return None
		if op in ("+", "+|"):
			return a + b
		if op in ("-", "-|"):
			return a - b
		if op in ("*", "*|"):
			return a * b
		if op == "/":
			q = abs(a) // abs(b)
			return q if (a < 0) == (b < 0) else -q
		if op == "%":
			r = abs(a) % abs(b)
			return -r if a < 0 else r
		if op == "&":
			return a & b
		if op == "|":
			return a | b
		if op == "^":
			return a ^ b
		if op == "<<":
			return a << b
		if op == ">>":
			return a >> b
	if t is FLOAT:
		try:
			if op == "+":
				return f32(a + b)
			if op == "-":
				return f32(a - b)
			if op == "*":
				return f32(a * b)
			if op == "/":
				return f32(a / b)
		except ZeroDivisionError:
			if a == 0 or math.isnan(a):
				return math.nan
			return math.copysign(math.inf, a) * math.copysign(1.0, b)
		except OverflowError:
			return math.copysign(math.inf, a)
	lo, hi = int_range(t)
	if op in ("+|", "-|", "*|"):
		v = a + b if op == "+|" else a - b if op == "-|" else a * b
		return max(lo, min(hi, v))
	if op in ("/", "%"):
		if b == 0:
			return wrap(-1, t) if op == "/" else a
		if t.signed and a == lo and b == -1:
			return lo if op == "/" else 0
		v = fold_binary(op, a, b, None)
		return wrap(v, t)
	if op in ("<<", ">>"):
		x, n = a & 0xFFFFFFFF, b & 31
		if op == "<<":
			return wrap(x << n, t)
		return wrap(a >> n if t.signed else x >> n, t)
	return wrap(fold_binary(op, a, b, None), t)


def fold_compare(op, a, b):
	return int({"==": a == b, "!=": a != b, "<": a < b, "<=": a <= b,
				">": a > b, ">=": a >= b}[op])


def fold_cast(v, src, dst):
	"""A constant converted with 'as' (4.6)."""
	if dst is FLOAT:
		return f32(float(v)) if src is not FLOAT else v
	if src is FLOAT:
		t = dst.base if dst.kind == "enum" else UWORD if dst.kind == "ptr" else dst
		lo, hi = int_range(t)
		if math.isnan(v):
			return hi
		return max(lo, min(hi, int(v)))
	if dst.kind == "enum":
		return wrap(v, dst.base)
	if is_int(dst):
		return wrap(v, dst)
	if dst.kind in ("ptr", "func"):
		return v & 0xFFFFFFFF
	return v


def size_of(t):
	"""The size of a type whose layout is known (after checking)."""
	if t.kind == "enum":
		return t.base.size
	if t.kind == "array":
		return t.n * size_of(t.elem)
	return t.size


def align_of(t):
	if t.kind == "enum":
		return t.base.align
	if t.kind == "array":
		return align_of(t.elem)
	return t.align
