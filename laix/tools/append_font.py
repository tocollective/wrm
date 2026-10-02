#!/usr/bin/env python3
"""Append font bitmap sectors after the WRMB boot payload, without loading them at boot."""

import argparse
from pathlib import Path
import struct

from pack_unifont import HEADER, MAGIC


def append(image, font):
    if len(image) < 16:
        raise ValueError('truncated boot header')
    magic, sectors, entry, flags = struct.unpack_from('<4sIII', image)
    if magic != b'WRMB' or not sectors or flags or entry & 3 or entry >= sectors * 512:
        raise ValueError('invalid WRMB boot header')
    if len(image) != sectors * 512:
        raise ValueError('boot payload must match WRMB sector count; font may already be appended')
    if len(font) < HEADER.size:
        raise ValueError('truncated font header')
    magic, version, count, index, pixels, height, stride, reserved = HEADER.unpack_from(font)
    if (magic != MAGIC or version != 1 or not count or index != 32 or pixels != 32 + count * 8
            or height != 16 or stride != 32 or reserved or len(font) != pixels + count * stride):
        raise ValueError('invalid LAF1 font')
    # These bytes are not covered by WRMB.sectors. The kernel reads them on demand.
    bitmaps = font[pixels:]
    return image + bitmaps + bytes(-len(bitmaps) % 512)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('font', type=Path)
    args = parser.parse_args()
    try:
        data = append(args.image.read_bytes(), args.font.read_bytes())
        args.image.write_bytes(data)
    except (OSError, ValueError) as e:
        parser.exit(1, f'append_font: {e}\n')


if __name__ == '__main__':
    main()
