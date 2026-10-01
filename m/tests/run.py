#!/usr/bin/env python3
"""Runs the tests of the M compiler (m/docs/COMPILER.md, "Тесты").

A test is an .m file under m/tests or m/examples, or an .asm file under
m/tests, with at least one directive in a comment line ('//' in .m, ';'
in .asm). Files without directives (imported modules, helpers) are not
tests.

  @output "text"     what the program writes to the UART; Python string
                     syntax, '"text" * N' repeats it, several lines are
                     joined; without it the output isn't checked
  @exit N            the exit code, the result of main (default 0)
  @error LINE: MSG   a compile error at LINE of this file whose message
                     contains MSG; LINE: may be left out (any place)
  @warning LINE: MSG the same for a warning
  @args ARGS         more emulator options, e.g. --ram 4M
  @rom               build a ROM image (m.py --rom) and run it in place of
                     the firmware, instead of a boot image on disk 0
  @input "text"      bytes for the UART, Python string syntax; they are
                     sent 1 s after the start, when the program is running
                     (the RX FIFO is flushed at reset and the program may
                     flush it too)

The reported errors have to be exactly the expected ones, and so do the
warnings if the test expects any (otherwise warnings are not checked).
A test without @output and @exit is only checked (m.py --check). Any
other test without @error is compiled with tools/m.py, assembled with
tools/asm.py into a boot image, and booted from disk 0 by the firmware in
the emulator (--headless), then its UART output (the emulator's stdout;
its own messages go to stderr) and exit code are compared.

usage: m/tests/run.py [--emulator PATH] [tests...]
"""

import argparse
import ast
import concurrent.futures
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time

M_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(M_DIR)
COMPILER = os.path.join(ROOT, "tools", "m.py")
ASSEMBLER = os.path.join(ROOT, "tools", "asm.py")
FIRMWARE = os.path.join(ROOT, "firmware", "main.m")    # in M: built with m.py --rom
EMULATOR = os.path.join(ROOT, "bin", "wrm081632.exe" if os.name == "nt" else "wrm081632")

TEST_DIRS = ("tests", "examples")
INPUT_DELAY = 1.0   # seconds
BOOT_LOAD = 0x00010000

DIRECTIVE = {
	".m": re.compile(r"^\s*//\s*@(\w+)\b\s*(.*?)\s*$"),
	".asm": re.compile(r"^\s*;\s*@(\w+)\b\s*(.*?)\s*$"),
}
EXPECTED_DIAG = re.compile(r"^(?:(\d+)\s*:\s*)?(.+)$")
DIAG = re.compile(r"^(?:(.*?):(\d+)(?::\d+)?: )?(error|warning): (.*)$")


REPEAT = re.compile(r"^(.*?)\s*\*\s*(\d+)$")


def parse_text(value):
	"""A Python string literal, or one repeated: "tick\\n" * 11. Raises
	SyntaxError."""
	m = REPEAT.match(value)
	body, times = (m.group(1), int(m.group(2))) if m else (value, 1)
	try:
		text = ast.literal_eval(body)
	except ValueError:
		raise SyntaxError
	if not isinstance(text, str):
		raise SyntaxError
	return text * times


class Test:
	def __init__(self, path):
		self.path = path
		self.output = None
		self.exit = 0
		self.run = False    # has @output or @exit
		self.diags = []  # (kind, line or None, message)
		self.args = []
		self.input = None
		self.rom = False


