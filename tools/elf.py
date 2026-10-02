"""ELF32 files of WRM.081632 (docs/ABI.md, "Object files" and
"Executables"): the relocatable files tools/asm.py writes and
tools/ld.py reads, and the executables ld.py writes. Only what these
tools use; ar archives too, for ld.py.
"""

import struct

EM_WRM = 0x0816
ET_REL, ET_EXEC = 1, 2

SHT_NULL, SHT_PROGBITS, SHT_SYMTAB, SHT_STRTAB, SHT_RELA, SHT_NOBITS = 0, 1, 2, 3, 4, 8
SHF_WRITE, SHF_ALLOC, SHF_EXECINSTR, SHF_INFO_LINK, SHF_TLS = 0x1, 0x2, 0x4, 0x40, 0x400

STB_LOCAL, STB_GLOBAL, STB_WEAK = 0, 1, 2
STT_NOTYPE, STT_OBJECT, STT_FUNC, STT_SECTION, STT_FILE, STT_TLS = 0, 1, 2, 3, 4, 6
SHN_UNDEF, SHN_ABS = 0, 0xFFF1

PT_LOAD, PT_TLS = 1, 7
PF_X, PF_W, PF_R = 1, 2, 4

PAGE_SIZE = 0x1000

RELOCATIONS = [
	"R_WRM_NONE", "R_WRM_32", "R_WRM_HI19", "R_WRM_LO13", "R_WRM_ABS14",
	"R_WRM_PCREL_HI19", "R_WRM_PCREL_LO13", "R_WRM_BRANCH14", "R_WRM_JAL19",
	"R_WRM_TPREL14", "R_WRM_TPREL_HI19", "R_WRM_TPREL_LO13",
]
R = {name: number for number, name in enumerate(RELOCATIONS)}

EHDR = struct.Struct("<16sHHIIIIIHHHHHH")   # 52 bytes
SHDR = struct.Struct("<IIIIIIIIII")         # 40 bytes
PHDR = struct.Struct("<IIIIIIII")           # 32 bytes
SYM = struct.Struct("<IIIBBH")              # 16 bytes
RELA = struct.Struct("<IIi")                # 12 bytes
IDENT = b"\x7fELF" + bytes([1, 1, 1, 0]) + bytes(8)  # ELFCLASS32, LSB, EV_CURRENT


class ElfError(Exception):
	pass


class Section:
	"""A section: data is None for SHT_NOBITS, which has only a size.
	relocs are (offset, type, symbol index, addend)."""

	def __init__(self, name, type=SHT_PROGBITS, flags=SHF_ALLOC, align=1, data=None, size=0):
		self.name = name
		self.type = type
		self.flags = flags
		self.align = align
		self.data = data if data is not None or type == SHT_NOBITS else bytearray()
		self.size = size if data is None else len(data)
		self.relocs = []
		self.addr = 0  # executables

	@property
	def nobits(self):
		return self.type == SHT_NOBITS


class Symbol:
	"""shndx is the index of the section (1 is the first after the null
	one), SHN_UNDEF or SHN_ABS."""

	def __init__(self, name, value=0, shndx=SHN_UNDEF, bind=STB_LOCAL, type=STT_NOTYPE, size=0):
		self.name = name
		self.value = value
		self.shndx = shndx
		self.bind = bind
		self.type = type
		self.size = size


class StringTable:
	def __init__(self):
		self.data = bytearray(b"\0")
		self.offsets = {"": 0}

	def add(self, text):
		if text not in self.offsets:
			self.offsets[text] = len(self.data)
			self.data += text.encode("utf-8") + b"\0"
		return self.offsets[text]


def align_up(n, align):
	return (n + align - 1) // align * align if align > 1 else n


def _pack_symbols(symbols, strtab):
	out = bytearray(SYM.size)  # the null symbol
	for s in symbols:
		out += SYM.pack(strtab.add(s.name), s.value & 0xFFFFFFFF, s.size,
						s.bind << 4 | s.type, 0, s.shndx)
	return out


