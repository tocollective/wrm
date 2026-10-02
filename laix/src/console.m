import { VIDEO_BASE, VIDEO_BUSY, VIDEO_ENABLE, VIDEO_MODE_640_480, VIDEO_8BPP,
    VIDEO_XY_SHIFT, VIDEO_FILL, VIDEO_COPY, VIDEO_EXPAND, SCREEN_WIDTH, SCREEN_HEIGHT,
    CELL_WIDTH, GLYPH_HEIGHT, GLYPH_BYTES, GLYPH_ROW_BYTES, PALETTE_BLACK, PALETTE_WHITE,
    PALETTE_BACKGROUND, PALETTE_FOREGROUND, UNICODE_MAX, UNICODE_SURROGATE_MIN,
    UNICODE_SURROGATE_MAX, UNICODE_REPLACEMENT, DECIMAL_BASE, HEX_TOP_SHIFT,
    HEX_DIGIT_BITS, HEX_DIGIT_MASK } from "defs.m"
let SCREEN_COLUMNS: UWord = SCREEN_WIDTH / CELL_WIDTH
let SCREEN_ROWS: UWord = SCREEN_HEIGHT / GLYPH_HEIGHT
let SCROLL_HEIGHT: UWord = SCREEN_HEIGHT - GLYPH_HEIGHT
let VIDEO_RESERVED_WORDS: UWord = 4
let FORMAT_TOKEN_BYTES: UWord = 2
let UTF8_TWO_BYTE_CONTINUATIONS: UWord = 1
let UTF8_THREE_BYTE_CONTINUATIONS: UWord = 2
let UTF8_FOUR_BYTE_CONTINUATIONS: UWord = 3
let UTF8_TWO_BYTE_MIN: UWord = 0xC2
let UTF8_TWO_BYTE_MAX: UWord = 0xDF
let UTF8_TWO_BYTE_MASK: UWord = 0x1F
let UTF8_TWO_BYTE_CODE_MIN: UWord = 0x80
let UTF8_THREE_BYTE_MIN: UWord = 0xE0
let UTF8_THREE_BYTE_MAX: UWord = 0xEF
let UTF8_THREE_BYTE_MASK: UWord = 0x0F
let UTF8_THREE_BYTE_CODE_MIN: UWord = 0x800
let UTF8_FOUR_BYTE_MIN: UWord = 0xF0
let UTF8_FOUR_BYTE_MAX: UWord = 0xF4
let UTF8_FOUR_BYTE_MASK: UWord = 0x07
let UTF8_FOUR_BYTE_CODE_MIN: UWord = 0x10000
let UTF8_CONTINUATION_MIN: UWord = 0x80
let UTF8_CONTINUATION_MAX: UWord = 0xBF
let UTF8_CONTINUATION_BITS: UWord = 6
let UTF8_CONTINUATION_MASK: UWord = (1 << UTF8_CONTINUATION_BITS) - 1
let FLOAT_SIGN_BIT: UWord = 0x80000000
let FLOAT_MAGNITUDE_MASK: UWord = 0x7FFFFFFF
let FLOAT_INFINITY: UWord = 0x7F800000
let FLOAT_DIGITS: UWord = 6
let FLOAT_DIGIT_SCALE: UWord = 100000
let FLOAT_ROUND_LIMIT: UWord = FLOAT_DIGIT_SCALE * DECIMAL_BASE
let FLOAT_ROUND_SCALE: Float = 100000.0
let FLOAT_DECIMAL_BASE: Float = 10.0
let FLOAT_FIXED_MIN_EXPONENT: Word = -4
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
    reserved: UWord[VIDEO_RESERVED_WORDS],
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

let video: *volatile mut Video = VIDEO_BASE as *volatile mut Video
let mut column: UWord
let mut row: UWord
let mut outputFailed: Bool

let consoleInit(): Bool {
    while video.status & VIDEO_BUSY != 0 {}
    video.control = 0
    video.mode = VIDEO_MODE_640_480 | VIDEO_8BPP
    video.start = 0
    video.paletteIndex = 0
    video.paletteData = PALETTE_BLACK
    video.paletteData = PALETTE_WHITE

    video.dstBase = 0
    video.dstPitch = SCREEN_WIDTH
    video.dstXY = 0
    video.size = SCREEN_HEIGHT << VIDEO_XY_SHIFT | SCREEN_WIDTH
    video.fg = PALETTE_BACKGROUND
    video.command = VIDEO_FILL
    if video.error != 0 return false

    let fontSize: UWord = (&fontDataEnd as UWord) - (&fontData as UWord)
    if !loadFont(&fontData, fontSize) return false
    if video.vramSize < CACHE_BASE + CACHE_BYTES return false
    if !glyphCacheInit(font.count) return false

    column = 0
    row = 0
    outputFailed = false
    video.control = VIDEO_ENABLE
    return true
}

