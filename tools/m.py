#!/usr/bin/env python3
"""Compiler for the M language, version M0.

The language is described in m/docs/spec, how this compiler builds
programs in m/docs/COMPILER.md. Every module (.m file) is compiled to an
ELF object file of its own (docs/ABI.md), through tools/asm.py -c, and
tools/ld.py links the objects with the runtime in m/runtime into an
image:

  m.py main.m -o prog.img        the program: main.m, the modules it
                                 imports and the runtime, as a boot image
                                 loaded at 0x00010000
  m.py --rom main.m -o fw.rom    ... as a ROM image, such as the firmware
  m.py -c mod.m -o mod.o         one module: an object file; the modules
                                 it imports are read for their
                                 declarations only
  m.py -S mod.m -o mod.s         ... its assembly, for tools/asm.py -c
  m.py a.o b.o -o prog.img       objects of modules, linked with the
                                 runtime (rt.m too)
  m.py prog.asm -o prog.img      an assembly program that defines main,
                                 linked with the runtime but not rt.m (the
                                 runtime tests in m/tests use this)

usage: tools/m.py [-I DIR]... [-o OUT] [--rom] [-c | -S] [--map FILE]
                  [--save-temps DIR] [--ast] [--check] FILE...
"""

import argparse
import os
import re
import sys
import tempfile

import asm as assembler
import ld as linker
from mlang.check import Checker
from mlang.codegen import CodeGen
from mlang.diag import CompileError, Diagnostics
from mlang.image import (BOOT_RUNTIME, ROM_RAM_DATA, ROM_RAM_LIMIT, ROM_RUNTIME, RUNTIME,
						 RUNTIME_M, module_asm)
from mlang.modules import load_program
from mlang.syntax import dump


class ModuleDiagnostics(Diagnostics):
	"""Compiling one module: warnings about the modules it imports are
	theirs, they come when those are compiled."""

	def __init__(self, path):
		super().__init__()
		self.path = os.path.realpath(path)

	def warning(self, loc, msg):
		if loc is None or os.path.realpath(loc.path) == self.path:
			super().warning(loc, msg)


def check_modules(roots, include_dirs, diag, program, ast=False, check=False):
	"""Loads and checks the root files and every file they import. Returns
	the modules, or None after errors (already reported) or when asked to
	stop early (--ast, --check)."""
	modules = load_program(roots, include_dirs, diag)
	if diag.errors:
		return None
	if ast:
		for module in modules:
			print(f"; {module.path}\n" + dump(module.decls), end="")
		return None
	Checker(modules, diag, program).run()
	if diag.errors or check:
		return None
	return modules


def module_text(codegen, module, diag):
	"""The assembly of a module's object file; None after errors."""
	try:
		program = codegen.run(module)
	except CompileError as e:
		diag.error(e.loc, e.msg)
		return None
	return None if diag.errors else module_asm(program)


def assemble(source, output, include_dirs, diag):
	"""Assembles the file with -c into output; False after errors, which
	asm.py has reported as they are."""
	try:
		obj, _ = assembler.assemble(source, obj=True, include_dirs=include_dirs)
	except assembler.AsmErrors as e:
		for line in e.errors:
			print(line, file=sys.stderr)
		diag.errors += len(e.errors)
		return False
	with open(output, "wb") as f:
		f.write(obj)
	return True


class Build:
	"""The object files of a program, in a directory of their own."""

	def __init__(self, workdir, include_dirs, diag):
		self.workdir = workdir
		self.include_dirs = include_dirs
		self.diag = diag
		self.objects = []

	def path(self, name, ext):
		stem = re.sub(r"\W", "_", os.path.splitext(os.path.basename(name))[0])
		return os.path.join(self.workdir, f"{len(self.objects):02d}_{stem}{ext}")

	def add_asm(self, source):
		output = self.path(source, ".o")
		if assemble(source, output, self.include_dirs, self.diag):
			self.objects.append(output)

	def add_module(self, codegen, module):
		text = module_text(codegen, module, self.diag)
		if text is None:
			return
		source = self.path(module.path, ".s")
		with open(source, "w", encoding="utf-8") as f:
			f.write(text)
		self.add_asm(source)

	def add_runtime(self, rom):
		for name in ROM_RUNTIME if rom else BOOT_RUNTIME:
			self.add_asm(os.path.join(RUNTIME, name))

	def add_rt(self, include_dirs):
		"""rt.m, compiled on its own (when the modules are objects)."""
		modules = check_modules([RUNTIME_M], include_dirs, self.diag, program=False)
		if modules is not None:
			self.add_module(CodeGen(modules, self.diag), modules[0])


