"""Names, types and the rules of the language (m/docs/spec)."""

from .lexer import CMP_OPS
from .syntax import *
from .typesys import *


class Sym:
	"""A named thing: kind 'var', 'func', 'type' or 'import'.

	var: storage is 'global', 'local', 'param' or 'for'; const is the
	value of a global 'let' when it's a scalar constant."""

	def __init__(self, kind, name, decl, module):
		self.kind = kind
		self.name = name
		self.decl = decl
		self.module = module
		self.type = None
		self.state = None           # None, busy, done: for lazy checking
		self.used = False           # referenced from another declaration
		self.exported = False
		self.export_names = []
		self.target = None          # import: the symbol it names
		self.alias = False          # type: 'type X = T'
		# variables
		self.storage = "global"
		self.mut = False
		self.extern = False
		self.const = None
		self.address_taken = False
		self.read = False           # locals, for warnings
		self.written = False        # changed after the declaration
		self.uninit = False         # 'let mut x: T' without '='
		self.warned_unset = False


def show(e):
	"""An expression as source text, for messages."""
	if isinstance(e, Name):
		return e.name
	if isinstance(e, Member):
		return f"{show(e.obj)}.{e.name}"
	if isinstance(e, Index):
		return f"{show(e.obj)}[{show(e.index)}]"
	if isinstance(e, Call):
		return f"{show(e.func)}(...)"
	if isinstance(e, BuiltinCall):
		return f"{e.name}(...)"
	if isinstance(e, Unary):
		return (e.op + " " if e.op == "&mut" else e.op) + show(e.operand)
	if isinstance(e, Binary):
		return f"{show(e.left)} {e.op} {show(e.right)}"
	if isinstance(e, Cast):
		return f"{show(e.expr)} as ..."
	if isinstance(e, (IntLit, CharLit)):
		return str(e.value)
	if isinstance(e, FloatLit):
		return repr(e.value)
	if isinstance(e, StringLit):
		return '"..."'
	if isinstance(e, BoolLit):
		return "true" if e.value else "false"
	if isinstance(e, NullLit):
		return "null"
	return "..."


