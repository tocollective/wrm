#!/usr/bin/env python3
"""Linker for WRM.081632.

Links the ELF object files of tools/asm.py -c, and ar archives of them,
into a boot image, a ROM image or an ELF executable (docs/ABI.md,
"Object files" and "Executables").

Layouts (--layout):
  boot  a boot image (docs/SPECIFICATION.md, "Boot image"), a flat file
        loaded to --base (0x00010000): .text, .rodata and .data, padded to
        whole sectors; .bss lies past the end of the image
  rom   a ROM image, flat, at --base (0xFE000000): .text and .rodata, then
        the bytes of .data, which runs in RAM at --data (0x00002000) and is
        copied there by the startup code; .bss follows .data in RAM
  exec  an ELF executable at --base (0x00400000): code, read-only data and
        writable data (.data, then .bss) in segments of their own pages

Input sections go to the output section of their name (.text.foo to
.text, and so on); the files' order is kept. Other section names make
output sections of their own: code after .text, read-only data after
.rodata, writable data after .data. Sections that aren't allocated are
dropped. The first file's .text starts the image.

Symbols the linker defines, unless an object file does:
  __image_start, __image_end      the image, as loaded (boot, rom)
  __image_sectors                 its size in 512-byte sectors (boot)
  __data_load                     where .data is in the image (rom)
  __data_start, __data_end        .data where it runs
  __bss_start, __bss_end, _end    .bss
  __tls_start, __tls_data_end, __tls_end
                                  the TLS image: .tdata, then .tbss
  __start_NAME, __stop_NAME       every output section, NAME without its
                                  leading dot (__start_init_array)

A JAL that can't reach its target (±1MB) goes through a veneer that the
linker puts after the code of the call's object (docs/ABI.md, "Linker
veneers"). --map writes every symbol, "ADDRESS NAME" a line, for the
monitor and for reading traces.

usage: ld.py [-o OUT] [--layout boot|rom|exec] [--base ADDR] [--data ADDR]
             [--ram-limit ADDR] [--entry SYMBOL] [--map FILE] FILE...
"""

import argparse
import os
import re
import sys

import elf
from elf import align_up

LAYOUTS = {"boot": 0x00010000, "rom": 0xFE000000, "exec": 0x00400000}
ROM_DATA = 0x00002000
ROM_SIZE = 32 * 1024 * 1024
SECTOR_SIZE = 512
STANDARD = (".text", ".rodata", ".data", ".tdata", ".tbss", ".bss")
VENEER_SIZE = 12  # LUI r9 + ORI r9 + JALR r0, r9


class LinkErrors(Exception):
	"""The errors of a link; undefined maps the symbols nothing defines
	to the file that uses them."""

	def __init__(self, errors, undefined=None):
		super().__init__("\n".join(errors))
		self.errors = errors
		self.undefined = undefined or {}


def fits(v, lo, hi):
	return lo <= v <= hi


def signed32(v):
	v &= 0xFFFFFFFF
	return v - (1 << 32) if v & 0x80000000 else v


class Input:
	"""An input section: where it goes and the veneers after it."""

	def __init__(self, obj, index, section):
		self.obj = obj
		self.index = index
		self.section = section
		self.out = None
		self.addr = 0  # where it runs
		self.lma = 0  # where it is in the image
		self.veneers = []  # (symbol index, addend) of the targets, in order

	@property
	def code_size(self):
		return align_up(self.section.size, 4) if self.veneers else self.section.size

	@property
	def size(self):
		return self.code_size + VENEER_SIZE * len(self.veneers)

	def veneer_addr(self, k):
		return self.addr + self.code_size + VENEER_SIZE * k


class Output:
	def __init__(self, name):
		self.name = name
		self.inputs = []
		self.flags = 0
		self.nobits = True
		self.align = 4
		self.addr = 0
		self.lma = 0
		self.size = 0

	def kind(self):
		"""Which group it goes in: code, rodata, data, tbss or bss."""
		if self.name in (".text", ".rodata", ".data", ".tdata", ".tbss", ".bss"):
			return {".text": "code", ".rodata": "rodata", ".tdata": "data"}.get(
				self.name, self.name[1:])
		if self.flags & elf.SHF_EXECINSTR:
			return "code"
		if not self.flags & elf.SHF_WRITE:
			return "rodata"
		return "bss" if self.nobits else "data"


