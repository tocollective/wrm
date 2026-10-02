// Runtime test: build as a boot payload, then append_font.py before booting.
// It exercises cache hits, page boundaries, FIFO eviction and index fallback.
// @exit 0
import { font, loadFont, glyphIndex } from "../src/font/font.m"
import { fontData, fontDataEnd } from "../src/font/data.m"
import { CACHE_BASE, CACHE_GLYPHS, glyphCacheInit, cacheGlyph } from "../src/font/glyph_cache.m"
import { BOOT_INFO, BOOT_FIELD_DISK, WORD_BYTES, VRAM_BASE, DISK_CHANGED } from "../src/defs.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let size: UWord = (&fontDataEnd as UWord) - (&fontData as UWord)
    if !loadFont(&fontData, size) || !glyphCacheInit(font.count) return 1
    // Also boot this test via Drag & Drop: init must consume the insertion
    // event, otherwise every subsequent cacheGlyph fails with CHANGED.
    let info: *UWord = BOOT_INFO as *UWord
    let status: *volatile UWord = info[BOOT_FIELD_DISK / WORD_BYTES] as *volatile UWord
    if *status & DISK_CHANGED != 0 return 15
    if cacheGlyph(0) != 0 || cacheGlyph(15) != 15 return 2
    if cacheGlyph(16) != 16 return 3
    let vram: *volatile UWord = (VRAM_BASE + CACHE_BASE) as *volatile UWord
    // U+0000 starts with bytes AA AA 00 01, padded nowhere (16 pixels).
    if vram[0] != 0x0100AAAA return 4
    for page: UWord in 2..16 {
        if cacheGlyph(page * 16) != page * 16 return 5
    }
    if cacheGlyph(256) != 0 return 6       // evicts the oldest page
    if cacheGlyph(16) != 16 return 7      // hits must not move FIFO cursor
    if cacheGlyph(0) != 16 return 8       // page 0 reloads, evicting page 1
    if vram[128] != 0x0100AAAA return 9
    if cacheGlyph(font.count) != CACHE_GLYPHS return 10
    if cacheGlyph(0xFFFFFFFF) != CACHE_GLYPHS return 11
    let last: UWord = cacheGlyph(font.count - 1)
    if last == CACHE_GLYPHS return 12      // padded partial final page
    if cacheGlyph(glyphIndex(0x5C3C)) == CACHE_GLYPHS return 13
    if cacheGlyph(glyphIndex(0x65E5)) == CACHE_GLYPHS return 14
    return 0
}