def read_test(path):
	"""Returns the Test of a file, None if it has no directives. Raises
	ValueError on a bad directive."""
	pattern = DIRECTIVE[os.path.splitext(path)[1]]
	test, found = Test(path), False
	with open(path, encoding="utf-8") as f:
		for n, line in enumerate(f, 1):
			m = pattern.match(line)
			if not m:
				continue
			found = True
			name, value = m.groups()
			try:
				if name == "output":
					test.output = (test.output or "") + parse_text(value)
					test.run = True
				elif name == "exit":
					try:
						test.exit = int(value, 0) & 0xFF
						test.run = True
					except ValueError:
						raise SyntaxError
				elif name in ("error", "warning"):
					d = EXPECTED_DIAG.match(value)
					if not d:
						raise SyntaxError
					line_no = int(d.group(1)) if d.group(1) else None
					test.diags.append((name, line_no, d.group(2)))
				elif name == "args":
					test.args += shlex.split(value)
				elif name == "rom":
					if value:
						raise SyntaxError
					test.rom = True
				elif name == "input":
					test.input = (test.input or "") + parse_text(value)
				else:
					raise ValueError(f"line {n}: unknown directive @{name}")
			except SyntaxError:
				raise ValueError(f"line {n}: bad @{name}: {value}")
	return test if found else None


def find_tests():
	found = []
	for d in TEST_DIRS:
		for dirpath, dirnames, filenames in os.walk(os.path.join(M_DIR, d)):
			dirnames.sort()
			for name in sorted(filenames):
				ext = os.path.splitext(name)[1]
				if ext == ".m" or (ext == ".asm" and d == "tests"):
					found.append(os.path.join(dirpath, name))
	return found


def test_name(path):
	rel = os.path.relpath(path, M_DIR)
	if rel.startswith(".."):  # a test from elsewhere
		rel = os.path.relpath(path)
	return os.path.splitext(rel)[0].replace(os.sep, "/")


def check_diags(test, stderr):
	"""Returns a list of problems: expected diagnostics that weren't
	reported and reported ones that weren't expected."""
	strict_warnings = any(kind == "warning" for kind, _, _ in test.diags)
	reported = []
	for line in stderr.splitlines():
		m = DIAG.match(line)
		if m:
			path, line_no, kind, msg = m.groups()
			if kind == "warning" and not strict_warnings:
				continue
			same_file = path is not None and os.path.realpath(path) == os.path.realpath(test.path)
			reported.append((kind, int(line_no) if same_file else None, msg, line))
	problems = []
	for kind, line_no, msg in test.diags:
		for r in reported:
			if r[0] == kind and (line_no is None or r[1] == line_no) and msg in r[2]:
				reported.remove(r)
				break
		else:
			problems.append(f"missing {kind}" + (f" at line {line_no}" if line_no else "") +
							f": {msg}")
	problems += [f"unexpected: {r[3]}" for r in reported]
	return problems


def run_test(test, emulator, firmware, timeout, workdir):
	"""Returns (passed, message, details)."""
	base = os.path.join(workdir, test_name(test.path).replace("/", "_"))
	source, image = base + ".s", base + ".img"
	expect_error = any(kind == "error" for kind, _, _ in test.diags)
	check_only = not test.run and not expect_error
	command = [sys.executable, COMPILER, test.path] + (["--check"] if check_only else ["-o", source]) + \
		(["--rom"] if test.rom else [])
	compile_ = subprocess.run(command, capture_output=True, text=True)
	compile_out = compile_.stdout + compile_.stderr
	problems = check_diags(test, compile_.stderr)
	if expect_error and compile_.returncode == 0:
		problems.insert(0, "compiled, but errors were expected")
	if not expect_error and compile_.returncode != 0:
		return False, "compiler failed", compile_out
	if problems:
		return False, "diagnostics differ", "\n".join(problems) + "\n" + compile_out
	if expect_error or check_only:
		return True, "", compile_out

	base_args = [] if test.rom else ["--base", hex(BOOT_LOAD)]
	asm = subprocess.run([sys.executable, ASSEMBLER, source] + base_args + ["-o", image],
						 capture_output=True, text=True)
	if asm.returncode != 0:
		return False, "assembler failed", asm.stdout + asm.stderr

	if test.rom:
		command = [emulator, "--headless", "--rom", image] + test.args
	else:
		command = [emulator, "--headless", "--rom", firmware, "--hdd", image] + test.args
	proc = subprocess.Popen(command, stdin=subprocess.PIPE if test.input else subprocess.DEVNULL,
							stdout=subprocess.PIPE, stderr=subprocess.PIPE)
	try:
		if test.input:
			time.sleep(INPUT_DELAY)
			try:
				proc.stdin.write(test.input.encode("latin-1"))
				proc.stdin.flush()
			except BrokenPipeError:
				pass
		# closes stdin itself; closing it here first makes 3.12's communicate() flush a closed file
		out, err = proc.communicate(timeout=timeout)
	except subprocess.TimeoutExpired:
		proc.kill()
		out, err = proc.communicate()
		output = out + err
		return False, f"timed out after {timeout}s", output.decode("latin-1")

	# bytes as they are: '\xE9' in @output is the byte 0xE9
	stdout = out.decode("latin-1")
	stderr = err.decode("latin-1")
	run = proc
	details = stdout + stderr
	if run.returncode < 0:
		return False, f"emulator killed by signal {-run.returncode}", details
	if "CPU: halted by a fault" in stderr:
		return False, "CPU halted on a fault it couldn't handle", details
	if test.output is not None and stdout != test.output:
		return False, "output differs", f"expected {test.output!r}\n     got {stdout!r}\n" + details
	if run.returncode != test.exit:
		return False, f"exit code {run.returncode}, expected {test.exit}", details
	return True, "", details


