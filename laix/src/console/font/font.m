import { WORD_BYTES, GLYPH_HEIGHT, GLYPH_BYTES, CELL_WIDTH, GLYPH_WIDTH,
    UNICODE_MAX, UNICODE_SURROGATE_MIN, UNICODE_SURROGATE_MAX, UNICODE_REPLACEMENT } from "../../arch/wrm081632/defs.m"
// LAF1: little-endian header, sorted Unicode index, 16x16 bitmap slots.
// Only the index is resident; bitmap sectors follow the boot payload on disk.
let FONT_MAGIC: UWord = 0x3146414C
let FONT_VERSION: UWord = 1
type FontHeader {
    magic: UWord,
    version: UWord,
    count: UWord,
    indexOffset: UWord,
    pixelsOffset: UWord,
    height: UWord,
    glyphBytes: UWord,
    reserved: UWord,
}
type Glyph {
    code: UWord,
    advance: UWord,
}
type Font {
    count: UWord,
    index: *Glyph,
    fallback: UWord,
}
let mut font: Font

// Returns font.count when the Unicode code has no glyph.
let glyphIndex(code: UWord): UWord {
    let mut low: UWord = 0
    let mut high: UWord = font.count
    while low < high {
        let mid: UWord = low + (high - low) / 2
        let current: UWord = font.index[mid].code
        if current < code low = mid + 1
        else if current > code high = mid
        else return mid
    }
    return font.count
}

let loadFont(data: *UByte, size: UWord): Bool {
    font.count = 0
    font.index = null
    font.fallback = 0
    if size < sizeof(FontHeader) || (data as UWord) & (WORD_BYTES - 1) != 0 return false
    let header: *FontHeader = data as *FontHeader
    if header.magic != FONT_MAGIC || header.version != FONT_VERSION return false
    let count: UWord = header.count
    // Bound multiplication before checking offsets and total size.
    if count == 0 || count > (size - sizeof(FontHeader)) / sizeof(Glyph) return false
    let pixelsOffset: UWord = sizeof(FontHeader) + count * sizeof(Glyph)
    if header.indexOffset != sizeof(FontHeader) || header.pixelsOffset != pixelsOffset return false
    if header.height != GLYPH_HEIGHT || header.glyphBytes != GLYPH_BYTES || header.reserved != 0 return false
    if size != pixelsOffset return false
    let index: *Glyph = &data[sizeof(FontHeader)] as *Glyph
    for i: UWord in 0..count {
        let code: UWord = index[i].code
        if code > UNICODE_MAX || (code >= UNICODE_SURROGATE_MIN && code <= UNICODE_SURROGATE_MAX) return false
        if i > 0 && index[i - 1].code >= code return false
        if index[i].advance != CELL_WIDTH && index[i].advance != GLYPH_WIDTH return false
    }
    font.count = count
    font.index = index
    font.fallback = glyphIndex(UNICODE_REPLACEMENT)
    if font.fallback == count font.fallback = glyphIndex('?' as UWord)
    if font.fallback == count {
        font.count = 0
        font.index = null
        return false
    }
    return true
}

export { Glyph, Font, font, loadFont, glyphIndex }