let newline(): Void {
    column = 0
    if row < SCREEN_ROWS - 1 {
        row++
        return
    }
    // COPY supports overlap, so scroll by one character row.
    video.dstBase = 0
    video.dstPitch = SCREEN_WIDTH
    video.dstXY = 0
    video.srcBase = 0
    video.srcPitch = SCREEN_WIDTH
    video.srcXY = GLYPH_HEIGHT << VIDEO_XY_SHIFT
    video.size = SCROLL_HEIGHT << VIDEO_XY_SHIFT | SCREEN_WIDTH
    video.command = VIDEO_COPY
    video.dstXY = SCROLL_HEIGHT << VIDEO_XY_SHIFT
    video.size = GLYPH_HEIGHT << VIDEO_XY_SHIFT | SCREEN_WIDTH
    video.fg = PALETTE_BACKGROUND
    video.command = VIDEO_FILL
}

let putChar(c: UWord): Void {
    if outputFailed return
    if c == ('\n' as UWord) {
        newline()
        return
    }
    if c == ('\r' as UWord) {
        column = 0
        return
    }
    let mut glyph: UWord = glyphIndex(c)
    if glyph == font.count glyph = font.fallback
    let advance: UWord = font.index[glyph].advance
    while video.status & VIDEO_BUSY != 0 {}
    let slot: UWord = cacheGlyph(glyph)
    if slot == CACHE_GLYPHS {
        outputFailed = true
        return
    }
    let cells: UWord = advance / CELL_WIDTH
    if column + cells > SCREEN_COLUMNS newline()
    video.dstBase = 0
    video.dstPitch = SCREEN_WIDTH
    video.dstXY = row * GLYPH_HEIGHT << VIDEO_XY_SHIFT | column * CELL_WIDTH
    video.srcBase = CACHE_BASE + slot * GLYPH_BYTES
    video.srcPitch = GLYPH_ROW_BYTES
    video.srcXY = 0
    video.size = GLYPH_HEIGHT << VIDEO_XY_SHIFT | advance
    video.fg = PALETTE_FOREGROUND
    video.bg = PALETTE_BACKGROUND
    video.command = VIDEO_EXPAND
    column += cells
    if column == SCREEN_COLUMNS newline()
}

let consoleFailed(): Bool { return outputFailed }

// Decode one UTF-8 code point; return the next byte offset.
let printNext(text: *UByte, offset: UWord): UWord {
    let mut i: UWord = offset
    let first: UWord = text[i] as UWord
    i++
    let mut code: UWord = first
    let mut extra: UWord = 0
    let mut minimum: UWord = 0
    if first >= UTF8_TWO_BYTE_MIN && first <= UTF8_TWO_BYTE_MAX {
        code = first & UTF8_TWO_BYTE_MASK
        extra = UTF8_TWO_BYTE_CONTINUATIONS
        minimum = UTF8_TWO_BYTE_CODE_MIN
    } else if first >= UTF8_THREE_BYTE_MIN && first <= UTF8_THREE_BYTE_MAX {
        code = first & UTF8_THREE_BYTE_MASK
        extra = UTF8_THREE_BYTE_CONTINUATIONS
        minimum = UTF8_THREE_BYTE_CODE_MIN
    } else if first >= UTF8_FOUR_BYTE_MIN && first <= UTF8_FOUR_BYTE_MAX {
        code = first & UTF8_FOUR_BYTE_MASK
        extra = UTF8_FOUR_BYTE_CONTINUATIONS
        minimum = UTF8_FOUR_BYTE_CODE_MIN
    } else if first >= UTF8_CONTINUATION_MIN {
        code = UNICODE_REPLACEMENT
    }
    let mut good: Bool = true
    for n: UWord in 0..extra {
        let next: UWord = text[i] as UWord
        if next < UTF8_CONTINUATION_MIN || next > UTF8_CONTINUATION_MAX {
            good = false
            break
        }
        code = code << UTF8_CONTINUATION_BITS | (next & UTF8_CONTINUATION_MASK)
        i++
    }
    if !good || code < minimum || code > UNICODE_MAX || (code >= UNICODE_SURROGATE_MIN && code <= UNICODE_SURROGATE_MAX) code = UNICODE_REPLACEMENT
    putChar(code)
    return i
}

let printText(text: *UByte): Void {
    let mut i: UWord = 0
    while !outputFailed && text[i] != 0 i = printNext(text, i)
}

let waitFrame(): Void {
    if outputFailed return
    // Scanout happens at the next frame. Wait before the caller can HLT.
    let frame: UWord = video.frame
    while video.frame == frame {}
}

let print(text: *UByte): Void {
    printText(text)
    waitFrame()
}

let printUnsigned(value: UWord): Void {
    let mut divisor: UWord = 1
    while value / divisor >= DECIMAL_BASE divisor *= DECIMAL_BASE
    let mut rest: UWord = value
    while divisor != 0 {
        putChar(('0' as UWord) + rest / divisor)
        rest %= divisor
        divisor /= DECIMAL_BASE
    }
}

