#!/usr/bin/env python3
"""Disassembler for the WRM.081632 CPU.

Reads a raw little-endian image, like the ones tools/asm.py writes, and
prints every word as an instruction in the assembler's syntax, so the
text assembles back to the same word: branch and JAL targets are absolute
addresses, and a word the assembler can't produce (unknown opcode,
reserved bits set, a control register MFCR/MTCR can't name, a shift by
more than 31) becomes .word. Runs of the same word are folded into a '*'
line. The emulator's --trace uses the same syntax (source/disasm.c).
"""

import argparse
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ next to asm.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import CREGS, CREGS_READONLY, ROM_BASE, auto_int  # noqa: E402

N = {0x00: "hlt", 0x01: "nop", 0x02: "wfi", 0x03: "iret", 0x07: "syscall",
	 0x08: "fence", 0x09: "break"}
R = {0x10 + i: name for i, name in enumerate((
	"add", "sub", "and", "or", "xor", "shl", "shr", "sar",
	"slt", "sltu", "mul", "div", "divu", "rem", "remu"))}
R.update({0x1F: "mulh", 0x2A: "mulhu", 0x2B: "mulhsu"})
ATOMIC = {0x4B: "ll", 0x4C: "sc"}
I_SIGNED = {0x20: "addi", 0x28: "slti", 0x29: "sltiu"}
I_UNSIGNED = {0x22: "andi", 0x23: "ori", 0x24: "xori"}
I_SHIFT = {0x25: "shli", 0x26: "shri", 0x27: "sari"}
UPPER = {0x30: "lui", 0x31: "auipc"}
MEMORY = {0x40: "lb", 0x41: "lbu", 0x42: "lh", 0x43: "lhu", 0x44: "lw",
		  0x48: "sb", 0x49: "sh", 0x4A: "sw"}
BRANCH = {0x50 + i: name for i, name in enumerate((
	"beq", "bne", "blt", "bge", "bltu", "bgeu"))}
OP_MFCR, OP_MTCR, OP_TLBI = 0x04, 0x05, 0x06
OP_JAL, OP_JALR = 0x60, 0x61

CR_NAMES = {n: name for name, n in CREGS.items() if not name.startswith("cr")}


def sign_extend(value, bits):
	sign = 1 << (bits - 1)
	return (value ^ sign) - sign


def disassemble(word, pc):
	"""Returns the text of the instruction word located at pc."""
	op = word & 0xFF
	rd, rs1, rs2 = word >> 8 & 31, word >> 13 & 31, word >> 18 & 31
	imm14 = word >> 18
	simm = sign_extend(imm14, 14)

	def target(offset):
		return f"0x{(pc + (offset << 2)) & 0xFFFFFFFF:08X}"

	if op in N and not word >> 8:
		return N[op]
	if op in R and not word >> 23:
		return f"{R[op]} r{rd}, r{rs1}, r{rs2}"
	if op in ATOMIC and not word >> 23 and (op != 0x4B or rs2 == 0):
		if op == 0x4B:
			return f"ll r{rd}, (r{rs1})"
		return f"{ATOMIC[op]} r{rd}, r{rs2}, (r{rs1})"
	if op in I_SIGNED:
		return f"{I_SIGNED[op]} r{rd}, r{rs1}, {simm}"
	if op in I_UNSIGNED:
		return f"{I_UNSIGNED[op]} r{rd}, r{rs1}, 0x{imm14:X}"
	if op in I_SHIFT and imm14 < 32:
		return f"{I_SHIFT[op]} r{rd}, r{rs1}, {imm14}"
	if op in UPPER:
		return f"{UPPER[op]} r{rd}, 0x{word >> 13:05X}"
	if op in MEMORY:
		return f"{MEMORY[op]} r{rd}, {simm}(r{rs1})"
	if op in BRANCH:
		return f"{BRANCH[op]} r{rd}, r{rs1}, {target(simm)}"
	if op == OP_JAL:
		return f"jal r{rd}, {target(sign_extend(word >> 13, 19))}"
	if op == OP_JALR:
		return f"jalr r{rd}, r{rs1}, {simm}"
	if op == OP_MFCR and not rs1 and simm in CR_NAMES:
		return f"mfcr r{rd}, {CR_NAMES[simm]}"
	if op == OP_MTCR and not rd and simm in CR_NAMES and simm not in CREGS_READONLY:
		return f"mtcr {CR_NAMES[simm]}, r{rs1}"
	if op == OP_TLBI and not rd and not imm14:
		return f"tlbi r{rs1}"
	return f".word 0x{word:08X}"


def main(argv=None):
	p = argparse.ArgumentParser(prog="disasm.py", description="WRM.081632 disassembler")
	p.add_argument("image", help="raw image (e.g. a ROM from asm.py)")
	p.add_argument("--base", type=auto_int, default=ROM_BASE,
				   help="address of the first image byte (default: 0x%(default)X)")
	p.add_argument("--start", type=auto_int,
				   help="first address to disassemble (default: --base)")
	p.add_argument("-n", "--count", type=auto_int,
				   help="number of words (default: up to the end of the image)")
	p.add_argument("--all", action="store_true",
				   help="print every word, without folding repeats into '*'")
	args = p.parse_args(argv)

	start = args.base if args.start is None else args.start
	if start % 4 or args.base % 4:
		p.error("--base and --start must be 4-byte aligned")
	if start < args.base:
		p.error("--start is below --base")

	try:
		with open(args.image, "rb") as f:
			f.seek(start - args.base)
			data = f.read() if args.count is None else f.read(args.count * 4)
	except OSError as e:
		p.error(f"cannot read '{args.image}': {e.strerror}")

	out = sys.stdout
	previous, folded = None, False
	for offset in range(0, len(data) - len(data) % 4, 4):
		word = int.from_bytes(data[offset:offset + 4], "little")
		pc = start + offset
		if word == previous and not args.all:
			if not folded:
				out.write("*\n")
				folded = True
			continue
		previous, folded = word, False
		out.write(f"{pc:08X}  {word:08X}  {disassemble(word, pc)}\n")
	if folded:  # show where the run ends
		out.write(f"{pc:08X}  {word:08X}  {disassemble(word, pc)}\n")


if __name__ == "__main__":
	main()
