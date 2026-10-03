"""The syntax tree."""


class Node:
	FIELDS = ()

	def __init__(self, loc, *values):
		assert len(values) == len(self.FIELDS), (type(self).__name__, values)
		self.loc = loc
		for name, value in zip(self.FIELDS, values):
			setattr(self, name, value)


def node(name, fields=""):
	return type(name, (Node,), {"FIELDS": tuple(fields.split())})


# types as written
TypeName = node("TypeName", "name")
PointerType = node("PointerType", "target mut volatile")
ArrayType = node("ArrayType", "elem size")
SliceType = node("SliceType", "elem mut")              # T[] and mut T[], parameters only
VariadicType = node("VariadicType")                    # named trailing 'args: ...'
FuncType = node("FuncType", "params result")

# declarations
Param = node("Param", "name type")
NameAs = node("NameAs", "name alias")                   # alias is None without 'as'
Import = node("Import", "names path")
Export = node("Export", "names")
StructDecl = node("StructDecl", "name fields packed")
Field = node("Field", "name type")
AliasDecl = node("AliasDecl", "name type")
EnumDecl = node("EnumDecl", "name base items")
EnumItem = node("EnumItem", "name value")
VarDecl = node("VarDecl", "name mut type init align extern")
FuncDecl = node("FuncDecl", "name params result body extern")

# statements
Block = node("Block", "stmts")
If = node("If", "cond then else_")
While = node("While", "cond body")
For = node("For", "name mut type start end inclusive step body")
Switch = node("Switch", "value cases")
Case = node("Case", "value body")                       # value None: default
Break = node("Break")
Continue = node("Continue")
Return = node("Return", "value")
Asm = node("Asm", "lines")
Assign = node("Assign", "op target value")
IncDec = node("IncDec", "op target")
ExprStmt = node("ExprStmt", "expr")

# expressions
IntLit = node("IntLit", "value")
FloatLit = node("FloatLit", "value")
CharLit = node("CharLit", "value wide")
StringLit = node("StringLit", "value")
BoolLit = node("BoolLit", "value")
NullLit = node("NullLit")
Name = node("Name", "name")
Member = node("Member", "obj name")                     # also Enum.Item
Index = node("Index", "obj index")
Call = node("Call", "func args")
Unary = node("Unary", "op operand")                     # - ! ~ * & &mut
Binary = node("Binary", "op left right")
Cast = node("Cast", "expr type")
StructLit = node("StructLit", "fields")
FieldInit = node("FieldInit", "name value")
ArrayLit = node("ArrayLit", "elems")
TypeQuery = node("TypeQuery", "op type field")          # sizeof alignof offsetof; type: or a value
BuiltinCall = node("BuiltinCall", "name args")
VaArg = node("VaArg", "pack index target")             # vaArg(pack, index, T)
FuncLit = node("FuncLit", "params result body")      # (a: A): R { ... }; also 'let mut f()'


def dump(n, indent=0):
	"""The tree as indented text, for --ast."""
	pad = "  " * indent
	if isinstance(n, list):
		return "".join(dump(x, indent) for x in n) if n else f"{pad}[]\n"
	if not isinstance(n, Node):
		return f"{pad}{n!r}\n"
	simple = [f for f in n.FIELDS if not isinstance(getattr(n, f), (Node, list))]
	nested = [f for f in n.FIELDS if f not in simple]
	head = " ".join(f"{f}={getattr(n, f)!r}" for f in simple)
	out = f"{pad}{type(n).__name__} {n.loc.line}:{n.loc.col}" + (f" {head}" if head else "") + "\n"
	for f in nested:
		out += f"{pad}  .{f}\n" + dump(getattr(n, f), indent + 2)
	return out