def _write(e_type, sections, symbols, entry=0, segments=()):
	"""The file: header, program headers, the sections' bytes, the symbol
	and string tables, section headers. sections are those after the null
	one, in index order; symbols those after the null symbol, the locals
	first. Executables put each loaded section at an offset that is its
	address modulo the page size."""
	shstrtab, strtab = StringTable(), StringTable()
	headers = []  # (name, type, flags, addr, offset, size, link, info, align, entsize)
	out = bytearray(EHDR.size + PHDR.size * len(segments))

	def place(data, align, addr=None):
		if addr is not None and e_type == ET_EXEC:
			pad = (addr - len(out)) % PAGE_SIZE
		else:
			pad = (-len(out)) % max(align, 1)
		out.extend(bytes(pad))
		offset = len(out)
		out.extend(data)
		return offset

	offsets = []
	for s in sections:
		if s.nobits:
			offsets.append(len(out))
		else:
			offsets.append(place(bytes(s.data), s.align, s.addr if s.flags & SHF_ALLOC else None))

	n_sections = len(sections)
	rela = [(i, s) for i, s in enumerate(sections) if s.relocs]
	symtab_index = 1 + n_sections + len(rela)
	strtab_index = symtab_index + 1
	shstrtab_index = strtab_index + 1

	for i, s in enumerate(sections):
		size = s.size if s.nobits else len(s.data)
		headers.append((shstrtab.add(s.name), s.type, s.flags, s.addr, offsets[i], size, 0, 0,
						max(s.align, 1), 0))
	for i, s in rela:
		data = b"".join(RELA.pack(off, sym << 8 | rtype, addend) for off, rtype, sym, addend in s.relocs)
		offset = place(data, 4)
		headers.append((shstrtab.add(".rela" + s.name), SHT_RELA, SHF_INFO_LINK, 0, offset, len(data),
						symtab_index, i + 1, 4, RELA.size))
	first_global = 1 + sum(1 for s in symbols if s.bind == STB_LOCAL)
	symdata = _pack_symbols(symbols, strtab)
	offset = place(symdata, 4)
	headers.append((shstrtab.add(".symtab"), SHT_SYMTAB, 0, 0, offset, len(symdata), strtab_index,
					first_global, 4, SYM.size))
	offset = place(strtab.data, 1)
	headers.append((shstrtab.add(".strtab"), SHT_STRTAB, 0, 0, offset, len(strtab.data), 0, 0, 1, 0))
	name = shstrtab.add(".shstrtab")
	offset = place(shstrtab.data, 1)
	headers.append((name, SHT_STRTAB, 0, 0, offset, len(shstrtab.data), 0, 0, 1, 0))

	shoff = place(b"", 4)
	out += SHDR.pack(*([0] * 10))
	for h in headers:
		out += SHDR.pack(*h)

	phoff = EHDR.size if segments else 0
	for i, seg in enumerate(segments):
		p_type, flags, addr, sections_in = seg
		loaded = [sections.index(s) for s in sections_in]
		file_start = offsets[loaded[0]] if loaded else 0
		file_end = max([offsets[j] + len(sections[j].data) for j in loaded if not sections[j].nobits]
					   or [file_start])
		mem_end = max([sections[j].addr + sections[j].size for j in loaded] or [addr])
		align = PAGE_SIZE if p_type == PT_LOAD else max([sections[j].align for j in loaded] or [1])
		PHDR.pack_into(out, EHDR.size + i * PHDR.size, p_type, file_start, addr, addr,
					   file_end - file_start, mem_end - addr, flags, align)

	EHDR.pack_into(out, 0, IDENT, e_type, EM_WRM, 1, entry, phoff, shoff, 0, EHDR.size,
				   PHDR.size if segments else 0, len(segments), SHDR.size, len(headers) + 1,
				   shstrtab_index)
	return bytes(out)


def write_relocatable(sections, symbols):
	"""An ET_REL file. Relocations name symbols by index: 0 is the null
	symbol, 1 the first of symbols."""
	return _write(ET_REL, sections, symbols)


def write_executable(entry, sections, symbols, segments):
	"""An ET_EXEC file. segments are (p_type, p_flags, vaddr, [sections]),
	the sections in address order."""
	return _write(ET_EXEC, sections, symbols, entry, segments)


