"""The parser (m/docs/spec/09-grammar.md)."""

from .diag import CompileError
from .lexer import ASSIGN_OPS, BUILTIN_FUNCS, BUILTIN_TYPES, CMP_OPS, CONTINUES_EXPR
from .syntax import *


class ParseError(CompileError):
	def __init__(self, tok, msg):
		super().__init__(tok.loc, msg)
		self.tok = tok


class Parser:
	"""Builds the syntax tree of one file (m/docs/spec/09-grammar.md).
	A syntax error stops the file; errors that leave the tree whole (a
	reserved name, a misplaced declaration) are reported and parsing goes
	on."""

	def __init__(self, path, src, tokens, diag):
		self.path = path
		self.src = src
		self.tokens = tokens
		self.diag = diag
		self.i = 0
		self.last = tokens[0]       # the last token taken
		self.no_struct = False      # '{' starts a body, not a struct literal
		self.void_result = False    # 'return' takes no expression
		self.func_name = None       # for messages: "'f'" or "the function literal"
		self.docs_used = set()
		# the leading white space of every line, for the indentation warning
		self.indents = [l[:len(l) - len(l.lstrip(" \t"))] for l in src.split("\n")]

	# -- tokens

	@property
	def tok(self):
		return self.tokens[self.i]

	def peek(self, n=1):
		return self.tokens[min(self.i + n, len(self.tokens) - 1)]

	def next(self):
		tok = self.tokens[self.i]
		if tok.kind != "eof":
			self.i += 1
		self.last = tok
		return tok

	def at(self, *texts):
		return any(self.tok.is_(t) for t in texts)

	def accept(self, text):
		if self.at(text):
			return self.next()
		return None

	def expect(self, text, what=None):
		if not self.at(text):
			self.unexpected(what or f"'{text}'")
		return self.next()

	def unexpected(self, expected):
		tok = self.tok
		if tok.kind == "op" and (tok.value in ASSIGN_OPS or tok.value in ("++", "--")):
			raise ParseError(tok, f"'{tok.value}' is a statement and has no value; "
								  f"it can't be part of an expression")
		raise ParseError(tok, f"expected {expected}, found {tok}")

	def error(self, loc, msg):
		self.diag.error(loc, msg)

	def text(self, first, last):
		"""Source text from token first to token last, on one line."""
		return " ".join(self.src[first.pos:last.end].split())

	def name(self, what="a name"):
		"""An identifier being declared."""
		tok = self.tok
		if tok.kind == "kw":
			raise ParseError(tok, f"'{tok.value}' is a keyword and can't be a name")
		if tok.kind != "id":
			self.unexpected(what)
		self.next()
		if tok.value in BUILTIN_TYPES or tok.value in BUILTIN_FUNCS:
			self.error(tok.loc, f"'{tok.value}' is a reserved name")
		return tok.value

	def use_doc(self, tok):
		if tok.doc:
			self.docs_used.add(id(tok))

	def check_docs(self):
		for tok in self.tokens:
			if tok.doc and id(tok) not in self.docs_used:
				self.diag.warning(tok.doc, "a '///' comment must go right before a declaration")

	def with_struct(self, fn, *args):
		"""Parses inside brackets, where '{' is a struct literal again."""
		saved, self.no_struct = self.no_struct, False
		try:
			return fn(*args)
		finally:
			self.no_struct = saved

	def without_struct(self, fn, *args):
		saved, self.no_struct = self.no_struct, True
		try:
			return fn(*args)
		finally:
			self.no_struct = saved

	def comma_list(self, item, close):
		"""item { ',' item } [ ',' ] close, or just close."""
		items = []
		while not self.at(close):
			items.append(item())
			if not self.accept(","):
				break
		self.expect(close, f"',' or '{close}'")
		return items

	# -- file

	def parse_file(self):
		decls = []
		while self.tok.kind != "eof":
			decls.append(self.top_decl())
		self.check_docs()
		return decls

	def top_decl(self):
		tok = self.tok
		if tok.is_("import"):
			return self.import_decl()
		if tok.is_("export"):
			loc = self.next().loc
			self.expect("{")
			names = self.comma_list(self.name_as, "}")
			if not names:
				self.error(loc, "'export' needs at least one name")
			return Export(loc, names)
		self.use_doc(tok)
		if tok.is_("packed"):
			self.next()
			if not self.at("type"):
				self.unexpected("'type'")
			decl = self.type_decl()
			if isinstance(decl, AliasDecl):
				self.error(tok.loc, "'packed' is only for structs, not for aliases")
			else:
				decl.packed = True
				decl.loc = tok.loc
			return decl
		if tok.is_("type"):
			return self.type_decl()
		if tok.is_("enum"):
			return self.enum_decl()
		if tok.is_("align"):
			self.next()
			self.expect("(")
			align = self.with_struct(self.expr)
			self.expect(")")
			if not self.at("let"):
				self.unexpected("'let': 'align' is only for global variables")
			decl = self.let_decl(top=True)
			if isinstance(decl, FuncDecl) or getattr(decl, "func_form", False):
				self.error(tok.loc, "'align' is only for global variables, not for functions")
			else:
				decl.align = align
				decl.loc = tok.loc
			return decl
		if tok.is_("let"):
			return self.let_decl(top=True)
		if tok.is_("extern"):
			return self.extern_decl()
		self.unexpected("a declaration")

	def import_decl(self):
		loc = self.next().loc
		self.expect("{")
		names = self.comma_list(self.name_as, "}")
		if not names:
			self.error(loc, "'import' needs at least one name")
		self.expect("from")
		if self.tok.kind != "str":
			self.unexpected("a file name in quotes")
		path = self.string_text()
		return Import(loc, names, path)

	def string_text(self):
		"""Decode strings used as source text rather than runtime bytes."""
		tok = self.next()
		try:
			return tok.value.decode("utf-8")
		except UnicodeDecodeError:
			raise ParseError(tok, "this string must contain valid UTF-8 text")

	def name_as(self):
		loc = self.tok.loc
		name = self.name()
		alias = self.name() if self.accept("as") else None
		return NameAs(loc, name, alias)

	def type_decl(self):
		loc = self.expect("type").loc
		name = self.name("a type name")
		if self.accept("="):
			return AliasDecl(loc, name, self.type())
		if not self.at("{"):
			self.unexpected("'{' or '='")
		self.next()
		fields = self.comma_list(self.field, "}")
		if not fields:
			self.error(loc, f"struct '{name}' has no fields")
		return StructDecl(loc, name, fields, False)

	def field(self):
		tok = self.tok
		self.use_doc(tok)
		name = self.name("a field name")
		self.expect(":")
		return Field(tok.loc, name, self.type())

	def enum_decl(self):
		loc = self.expect("enum").loc
		name = self.name("an enum name")
		self.expect(":")
		base = self.type()
		self.expect("{")
		items = self.comma_list(self.enum_item, "}")
		if not items:
			self.error(loc, f"enum '{name}' has no members")
		return EnumDecl(loc, name, base, items)

	def enum_item(self):
		tok = self.tok
		self.use_doc(tok)
		name = self.name("an enum member")
		value = self.expr() if self.accept("=") else None
		return EnumItem(tok.loc, name, value)

	def let_decl(self, top):
		"""'let' at the top level or in a function: a variable or a
		function (3.8 for one in a function and for 'let mut f()')."""
		let = self.tok
		loc = self.expect("let").loc
		mut = bool(self.accept("mut"))
		name = self.name()
		if self.at("("):
			if not top:
				self.use_doc(let)
			if mut:
				return self.mut_func(loc, name)
			return self.func_rest(loc, name)
		if self.at("="):
			raise ParseError(self.tok, f"the type of '{name}' must be written: 'let {name}: T = ...'")
		self.expect(":", "':' and a type")
		typ = self.type()
		init = None
		if self.accept("="):
			init = self.expr()
		elif not mut:
			self.error(loc, f"'{name}' never gets a value: 'let' needs '=', or 'let mut'")
		return VarDecl(loc, name, mut, typ, init, None, False)

	def params(self):
		self.expect("(")
		return self.comma_list(self.param, ")")

	def param(self):
		loc = self.tok.loc
		name = self.name("a parameter name")
		self.expect(":")
		return Param(loc, name, self.param_type())

	def param_type(self):
		if self.at("..."):
			return VariadicType(self.next().loc)
		mut = self.accept("mut")
		typ = self.type(slice_ok=True)
		if mut:
			if not isinstance(typ, SliceType):
				self.error(mut.loc, "'mut' before a type goes only in 'mut T[]'")
			else:
				typ.mut = True
		return typ

	def result_type(self, name):
		if not self.at(":"):
			raise ParseError(self.tok, f"the result type of '{name}' must be written, "
									   f"': Void' if there is none")
		self.next()
		return self.type()

	def func_rest(self, loc, name):
		params = self.params()
		result = self.result_type(name)
		body = self.func_body(f"'{name}'", result)
		return FuncDecl(loc, name, params, result, body, False)

	def mut_func(self, loc, name):
		"""'let mut f(...): R { ... }' is 'let mut f: (...): R' that starts
		as a function literal with that body (3.8)."""
		params = self.params()
		result = self.result_type(name)
		body = self.func_body(f"'{name}'", result)
		lit = FuncLit(loc, params, result, body)
		lit.label_name = name
		decl = VarDecl(loc, name, True, FuncType(loc, params, result), lit, None, False)
		decl.func_form = True
		return decl

	def func_body(self, what, result):
		"""The body of a function or a function literal, which may be
		inside another function."""
		saved = self.void_result, self.func_name
		self.void_result = isinstance(result, TypeName) and result.name == "Void"
		self.func_name = what
		try:
			return self.block()
		finally:
			self.void_result, self.func_name = saved

	def extern_decl(self):
		loc = self.expect("extern").loc
		self.expect("let")
		mut = bool(self.accept("mut"))
		name_tok = self.tok
		name = self.name()
		if self.at("("):
			if mut:
				raise ParseError(name_tok, f"there is no 'extern let mut {name}(...)'; an external variable "
										   f"of a function type is 'extern let mut {name}: (...): R'")
			params = self.params()
			result = self.result_type(name)
			if self.at("{"):
				raise ParseError(self.tok, "an 'extern' function has no body")
			return FuncDecl(loc, name, params, result, None, True)
		self.expect(":", "':' and a type")
		typ = self.type()
		if self.at("="):
			raise ParseError(self.tok, "an 'extern' variable has no initializer")
		return VarDecl(loc, name, mut, typ, None, None, True)

	# -- types

	def type(self, slice_ok=False):
		typ = self.prefix_type()
		while self.at("["):
			loc = self.next().loc
			if self.accept("]"):
				if not slice_ok:
					self.error(loc, "'T[]' is only for parameter types; elsewhere write '*T' or 'T[N]'")
				return SliceType(loc, typ, False)
			size = self.with_struct(self.expr)
			self.expect("]")
			typ = ArrayType(loc, typ, size)
		return typ

	def prefix_type(self):
		tok = self.tok
		if tok.is_("*"):
			self.next()
			volatile = bool(self.accept("volatile"))
			mut = bool(self.accept("mut"))
			return PointerType(tok.loc, self.prefix_type(), mut, volatile)
		if tok.is_("("):
			after = self.peek()
			if after.is_(")") or (after.kind == "id" and self.peek(2).is_(":")):
				params = self.params()
				self.expect(":", "':' and the result type")
				return FuncType(tok.loc, params, self.type())
			self.next()
			typ = self.type()
			self.expect(")")
			return typ
		if tok.kind == "id":
			self.next()
			return TypeName(tok.loc, tok.value)
		self.unexpected("a type")

	# -- statements

	def block(self):
		loc = self.expect("{").loc
		saved, self.no_struct = self.no_struct, False
		stmts = []
		while not self.at("}"):
			if self.tok.kind == "eof":
				self.unexpected("'}'")
			stmts.append(self.statement("block"))
		self.next()
		self.no_struct = saved
		return Block(loc, stmts)

	def statement(self, where):
		"""where: 'block', 'body' (of if/while/for without braces) or
		'case' (right inside a case)."""
		tok = self.tok
		if tok.is_("let"):
			if where == "body":
				self.error(tok.loc, "a declaration can't be the body of a statement without braces: "
									"its name would be visible nowhere")
			elif where == "case":
				self.error(tok.loc, "'let' can't go right inside a 'case'; put the case in a block: "
									"'case X: { ... }'")
			return self.let_decl(top=False)
		if tok.is_("align"):
			raise ParseError(tok, "'align' is only for global variables")
		if tok.is_("{"):
			return self.block()
		if tok.is_("if"):
			return self.if_stmt()
		if tok.is_("while"):
			kw = self.next()
			cond, paren = self.condition()
			return While(kw.loc, cond, self.body(kw, cond, paren))
		if tok.is_("for"):
			return self.for_stmt()
		if tok.is_("switch"):
			return self.switch_stmt()
		if tok.is_("break"):
			return Break(self.next().loc)
		if tok.is_("continue"):
			return Continue(self.next().loc)
		if tok.is_("return"):
			self.next()
			return Return(tok.loc, None if self.void_result else self.expr())
		if tok.is_("asm"):
			return self.asm_stmt()
		return self.simple_stmt()

	def simple_stmt(self):
		start = self.tok
		if start.is_("*"):
			self.next()
			target = Unary(start.loc, "*", self.unary())
		elif start.kind == "op" and start.value in ("-", "!", "~", "&"):
			self.unary()
			raise ParseError(start, f"'{self.text(start, self.last)}' is not a statement: only a call, "
									f"an assignment or '++'/'--' can be")
		elif start.is_("++") or start.is_("--"):
			self.unexpected("a statement")
		elif start.kind == "op" and start.value in ASSIGN_OPS:
			raise ParseError(start, f"a statement can't start with '{start.value}': "
									f"an assignment has no value")
		else:
			target = self.postfix()
		tok = self.tok
		if tok.kind == "op" and tok.value in ASSIGN_OPS:
			self.next()
			return Assign(tok.loc, tok.value, target, self.expr())
		if tok.is_("++") or tok.is_("--"):
			self.next()
			return IncDec(tok.loc, tok.value, target)
		if tok.kind == "op" and tok.value in ("+|", "-|", "*|") and self.peek().is_("="):
			raise ParseError(tok, f"there is no '{tok.value}='; write 'x = x {tok.value} y'")
		if isinstance(target, (Call, BuiltinCall, VaArg)):
			return ExprStmt(start.loc, target)
		before = self.tokens[self.tokens.index(start) - 1]
		if before.is_("return") and self.void_result:
			raise ParseError(start, f"{self.func_name} returns Void, so its 'return' takes no value")
		end = self.last
		if tok.kind == "op" and tok.value not in ("{", "}", ")", "]", ",", ":"):
			try:
				self.i = self.tokens.index(start)
				self.expr()
				end = self.last
			except ParseError:
				pass
		raise ParseError(start, f"'{self.text(start, end)}' is not a statement: only a call, "
								f"an assignment or '++'/'--' can be")

	def condition(self):
		"""The condition of if/while, the value of switch, the end and the
		step of a for range (5.5): exactly the parentheses if it starts
		with '(', else the longest expression. Returns (expr, the '('
		token or None)."""
		self.cond_first = self.tok
		if self.at("("):
			open_ = self.next()
			cond = self.with_struct(self.expr)
			self.expect(")")
			return cond, open_
		return self.without_struct(self.expr), None

	def body(self, kw, cond, paren):
		"""The body of if/else/while/for: a block or one statement."""
		first = self.tok
		if first.is_("{"):
			return self.block()
		if first.loc.line != self.last.loc.line and \
				self.indents[first.loc.line - 1] == self.indents[kw.loc.line - 1]:
			self.diag.warning(first.loc, f"the body of '{kw.value}' is on its own line with the same "
										 f"indentation as the '{kw.value}'; indent it or use braces")
		if first.kind == "op" and (first.value in ASSIGN_OPS or first.value in ("++", "--")) \
				and paren is None and cond is not None:
			raise ParseError(first, f"the '{kw.value}' condition is "
									f"'{self.text(self.cond_first, self.last)}', and a statement "
									f"can't start with '{first.value}'")
		try:
			return self.statement("body")
		except ParseError as e:
			if paren is not None and first.kind in ("op", "kw") and first.value in CONTINUES_EXPR:
				self.paren_condition_error(kw, paren, first, e)
			raise

	def paren_condition_error(self, kw, paren, first, original):
		"""The condition ended at ')', but the expression goes on (8.3)."""
		saved = self.i
		self.i = self.tokens.index(paren)
		try:
			self.without_struct(self.expr)
		except ParseError:
			self.i = saved
			return
		end = self.last
		self.i = saved
		if end.pos <= first.pos or original.tok.pos > end.pos:
			return
		close = self.tokens[self.tokens.index(first) - 1]
		raise ParseError(paren, (
			f"the '{kw.value}' condition is '{self.text(paren, close)}', and "
			f"'{self.text(first, end)} ...' is not a statement\n"
			f"    if the whole expression is the condition, put it in parentheses:\n"
			f"        {kw.value} ({self.text(paren, end)}) ..."))

	def if_stmt(self):
		kw = self.next()
		cond, paren = self.condition()
		then = self.body(kw, cond, paren)
		else_ = None
		if self.at("else"):
			else_kw = self.next()
			else_ = self.body(else_kw, None, None)
		return If(kw.loc, cond, then, else_)

	def for_stmt(self):
		kw = self.next()
		mut = bool(self.accept("mut"))
		name = self.name("the loop variable")
		self.expect(":", "':' and the type of the loop variable")
		typ = self.type()
		self.expect("in")
		start = self.without_struct(self.expr)
		if not self.at("..", "..."):
			self.unexpected("'..' or '...'")
		inclusive = self.next().value == "..."
		end, paren = self.condition()
		step = None
		if self.accept("by"):
			step, paren = self.condition()
		body = self.body(kw, end, paren)
		return For(kw.loc, name, mut, typ, start, end, inclusive, step, body)

	def switch_stmt(self):
		kw = self.next()
		value, _ = self.condition()
		self.expect("{")
		cases = []
		while not self.at("}"):
			tok = self.tok
			if tok.is_("case"):
				self.next()
				label = self.with_struct(self.expr)
			elif tok.is_("default"):
				self.next()
				label = None
			else:
				self.unexpected("'case', 'default' or '}'")
			self.expect(":")
			stmts = []
			while not self.at("case", "default", "}"):
				if self.tok.kind == "eof":
					self.unexpected("'}'")
				stmts.append(self.statement("case"))
			cases.append(Case(tok.loc, label, stmts))
		self.next()
		return Switch(kw.loc, value, cases)

	def asm_stmt(self):
		kw = self.next()
		self.expect("{")
		lines = []
		while self.tok.kind == "str":
			lines.append(self.string_text())
		if not lines:
			self.unexpected("a line of assembly in quotes")
		self.expect("}", "another line in quotes or '}'")
		return Asm(kw.loc, lines)

	# -- expressions

	def expr(self):
		return self.binary(0)

	# loosest first; comparisons are handled apart: they don't chain
	LEVELS = [("||",), ("&&",), None, ("|",), ("^",), ("&",), ("<<", ">>"),
			  ("+", "-", "+|", "-|"), ("*", "/", "%", "*|")]

	def binary(self, level):
		if level == len(self.LEVELS):
			return self.cast()
		ops = self.LEVELS[level]
		if ops is None:
			left = self.binary(level + 1)
			if self.tok.kind == "op" and self.tok.value in CMP_OPS:
				op = self.next()
				left = Binary(op.loc, op.value, left, self.binary(level + 1))
				if self.tok.kind == "op" and self.tok.value in CMP_OPS:
					raise ParseError(self.tok, "comparisons don't chain: write 'a < b && b < c'")
			return left
		left = self.binary(level + 1)
		while self.tok.kind == "op" and self.tok.value in ops:
			op = self.next()
			left = Binary(op.loc, op.value, left, self.binary(level + 1))
		return left

	def cast(self):
		e = self.unary()
		while self.at("as"):
			loc = self.next().loc
			e = Cast(loc, e, self.type())
		return e

	def unary(self):
		tok = self.tok
		if tok.kind == "op" and tok.value in ("-", "!", "~", "*", "&"):
			self.next()
			op = tok.value
			if op == "&" and self.accept("mut"):
				op = "&mut"
			return Unary(tok.loc, op, self.unary())
		return self.postfix()

	def postfix(self):
		e = self.primary()
		while True:
			tok = self.tok
			if tok.is_("("):
				e = Call(tok.loc, e, self.args())
			elif tok.is_("["):
				self.next()
				index = self.with_struct(self.expr)
				self.expect("]")
				e = Index(tok.loc, e, index)
			elif tok.is_("."):
				self.next()
				if self.tok.kind != "id":
					self.unexpected("a field name")
				e = Member(tok.loc, e, self.next().value)
			else:
				return e

	def args(self):
		self.expect("(")
		return self.with_struct(self.comma_list, self.expr, ")")

	def primary(self):
		tok = self.tok
		k = tok.kind
		if k == "int":
			return IntLit(self.next().loc, tok.value)
		if k == "float":
			return FloatLit(self.next().loc, tok.value)
		if k == "char":
			return CharLit(self.next().loc, tok.value, tok.wide)
		if k == "str":
			return StringLit(self.next().loc, tok.value)
		if tok.is_("true") or tok.is_("false"):
			return BoolLit(self.next().loc, tok.value == "true")
		if tok.is_("null"):
			return NullLit(self.next().loc)
		if k == "id":
			self.next()
			if tok.value in BUILTIN_FUNCS:
				return self.builtin(tok)
			return Name(tok.loc, tok.value)
		if tok.is_("("):
			after = self.peek()
			if after.is_(")") or (after.kind == "id" and self.peek(2).is_(":")):
				return self.func_lit()
			self.next()
			e = self.with_struct(self.expr)
			self.expect(")")
			return e
		if tok.is_("{") and not self.no_struct:
			return self.struct_lit()
		if tok.is_("["):
			self.next()
			return ArrayLit(tok.loc, self.with_struct(self.comma_list, self.expr, "]"))
		self.unexpected("an expression")

	def builtin(self, tok):
		if not self.at("("):
			raise ParseError(tok, f"'{tok.value}' is a built-in function: it can only be called")
		if tok.value == "vaArg":
			self.next()
			pack = self.with_struct(self.expr)
			self.expect(",")
			index = self.with_struct(self.expr)
			self.expect(",")
			target = self.with_struct(self.type)
			self.expect(")")
			return VaArg(tok.loc, pack, index, target)
		if tok.value in ("sizeof", "alignof", "offsetof"):
			self.next()
			typ = self.with_struct(self.type)
			field = None
			if tok.value == "offsetof":
				self.expect(",")
				if self.tok.kind != "id":
					self.unexpected("a field name")
				field = self.next().value
			self.expect(")")
			return TypeQuery(tok.loc, tok.value, typ, field)
		return BuiltinCall(tok.loc, tok.value, self.args())

	def func_lit(self):
		"""(params): R { body }, the same rule as a function type (9)."""
		tok = self.tok
		if self.no_struct:
			raise ParseError(tok, "a function literal here must be in parentheses: "
								  "its '{' would start the body of the statement")
		params = self.params()
		self.expect(":", "':' and the result type")
		result = self.type()
		if not self.at("{"):
			self.unexpected("'{' and the body of the function literal")
		body = self.func_body("the function literal", result)
		return FuncLit(tok.loc, params, result, body)

	def struct_lit(self):
		loc = self.next().loc
		fields = []
		while not self.at("}"):
			dot = self.tok
			if not dot.is_("."):
				self.unexpected("'.field = value' or '}'")
			self.next()
			if self.tok.kind != "id":
				self.unexpected("a field name")
			name = self.next().value
			self.expect("=")
			value = self.with_struct(self.expr)
			fields.append(FieldInit(dot.loc, name, value))
			if self.accept(","):
				continue
			if self.at("=") and isinstance(value, Member):
				raise ParseError(self.tokens[self.i - 2], f"missing ',' before '.{value.name}'")
			if self.at("."):
				raise ParseError(self.tok, "missing ',' between fields")
			break
		self.expect("}", "',' or '}'")
		return StructLit(loc, fields)
