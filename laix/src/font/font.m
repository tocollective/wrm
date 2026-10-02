// LAF1: little-endian header, sorted Unicode index, 16x16 bitmap slots.
// Only the index is resident; bitmap sectors follow the boot payload on disk.
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
    if size < 32 || (data as UWord) & 3 != 0 return false
    let header: *UWord = data as *UWord
    if header[0] != 0x3146414C || header[1] != 1 return false
    let count: UWord = header[2]
    // Bound multiplication before checking offsets and total size.
    if count == 0 || count > (size - 32) / 8 return false
    let pixelsOffset: UWord = 32 + count * 8
    if header[3] != 32 || header[4] != pixelsOffset return false
    if header[5] != 16 || header[6] != 32 || header[7] != 0 return false
    if size != pixelsOffset return false
    let index: *Glyph = &data[32] as *Glyph
    for i: UWord in 0..count {
        let code: UWord = index[i].code
        if code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) return false
        if i > 0 && index[i - 1].code >= code return false
        if index[i].advance != 8 && index[i].advance != 16 return false
    }
    font.count = count
    font.index = index
    font.fallback = glyphIndex(0xFFFD)
    if font.fallback == count font.fallback = glyphIndex(63)
    if font.fallback == count {
        font.count = 0
        font.index = null
        return false
    }
    return true
}

export { Glyph, Font, font, loadFont, glyphIndex }