def out_name(name):
	for s in STANDARD:
		if name == s or name.startswith(s + "."):
			return s
	return name


def bound_name(name):
	return re.sub(r"\W", "_", name.lstrip("."))


class Linker:
	def __init__(self, layout, base=None, data=None, ram_limit=None, entry=None):
		self.layout = layout
		self.base = LAYOUTS[layout] if base is None else base
		self.data_addr = ROM_DATA if data is None else data
		self.ram_limit = ram_limit
		self.entry_name = entry or ("_start" if layout == "exec" else None)
		self.objects = []
		self.globals = {}  # name -> (object, symbol)
		self.undefined = {}  # name -> the first object that uses it
		self.provided = {}  # the linker's symbols: name -> address
		self.errors = []
		self.missing = {}
		self.inputs = {}  # (object, section index) -> Input
		self.outputs = []
		self.groups = {}

	def error(self, msg):
		self.errors.append(f"ld.py: error: {msg}")

	def check(self):
		if self.errors:
			raise LinkErrors(self.errors, self.missing)

	# -- input

	def add_object(self, obj):
		self.objects.append(obj)
		for sym in obj.symbols[1:]:
			if sym.bind == elf.STB_LOCAL or not sym.name:
				continue
			if sym.shndx == elf.SHN_UNDEF:
				if sym.name not in self.globals:
					self.undefined.setdefault(sym.name, (obj, sym.bind == elf.STB_WEAK))
				continue
			old = self.globals.get(sym.name)
			if old is None or (old[1].bind == elf.STB_WEAK and sym.bind == elf.STB_GLOBAL):
				self.globals[sym.name] = (obj, sym)
			elif sym.bind == elf.STB_GLOBAL and old[1].bind == elf.STB_GLOBAL:
				self.error(f"'{sym.name}' is defined in {old[0].name} and in {obj.name}")
			self.undefined.pop(sym.name, None)

	def load(self, paths):
		archives = []
		for path in paths:
			try:
				with open(path, "rb") as f:
					data = f.read()
				if data.startswith(b"!<arch>\n"):
					archives.append([(f"{path}({name})", body)
									 for name, body in elf.read_archive(data, path)])
				else:
					self.add_object(elf.read_object(data, path))
			except OSError as e:
				self.error(f"cannot read '{path}': {e.strerror}")
			except elf.ElfError as e:
				self.error(str(e))
		self.check()
		# an archive's member comes in if it defines a symbol still wanted
		loaded = set()
		changed = True
		while changed:
			changed = False
			for members in archives:
				for name, body in members:
					if name in loaded:
						continue
					try:
						obj = elf.read_object(body, name)
					except elf.ElfError as e:
						self.error(str(e))
						loaded.add(name)
						continue
					wanted = any(s.bind != elf.STB_LOCAL and s.shndx != elf.SHN_UNDEF
								 and s.name in self.undefined for s in obj.symbols[1:])
					if wanted:
						loaded.add(name)
						self.add_object(obj)
						changed = True
		self.check()

	# -- layout

	def collect(self):
		"""Input sections into output sections, in groups."""
		by_name = {}
		for obj in self.objects:
			for index, section in enumerate(obj.sections):
				if section is None or not section.flags & elf.SHF_ALLOC:
					continue
				name = out_name(section.name)
				out = by_name.get(name)
				if out is None:
					out = by_name[name] = Output(name)
					self.outputs.append(out)
				inp = Input(obj, index, section)
				inp.out = out
				out.inputs.append(inp)
				out.flags |= section.flags
				out.nobits &= section.nobits
				out.align = max(out.align, section.align)
				self.inputs[(obj, index)] = inp
		order = {".text": 0, ".rodata": 0, ".data": 0, ".tdata": 2, ".tbss": 0, ".bss": 2}
		for kind in ("code", "rodata", "data", "tbss", "bss"):
			outs = [o for o in self.outputs if o.kind() == kind]
			# the standard section first in its group (.tdata last of data,
			# .bss last of bss), the others in the order they came
			outs.sort(key=lambda o: order.get(o.name, 1))
			self.groups[kind] = outs

	@staticmethod
	def place(outs, addr):
		"""Lays out the output sections from addr; returns the end."""
		for out in outs:
			addr = align_up(addr, out.align)
			out.addr = out.lma = addr
			for inp in out.inputs:
				addr = align_up(addr, inp.section.align)
				inp.addr = inp.lma = addr
				addr += inp.size
			out.size = addr - out.addr
		return addr

	@staticmethod
	def load_at(outs, lma):
		"""Gives the sections, laid out already, their place in the image
		from lma on, at the same distances."""
		if not outs:
			return lma
		delta = lma - outs[0].addr
		for out in outs:
			out.lma = out.addr + delta
			for inp in out.inputs:
				inp.lma = inp.addr + delta
		last = outs[-1]
		return last.lma + last.size

	def group_align(self, kind):
		return max([4] + [o.align for o in self.groups[kind]])

	def lay_out(self):
		g = self.groups
		p = self.provided
		code = self.place(g["code"], self.base)
		if self.layout == "exec":
			rodata = self.place(g["rodata"], align_up(code, elf.PAGE_SIZE))
			data_start = align_up(rodata, elf.PAGE_SIZE)
		elif self.layout == "boot":
			data_start = align_up(self.place(g["rodata"], code), self.group_align("data"))
		else:
			rom_end = self.place(g["rodata"], code)
			align = self.group_align("data")
			if self.data_addr % align:
				self.error(f".data is aligned to {align}: it can't run at 0x{self.data_addr:X}")
			data_start = self.data_addr
		data_end = self.place(g["data"], data_start)
		tdata = g["data"][-1] if g["data"] and g["data"][-1].name == ".tdata" else None
		tdata_end = tdata.addr + tdata.size if tdata else data_end
		# .tbss takes no place of its own: it is the end of the TLS image
		tbss_end = self.place(g["tbss"], tdata_end)
		tls_start = tdata.addr if tdata else (g["tbss"][0].addr if g["tbss"] else data_end)

		if self.layout == "boot":
			self.load_at(g["code"] + g["rodata"] + g["data"], self.base)
			image_end = align_up(data_end, max(SECTOR_SIZE, self.group_align("bss")))
			bss_start = image_end
			p["__image_sectors"] = (image_end - self.base) // SECTOR_SIZE
		elif self.layout == "rom":
			self.load_at(g["code"] + g["rodata"], self.base)
			data_load = align_up(rom_end, self.group_align("data"))
			image_end = align_up(self.load_at(g["data"], data_load), 4)
			p["__data_load"] = data_load
			bss_start = align_up(data_end, self.group_align("bss"))
		else:
			self.load_at(g["code"] + g["rodata"] + g["data"], self.base)
			image_end = data_end
			bss_start = align_up(data_end, self.group_align("bss"))
		bss_end = align_up(self.place(g["bss"], bss_start), 4)

		p.update(__image_start=self.base, __image_end=image_end,
				 __data_start=data_start, __data_end=align_up(data_end, 4),
				 __bss_start=bss_start, __bss_end=bss_end, _end=bss_end,
				 __tls_start=tls_start, __tls_data_end=tdata_end, __tls_end=tbss_end)
		if self.layout != "rom":
			p.setdefault("__data_load", data_start)
		for out in self.outputs:
			p[f"__start_{bound_name(out.name)}"] = out.addr
			p[f"__stop_{bound_name(out.name)}"] = out.addr + out.size
		self.image_end = image_end
		self.tls = (tls_start, tdata_end, tbss_end)
		self.bss_end = bss_end

	# -- symbols and relocations

	def value(self, obj, index, want=None):
		"""The address (or value) of symbol index of obj; None if it has
		none (an error was reported)."""
		if index == 0:
			return 0
		sym = obj.symbols[index]
		if sym.bind != elf.STB_LOCAL and sym.name in self.globals:
			obj, sym = self.globals[sym.name]
		elif sym.bind != elf.STB_LOCAL and sym.shndx == elf.SHN_UNDEF:
			if sym.name in self.provided:
				return self.provided[sym.name]
			if sym.bind == elf.STB_WEAK:
				return 0
			return None
		if sym.shndx == elf.SHN_ABS:
			return sym.value
		inp = self.inputs.get((obj, sym.shndx))
		if inp is None:
			return None
		return inp.addr + sym.value

	def undefined_used(self):
		"""{name: the first object that uses it} of the symbols that
		relocations need and nothing defines."""
		missing = {}
		for obj in self.objects:
			for section in obj.sections:
				if section is None or not section.flags & elf.SHF_ALLOC:
					continue
				for _, _, index, _ in section.relocs:
					sym = obj.symbols[index] if index < len(obj.symbols) else None
					if sym is not None and index and self.value(obj, index) is None \
							and sym.shndx == elf.SHN_UNDEF:
						missing.setdefault(sym.name, obj.name)
		return missing

	def report_undefined(self):
		self.missing = self.undefined_used()
		for name, where in self.missing.items():
			self.error(f"undefined symbol '{name}', used in {where}")
		if self.entry_name and self.entry_name not in self.globals \
				and self.entry_name not in self.provided:
			self.error(f"no entry point: nothing defines '{self.entry_name}'")

	def jal_veneers(self):
		"""Adds the veneers that calls out of reach need; True if it added
		any (the layout has to be done again)."""
		added = False
		for inp in self.inputs.values():
			for off, rtype, index, addend in inp.section.relocs:
				if elf.RELOCATIONS[rtype] != "R_WRM_JAL19":
					continue
				s = self.value(inp.obj, index)
				if s is None or (index, addend) in inp.veneers:
					continue
				delta = signed32(s + addend - (inp.addr + off))
				if fits(delta, -(1 << 20), (1 << 20) - 4):
					continue
				inp.veneers.append((index, addend))
				added = True
		return added

	def describe(self, inp, off, index):
		sym = inp.obj.symbols[index]
		name = sym.name or (inp.obj.sections[sym.shndx].name
							if sym.type == elf.STT_SECTION and sym.shndx < len(inp.obj.sections)
							and inp.obj.sections[sym.shndx] else "?")
		return f"{inp.obj.name}: {inp.section.name}+0x{off:X}: to '{name}'"

	def relocate(self, inp):
		"""The section's bytes with its relocations applied, and its
		veneers after them."""
		data = bytearray(inp.section.data) if not inp.section.nobits else bytearray(inp.section.size)
		data += bytes(inp.code_size - len(data))
		for off, rtype, index, addend in inp.section.relocs:
			name = elf.RELOCATIONS[rtype] if rtype < len(elf.RELOCATIONS) else str(rtype)
			s = self.value(inp.obj, index)
			if s is None:
				continue  # undefined: reported already
			if off + 4 > len(inp.section.data or b""):
				self.error(f"{self.describe(inp, off, index)}: {name} past the end of the section")
				continue
			sa = (s + addend) & 0xFFFFFFFF
			p = (inp.addr + off) & 0xFFFFFFFF
			word = int.from_bytes(data[off:off + 4], "little")
			try:
				word = self.field(name, word, sa, p, inp, (index, addend))
			except ValueError as e:
				self.error(f"{self.describe(inp, off, index)}: {e}")
				continue
			data[off:off + 4] = word.to_bytes(4, "little")
		for index, addend in inp.veneers:
			target = ((self.value(inp.obj, index) or 0) + addend) & 0xFFFFFFFF
			hi, lo = target >> 13, target & 0x1FFF
			code = [0x30 | 9 << 8 | hi << 13,  # LUI r9, %hi(target)
					0x23 | 9 << 8 | 9 << 13 | lo << 18,  # ORI r9, r9, %lo(target)
					0x61 | 0 << 8 | 9 << 13]  # JALR r0, r9, 0
			data += b"".join(w.to_bytes(4, "little") for w in code)
		return data

	def field(self, name, word, sa, p, inp, target):
		"""The relocated word; raises ValueError if the value doesn't fit."""
		def imm14(v):
			return (word & 0x3FFFF) | (v & 0x3FFF) << 18

		def imm19(v):
			return (word & 0x1FFF) | (v & 0x7FFFF) << 13

		tls = self.tls[0]
		if name == "R_WRM_NONE":
			return word
		if name == "R_WRM_32":
			return sa
		if name == "R_WRM_HI19":
			return imm19(sa >> 13)
		if name == "R_WRM_LO13":
			return imm14(sa & 0x1FFF)
		if name == "R_WRM_ABS14":
			v = signed32(sa)
			if not fits(v, -8192, 8191):
				raise ValueError(f"0x{sa:08X} doesn't fit in a signed 14-bit field")
			return imm14(v)
		if name == "R_WRM_PCREL_HI19":
			return imm19(((sa - p) & 0xFFFFFFFF) >> 13)
		if name == "R_WRM_PCREL_LO13":
			return imm14((sa - (p - 4)) & 0x1FFF)
		if name in ("R_WRM_BRANCH14", "R_WRM_JAL19"):
			delta = signed32(sa - p)
			bits = 14 if name == "R_WRM_BRANCH14" else 19
			reach = 1 << (bits + 1)
			if delta % 4:
				raise ValueError(f"the target 0x{sa:08X} is not 4-byte aligned")
			if not fits(delta, -reach, reach - 4):
				if name == "R_WRM_BRANCH14":
					raise ValueError(f"the target 0x{sa:08X} is out of reach of a branch "
									 f"({delta} bytes, ±32KB)")
				if target not in inp.veneers:
					raise ValueError(f"the target 0x{sa:08X} is out of reach of a JAL")
				delta = signed32(inp.veneer_addr(inp.veneers.index(target)) - p)
				if not fits(delta, -reach, reach - 4):
					raise ValueError("the veneer is out of reach: the section is over 1MB")
			v = delta >> 2
			return imm14(v) if bits == 14 else imm19(v)
		if name == "R_WRM_TPREL14":
			v = signed32(sa - tls)
			if not fits(v, 0, 8191):
				raise ValueError(f"{v} bytes into the TLS image doesn't fit in 0..8191")
			return imm14(v)
		if name == "R_WRM_TPREL_HI19":
			return imm19(((sa - tls) & 0xFFFFFFFF) >> 13)
		if name == "R_WRM_TPREL_LO13":
			return imm14((sa - tls) & 0x1FFF)
		raise ValueError(f"unknown relocation {name}")

	# -- output

	def run(self, paths):
		self.load(paths)
		self.collect()
		self.lay_out()
		self.report_undefined()
		self.check()
		for _ in range(16):
			if not self.jal_veneers():
				break
			self.lay_out()
		self.contents = {inp: self.relocate(inp) for inp in self.all_inputs()}
		self.check_layout()
		self.check()

	def all_inputs(self):
		return [inp for out in self.outputs for inp in out.inputs]

	def check_layout(self):
		end = self.image_end
		if self.layout in ("boot", "rom") and end - self.base > (1 << 32) - self.base:
			self.error("the image runs past the end of the address space")
		if self.layout == "rom" and end - self.base > ROM_SIZE:
			self.error(f"the image is {end - self.base} bytes, over the 32MB of ROM")
		if self.ram_limit is not None and self.layout == "rom" and self.bss_end > self.ram_limit:
			self.error(f".data and .bss take 0x{self.data_addr:X} to 0x{self.bss_end:X} in RAM, "
					   f"past 0x{self.ram_limit:X}")

	def flat_image(self):
		image = bytearray(self.image_end - self.base)
		for inp in self.all_inputs():
			if inp.section.nobits or inp.out.kind() in ("tbss", "bss"):
				continue
			start = inp.lma - self.base
			image[start:start + len(self.contents[inp])] = self.contents[inp]
		return bytes(image)

	def symbol_table(self):
		"""Every symbol with an address: (address, name, global)."""
		table = []
		for obj in self.objects:
			for index, sym in enumerate(obj.symbols[1:], 1):
				if sym.type in (elf.STT_SECTION, elf.STT_FILE) or not sym.name:
					continue
				if sym.shndx == elf.SHN_UNDEF:
					continue
				if sym.bind != elf.STB_LOCAL and self.globals.get(sym.name, (obj, sym))[1] is not sym:
					continue  # a weak one that lost
				v = self.value(obj, index)
				if v is not None:
					table.append((v & 0xFFFFFFFF, sym.name, sym.bind != elf.STB_LOCAL))
		defined = {name for _, name, g in table if g}
		for name, v in self.provided.items():
			if name not in defined:
				table.append((v & 0xFFFFFFFF, name, True))
		table.sort(key=lambda t: (t[0], t[1]))
		return table

	def map_text(self):
		lines = ["; sections: address, size, name"]
		for out in self.outputs:
			lma = f"  (at 0x{out.lma:08X})" if out.lma != out.addr else ""
			lines.append(f"; {out.addr:08X} {out.size:8X} {out.name}{lma}")
		lines.append("; symbols")
		lines += [f"{addr:08X}  {name}" for addr, name, _ in self.symbol_table()]
		return "\n".join(lines) + "\n"

	def executable(self):
		sections, by_out = [], {}
		for out in self.outputs:
			if out.kind() == "tbss" and not out.size:
				continue
			nobits = out.nobits or out.kind() in ("tbss", "bss")
			data = None
			if not nobits:
				data = bytearray(out.size)
				for inp in out.inputs:
					start = inp.addr - out.addr
					data[start:start + len(self.contents[inp])] = self.contents[inp]
			s = elf.Section(out.name, elf.SHT_NOBITS if nobits else elf.SHT_PROGBITS,
							out.flags, out.align, data, out.size)
			s.addr = out.addr
			sections.append(s)
			by_out[out.name] = s

		def pick(kinds):
			return [by_out[o.name] for k in kinds for o in self.groups[k] if o.name in by_out]

		segments = []
		for kinds, flags in ((("code",), elf.PF_R | elf.PF_X), (("rodata",), elf.PF_R),
							 (("data", "bss"), elf.PF_R | elf.PF_W)):
			chosen = [s for s in pick(kinds) if s.size or not s.nobits]
			if chosen:
				segments.append((elf.PT_LOAD, flags, chosen[0].addr, chosen))
		tls = pick(("data", "tbss"))
		tls = [s for s in tls if s.flags & elf.SHF_TLS]
		if tls:
			segments.append((elf.PT_TLS, elf.PF_R, tls[0].addr, tls))

		index = {s.name: i + 1 for i, s in enumerate(sections)}
		symbols = []
		for addr, name, is_global in self.symbol_table():
			shndx = elf.SHN_ABS
			for s in sections:
				if s.addr <= addr < s.addr + s.size:
					shndx = index[s.name]
			symbols.append(elf.Symbol(name, addr, shndx,
									  elf.STB_GLOBAL if is_global else elf.STB_LOCAL))
		symbols.sort(key=lambda s: s.bind != elf.STB_LOCAL)
		entry = self.provided.get(self.entry_name)
		if self.entry_name in self.globals:
			obj, sym = self.globals[self.entry_name]
			entry = self.value(obj, obj.symbols.index(sym))
		return elf.write_executable(entry or 0, sections, symbols, segments)

	def output(self):
		return self.executable() if self.layout == "exec" else self.flat_image()


