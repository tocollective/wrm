`unifont-console.laf` contains all 57,084 glyphs from GNU Unifont 15.1.05:
`vendor/SDL/test/unifont-15.1.05.hex`. No source-text subsetting is performed.
GNU Unifont is by Roman Czyborra, Paul Hardy and contributors.
The SIL Open Font License 1.1 is included in `LICENSE-Unifont.txt`.

Regenerate the font data (without compiling the kernel):

```sh
python3 -B laix/tools/pack_unifont.py vendor/SDL/test/unifont-15.1.05.hex laix/fonts/unifont-console.laf --index laix/fonts/unifont-index.laf
```

LAF1 is little-endian. Its 32-byte header contains eight 32-bit words:

| Byte offset | Value |
| --- | --- |
| 0 | Magic `LAF1` (`0x3146414C`) |
| 4 | Version: 1 |
| 8 | Glyph count: N |
| 12 | Index offset: 32 |
| 16 | Bitmap offset: 32 + N × 8 |
| 20 | Height: 16 |
| 24 | Bitmap slot size: 32 bytes |
| 28 | Reserved: 0 |

The index has N entries in strictly increasing Unicode order. Each entry
is two 32-bit words: Unicode scalar value and horizontal advance (8 or 16).
Entry i refers to bitmap slot i. The file ends after N bitmap slots;
its exact size is 32 + N × 40 bytes. U+FFFD or U+003F is required for fallback.

Each bitmap slot is 16 rows of two bytes, MSB first, left byte first.
An 8-pixel glyph uses the left byte of every row; the right byte is zero.
A 16-pixel glyph preserves the original two-byte rows. Bitmaps are
otherwise unchanged; no rasterizer is required at runtime.

The bundled file covers the glyphs available in the BMP source, not all
Unicode. The format also accepts supplementary-plane glyphs supplied in
another HEX file. The packer rejects invalid scalar values, duplicate codes,
malformed bitmaps and absent fallback. Font size is independent of the VRAM
cache capacity.

`unifont-index.laf` contains only the header and index: the prefix ending
at the bitmap offset. This is the part included in the kernel. The full
LAF1 remains the source for `tools/append_font.py`, which appends only the
bitmap section (padded to 512 bytes) to the boot disk image.
The WRMB sector count still describes only the kernel payload; the first
bitmap sector is at `BootInfo.imageSize / 512`. Glyph i belongs to bitmap
sector i / 16 at byte offset (i % 16) × 32. The kernel caches sixteen
512-byte bitmap pages in VRAM and replaces them in FIFO order.