def main(argv=None):
	p = argparse.ArgumentParser(prog="run.py", description="M compiler test runner")
	p.add_argument("tests", nargs="*", help="test files (default: all under m/tests and m/examples)")
	p.add_argument("--emulator", default=EMULATOR,
				   help="emulator binary (default: %(default)s)")
	p.add_argument("--timeout", type=float, default=30,
				   help="seconds per test (default: %(default)s)")
	p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1,
				   help="tests run in parallel (default: %(default)s)")
	p.add_argument("-v", "--verbose", action="store_true",
				   help="show the output of passing tests too")
	p.add_argument("--keep", metavar="DIR",
				   help="keep the generated assembly and images in DIR")
	args = p.parse_args(argv)

	if not os.path.isfile(args.emulator):
		p.error(f"no emulator at {args.emulator}, build it or pass --emulator")
	paths = [os.path.abspath(t) for t in args.tests] or find_tests()

	tests, failed = [], []  # failed also has the files that aren't valid tests
	for path in paths:
		try:
			test = read_test(path)
		except (OSError, ValueError) as e:
			print(f"FAIL  {test_name(path)}: {e}")
			failed.append(test_name(path))
			continue
		if test:
			tests.append(test)
		elif args.tests:
			print(f"FAIL  {test_name(path)}: no directives, not a test")
			failed.append(test_name(path))
	invalid = len(failed)

	with tempfile.TemporaryDirectory(prefix="m-tests-") as tmp:
		workdir = args.keep or tmp
		os.makedirs(workdir, exist_ok=True)
		firmware = os.path.join(workdir, "firmware.rom")
		source = os.path.join(workdir, "firmware.s")
		for command in ([COMPILER, "--rom", FIRMWARE, "-o", source],
						[ASSEMBLER, source, "-o", firmware]):
			build = subprocess.run([sys.executable] + command, capture_output=True, text=True)
			if build.returncode != 0:
				print(build.stdout + build.stderr, end="")
				p.exit(1, "run.py: can't build the firmware\n")

		with concurrent.futures.ThreadPoolExecutor(max(1, args.jobs)) as pool:
			jobs = [pool.submit(run_test, t, args.emulator, firmware, args.timeout, workdir)
					for t in tests]
			for test, job in zip(tests, jobs):
				passed, message, details = job.result()
				name = test_name(test.path)
				print(f"{'PASS' if passed else 'FAIL'}  {name}" + (f": {message}" if message else ""))
				if not passed or args.verbose:
					for line in details.rstrip().splitlines():
						print(f"      {line}")
				if not passed:
					failed.append(name)

	total = len(tests) + invalid
	print(f"\n{total - len(failed)} of {total} tests passed")
	return 1 if failed else 0


if __name__ == "__main__":
	sys.exit(main())