class ObjectFile:
	"""A relocatable file as read: sections by index (0 is None for the
	null one; tables and relocations are left out), symbols by index (0 is
	the null symbol)."""

	def __init__(self, name):
		self.name = name
		self.sections = [None]
		self.symbols = [Symbol("")]


def read_object(data, name):
	"""Reads an ET_REL file of this machine; raises ElfError."""
	if len(data) < EHDR.size or data[:4] != b"\x7fELF":
		raise ElfError(f"{name}: not an ELF file")
	(ident, e_type, machine, _, _, _, shoff, _, _, _, _, shentsize, shnum,
	 shstrndx) = EHDR.unpack_from(data)
	if ident[4] != 1 or ident[5] != 1:
		raise ElfError(f"{name}: not a 32-bit little-endian ELF file")
	if machine != EM_WRM:
		raise ElfError(f"{name}: an ELF file for machine 0x{machine:X}, not WRM.081632")
	if e_type != ET_REL:
		raise ElfError(f"{name}: not a relocatable file")
	if shentsize != SHDR.size or shoff + shnum * SHDR.size > len(data):
		raise ElfError(f"{name}: bad section headers")
	headers = [SHDR.unpack_from(data, shoff + i * SHDR.size) for i in range(shnum)]

	def string(table, offset):
		h = headers[table]
		start = h[4] + offset
		end = data.index(b"\0", start)
		return data[start:end].decode("utf-8", "replace")

	obj = ObjectFile(name)
	symtab = None
	for i, h in enumerate(headers[1:], 1):
		sh_name, sh_type, flags, _, offset, size, link, info, align, _ = h
		section_name = string(shstrndx, sh_name)
		if sh_type == SHT_SYMTAB:
			symtab = h
		if sh_type in (SHT_PROGBITS, SHT_NOBITS):
			body = None if sh_type == SHT_NOBITS else bytearray(data[offset:offset + size])
			section = Section(section_name, sh_type, flags, max(align, 1), body, size)
			section.index = i
			obj.sections.append(section)
		else:
			obj.sections.append(None)
	if symtab:
		_, _, _, _, offset, size, link, _, _, _ = symtab
		for j in range(1, size // SYM.size):
			st_name, value, st_size, info, _, shndx = SYM.unpack_from(data, offset + j * SYM.size)
			obj.symbols.append(Symbol(string(link, st_name), value, shndx, info >> 4, info & 0xF,
									  st_size))
	for h in headers[1:]:
		sh_name, sh_type, _, _, offset, size, link, info, _, _ = h
		if sh_type != SHT_RELA:
			continue
		target = obj.sections[info] if info < len(obj.sections) else None
		if target is None:
			continue
		for j in range(size // RELA.size):
			r_offset, r_info, addend = RELA.unpack_from(data, offset + j * RELA.size)
			target.relocs.append((r_offset, r_info & 0xFF, r_info >> 8, addend))
	return obj


def read_archive(data, name):
	"""The members of an ar archive (System V/GNU or BSD names) as
	[(member name, bytes)], symbol tables left out; raises ElfError."""
	if not data.startswith(b"!<arch>\n"):
		raise ElfError(f"{name}: not an ar archive")
	members, pos, long_names = [], 8, b""
	while pos + 60 <= len(data):
		header = data[pos:pos + 60]
		raw_name = header[:16].decode("ascii", "replace").rstrip()
		size = int(header[48:58].decode("ascii").strip() or 0)
		body = data[pos + 60:pos + 60 + size]
		pos += 60 + size + (size & 1)
		if raw_name in ("/", "/SYM64/", "__.SYMDEF", "__.SYMDEF SORTED"):
			continue
		if raw_name == "//":
			long_names = body
			continue
		if raw_name.startswith("#1/"):  # BSD: the name starts the body
			length = int(raw_name[3:])
			member = body[:length].rstrip(b"\0").decode("utf-8", "replace")
			body = body[length:]
		elif raw_name.startswith("/") and raw_name[1:].isdigit():  # GNU: in //
			start = int(raw_name[1:])
			end = long_names.index(b"/\n", start)
			member = long_names[start:end].decode("utf-8", "replace")
		else:
			member = raw_name.rstrip("/")
		if member in ("__.SYMDEF", "__.SYMDEF SORTED"):
			continue
		members.append((member, bytes(body)))
	return members
