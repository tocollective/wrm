"""Loading main.m and the files it imports."""

import os

from .diag import Loc
from .lexer import Lexer
from .parser import ParseError, Parser
from .syntax import Import


class Module:
	def __init__(self, path):
		self.path = path    # as shown in messages
		self.decls = None   # None if the file couldn't be read or parsed


def parse_module(path, diag):
	module = Module(path)
	try:
		with open(path, "rb") as f:
			data = f.read()
	except OSError as e:
		diag.error(None, f"cannot read '{path}': {e.strerror}")
		return module
	try:
		src = data.decode("utf-8")
	except UnicodeDecodeError as e:
		line = data[:e.start].count(b"\n") + 1
		diag.error(Loc(path, line), "the file is not valid UTF-8")
		return module
	tokens = Lexer(path, src, diag).run()
	try:
		module.decls = Parser(path, src, tokens, diag).parse_file()
	except ParseError as e:
		diag.error(e.loc, e.msg)
	return module


def find_import(path, importer, include_dirs):
	for d in [os.path.dirname(importer)] + include_dirs:
		candidate = os.path.normpath(os.path.join(d, path))
		if os.path.isfile(candidate):
			return candidate
	return None


def load_program(roots, include_dirs, diag):
	"""Parses the root files (main.m first) and every file they import,
	each once. Returns the modules in that order; each Import node gets
	.module."""
	modules, by_path, work = [], {}, []
	for path in roots:
		key = os.path.realpath(path)
		if key not in by_path:
			by_path[key] = parse_module(os.path.normpath(path), diag)
			modules.append(by_path[key])
			work.append(by_path[key])
	while work:
		module = work.pop(0)
		for decl in module.decls or ():
			if not isinstance(decl, Import):
				continue
			path = find_import(decl.path, module.path, include_dirs)
			if path is None:
				diag.error(decl.loc, f"cannot find '{decl.path}'")
				decl.module = None
				continue
			key = os.path.realpath(path)
			if key not in by_path:
				by_path[key] = parse_module(path, diag)
				modules.append(by_path[key])
				work.append(by_path[key])
			decl.module = by_path[key]
	return modules
