#!/usr/bin/env python3
"""Compiler for the M language, version M0.

The language is described in m/docs/spec, how this compiler builds
programs in m/docs/COMPILER.md. The output is one assembly file for
tools/asm.py: a boot image to be assembled at 0x00010000, with crt0 and
memcpy/memset from m/runtime, the code of every module, then .rodata and
.data. .bss follows the image and is zeroed by crt0.

An .asm input is taken as an already compiled program: it is linked with
the runtime the same way and has to define main. The runtime tests in
m/tests use this.

With --rom the program is a ROM image instead, such as the firmware:
assembled at the start of ROM, with .data copied to RAM by its crt0.

usage: tools/m.py [-I DIR]... [-o OUT.asm] [--rom] [--ast] [--check] main.m
"""

import argparse
import os
import sys

from mlang.check import Checker
from mlang.codegen import CodeGen
from mlang.diag import CompileError, Diagnostics
from mlang.image import RUNTIME_M, Program, boot_image, rom_image
from mlang.modules import load_program
from mlang.syntax import dump


def compile_program(path, include_dirs, diag, ast=False, check=False):
	"""Compiles main.m and everything it imports into a Program. Returns
	None after errors, which are already reported, or when asked to stop
	early (--ast, --check)."""
	modules = load_program([path, RUNTIME_M], include_dirs, diag)
	if diag.errors:
		return None
	if ast:
		for module in modules:
			print(f"; {module.path}\n" + dump(module.decls), end="")
		return None
	Checker(modules, diag).run()
	if diag.errors or check:
		return None
	program = CodeGen(modules, diag).run()
	return None if diag.errors else program


def main(argv=None):
	p = argparse.ArgumentParser(prog="m.py", description="M compiler (M0)")
	p.add_argument("input", help="main module (.m), or an .asm program to link with the runtime")
	p.add_argument("-o", "--output",
				   help="output assembly (default: the input with the .asm extension)")
	p.add_argument("-I", dest="include", action="append", default=[], metavar="DIR",
				   help="add a directory to search for imported files")
	p.add_argument("--rom", action="store_true",
				   help="make a ROM image (like the firmware), not a boot image")
	p.add_argument("--ast", action="store_true",
				   help="print the syntax tree of every module and stop")
	p.add_argument("--check", action="store_true",
				   help="only check the program: report errors and warnings, write nothing")
	args = p.parse_args(argv)

	is_asm = args.input.endswith(".asm")
	if is_asm and not args.output:
		p.error("an .asm input needs -o")
	output = args.output or os.path.splitext(args.input)[0] + ".asm"

	diag = Diagnostics()
	if is_asm:
		if not os.path.isfile(args.input):
			diag.error(None, f"cannot read '{args.input}'")
			return 1
		program = Program()
		program.includes.append(args.input)
	else:
		program = None
		try:
			program = compile_program(args.input, args.include, diag, args.ast, args.check)
		except CompileError as e:
			diag.error(e.loc, e.msg)
		if program is None:
			return 1 if diag.errors else 0

	layout = rom_image if args.rom else boot_image
	try:
		text = layout(program, os.path.dirname(os.path.abspath(output)))
	except ValueError as e:
		diag.error(None, str(e))
		return 1
	with open(output, "w", encoding="utf-8") as f:
		f.write(text)
	return 0


if __name__ == "__main__":
	sys.exit(main())
