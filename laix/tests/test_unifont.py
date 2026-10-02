"""Font data tests: python3 -B -m unittest discover -s laix/tests."""

import bisect
from pathlib import Path
import sys
import unittest

LAIX = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LAIX / 'tools'))
from pack_unifont import ENTRY, HEADER, pack
from append_font import append


class UnifontTests(unittest.TestCase):
    def test_rows_width_and_sorted_index(self):
        # Input deliberately unordered; narrow rows occupy the left byte.
        wide = bytes(range(32))
        narrow = bytes(range(16))
        data = pack(f'65E5:{wide.hex()}\n003F:{narrow.hex()}\n')
        self.assertEqual(HEADER.unpack_from(data), (b'LAF1', 1, 2, 32, 48, 16, 32, 0))
        self.assertEqual(ENTRY.unpack_from(data, 32), (63, 8))
        self.assertEqual(ENTRY.unpack_from(data, 40), (0x65E5, 16))
        self.assertEqual(data[48:80], b''.join(bytes((b, 0)) for b in narrow))
        self.assertEqual(data[80:], wide)

    def test_supplementary_unicode_and_replacement_fallback(self):
        pixels = '80' * 16
        data = pack(f'1F600:{pixels}\nFFFD:{pixels}\n')
        self.assertEqual(ENTRY.unpack_from(data, 32), (0xFFFD, 8))
        self.assertEqual(ENTRY.unpack_from(data, 40), (0x1F600, 8))

    def test_invalid_sources(self):
        question = '003F:' + '00' * 16
        for invalid, message in (
            ('', 'expected 1..'),
            ('0041:' + '00' * 16, 'fallback'),
            (question + '\n' + question, 'duplicate'),
            (question + '\nD800:' + '00' * 16, 'scalar'),
            (question + '\n110000:' + '00' * 16, 'scalar'),
            (question + '\n0041:ZZ' + '00' * 15, '16 rows'),
            (question + '\n0041:00', '16 rows'),
            (question + '\nnot-a-glyph', 'line 2'),
        ):
            with self.subTest(message=message):
                with self.assertRaisesRegex(ValueError, message):
                    pack(invalid)

    def test_capacity(self):
        # A disk-backed font can exceed the old whole-font VRAM budget.
        old_limit = (4 * 1024 * 1024 - 640 * 480) // 32
        codes = (code for code in range(0x110000) if not 0xD800 <= code <= 0xDFFF)
        text = '\n'.join(f'{code:X}:' + '00' * 16 for _, code in zip(range(old_limit + 1), codes))
        self.assertEqual(HEADER.unpack_from(pack(text))[2], old_limit + 1)

    def test_full_font_and_embedded_asset(self):
        source = LAIX.parent / 'vendor/SDL/test/unifont-15.1.05.hex'
        data = pack(source.read_text(encoding='utf-8'))
        self.assertEqual(data, (LAIX / 'fonts/unifont-console.laf').read_bytes())
        magic, version, count, index, pixels, height, stride, reserved = HEADER.unpack_from(data)
        self.assertEqual(data[:pixels], (LAIX / 'fonts/unifont-index.laf').read_bytes())
        self.assertEqual((magic, version, height, stride, reserved), (b'LAF1', 1, 16, 32, 0))
        self.assertGreater(count, 512)
        self.assertEqual(len(data), pixels + count * stride)
        self.assertLessEqual(640 * 480 + count * stride, 4 * 1024 * 1024)
        records = [ENTRY.unpack_from(data, index + i * ENTRY.size) for i in range(count)]
        codes = [code for code, _ in records]
        self.assertEqual(codes, sorted(set(codes)))
        original = {int(code, 16): bytes.fromhex(bitmap) for code, bitmap in
                    (row.split(':') for row in source.read_text().splitlines())}
        self.assertEqual(set(codes), set(original))
        for i, (code, width) in enumerate(records):
            bitmap = data[pixels + i * stride:pixels + (i + 1) * stride]
            if width == 8:
                self.assertEqual(bitmap[1::2], bytes(16))
                bitmap = bitmap[::2]
            else:
                self.assertEqual(width, 16)
            self.assertEqual(bitmap, original[code])
        for char in 'AéЯ尼日日本語�':
            i = bisect.bisect_left(codes, ord(char))
            self.assertEqual(codes[i], ord(char))

    def test_bitmap_sectors_are_outside_boot_payload(self):
        import struct
        # More than one bitmap page; include a partial final page.
        text = '\n'.join(f'{code:04X}:' + '80' * 16 for code in range(63, 82))
        font = pack(text)
        core = struct.pack('<4sIII', b'WRMB', 2, 16, 0) + bytes(1024 - 16)
        image = append(core, font)
        offset = HEADER.unpack_from(font)[4]
        self.assertEqual(image[:len(core)], core)
        self.assertEqual(len(image) % 512, 0)
        self.assertEqual(len(image), len(core) + 1024)
        for glyph in range(19):
            page, in_page = divmod(glyph, 16)
            address = len(core) + page * 512 + in_page * 32
            self.assertEqual(image[address:address + 32], font[offset + glyph * 32:offset + (glyph + 1) * 32])
        self.assertEqual(image[-(1024 - 19 * 32):], bytes(1024 - 19 * 32))
        with self.assertRaisesRegex(ValueError, 'already be appended'):
            append(image, font)

    def test_reject_malformed_disk_layout(self):
        import struct
        font = pack('003F:' + '00' * 16)
        core = struct.pack('<4sIII', b'WRMB', 1, 16, 0) + bytes(512 - 16)
        for image, data in ((core[:15], font), (core[:-1], font),
                            (b'FAIL' + core[4:], font), (core, font[:-1]),
                            (core, b'FAIL' + font[4:]), (core, font[:31])):
            with self.subTest(image_size=len(image), font_size=len(data)):
                with self.assertRaises(ValueError):
                    append(image, data)
