#!/usr/bin/env python3
"""Pack all glyphs from Unifont HEX into the indexed LA/IX LAF1 format."""

import argparse
from pathlib import Path
import struct

MAGIC = b'LAF1'
HEADER = struct.Struct('<4s7I')
ENTRY = struct.Struct('<II')
HEIGHT = 16
STRIDE = 32
MAX_GLYPHS = 0x110000 - 0x800  # All Unicode scalar values, independent of VRAM.


def pack(text):
    glyphs = {}
    for line_no, row in enumerate(text.splitlines(), 1):
        if not row.strip():
            continue
        try:
            code_text, bitmap = row.strip().split(':')
            code = int(code_text, 16)
            if not 0 <= code <= 0x10FFFF or 0xD800 <= code <= 0xDFFF:
                raise ValueError('not a Unicode scalar value')
            if code in glyphs:
                raise ValueError(f'duplicate U+{code:04X}')
            if len(bitmap) not in (32, 64) or any(c not in '0123456789abcdefABCDEF' for c in bitmap):
                raise ValueError('expected 16 rows of 8 or 16 pixels')
            pixels = bytes.fromhex(bitmap)
            width = len(pixels) // 2
            if width == 8:
                pixels = b''.join(bytes((byte, 0)) for byte in pixels)
            glyphs[code] = (width, pixels)
        except ValueError as e:
            raise ValueError(f'line {line_no}: {e}') from e
    if not glyphs or len(glyphs) > MAX_GLYPHS:
        raise ValueError(f'expected 1..{MAX_GLYPHS} glyphs')
    if 0xFFFD not in glyphs and 63 not in glyphs:
        raise ValueError('font needs U+FFFD or U+003F as a missing-glyph fallback')
    ordered = sorted(glyphs.items())
    pixels_offset = HEADER.size + len(ordered) * ENTRY.size
    header = HEADER.pack(MAGIC, 1, len(ordered), HEADER.size, pixels_offset, HEIGHT, STRIDE, 0)
    index = b''.join(ENTRY.pack(code, glyph[0]) for code, glyph in ordered)
    pixels = b''.join(glyph[1] for _, glyph in ordered)
    return header + index + pixels


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Unifont HEX file')
    parser.add_argument('output', type=Path, help='indexed binary font (.laf)')
    parser.add_argument('--index', type=Path, help='also write just the header and index for the kernel')
    args = parser.parse_args()
    try:
        data = pack(args.source.read_text(encoding='utf-8'))
        args.output.write_bytes(data)
        if args.index is not None:
            pixels_offset = HEADER.unpack_from(data)[4]
            args.index.write_bytes(data[:pixels_offset])
    except (OSError, ValueError) as e:
        parser.exit(1, f'pack_unifont: {e}\n')


if __name__ == '__main__':
    main()