def link(objects, output, rom, map_path, modules, diag):
	"""Links the objects into the image; False after errors. An undefined
	symbol that a module declares 'extern' is reported at the
	declaration."""
	layout = "rom" if rom else "boot"
	options = dict(data=ROM_RAM_DATA, ram_limit=ROM_RAM_LIMIT) if rom else {}
	try:
		image, map_text = linker.link(objects, layout, **options)
	except linker.LinkErrors as e:
		externs = {sym.label: sym for m in modules for sym in m.scope.values()
				   if sym.kind in ("var", "func") and sym.extern and sym.used}
		explained = set()
		for name in e.undefined:
			sym = externs.get(name)
			if sym is not None:
				diag.error(sym.decl.loc, f"nothing defines 'extern' '{sym.name}': no M module "
										 f"exports it, and no '.asm' next to a module has it")
				explained.add(f"undefined symbol '{name}'")
		for line in e.errors:
			if not any(text in line for text in explained):
				diag.error(None, line.replace("ld.py: error: ", "", 1))
		return False
	with open(output, "wb") as f:
		f.write(image)
	if map_path:
		with open(map_path, "w", encoding="utf-8") as f:
			f.write(map_text)
	return True


def default_output(args, first):
	stem = os.path.splitext(first)[0]
	if args.obj:
		return stem + ".o"
	if args.asm:
		return stem + ".s"
	return stem + (".rom" if args.rom else ".img")


def main(argv=None):
	p = argparse.ArgumentParser(prog="m.py", description="M compiler (M0)", epilog=__doc__,
								formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("inputs", nargs="+", metavar="FILE",
				   help="main module (.m), an .asm program, or object files to link")
	p.add_argument("-o", "--output", help="output file (default: the input with .img, .rom, "
										   ".o or .s)")
	p.add_argument("-I", dest="include", action="append", default=[], metavar="DIR",
				   help="add a directory to search for imported files")
	p.add_argument("--rom", action="store_true",
				   help="make a ROM image (like the firmware), not a boot image")
	mode = p.add_mutually_exclusive_group()
	mode.add_argument("-c", dest="obj", action="store_true",
					  help="compile one module to an object file, don't link")
	mode.add_argument("-S", dest="asm", action="store_true",
					  help="write one module's assembly, for tools/asm.py -c")
	p.add_argument("--map", help="write the image's sections and symbols (tools/ld.py --map)")
	p.add_argument("--save-temps", metavar="DIR",
				   help="keep the assembly and object files of the modules in DIR")
	p.add_argument("--ast", action="store_true",
				   help="print the syntax tree of every module and stop")
	p.add_argument("--check", action="store_true",
				   help="only check the program: report errors and warnings, write nothing")
	args = p.parse_args(argv)

	inputs = args.inputs
	kinds = {os.path.splitext(path)[1] for path in inputs}
	linking = kinds <= {".o", ".a"}
	if not linking and len(inputs) > 1:
		p.error("one .m or .asm file, or object files to link")
	if (args.obj or args.asm or args.ast or args.check) and kinds != {".m"}:
		p.error("-c, -S, --ast and --check take one .m file")
	output = args.output or default_output(args, inputs[0])
	diag = Diagnostics()
	include_dirs = args.include

	# one module
	if args.obj or args.asm:
		diag = ModuleDiagnostics(inputs[0])
		modules = check_modules(inputs, include_dirs, diag, program=False)
		if modules is None:
			return 1 if diag.errors else 0
		text = module_text(CodeGen(modules, diag), modules[0], diag)
		if text is None:
			return 1
		if args.asm:
			with open(output, "w", encoding="utf-8") as f:
				f.write(text)
			return 0
		with tempfile.TemporaryDirectory(prefix="m-") as tmp:
			source = os.path.join(args.save_temps or tmp, os.path.basename(output) + ".s")
			if args.save_temps:
				os.makedirs(args.save_temps, exist_ok=True)
			with open(source, "w", encoding="utf-8") as f:
				f.write(text)
			return 0 if assemble(source, output, include_dirs, diag) else 1

	modules = []
	if not linking and inputs[0].endswith(".m"):
		modules = check_modules([inputs[0], RUNTIME_M], include_dirs, diag, program=True,
								ast=args.ast, check=args.check)
		if modules is None:
			return 1 if diag.errors else 0
	elif not linking:
		if not os.path.isfile(inputs[0]):
			diag.error(None, f"cannot read '{inputs[0]}'")
			return 1

	with tempfile.TemporaryDirectory(prefix="m-") as tmp:
		workdir = args.save_temps or tmp
		os.makedirs(workdir, exist_ok=True)
		build = Build(workdir, include_dirs, diag)
		build.add_runtime(args.rom)   # crt0 or rom0 first: it starts the image
		if modules:
			codegen = CodeGen(modules, diag)
			for module in modules:
				build.add_module(codegen, module)
		elif linking:
			build.add_rt(include_dirs)
			build.objects += inputs
		else:
			build.add_asm(inputs[0])
		if diag.errors:
			return 1
		return 0 if link(build.objects, output, args.rom, args.map, modules, diag) else 1


if __name__ == "__main__":
	sys.exit(main())
