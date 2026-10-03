// Video card: setup, text and the screen console.
//
// The CPU can't reach VRAM: everything goes through the drawing engine.
// The font (../console/font.m) is loaded by DMA from ROM into the end of VRAM once,
// and a character is then one EXPAND command from there (a glyph cache,
// as on the 2D accelerators of the 90s).
//
// The screen console uses 640x480, 8 bpp. Its width leaves room for the
// current BMP at the upper right, so scrolling does not move the image.

import {
    video, VIDEO_DONE, VIDEO_ENABLE, VIDEO_640X480, VIDEO_8BPP,
    VIDEO_FILL, VIDEO_COPY, VIDEO_EXPAND, VIDEO_LOAD, VRAM_SIZE,
} from "../arch/wrm081632/defs.m"
import { FontData, FONT } from "../console/font.m"
import { BmpInfo, bmpInfo, bmpDraw } from "bmp.m"
import { logoBmp, logoBmpEnd } from "logo.m"

let CON_MODE: UWord = VIDEO_640X480 | VIDEO_8BPP
let CON_PITCH: UWord = 640
let LOGO_MARGIN: UWord = 8
let LOGO_PALETTE0: UWord = 208
let LOGO_PALETTE1: UWord = 15
let CON_ROWS: UWord = 30
let CON_FG: UWord = 7               // palette entries
let CON_BG: UWord = 0

// the font stays at the end of VRAM, past the frame of any mode
let FONT_VRAM: UWord = VRAM_SIZE - sizeof(FontData)
let FONT_SIZE: UWord = sizeof(FontData)
let GLYPH_SIZE: UWord = 16 << 16 | 8

let VGA_COLORS: UWord[16] = [
    0x000000, 0x0000AA, 0x00AA00, 0x00AAAA,
    0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
    0x555555, 0x5555FF, 0x55FF55, 0x55FFFF,
    0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF,
]
let CUBE_LEVELS: UWord[6] = [0, 95, 135, 175, 215, 255]

// the console cursor, in characters
let mut conX: UWord
let mut conY: UWord
let mut conCols: UWord

/// Console mode, palette, font, cleared screen, display on.
let videoInit(): Bool {
    video.control = 0               // display off while it is set up
    video.mode = CON_MODE
    video.start = 0
    videoPalette()

    let data: *UByte = &logoBmp
    let length: UWord = (&logoBmpEnd as UWord) - (data as UWord)
    let mut info: BmpInfo = {}
    if !bmpInfo(data, length, &mut info) return false
    if info.width > CON_PITCH - 2 * LOGO_MARGIN return false
    if info.height > 480 - LOGO_MARGIN return false
    let logoX: UWord = CON_PITCH - info.width - LOGO_MARGIN
    conCols = logoX / 8

    if videoLoad(&FONT as UWord, FONT_VRAM, FONT_SIZE) != 0 return false
    conClear()
    if !bmpDraw(data, length, logoX, LOGO_MARGIN,
                LOGO_PALETTE0, LOGO_PALETTE1) return false
    video.control = VIDEO_ENABLE
    return true
}

/// The 16 VGA colours, then the xterm 6x6x6 colour cube (16-231) and grey
/// ramp (232-255).
let videoPalette(): Void {
    video.paletteIndex = 0          // each write to DATA moves to the next entry
    for i: UWord in 0..16 video.paletteData = VGA_COLORS[i]
    for r: UWord in 0..6 {
        for g: UWord in 0..6 {
            for b: UWord in 0..6 {
                video.paletteData = CUBE_LEVELS[r] << 16 | CUBE_LEVELS[g] << 8 | CUBE_LEVELS[b]
            }
        }
    }
    for i: UWord in 0..24 {
        let grey: UWord = 8 + 10 * i
        video.paletteData = grey << 16 | grey << 8 | grey
    }
}

/// Copies RAM or ROM into VRAM by DMA and waits for it by polling STATUS.
/// Returns ERROR, 0 on success.
let videoLoad(address: UWord, offset: UWord, count: UWord): UWord {
    video.address = address
    video.dstBase = offset
    video.count = count
    video.command = VIDEO_LOAD
    while video.status & VIDEO_DONE == 0 {}
    return video.error
}

/// Draws a character of the font on the destination surface, which
/// DST_BASE and DST_PITCH already describe. flags: VIDEO_TRANSPARENT or 0.
let videoGlyph(c: UByte, xy: UWord, fg: UWord, bg: UWord, flags: UWord): Void {
    video.srcBase = FONT_VRAM + (c as UWord) * 16
    video.srcPitch = 1              // a byte per line of the glyph
    video.srcXY = 0
    video.size = GLYPH_SIZE
    video.dstXY = xy
    video.fg = fg
    video.bg = bg
    video.command = flags | VIDEO_EXPAND    // done at once
}

/// Draws a zero-terminated string on one line, like videoGlyph.
let videoText(s: *UByte, xy: UWord, fg: UWord, bg: UWord, flags: UWord): Void {
    let mut i: UWord = 0
    while s[i] != 0 {
        videoGlyph(s[i], xy + 8 * i, fg, bg, flags)     // x is the low half of DST_XY
        i++
    }
}

// ---- the screen console --------------------------------------------------

/// Clears the console and puts the cursor at the top left.
let conClear(): Void {
    video.dstBase = 0
    video.dstPitch = CON_PITCH
    video.dstXY = 0
    video.size = CON_ROWS * 16 << 16 | CON_PITCH
    video.fg = CON_BG
    video.command = VIDEO_FILL
    conX = 0
    conY = 0
}

/// '\n' starts a new line, anything else is a glyph.
let conPutc(c: UByte): Void {
    if c == '\n' {
        conNewline()
        return
    }
    video.dstBase = 0
    video.dstPitch = CON_PITCH
    videoGlyph(c, conX * 8 | conY * 16 << 16, CON_FG, CON_BG, 0)
    conX++
    if conX >= conCols conNewline()
}

/// Moves the cursor to the next line, scrolling up by a line at the bottom
/// of the screen.
let conNewline(): Void {
    conX = 0
    if conY + 1 < CON_ROWS {
        conY++
        return
    }
    // the cursor stays on the last line
    video.srcBase = 0
    video.dstBase = 0
    video.srcPitch = CON_PITCH
    video.dstPitch = CON_PITCH
    video.srcXY = 16 << 16          // from the second line...
    video.dstXY = 0                 // ...to the first
    video.size = (CON_ROWS - 1) * 16 << 16 | conCols * 8
    video.command = VIDEO_COPY
    video.dstXY = (CON_ROWS - 1) * 16 << 16     // then clear the last line
    video.size = 16 << 16 | conCols * 8
    video.fg = CON_BG
    video.command = VIDEO_FILL
}

let conPuts(s: *UByte): Void {
    let mut i: UWord = 0
    while s[i] != 0 {
        conPutc(s[i])
        i++
    }
}

export { videoInit, videoPalette, videoLoad, videoGlyph, videoText,
         conClear, conPutc, conPuts }
