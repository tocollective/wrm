#!/usr/bin/env python3
r"""Runs the WRM.081632 test ROMs.

Each tests/<group>/<name>.asm is assembled with tools/asm.py and run in the
emulator with --headless. The harness (tests/common/harness.asm) prints
"PASS" and powers the machine off with exit code 0, or prints "FAIL ..."
and uses the number of the failed check as the exit code.

A test passes only when the emulator exits with 0 and the output has the
PASS line: an HLT also exits with 0 in headless mode.

A test can set up the machine with comment lines in its source:
  ; @hdd N          attach a disk of N sectors in which the word at byte
                    offset o of sector s is s << 16 | o / 4
  ; @hdd FILE.asm   attach a boot image assembled from FILE.asm (relative
                    to the test) at BOOT_LOAD
  ; @floppy SPEC    put a disk in the floppy drive, SPEC as for @hdd
  ; @args ARGS      more emulator options, e.g. --ram 4M,2M
  ; @rom FILE.m     run a ROM compiled from M (relative to the test, e.g.
                    the firmware) instead of the test itself
  ; @input EVENT    a line of the input script (--input, see
                    include/input.h), e.g. "@input 1000 key 4 down"
  ; @stdin TEXT     bytes for the emulator's stdin, the UART's RX line,
                    with \n, \t, \\ and \xNN escapes; several add up
  ; @share [ro]     share a fresh folder (--share) holding hello.txt
                    ("Hello, share!\n") and sub/data.bin (300 bytes, byte i
                    is i & 0xFF); with ro read-only
Each @hdd attaches the next disk, 0 then 1.

usage: tests/run.py [--emulator PATH] [tests...]
"""

import argparse
import concurrent.futures
import os
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TESTS = os.path.join(ROOT, "tests")
ASSEMBLER = os.path.join(ROOT, "tools", "asm.py")
COMPILER = os.path.join(ROOT, "tools", "m.py")
EMULATOR = os.path.join(ROOT, "bin", "wrm081632.exe" if os.name == "nt" else "wrm081632")

EXIT_TRAP = 254  # tests/common/harness.asm
SECTOR_SIZE = 512
BOOT_LOAD = 0x00010000  # firmware/defs.asm

DIRECTIVE = re.compile(r"^\s*;\s*@(\w+)\b\s*(.*?)\s*$")


def find_tests():
	found = []
	for group in sorted(os.listdir(TESTS)):
		path = os.path.join(TESTS, group)
		if group == "common" or not os.path.isdir(path):
			continue
		for name in sorted(os.listdir(path)):
			if name.endswith(".asm"):
				found.append(os.path.join(path, name))
	return found


def test_name(path):
	return os.path.splitext(os.path.relpath(path, TESTS))[0].replace(os.sep, "/")


def read_directives(path):
	"""Returns the @hdd specs, the @floppy spec (or None), the @args
	options, the @rom source (or None), the @input lines, the @stdin
	bytes and the @share spec (or None) of a test."""
	hdds, floppy, args, rom, script, stdin, share = [], None, [], None, [], b"", None
	with open(path, encoding="utf-8") as f:
		for line in f:
			m = DIRECTIVE.match(line)
			if not m:
				continue
			name, value = m.groups()
			if name == "hdd":
				hdds.append(value)
			elif name == "floppy":
				floppy = value
			elif name == "args":
				args += shlex.split(value)
			elif name == "rom":
				rom = value
			elif name == "input":
				script.append(value)
			elif name == "stdin":
				stdin += value.encode("latin-1").decode("unicode_escape").encode("latin-1")
			elif name == "share":
				if value not in ("", "ro"):
					raise ValueError(f"@share takes nothing or ro, not {value!r}")
				share = value
			else:
				raise ValueError(f"unknown directive @{name}")
	return hdds, floppy, args, rom, script, stdin, share