let printInteger(value: Word): Void {
    let mut magnitude: UWord = value as UWord
    if value < 0 {
        putChar('-' as UWord)
        // Unsigned negation also handles Word's minimum (-2147483648).
        magnitude = 0 - magnitude
    }
    printUnsigned(magnitude)
}

let printHex(value: UWord): Void {
    let digits: *UByte = "0123456789ABCDEF"
    printText("0x")
    let mut shift: UWord = HEX_TOP_SHIFT
    while shift != 0 && (value >> shift & HEX_DIGIT_MASK) == 0 shift -= HEX_DIGIT_BITS
    while true {
        putChar(digits[value >> shift & HEX_DIGIT_MASK] as UWord)
        if shift == 0 break
        shift -= HEX_DIGIT_BITS
    }
}

// Six significant decimal digits, trailing zeros trimmed, at least '.0'.
// Scientific notation is used below 0.0001 and at/above 1000000.
let printFloat(number: Float): Void {
    let bits: UWord = *(&number as *UWord)
    let magnitude: UWord = bits & FLOAT_MAGNITUDE_MASK
    if magnitude > FLOAT_INFINITY {
        printText("nan")
        return
    }
    if bits & FLOAT_SIGN_BIT != 0 putChar('-' as UWord)
    if magnitude == FLOAT_INFINITY {
        printText("inf")
        return
    }
    if magnitude == 0 {
        printText("0.0")
        return
    }
    let mut value: Float = number
    if bits & FLOAT_SIGN_BIT != 0 value = -value
    let mut exponent: Word = 0
    while value >= FLOAT_DECIMAL_BASE {
        value /= FLOAT_DECIMAL_BASE
        exponent++
    }
    while value < 1.0 {
        value *= FLOAT_DECIMAL_BASE
        exponent--
    }
    let mut rounded: UWord = (value * FLOAT_ROUND_SCALE + 0.5) as UWord
    if rounded >= FLOAT_ROUND_LIMIT {
        rounded = FLOAT_DIGIT_SCALE
        exponent++
    }
    let mut digits: UByte[FLOAT_DIGITS]
    let mut divisor: UWord = FLOAT_DIGIT_SCALE
    for n: UWord in 0..FLOAT_DIGITS {
        digits[n] = (('0' as UWord) + rounded / divisor) as UByte
        rounded %= divisor
        divisor /= DECIMAL_BASE
    }
    let mut count: UWord = FLOAT_DIGITS
    while count > 1 && digits[count - 1] == '0' count--
    if exponent < FLOAT_FIXED_MIN_EXPONENT || exponent >= (FLOAT_DIGITS as Word) {
        putChar(digits[0] as UWord)
        putChar('.' as UWord)
        if count == 1 putChar('0' as UWord)
        for n: UWord in 1..count putChar(digits[n] as UWord)
        putChar('e' as UWord)
        if exponent >= 0 putChar('+' as UWord)
        printInteger(exponent)
        return
    }
    if exponent < 0 {
        printText("0.")
        for n: Word in 0..(-exponent - 1) putChar('0' as UWord)
        for n: UWord in 0..count putChar(digits[n] as UWord)
        return
    }
    let whole: UWord = (exponent + 1) as UWord
    for n: UWord in 0..whole {
        if n < count putChar(digits[n] as UWord)
        else putChar('0' as UWord)
    }
    putChar('.' as UWord)
    if count <= whole putChar('0' as UWord)
    for n: UWord in whole..count putChar(digits[n] as UWord)
}

// Each recognized placeholder consumes one argument. Missing arguments,
// unknown placeholders and a trailing $ stay literal; $$ escapes a dollar.
let prints(text: *UByte, args: ...): Void {
    let mut i: UWord = 0
    let mut argument: UWord = 0
    let count: UWord = vaCount(args)
    while !outputFailed && text[i] != 0 {
        if text[i] != '$' {
            i = printNext(text, i)
            continue
        }
        let kind: UByte = text[i + 1]
        if kind == '$' {
            putChar('$' as UWord)
            i += FORMAT_TOKEN_BYTES
            continue
        }
        if kind != 'i' && kind != 'f' && kind != 'h' && kind != 's' {
            putChar('$' as UWord)
            i++
            continue
        }
        i += FORMAT_TOKEN_BYTES
        if argument >= count {
            putChar('$' as UWord)
            putChar(kind as UWord)
            continue
        }
        switch kind {
            case 'i':
                printInteger(vaArg(args, argument, Word))
                break
            case 'f':
                printFloat(vaArg(args, argument, Float))
                break
            case 'h':
                printHex(vaArg(args, argument, UWord))
                break
            case 's': {
                let value: *UByte = vaArg(args, argument, *UByte)
                if value == null printText("(null)")
                else printText(value)
                break
            }
        }
        argument++
    }
    waitFrame()
}

export { consoleInit, putChar, print, prints, consoleFailed }