def link(paths, layout="exec", base=None, data=None, ram_limit=None, entry=None):
	"""Links the files: returns (the output bytes, the map text). Raises
	LinkErrors."""
	linker = Linker(layout, base, data, ram_limit, entry)
	linker.run(paths)
	out = linker.output()
	linker.check()
	return out, linker.map_text()


def auto_int(text):
	return int(text, 0)


def main(argv=None):
	p = argparse.ArgumentParser(prog="ld.py", description="WRM.081632 linker", epilog=__doc__,
								formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("inputs", nargs="+", metavar="FILE", help="object files and ar archives")
	p.add_argument("-o", "--output", help="output file (default: a.out)")
	p.add_argument("--layout", choices=sorted(LAYOUTS), default="exec",
				   help="what to make (default: %(default)s)")
	p.add_argument("--base", type=auto_int,
				   help="address of the image (default: 0x10000 boot, 0xFE000000 rom, "
						"0x400000 exec)")
	p.add_argument("--data", type=auto_int,
				   help="rom: RAM address where .data runs (default: 0x2000)")
	p.add_argument("--ram-limit", type=auto_int,
				   help="rom: .data and .bss must end below this RAM address")
	p.add_argument("--entry", help="exec: the entry point (default: _start)")
	p.add_argument("--map", help="write the sections and symbols, an address and a name a line")
	args = p.parse_args(argv)

	try:
		out, map_text = link(args.inputs, args.layout, args.base, args.data, args.ram_limit,
							 args.entry)
	except LinkErrors as e:
		for line in e.errors:
			print(line, file=sys.stderr)
		return 1
	output = args.output or "a.out"
	with open(output, "wb") as f:
		f.write(out)
	if args.map:
		with open(args.map, "w", encoding="utf-8") as f:
			f.write(map_text)
	print(f"{output}: {len(out)} bytes")
	return 0


if __name__ == "__main__":
	sys.exit(main())