def pattern_disk(sectors):
	words = ((s << 16) | i for s in range(sectors) for i in range(SECTOR_SIZE // 4))
	return b"".join(w.to_bytes(4, "little") for w in words)


def make_disk(spec, path, image):
	"""Writes the disk image for an @hdd or @floppy spec; returns an error
	or None."""
	if spec.isdigit():
		with open(image, "wb") as f:
			f.write(pattern_disk(int(spec)))
		return None
	source = os.path.join(os.path.dirname(path), spec)
	asm = subprocess.run([sys.executable, ASSEMBLER, source, "--base", hex(BOOT_LOAD),
						  "-o", image], capture_output=True, text=True)
	return None if asm.returncode == 0 else asm.stdout + asm.stderr


def make_share(folder):
	"""Fills the folder an @share test gets."""
	os.makedirs(os.path.join(folder, "sub"))
	with open(os.path.join(folder, "hello.txt"), "wb") as f:
		f.write(b"Hello, share!\n")
	with open(os.path.join(folder, "sub", "data.bin"), "wb") as f:
		f.write(bytes(i & 0xFF for i in range(300)))


def run_test(path, emulator, timeout, workdir):
	"""Returns (passed, message, output)."""
	base = os.path.join(workdir, test_name(path).replace("/", "_"))
	rom = base + ".rom"
	try:
		hdds, floppy, extra, rom_source, script, stdin, share = read_directives(path)
	except ValueError as e:
		return False, str(e), ""
	if rom_source is not None:
		m = subprocess.run([sys.executable, COMPILER, "--rom",
							os.path.join(os.path.dirname(path), rom_source), "-o", rom],
						   capture_output=True, text=True)
		if m.returncode != 0:
			return False, f"can't compile @rom {rom_source}", m.stdout + m.stderr
	else:
		asm = subprocess.run([sys.executable, ASSEMBLER, path, "-o", rom],
							 capture_output=True, text=True)
		if asm.returncode != 0:
			return False, "assembler failed", asm.stdout + asm.stderr

	command = [emulator, "--headless", "--rom", rom]
	for n, spec in enumerate(hdds):
		image = f"{base}.hdd{n}.img"
		error = make_disk(spec, path, image)
		if error is not None:
			return False, f"can't make the disk image for @hdd {spec}", error
		command += ["--hdd", image]
	if floppy is not None:
		image = f"{base}.floppy.img"
		error = make_disk(floppy, path, image)
		if error is not None:
			return False, f"can't make the disk image for @floppy {floppy}", error
		command += ["--floppy", image]
	if share is not None:
		folder = base + ".share"
		make_share(folder)
		command += ["--share", folder + (":ro" if share else "")]
	if script:
		script_path = base + ".input"
		with open(script_path, "w", encoding="utf-8") as f:
			f.write("\n".join(script) + "\n")
		command += ["--input", script_path]
	command += extra

	try:
		run = subprocess.run(command, input=stdin, capture_output=True,
							 timeout=timeout)
	except subprocess.TimeoutExpired as e:
		output = (e.stdout or b"") + (e.stderr or b"")
		return False, f"timed out after {timeout}s", output.decode("utf-8", "replace")

	output = (run.stdout + run.stderr).decode("utf-8", "replace")
	lines = output.splitlines()
	code = run.returncode
	if code == 0 and "PASS" in lines:
		return True, "", output
	if code == 0:
		return False, "halted without PASS", output
	if code == EXIT_TRAP:
		return False, "unexpected trap", output
	if any(line.startswith("FAIL") for line in lines):
		return False, f"check {code} failed", output
	if any("CPU fault" in line for line in lines):
		return False, "CPU halted on a fault it couldn't handle", output
	if code < 0:
		return False, f"emulator killed by signal {-code}", output
	return False, f"emulator exited with {code}", output


def main(argv=None):
	p = argparse.ArgumentParser(prog="run.py", description="WRM.081632 test runner")
	p.add_argument("tests", nargs="*", help="test sources (default: all of tests/*/*.asm)")
	p.add_argument("--emulator", default=EMULATOR,
				   help="emulator binary (default: %(default)s)")
	p.add_argument("--timeout", type=float, default=30,
				   help="seconds per test (default: %(default)s)")
	p.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1,
				   help="tests run in parallel (default: %(default)s)")
	p.add_argument("-v", "--verbose", action="store_true",
				   help="show the output of passing tests too")
	args = p.parse_args(argv)

	if not os.path.isfile(args.emulator):
		p.error(f"no emulator at {args.emulator}, build it or pass --emulator")
	tests = [os.path.abspath(t) for t in args.tests] or find_tests()

	failed = []
	with tempfile.TemporaryDirectory(prefix="wrm-tests-") as workdir, \
		 concurrent.futures.ThreadPoolExecutor(max(1, args.jobs)) as pool:
		jobs = [pool.submit(run_test, t, args.emulator, args.timeout, workdir) for t in tests]
		for path, job in zip(tests, jobs):
			passed, message, output = job.result()
			name = test_name(path)
			print(f"{'PASS' if passed else 'FAIL'}  {name}" + (f": {message}" if message else ""))
			if not passed or args.verbose:
				for line in output.rstrip().splitlines():
					print(f"      {line}")
			if not passed:
				failed.append(name)

	print(f"\n{len(tests) - len(failed)} of {len(tests)} tests passed")
	return 1 if failed else 0


if __name__ == "__main__":
	sys.exit(main())