class Checker:
	"""Name resolution, types and the rules of the language. Annotates
	the tree for the code generator: every expression gets .type and
	.const (its value when known at compile time, else None), names get
	.sym, places get .volatile, declarations get .sym or .var."""

	def __init__(self, modules, diag):
		self.modules = modules
		self.diag = diag
		self.module = None
		self.scopes = []        # local scopes of the current function
		self.func = None        # Sym of the function being checked
		self.current = None     # the declaration being checked, for 'used'
		self.loops = []         # ('loop' | 'switch', node)

	def error(self, loc, msg):
		self.diag.error(loc, msg)

	def warning(self, loc, msg):
		self.diag.warning(loc, msg)

	def run(self):
		for m in self.modules:
			self.declare_module(m)
		for m in self.modules:
			self.resolve_exports(m)
		for m in self.modules:
			self.resolve_imports(m)
		for m in self.modules:
			for d in m.decls:
				self.check_decl(m, d)
		for m in self.modules:
			for d in m.decls:
				if isinstance(d, FuncDecl) and d.body is not None:
					self.check_function(m, d)
		self.check_unused()
		self.check_program()

	def enter(self, module, current, scopes=None):
		"""Switches the context to a declaration; returns the old one."""
		saved = (self.module, self.current, self.scopes, self.func, self.loops)
		self.module, self.current = module, current
		self.scopes = [] if scopes is None else scopes
		if scopes is None:
			self.func, self.loops = None, []
		return saved

	def leave(self, saved):
		self.module, self.current, self.scopes, self.func, self.loops = saved

	# -- modules

	def declare_module(self, m):
		m.scope = {}
		m.exports = {}
		for d in m.decls:
			if isinstance(d, Import):
				for na in d.names:
					sym = Sym("import", na.alias or na.name, na, m)
					na.sym = sym
					self.declare_top(m, sym, na.loc)
				continue
			if isinstance(d, Export):
				continue
			if isinstance(d, StructDecl):
				sym = Sym("type", d.name, d, m)
				sym.type = StructT(d.name, d, m)
			elif isinstance(d, EnumDecl):
				sym = Sym("type", d.name, d, m)
				sym.type = EnumT(d.name, d, m)
			elif isinstance(d, AliasDecl):
				sym = Sym("type", d.name, d, m)
				sym.alias = True
			elif isinstance(d, VarDecl):
				sym = Sym("var", d.name, d, m)
				sym.mut, sym.extern = d.mut, d.extern
			else:
				sym = Sym("func", d.name, d, m)
				sym.extern = d.extern
			d.sym = sym
			self.declare_top(m, sym, d.loc)

	def declare_top(self, m, sym, loc):
		old = m.scope.get(sym.name)
		if old is not None:
			where = old.decl.loc.line
			self.error(loc, f"'{sym.name}' is already declared at line {where}")
			return
		m.scope[sym.name] = sym

	def resolve_exports(self, m):
		for d in m.decls:
			if not isinstance(d, Export):
				continue
			for na in d.names:
				sym = m.scope.get(na.name)
				if sym is None:
					self.error(na.loc, f"'{na.name}' is not declared in this file")
					continue
				if sym.kind == "import":
					self.error(na.loc, f"'{na.name}' is imported, and an imported name can't be exported again")
					continue
				ext = na.alias or na.name
				old = m.exports.get(ext)
				if old is not None and old is not sym:
					self.error(na.loc, f"'{ext}' is already exported as another declaration")
					continue
				m.exports[ext] = sym
				sym.exported = True
				if ext not in sym.export_names:
					sym.export_names.append(ext)
		main = m.scope.get("main")
		if main is not None and main.kind == "func":
			m.exports.setdefault("main", main)
			main.exported = True
			if "main" not in main.export_names:
				main.export_names.append("main")

	def resolve_imports(self, m):
		for d in m.decls:
			if not isinstance(d, Import) or d.module is None:
				continue
			for na in d.names:
				target = d.module.exports.get(na.name)
				if target is None:
					hint = " (it is declared there, but not exported)" if na.name in d.module.scope else ""
					self.error(na.loc, f"'{na.name}' is not exported from '{d.path}'{hint}")
					continue
				na.sym.target = target

	def lookup(self, name, loc, report=True):
		for scope in reversed(self.scopes):
			if name in scope:
				return scope[name]
		sym = self.module.scope.get(name)
		if sym is None:
			if report:
				self.error(loc, f"'{name}' is not declared" + self.enum_hint(name))
			return None
		if sym.kind == "import":
			sym.used = True
			sym = sym.target
			if sym is None:
				return None
		if sym is not self.current:
			sym.used = True
		return sym

	def enum_hint(self, name):
		for sym in self.module.scope.values():
			target = sym.target if sym.kind == "import" else sym
			if target is not None and target.kind == "type" and isinstance(target.type, EnumT):
				self.enum_info(target.type)
				if name in target.type.items:
					return f"; did you mean '{sym.name}.{name}'?"
		return ""

	# -- types

	def resolve_type(self, t, void_ok=False):
		if isinstance(t, TypeName):
			if t.name in SCALARS:
				typ = SCALARS[t.name]
			else:
				sym = self.lookup(t.name, t.loc)
				if sym is None:
					return ERROR
				if sym.kind != "type":
					self.error(t.loc, f"'{t.name}' is not a type")
					return ERROR
				typ = self.type_of(sym)
			if typ is VOID and not void_ok:
				self.error(t.loc, "'Void' is only for the result of a function")
				return ERROR
			return typ
		if isinstance(t, PointerType):
			return PtrT(self.resolve_type(t.target), t.mut, t.volatile)
		if isinstance(t, ArrayType):
			elem = self.resolve_type(t.elem)
			n = self.const_int(t.size, UWORD, "the length of an array")
			if n is None or elem is ERROR:
				return ERROR
			if n < 1:
				self.error(t.size.loc, "an array needs at least one element")
				return ERROR
			return ArrT(elem, n)
		if isinstance(t, SliceType):
			return PtrT(self.resolve_type(t.elem), t.mut, False)
		if isinstance(t, FuncType):
			params = [self.resolve_type(p.type) for p in t.params]
			return FuncT(params, self.resolve_type(t.result, void_ok=True))
		raise AssertionError(t)

	def type_of(self, sym):
		"""The type a type symbol names; aliases are resolved here."""
		if not sym.alias:
			return sym.type
		if sym.state == "done":
			return sym.type
		if sym.state == "busy":
			self.error(sym.decl.loc, f"type '{sym.name}' refers to itself")
			sym.type = ERROR
			return ERROR
		sym.state = "busy"
		saved = self.enter(sym.module, sym)
		typ = self.resolve_type(sym.decl.type, void_ok=True)
		self.leave(saved)
		if sym.state == "busy":
			sym.type = typ
		sym.state = "done"
		return sym.type

	def size_align(self, t):
		if isinstance(t, StructT):
			self.layout(t)
		elif isinstance(t, EnumT):
			self.enum_info(t)
			return t.base.size, t.base.align
		elif isinstance(t, ArrT):
			size, align = self.size_align(t.elem)
			return size * t.n, align
		return t.size, t.align

	def layout(self, st):
		if st.state == "done":
			return
		if st.state == "busy":
			self.error(st.decl.loc, f"'{st.name}' contains itself, so its size would be infinite")
			st.state = "error"
			return
		if st.state == "error":
			return
		st.state = "busy"
		saved = self.enter(st.module, st.decl.sym)
		offset, align, seen = 0, 1, set()
		for f in st.decl.fields:
			ft = self.resolve_type(f.type)
			if f.name in seen:
				self.error(f.loc, f"field '{f.name}' is already in '{st.name}'")
				continue
			seen.add(f.name)
			size, falign = self.size_align(ft)
			if st.state == "error":
				break
			if not st.packed:
				offset = align_up(offset, falign)
				align = max(align, falign)
			st.fields.append(FieldInfo(f.name, ft, offset, st.packed and offset % falign != 0))
			offset += size
		st.size = align_up(offset, align)
		st.align = align
		self.leave(saved)
		if st.state == "busy":
			st.state = "done"

	def enum_info(self, et):
		if et.state is not None:
			return
		et.state = "busy"
		d = et.decl
		saved = self.enter(et.module, d.sym)
		base = self.resolve_type(d.base)
		if base is not ERROR and not is_int(base):
			self.error(d.base.loc, f"the base type of an enum is an integer type, not '{base}'")
			base = ERROR
		et.base = base
		values, value = {}, 0
		for item in d.items:
			if item.value is not None and base is not ERROR:
				v = self.const_int(item.value, base, "the value of an enum member")
				value = value if v is None else v
			if item.name in et.items:
				self.error(item.loc, f"'{item.name}' is already a member of '{et.name}'")
				continue
			if base is not ERROR and item.value is None and not fits(value, base):
				self.error(item.loc, f"'{item.name}' would be {value}, which doesn't fit in '{base}'")
			elif value in values:
				self.error(item.loc, f"'{item.name}' has the same value as '{values[value]}' ({value})")
			values.setdefault(value, item.name)
			et.items[item.name] = value
			value += 1
		self.leave(saved)
		et.state = "done"

	def func_type(self, sym):
		if sym.state is None:
			sym.state = "busy"
			saved = self.enter(sym.module, sym)
			d = sym.decl
			names = set()
			for p in d.params:
				if p.name in names:
					self.error(p.loc, f"parameter '{p.name}' is already declared")
				names.add(p.name)
			sym.type = FuncT([self.resolve_type(p.type) for p in d.params],
							 self.resolve_type(d.result, void_ok=True))
			self.leave(saved)
			sym.state = "done"
		return sym.type

	def global_var(self, sym):
		"""Checks a global variable on first use: its initializer may use
		other globals declared anywhere (3.7)."""
		if sym.state == "done":
			return
		if sym.state == "busy":
			self.error(sym.decl.loc, f"the value of '{sym.name}' depends on itself")
			sym.state = "cycle"
			return
		if sym.state == "cycle":
			return
		sym.state = "busy"
		d = sym.decl
		saved = self.enter(sym.module, sym)
		sym.type = self.resolve_type(d.type)
		if d.init is not None:
			self.check_value(d.init, sym.type)
			if self.check_static(d.init) and not d.mut and d.init.type.kind in \
					("int", "bool", "float", "enum", "ptr") and d.init.const is not None:
				sym.const = d.init.const
		if d.align is not None:
			n = self.const_int(d.align, UWORD, "the alignment")
			natural = self.size_align(sym.type)[1]
			if n is not None and (n <= 0 or n & (n - 1)):
				self.error(d.align.loc, f"the alignment must be a power of two, not {n}")
			elif n is not None and n < natural:
				self.error(d.align.loc, f"the alignment {n} is less than the natural alignment "
										f"of '{sym.type}' ({natural})")
			d.align_value = n
		self.leave(saved)
		if sym.state == "cycle":
			sym.type = sym.type or ERROR
		sym.state = "done"

	# -- declarations

	def check_decl(self, m, d):
		if isinstance(d, StructDecl):
			self.layout(d.sym.type)
		elif isinstance(d, EnumDecl):
			self.enum_info(d.sym.type)
		elif isinstance(d, AliasDecl):
			self.type_of(d.sym)
		elif isinstance(d, VarDecl):
			self.global_var(d.sym)
		elif isinstance(d, FuncDecl):
			self.func_type(d.sym)

	def check_static(self, e):
		"""A global initializer must be known before main: constants,
		strings, addresses of globals and functions (3.3). Reports what
		isn't; returns True if all is."""
		if getattr(e, "type", ERROR) is ERROR or e.const is not None:
			return True
		if isinstance(e, (StringLit, NullLit)):
			return True
		if isinstance(e, Name):
			sym = getattr(e, "sym", None)
			if sym is None or sym.kind == "func":
				return True
			if sym.mut:
				self.error(e.loc, f"'{e.name}' is 'let mut': a global initializer can use only constants")
				return False
			if sym.extern:
				self.error(e.loc, f"the value of 'extern' '{e.name}' isn't known when compiling")
				return False
			return True
		if isinstance(e, Unary) and e.op in ("&", "&mut"):
			return self.static_place(e.operand)
		if isinstance(e, Cast):
			return self.check_static(e.expr)
		if isinstance(e, StructLit):
			return all([self.check_static(f.value) for f in e.fields])
		if isinstance(e, ArrayLit):
			return all([self.check_static(x) for x in e.elems])
		if isinstance(e, (Call, BuiltinCall)):
			self.error(e.loc, "a function call is not a constant expression: nothing runs before 'main'")
			return False
		self.error(e.loc, f"'{show(e)}' is not a constant expression")
		return False

	def static_place(self, e):
		if isinstance(e, Name):
			return True
		if isinstance(e, Member) and e.obj.type.kind == "struct":
			return self.static_place(e.obj)
		if isinstance(e, Index) and e.obj.type.kind == "array" and e.index.const is not None:
			return self.static_place(e.obj)
		self.error(e.loc, f"'&{show(e)}' is not a constant expression: only the address of a global "
						  f"variable, its field or its element with a constant index is")
		return False

	def const_int(self, e, want, what):
		"""The value of a constant integer expression, or None after an
		error."""
		t = self.expr(e, want)
		if t is ERROR:
			return None
		if t is UNTYPED and want is not None:
			if not self.coerce(e, t, want):
				return None
		elif t.kind not in ("int", "enum", "untyped"):
			self.error(e.loc, f"{what} must be an integer, not '{t}'")
			return None
		if e.const is None:
			self.error(e.loc, f"{what} must be a constant")
			return None
		return e.const

	# -- unused names and the whole program

	def check_unused(self):
		for m in self.modules:
			for name, sym in m.scope.items():
				if sym.kind == "import":
					if not sym.used and sym.target is not None:
						self.warning(sym.decl.loc, f"'{name}' is imported but never used")
					continue
				if sym.used or sym.exported:
					continue
				if sym.kind == "func":
					self.warning(sym.decl.loc, f"'{name}' is not exported and never called")
				else:
					self.warning(sym.decl.loc, f"'{name}' is never used")

	def check_program(self):
		mains = [m.scope["main"] for m in self.modules
				 if m.scope.get("main") is not None and m.scope["main"].kind == "func"]
		if not mains:
			self.error(None, "the program has no 'main'")
		for extra in mains[1:]:
			self.error(extra.decl.loc, f"a second 'main'; the first is in '{mains[0].module.path}'")
		if mains:
			main = mains[0]
			argv = PtrT(PtrT(UBYTE))
			ft = main.type
			if main.extern or ft.result != WORD or ft.params not in ([], [UWORD, argv]):
				self.error(main.decl.loc, "'main' must be 'let main(argc: UWord, argv: *UByte[]): Word'")
		symbols = {}
		for m in self.modules:
			for name, sym in m.exports.items():
				if sym.extern or name == "main":    # main is checked above
					continue
				other = symbols.get(name)
				if other is not None and other is not sym:
					self.error(sym.decl.loc, f"'{name}' is exported by both '{other.module.path}' "
											 f"and '{m.path}'; rename one with 'export {{ ... as ... }}'")
				symbols[name] = sym

	# -- functions and statements

	def check_function(self, m, d):
		sym = d.sym
		ft = self.func_type(sym)
		saved = self.enter(m, sym, scopes=[{}])
		self.func, self.loops = sym, []
		d.locals = []
		for p, pt in zip(d.params, ft.params):
			var = Sym("var", p.name, p, m)
			var.storage, var.type = "param", pt
			p.var = var
			if p.name in m.scope:
				self.error(p.loc, f"parameter '{p.name}' has the name of a top-level declaration "
								  f"of this file; there is no shadowing")
			self.scopes[0][p.name] = var
		self.block(d.body)
		if ft.result is not VOID and ft.result is not ERROR and not self.returns(d.body):
			self.error(d.loc, f"'{d.name}' can reach its end without 'return'")
		self.leave(saved)

	def declare_local(self, var, loc):
		name = var.name
		for scope in reversed(self.scopes):
			old = scope.get(name)
			if old is not None:
				if old.storage == "param":
					self.error(loc, f"'{name}' is a parameter; there is no shadowing")
				else:
					self.error(loc, f"'{name}' is already declared at line {old.decl.loc.line}; "
									f"there is no shadowing")
				break
		else:
			if name in self.module.scope:
				self.error(loc, f"'{name}' is a top-level name of this file; there is no shadowing")
		self.scopes[-1][name] = var
		self.func.decl.locals.append(var)

	def push(self):
		self.scopes.append({})

	def pop(self):
		for var in self.scopes.pop().values():
			if var.storage != "local":
				continue
			if not var.read:
				self.warning(var.decl.loc, f"'{var.name}' is never read")
			elif var.mut and not var.written:
				self.warning(var.decl.loc, f"'{var.name}' is never changed, so 'let' is enough")

	def block(self, b, scope=True):
		if scope:
			self.push()
		self.statements(b.stmts)
		if scope:
			self.pop()

	def statements(self, stmts):
		dead = False
		for s in stmts:
			if dead:
				self.warning(s.loc, "unreachable code")
				dead = None
			self.stmt(s)
			if dead is False and self.terminates(s):
				dead = True

	def terminates(self, s):
		"""Nothing after s in the same block can run."""
		if isinstance(s, (Return, Break, Continue)):
			return True
		if isinstance(s, While):
			return s.cond.const == 1 and not s.has_break
		if isinstance(s, If):
			return s.else_ is not None and self.terminates(s.then) and self.terminates(s.else_)
		if isinstance(s, Block):
			return any(self.terminates(x) for x in s.stmts)
		return False

	def returns(self, s):
		"""The function can't go past s (5.10). A block returns if any of
		its statements does: what follows is unreachable."""
		if isinstance(s, Return):
			return True
		if isinstance(s, While):
			return s.cond.const == 1 and not s.has_break
		if isinstance(s, If):
			return s.else_ is not None and self.returns(s.then) and self.returns(s.else_)
		if isinstance(s, Block):
			return any(self.returns(x) for x in s.stmts)
		return False

	def stmt(self, s):
		getattr(self, "st_" + type(s).__name__)(s)

	def st_Block(self, s):
		self.block(s)

	def st_VarDecl(self, s):
		var = Sym("var", s.name, s, self.module)
		var.storage, var.mut = "local", s.mut
		var.type = self.resolve_type(s.type)
		if s.init is not None:
			self.check_value(s.init, var.type)
			self.uses(s.init)
		else:
			var.uninit = True
		s.var = var
		self.declare_local(var, s.loc)

	def st_Assign(self, s):
		tt = self.expr(s.target)
		self.require_mutable(s.target)
		op = s.op[:-1]
		if op == "":
			self.check_value(s.value, tt)
		elif tt is not ERROR:
			if op in ("<<", ">>"):
				self.shift_amount(s.value)
			else:
				self.check_value(s.value, tt)
			self.arith_allowed(op, tt, s.loc)
		self.uses(s.value)
		self.uses(s.target, "write" if op == "" else "update")

	def st_IncDec(self, s):
		tt = self.expr(s.target)
		self.require_mutable(s.target)
		if tt is not ERROR and not is_int(tt):
			self.error(s.loc, f"'{s.op}' works only on integers, not on '{tt}'")
		self.uses(s.target, "update")

	def st_ExprStmt(self, s):
		t = self.expr(s.expr)
		if t is not ERROR and t is not VOID:
			name = s.expr.name if isinstance(s.expr, BuiltinCall) else show(s.expr.func)
			self.warning(s.loc, f"the result of '{name}' is lost")
		self.uses(s.expr)

	def condition(self, e, what):
		t = self.expr(e)
		if t is not ERROR and t is not BOOL:
			hint = ""
			if t.kind in ("int", "untyped"):
				hint = ": compare it, e.g. 'x != 0'"
			elif t.kind in ("ptr", "func"):
				hint = ": compare it with null"
			self.error(e.loc, f"the condition of '{what}' must be Bool, not '{t}'{hint}")
		self.uses(e)

	def st_If(self, s):
		self.condition(s.cond, "if")
		self.body(s.then)
		if s.else_ is not None:
			self.body(s.else_)

	def body(self, s):
		self.push()
		self.stmt(s)
		self.pop()

	def st_While(self, s):
		self.condition(s.cond, "while")
		s.has_break = False
		self.loops.append(("loop", s))
		self.body(s.body)
		self.loops.pop()

	def st_For(self, s):
		t = self.resolve_type(s.type)
		if t is not ERROR and not is_int(t):
			self.error(s.type.loc, f"the variable of 'for' must be an integer, not '{t}'")
			t = ERROR
		self.check_value(s.start, t)
		self.check_value(s.end, t)
		self.uses(s.start)
		self.uses(s.end)
		s.step_value = 1
		if s.step is not None:
			k = self.const_int(s.step, None, "the step of 'for'")
			if k is not None and t is not ERROR:
				if k == 0:
					self.error(s.step.loc, "the step of 'for' can't be 0")
				elif abs(k) > int_range(t)[1] - int_range(t)[0]:
					self.error(s.step.loc, f"the step {k} doesn't fit in '{t}'")
				s.step_value = k
		var = Sym("var", s.name, s, self.module)
		var.storage, var.mut, var.type = "for", s.mut, t
		s.var = var
		self.push()
		self.declare_local(var, s.loc)
		s.has_break = False
		self.loops.append(("loop", s))
		self.body(s.body)
		self.loops.pop()
		self.pop()

	def st_Switch(self, s):
		t = self.expr(s.value)
		if t is UNTYPED:
			self.error(s.value.loc, "the type of the 'switch' value is unknown")
			t = ERROR
		elif t is not ERROR and t.kind not in ("int", "enum"):
			self.error(s.value.loc, f"'switch' works on integers and enums, not on '{t}'")
			t = ERROR
		self.uses(s.value)
		seen, default = {}, None
		for case in s.cases:
			if case.value is None:
				if default is not None:
					self.error(case.loc, f"a second 'default'; the first is at line {default.loc.line}")
				default = case
				continue
			if t is ERROR:
				continue
			self.check_value(case.value, t)
			if case.value.type is ERROR:
				continue
			if case.value.const is None:
				self.error(case.value.loc, "a 'case' label must be a constant")
				continue
			v = case.value.const
			if v in seen:
				self.error(case.value.loc, f"this 'case' value is already used at line {seen[v]}")
			seen[v] = case.loc.line
		self.loops.append(("switch", s))
		for case in s.cases:
			self.push()
			self.statements(case.body)
			self.pop()
		self.loops.pop()

	def st_Break(self, s):
		if not self.loops:
			self.error(s.loc, "'break' outside a loop or 'switch'")
			return
		kind, target = self.loops[-1]
		if kind == "loop":
			target.has_break = True
		s.target = target

	def st_Continue(self, s):
		loops = [n for kind, n in self.loops if kind == "loop"]
		if not loops:
			self.error(s.loc, "'continue' outside a loop")
			return
		s.target = loops[-1]

	def st_Return(self, s):
		if s.value is not None:
			self.check_value(s.value, self.func.type.result)
			self.uses(s.value)

	def st_Asm(self, s):
		pass

	# -- places and mutability

	def is_place(self, e):
		if isinstance(e, Name):
			return getattr(e, "sym", None) is not None and e.sym.kind == "var"
		if isinstance(e, Member):
			if getattr(e, "enum_item", False):
				return False
			return e.obj.type.kind == "ptr" or self.is_place(e.obj)
		if isinstance(e, Index):
			return e.obj.type.kind == "ptr" or self.is_place(e.obj)
		return isinstance(e, Unary) and e.op == "*"

	def mutability(self, e):
		"""Returns None if e can be written, else why not."""
		if isinstance(e, Name):
			sym = e.sym
			if sym.kind != "var":
				return f"'{e.name}' is a function, not a variable" if sym.kind == "func" else \
					f"'{e.name}' can't be changed"
			if sym.mut:
				return None
			if sym.storage == "param":
				return f"'{e.name}' is a parameter, and parameters can't be changed; copy it into a 'let mut'"
			if sym.storage == "for":
				return f"'{e.name}' is the variable of a 'for' without 'mut'"
			return f"'{e.name}' is not 'let mut'"
		if isinstance(e, (Member, Index)) and e.obj.type.kind == "ptr":
			return self.pointer_mutability(e.obj)
		if isinstance(e, (Member, Index)):
			return self.mutability(e.obj)
		if isinstance(e, Unary) and e.op == "*":
			return self.pointer_mutability(e.operand)
		return f"'{show(e)}' is not a variable, a field or an element"

	def pointer_mutability(self, p):
		t = p.type
		if t.mut:
			return None
		return f"'{show(p)}' is '{t}': writing through it needs '{PtrT(t.target, True, t.volatile)}'"

	def require_mutable(self, e):
		if getattr(e, "type", ERROR) is ERROR:
			return
		why = self.mutability(e)
		if why is not None:
			self.error(e.loc, why)

	def root_var(self, e):
		"""The variable whose own memory e is part of, if any."""
		while isinstance(e, (Member, Index)) and e.obj.type.kind != "ptr":
			e = e.obj
		if isinstance(e, Name) and getattr(e, "sym", None) is not None and e.sym.kind == "var":
			return e.sym
		return None

	def uses(self, e, mode="read"):
		"""Marks how locals are used, after e is checked: read, write
		(the whole place is assigned), update (op=, ++), addr (&), addrmut
		(&mut, an array passed as mut T[])."""
		if e is None or getattr(e, "type", None) is None:
			return
		if isinstance(e, Name):
			sym = getattr(e, "sym", None)
			if sym is None or sym.kind != "var" or sym.storage == "global":
				return
			if mode == "read" and sym.uninit and not sym.written and not sym.warned_unset:
				self.warning(e.loc, f"'{e.name}' is read before it is written")
				sym.warned_unset = True
			if mode in ("read", "addr", "addrmut"):
				sym.read = True
			if mode in ("write", "update", "addrmut"):
				sym.written = True
		elif isinstance(e, (Member, Index)):
			if not getattr(e, "enum_item", False):
				self.uses(e.obj, "read" if e.obj.type.kind == "ptr" else mode)
			if isinstance(e, Index):
				self.uses(e.index)
		elif isinstance(e, Unary):
			sub = {"*": "read", "&": "addr", "&mut": "addrmut"}.get(e.op, "read")
			self.uses(e.operand, sub)
		elif isinstance(e, Call):
			self.uses(e.func)
			for a in e.args:
				decay = getattr(a, "decay", None)
				self.uses(a, "read" if decay is None else "addrmut" if decay.mut else "addr")
		elif isinstance(e, BuiltinCall):
			for a in e.args:
				self.uses(a)
		elif isinstance(e, Binary):
			self.uses(e.left)
			self.uses(e.right)
		elif isinstance(e, Cast):
			self.uses(e.expr)
		elif isinstance(e, StructLit):
			for f in e.fields:
				self.uses(f.value)
		elif isinstance(e, ArrayLit):
			for x in e.elems:
				self.uses(x)

	# -- expressions

	def expr(self, e, want=None):
		"""Checks e and returns its type; want is the type the context
		expects, if any (it types literals, it doesn't convert)."""
		e.const = None
		t = getattr(self, "ex_" + type(e).__name__)(e, want)
		e.type = t
		return t

	def check_value(self, e, target, arg=False):
		"""Checks e where a value of type target is needed."""
		t = self.expr(e, target)
		self.coerce(e, t, target, arg)
		return t

	def coerce(self, e, t, target, arg=False):
		"""Can a value of type t go where target is expected, as is or by
		one of the four implicit conversions (2.10)? Reports if not."""
		if t is ERROR or target is ERROR:
			return False
		if t is UNTYPED:
			if is_int(target):
				if not fits(e.const, target):
					self.error(e.loc, f"{e.const} doesn't fit in '{target}'")
					return False
				e.type = target
				return True
			hint = ": convert it with 'as'" if target.kind == "enum" else ""
			self.error(e.loc, f"an integer literal can't be '{target}'{hint}")
			return False
		if t is NULL:
			if target.kind in ("ptr", "func"):
				e.type = target
				e.const = 0
				return True
			self.error(e.loc, f"null is only for pointers and functions, not for '{target}'")
			return False
		if t == target:
			return True
		if t is VOID:
			self.error(e.loc, f"'{show(e)}' has no value: it returns Void")
			return False
		if t.kind == "ptr" and target.kind == "ptr" and t.target == target.target:
			if t.volatile and not target.volatile:
				self.error(e.loc, f"'{t}' can't become '{target}' without 'as': it would drop 'volatile'")
				return False
			if target.mut and not t.mut:
				self.error(e.loc, f"'{t}' can't become '{target}' without 'as': it would allow writing")
				return False
			return True
		if arg and t.kind == "array" and target.kind == "ptr" and t.elem == target.target:
			if target.mut:
				why = self.mutability(e) if self.is_place(e) else \
					f"'{show(e)}' is a temporary value"
				if why is not None:
					self.error(e.loc, f"{why}, so it can't be passed as 'mut {t.elem}[]'")
					return False
			if not self.is_place(e):
				self.error(e.loc, f"'{show(e)}' is a temporary value; only an array variable "
								  f"can be passed as '{t.elem}[]'")
				return False
			e.decay = target
			var = self.root_var(e)
			if var is not None:
				var.address_taken = True
			return True
		hint = ""
		if t.kind in ("int", "float", "bool", "enum") and target.kind in ("int", "float", "enum"):
			hint = "; convert it with 'as'"
		self.error(e.loc, f"expected '{target}', found '{t}'{hint}")
		return False

	def ex_IntLit(self, e, want):
		e.const = e.value
		return UNTYPED

	def ex_CharLit(self, e, want):
		e.const = e.value
		return UBYTE

	def ex_FloatLit(self, e, want):
		e.const = f32(e.value)
		return FLOAT

	def ex_StringLit(self, e, want):
		return PtrT(UBYTE)

	def ex_BoolLit(self, e, want):
		e.const = int(e.value)
		return BOOL

	def ex_NullLit(self, e, want):
		return NULL

	def ex_Name(self, e, want):
		sym = self.lookup(e.name, e.loc)
		e.sym = sym
		if sym is None:
			return ERROR
		if sym.kind == "var":
			if sym.storage == "global":
				self.global_var(sym)
				if sym.const is not None:
					e.const = sym.const
			return sym.type or ERROR
		if sym.kind == "func":
			return self.func_type(sym)
		self.error(e.loc, f"'{e.name}' is a type, not a value")
		return ERROR

	def ex_Member(self, e, want):
		if isinstance(e.obj, Name):
			sym = self.lookup(e.obj.name, e.obj.loc, report=False)
			if sym is not None and sym.kind == "type":
				t = self.type_of(sym)
				e.obj.sym, e.obj.type, e.obj.const = sym, t, None
				if not isinstance(t, EnumT):
					self.error(e.loc, f"'{e.obj.name}' is a type, not a value")
					return ERROR
				self.enum_info(t)
				if e.name not in t.items:
					self.error(e.loc, f"'{t.name}' has no member '{e.name}'")
					return ERROR
				e.enum_item = True
				e.const = t.items[e.name]
				e.volatile = False
				return t
		ot = self.expr(e.obj)
		if ot is ERROR:
			return ERROR
		st, via = ot, None
		if ot.kind == "ptr":
			st, via = ot.target, ot
			if st.kind == "ptr" and st.target.kind == "struct":
				self.error(e.loc, f"'.' goes through one pointer only: '{show(e.obj)}' is '{ot}', "
								  f"write '(*{show(e.obj)}).{e.name}'")
				return ERROR
		if st.kind != "struct":
			self.error(e.loc, f"'{show(e.obj)}' is '{ot}', which has no fields")
			return ERROR
		self.layout(st)
		f = st.field(e.name)
		if f is None:
			self.error(e.loc, f"'{st.name}' has no field '{e.name}'")
			return ERROR
		e.field = f
		e.volatile = via.volatile if via is not None else getattr(e.obj, "volatile", False)
		return f.type

	def ex_Index(self, e, want):
		ot = self.expr(e.obj)
		it = self.expr(e.index, UWORD)
		if it is UNTYPED:
			self.coerce(e.index, it, UWORD)
		elif it is not ERROR and not (is_int(it) and not it.signed):
			hint = ": convert it with 'as'" if is_int(it) else ""
			self.error(e.index.loc, f"an index must be an unsigned integer, not '{it}'{hint}")
		if ot is ERROR:
			return ERROR
		if ot.kind == "array":
			e.volatile = getattr(e.obj, "volatile", False)
			return ot.elem
		if ot.kind == "ptr":
			e.volatile = ot.volatile
			return ot.target
		self.error(e.loc, f"'{show(e.obj)}' is '{ot}': only arrays and pointers can be indexed")
		return ERROR

	def ex_Call(self, e, want):
		ft = self.expr(e.func)
		if ft is ERROR:
			for a in e.args:
				self.expr(a)
			return ERROR
		if ft.kind != "func":
			self.error(e.loc, f"'{show(e.func)}' is '{ft}', not a function")
			return ERROR
		if len(e.args) != len(ft.params):
			self.error(e.loc, f"'{show(e.func)}' takes {len(ft.params)} argument"
							  f"{'' if len(ft.params) == 1 else 's'}, found {len(e.args)}")
		for i, a in enumerate(e.args):
			if i < len(ft.params):
				self.check_value(a, ft.params[i], arg=True)
			else:
				self.expr(a)
		return ft.result

	def ex_Unary(self, e, want):
		op = e.op
		if op in ("&", "&mut"):
			t = self.expr(e.operand)
			if t is ERROR:
				return ERROR
			x = e.operand
			if isinstance(x, Name) and getattr(x, "sym", None) is not None and x.sym.kind == "func":
				self.error(e.loc, f"'{x.name}' is already a pointer to its code: write '{x.name}', "
								  f"not '&{x.name}'")
				return ERROR
			if not self.is_place(x):
				self.error(e.loc, f"'{show(x)}' is a temporary value: it has no address")
				return ERROR
			if isinstance(x, Member) and x.field.unaligned:
				st = x.obj.type.target if x.obj.type.kind == "ptr" else x.obj.type
				self.error(e.loc, f"'{x.name}' is not aligned in packed '{st}': "
								  f"a load through a pointer to it would fault")
				return ERROR
			if op == "&mut":
				self.require_mutable(x)
			var = self.root_var(x)
			if var is not None:
				var.address_taken = True
			return PtrT(t, op == "&mut", getattr(x, "volatile", False))
		if op == "*":
			t = self.expr(e.operand)
			if t is ERROR:
				return ERROR
			if t.kind != "ptr":
				self.error(e.loc, f"'{show(e.operand)}' is '{t}', not a pointer")
				return ERROR
			e.volatile = t.volatile
			return t.target
		t = self.expr(e.operand, want)
		if t is ERROR:
			return ERROR
		if op == "!":
			if t is not BOOL:
				self.error(e.loc, f"'!' needs a Bool, not '{t}'")
				return ERROR
			if e.operand.const is not None:
				e.const = 1 - e.operand.const
			return BOOL
		if op == "-" and t is UNTYPED:
			e.const = -e.operand.const
			return UNTYPED
		if op == "~" and t is UNTYPED:
			e.const = ~e.operand.const
			return UNTYPED
		if not (is_int(t) or (op == "-" and t is FLOAT)):
			self.error(e.loc, f"'{op}' works on {'numbers' if op == '-' else 'integers'}, not on '{t}'")
			return ERROR
		c = e.operand.const
		if c is not None:
			e.const = (f32(-c) if t is FLOAT else wrap(-c, t)) if op == "-" else wrap(~c, t)
		return t

	def ex_Binary(self, e, want):
		op = e.op
		if op in ("&&", "||"):
			for side in (e.left, e.right):
				t = self.expr(side)
				if t is not ERROR and t is not BOOL:
					self.error(side.loc, f"'{op}' needs Bool operands, not '{t}'")
			if e.left.const is not None and e.right.const is not None:
				a, b = e.left.const, e.right.const
				e.const = int(a and b) if op == "&&" else int(a or b)
			return BOOL
		if op in CMP_OPS:
			return self.compare(e)
		if op in ("<<", ">>"):
			return self.shift(e, want)
		lt = self.expr(e.left, want)
		rt = self.expr(e.right, want if lt is UNTYPED else lt)
		t = self.unify(e, lt, rt)
		if t is ERROR:
			return ERROR
		if t is UNTYPED:
			v = fold_binary(op, e.left.const, e.right.const, None)
			if v is None:
				self.error(e.loc, "division by zero in a constant expression")
				return ERROR
			e.const = v
			return UNTYPED
		if not self.arith_allowed(op, t, e.loc):
			return ERROR
		if e.left.const is not None and e.right.const is not None:
			e.const = fold_binary(op, e.left.const, e.right.const, t)
		return t

	def arith_allowed(self, op, t, loc):
		if is_int(t):
			return True
		if t is FLOAT and op in ("+", "-", "*", "/"):
			return True
		if t is FLOAT:
			self.error(loc, f"'{op}' is not defined for Float")
		elif t.kind == "enum":
			self.error(loc, f"'{op}' is not defined for enums: convert to the base type with 'as'")
		else:
			self.error(loc, f"'{op}' works on numbers, not on '{t}'")
		return False

	def unify(self, e, lt, rt):
		"""The common type of two operands: a literal takes the type of
		the other side."""
		if lt is ERROR or rt is ERROR:
			return ERROR
		for t, side in ((lt, e.left), (rt, e.right)):
			if t is VOID:
				self.error(side.loc, f"'{show(side)}' has no value: it returns Void")
				return ERROR
		if lt is UNTYPED and rt is UNTYPED:
			return UNTYPED
		if lt is UNTYPED:
			return rt if self.coerce(e.left, lt, rt) else ERROR
		if rt is UNTYPED:
			return lt if self.coerce(e.right, rt, lt) else ERROR
		if lt is NULL and rt is NULL:
			self.error(e.loc, "two nulls: compare a pointer with null")
			return ERROR
		if lt is NULL:
			return rt if self.coerce(e.left, lt, rt) else ERROR
		if rt is NULL:
			return lt if self.coerce(e.right, rt, lt) else ERROR
		if lt == rt:
			return lt
		if lt.kind == "ptr" and rt.kind == "ptr" and lt.target == rt.target:
			return lt
		self.error(e.loc, f"'{e.op}' needs both operands of one type, found '{lt}' and '{rt}'; "
						  f"convert one with 'as'")
		return ERROR

	def compare(self, e):
		op = e.op
		lt = self.expr(e.left)
		rt = self.expr(e.right, lt if lt.kind not in ("untyped", "null", "error") else None)
		t = self.unify(e, lt, rt)
		if t is ERROR:
			return ERROR
		if t is UNTYPED:
			e.const = fold_compare(op, e.left.const, e.right.const)
			return BOOL
		if t.kind in ("struct", "array"):
			self.error(e.loc, f"'{t}' values can't be compared with '{op}'")
			return ERROR
		if op not in ("==", "!=") and t.kind not in ("int", "float", "enum"):
			if t.kind == "ptr":
				self.error(e.loc, f"pointers can't be ordered with '{op}': compare them 'as UWord'")
			else:
				self.error(e.loc, f"'{op}' doesn't work on '{t}'")
			return ERROR
		if e.left.const is not None and e.right.const is not None:
			e.const = fold_compare(op, e.left.const, e.right.const)
		return BOOL

	def shift_amount(self, e):
		t = self.expr(e, UWORD)
		if t is UNTYPED:
			if e.const < 0:
				self.error(e.loc, "a negative shift amount")
				return ERROR
			if not self.coerce(e, t, UWORD):
				return ERROR
			return UWORD
		if t is not ERROR and not (is_int(t) and not t.signed):
			self.error(e.loc, f"the shift amount must be an unsigned integer, not '{t}'")
			return ERROR
		return t

	def shift(self, e, want):
		lt = self.expr(e.left, want)
		rt = self.expr(e.right, UWORD)
		if lt is UNTYPED and rt is UNTYPED:
			if e.right.const < 0:
				self.error(e.right.loc, "a negative shift amount")
				return ERROR
			e.const = fold_binary(e.op, e.left.const, e.right.const, None)
			return UNTYPED
		if rt is UNTYPED:
			if e.right.const < 0:
				self.error(e.right.loc, "a negative shift amount")
				return ERROR
			self.coerce(e.right, rt, UWORD)
			rt = UWORD
		elif rt is not ERROR and not (is_int(rt) and not rt.signed):
			self.error(e.right.loc, f"the shift amount must be an unsigned integer, not '{rt}'")
			return ERROR
		if lt is UNTYPED:
			if want is None or not is_int(want):
				self.error(e.left.loc, "the type of this literal is unknown: nothing around it gives one; "
									   "write e.g. '(1 as UWord) << n'")
				return ERROR
			if not self.coerce(e.left, lt, want):
				return ERROR
			lt = want
		if lt is ERROR or rt is ERROR:
			return ERROR
		if not is_int(lt):
			self.error(e.loc, f"'{e.op}' works on integers, not on '{lt}'")
			return ERROR
		if e.left.const is not None and e.right.const is not None:
			e.const = fold_binary(e.op, e.left.const, e.right.const, lt)
		return lt

	def ex_Cast(self, e, want):
		to = self.resolve_type(e.type)
		base = to.base if to.kind == "enum" else UWORD if to.kind == "ptr" else to if is_int(to) else None
		src = self.expr(e.expr, base)
		if to is ERROR or src is ERROR:
			return ERROR
		x = e.expr
		if src is UNTYPED:
			if to is FLOAT:
				base = WORD if fits(x.const, WORD) else UWORD
			if base is None:
				self.error(e.loc, f"an integer literal can't be converted to '{to}'" +
						   (": compare it, e.g. 'x != 0'" if to is BOOL else ""))
				return ERROR
			if not self.coerce(x, src, base):
				return ERROR
			src = base
		if src is NULL:
			if to.kind in ("ptr", "func"):
				x.type, x.const = to, 0
				e.const = 0
				return to
			self.error(e.loc, f"null can't be converted to '{to}'")
			return ERROR
		if not self.cast_allowed(src, to):
			hint = ": compare it, e.g. 'x != 0'" if to is BOOL and is_int(src) else ""
			self.error(e.loc, f"'{src}' can't be converted to '{to}'{hint}")
			return ERROR
		if x.const is not None and to.kind in ("int", "enum", "float", "ptr", "bool"):
			e.const = fold_cast(x.const, src, to) if src != to else x.const
		return to

	def cast_allowed(self, src, to):
		if src == to:
			return True
		sk, tk = src.kind, to.kind
		if sk == "int" and tk in ("int", "float", "enum"):
			return True
		if sk == "float" and tk == "int":
			return True
		if sk == "bool" and tk == "int":
			return True
		if sk == "enum" and tk == "int":
			return True
		if sk == "ptr" and (tk == "ptr" or to in (UWORD, WORD)):
			return True
		if sk == "int" and tk == "ptr":
			return src in (UWORD, WORD)
		if sk == "func" and to is UWORD:
			return True
		return False

	def ex_StructLit(self, e, want):
		if want is ERROR:
			return ERROR
		if want is None or want.kind != "struct":
			what = "its context gives none" if want is None else f"'{want}' is expected"
			self.error(e.loc, f"a struct literal needs a struct type, and {what}")
			return ERROR
		self.layout(want)
		seen = set()
		for fi in e.fields:
			f = want.field(fi.name)
			if f is None:
				self.error(fi.loc, f"'{want.name}' has no field '{fi.name}'")
				self.expr(fi.value)
				continue
			if fi.name in seen:
				self.error(fi.loc, f"field '{fi.name}' is given twice")
			seen.add(fi.name)
			fi.field = f
			self.check_value(fi.value, f.type)
		return want

	def ex_ArrayLit(self, e, want):
		if want is ERROR:
			return ERROR
		if want is None or want.kind != "array":
			what = "its context gives none" if want is None else f"'{want}' is expected"
			self.error(e.loc, f"an array literal needs an array type, and {what}")
			return ERROR
		if len(e.elems) > want.n:
			self.error(e.loc, f"{len(e.elems)} elements don't fit in '{want}'")
		for x in e.elems:
			self.check_value(x, want.elem)
		return want

	def ex_TypeQuery(self, e, want):
		t = self.resolve_type(e.type)
		if t is ERROR:
			return ERROR
		size, align = self.size_align(t)
		if e.op == "sizeof":
			e.const = size
		elif e.op == "alignof":
			e.const = align
		else:
			if t.kind != "struct":
				self.error(e.loc, f"'offsetof' needs a struct, not '{t}'")
				return ERROR
			f = t.field(e.field)
			if f is None:
				self.error(e.loc, f"'{t.name}' has no field '{e.field}'")
				return ERROR
			e.const = f.offset
		return UWORD

	def ex_BuiltinCall(self, e, want):
		name, args = e.name, e.args

		def count(n, most=None):
			most = n if most is None else most
			if not n <= len(args) <= most:
				want_n = f"{n}" if n == most else f"{n} to {most}"
				self.error(e.loc, f"'{name}' takes {want_n} argument{'' if most == 1 else 's'}, "
								  f"found {len(args)}")
				for a in args:
					self.expr(a)
				return False
			return True

		if name in ("wfi", "hlt", "fence", "breakpoint"):
			count(0)
			return VOID
		if name == "mfcr" or name == "mtcr":
			if not count(1 if name == "mfcr" else 2):
				return ERROR
			n = self.const_int(args[0], UWORD, f"the register number of '{name}'")
			if n is not None and not 0 <= n <= 15:
				self.error(args[0].loc, f"there is no control register {n} (0 to 15)")
			if name == "mfcr":
				return UWORD
			self.check_value(args[1], UWORD)
			return VOID
		if name == "tlbi":
			if count(1, 2):
				self.check_value(args[0], UWORD)
				if len(args) == 2:
					mode = self.const_int(args[1], UWORD, "the mode of 'tlbi'")
					if mode is not None and not 0 <= mode <= 2:
						self.error(args[1].loc, f"there is no TLBI mode {mode} (0 to 2)")
			return VOID
		if name == "syscall":
			if not count(1, 7):
				return WORD
			for a in args:
				t = self.expr(a, UWORD)
				if t is UNTYPED:
					self.coerce(a, t, UWORD)
				elif t is not ERROR and t not in (WORD, UWORD) and t.kind != "ptr":
					self.error(a.loc, f"a 'syscall' argument must be Word, UWord or a pointer, not '{t}'")
			return WORD
		# atomics
		n = {"atomicLoad": 1, "atomicStore": 2, "atomicSwap": 2, "atomicAdd": 2,
			 "atomicCompareSwap": 3}[name]
		if not count(n):
			return ERROR
		pt = self.expr(args[0])
		if pt is ERROR:
			for a in args[1:]:
				self.expr(a)
			return ERROR
		if pt.kind != "ptr":
			self.error(args[0].loc, f"'{name}' needs a pointer, not '{pt}'")
			return ERROR
		t = pt.target
		allowed = (WORD, UWORD) if name == "atomicAdd" else None
		if (allowed and t not in allowed) or (not allowed and t not in (WORD, UWORD) and t.kind != "ptr"):
			what = "Word and UWord" if allowed else "Word, UWord and pointers"
			self.error(args[0].loc, f"'{name}' works only on {what}, not on '{t}'")
			return ERROR
		if name != "atomicLoad" and not pt.mut:
			self.error(args[0].loc, f"'{name}' writes through '{show(args[0])}', so it needs "
									f"'{PtrT(t, True, pt.volatile)}', not '{pt}'")
		for a in args[1:]:
			self.check_value(a, t)
		return VOID if name == "atomicStore" else t
