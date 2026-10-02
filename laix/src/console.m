// Standalone screen console: 640x480, 8 bpp, 80x30 cells; indexed Unifont.
import { font, loadFont, glyphIndex } from "font/font.m"
import { fontData, fontDataEnd } from "font/data.m"
import { CACHE_BASE, CACHE_BYTES, CACHE_GLYPHS, glyphCacheInit, cacheGlyph } from "font/glyph_cache.m"

// Video MMIO layout from docs/SPECIFICATION.md (Video card).
type Video {
    status: UWord,
    control: UWord,
    mode: UWord,
    width: UWord,
    height: UWord,
    bpp: UWord,
    pitch: UWord,
    vramSize: UWord,
    start: UWord,
    frame: UWord,
    paletteIndex: UWord,
    paletteData: UWord,
    reserved: UWord[4],
    command: UWord,
    error: UWord,
    dstBase: UWord,
    dstPitch: UWord,
    dstXY: UWord,
    srcBase: UWord,
    srcPitch: UWord,
    srcXY: UWord,
    size: UWord,
    fg: UWord,
    bg: UWord,
    address: UWord,
    count: UWord,
}

let video: *volatile mut Video = 0xFD007000 as *volatile mut Video
let FILL: UWord = 1
let COPY: UWord = 2
let EXPAND: UWord = 3
let mut column: UWord
let mut row: UWord
let mut outputFailed: Bool

let consoleInit(): Bool {
    while video.status & 1 != 0 {}
    video.control = 0
    video.mode = 0x21            // 640x480, 8 bpp
    video.start = 0
    video.paletteIndex = 0
    video.paletteData = 0x000000
    video.paletteData = 0xFFFFFF

    video.dstBase = 0
    video.dstPitch = 640
    video.dstXY = 0
    video.size = 480 << 16 | 640
    video.fg = 0
    video.command = FILL
    if video.error != 0 return false

    let fontSize: UWord = (&fontDataEnd as UWord) - (&fontData as UWord)
    if !loadFont(&fontData, fontSize) return false
    if video.vramSize < CACHE_BASE + CACHE_BYTES return false
    if !glyphCacheInit(font.count) return false

    column = 0
    row = 0
    outputFailed = false
    video.control = 1
    return true
}

let newline(): Void {
    column = 0
    if row < 29 {
        row++
        return
    }
    // COPY supports overlap, so scroll by one character row.
    video.dstBase = 0
    video.dstPitch = 640
    video.dstXY = 0
    video.srcBase = 0
    video.srcPitch = 640
    video.srcXY = 16 << 16
    video.size = 464 << 16 | 640
    video.command = COPY
    video.dstXY = 464 << 16
    video.size = 16 << 16 | 640
    video.fg = 0
    video.command = FILL
}

let putChar(c: UWord): Void {
    if outputFailed return
    if c == 10 {
        newline()
        return
    }
    if c == 13 {
        column = 0
        return
    }
    let mut glyph: UWord = glyphIndex(c)
    if glyph == font.count glyph = font.fallback
    let advance: UWord = font.index[glyph].advance
    while video.status & 1 != 0 {}
    let slot: UWord = cacheGlyph(glyph)
    if slot == CACHE_GLYPHS {
        outputFailed = true
        return
    }
    let cells: UWord = advance / 8
    if column + cells > 80 newline()
    video.dstBase = 0
    video.dstPitch = 640
    video.dstXY = row * 16 << 16 | column * 8
    video.srcBase = CACHE_BASE + slot * 32
    video.srcPitch = 2
    video.srcXY = 0
    video.size = 16 << 16 | advance
    video.fg = 1
    video.bg = 0
    video.command = EXPAND
    column += cells
    if column == 80 newline()
}

let consoleFailed(): Bool { return outputFailed }

let print(text: *UByte): Void {
    if outputFailed return
    let mut i: UWord = 0
    while text[i] != 0 {
        let first: UWord = text[i] as UWord
        i++
        let mut code: UWord = first
        let mut extra: UWord = 0
        let mut minimum: UWord = 0
        if first >= 0xC2 && first <= 0xDF {
            code = first & 0x1F
            extra = 1
            minimum = 0x80
        } else if first >= 0xE0 && first <= 0xEF {
            code = first & 0x0F
            extra = 2
            minimum = 0x800
        } else if first >= 0xF0 && first <= 0xF4 {
            code = first & 7
            extra = 3
            minimum = 0x10000
        } else if first >= 0x80 {
            code = 0xFFFD
        }
        let mut good: Bool = true
        for n: UWord in 0..extra {
            let next: UWord = text[i] as UWord
            if next < 0x80 || next > 0xBF {
                good = false
                break 
            }
            code = code << 6 | (next & 0x3F)
            i++
        }
        if !good || code < minimum || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF) code = 0xFFFD
        putChar(code)
        if outputFailed return
    }
    // Scanout happens at the next frame. Wait before the caller can HLT.
    let frame: UWord = video.frame
    while video.frame == frame {}
}

export { consoleInit, putChar, print, consoleFailed }
