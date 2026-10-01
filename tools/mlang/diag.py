"""Source locations, errors and warnings."""

import sys


class Loc:
	def __init__(self, path, line, col=None):
		self.path = path
		self.line = line
		self.col = col

	def __str__(self):
		return f"{self.path}:{self.line}" + (f":{self.col}" if self.col is not None else "")


class Diagnostics:
	"""Prints errors and warnings as 'path:line:col: error: message' on
	stderr, like asm.py, and counts them."""

	def __init__(self, out=sys.stderr):
		self.out = out
		self.errors = 0
		self.warnings = 0

	def report(self, kind, loc, msg):
		print(f"{loc}: {kind}: {msg}" if loc else f"{kind}: {msg}", file=self.out)

	def error(self, loc, msg):
		self.errors += 1
		self.report("error", loc, msg)

	def warning(self, loc, msg):
		self.warnings += 1
		self.report("warning", loc, msg)


class CompileError(Exception):
	"""An error after which compilation can't go on."""

	def __init__(self, loc, msg):
		super().__init__(msg)
		self.loc = loc
		self.msg = msg
