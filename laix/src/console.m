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

// Decode one UTF-8 code point; return the next byte offset.
let printNext(text: *UByte, offset: UWord): UWord {
    let mut i: UWord = offset
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
    while value / divisor >= 10 divisor *= 10
    let mut rest: UWord = value
    while divisor != 0 {
        putChar(48 + rest / divisor)
        rest %= divisor
        divisor /= 10
    }
}

let printInteger(value: Word): Void {
    let mut magnitude: UWord = value as UWord
    if value < 0 {
        putChar(45)
        // Unsigned negation also handles Word's minimum (-2147483648).
        magnitude = 0 - magnitude
    }
    printUnsigned(magnitude)
}

let printHex(value: UWord): Void {
    let digits: *UByte = "0123456789ABCDEF"
    printText("0x")
    let mut shift: UWord = 28
    while shift != 0 && (value >> shift & 15) == 0 shift -= 4
    while true {
        putChar(digits[value >> shift & 15] as UWord)
        if shift == 0 break
        shift -= 4
    }
}

// Six significant decimal digits, trailing zeros trimmed, at least '.0'.
// Scientific notation is used below 0.0001 and at/above 1000000.
let printFloat(number: Float): Void {
    let bits: UWord = *(&number as *UWord)
    let magnitude: UWord = bits & 0x7FFFFFFF
    if magnitude > 0x7F800000 {
        printText("nan")
        return
    }
    if bits & 0x80000000 != 0 putChar(45)
    if magnitude == 0x7F800000 {
        printText("inf")
        return
    }
    if magnitude == 0 {
        printText("0.0")
        return
    }
    let mut value: Float = number
    if bits & 0x80000000 != 0 value = -value
    let mut exponent: Word = 0
    while value >= 10.0 {
        value /= 10.0
        exponent++
    }
    while value < 1.0 {
        value *= 10.0
        exponent--
    }
    let mut rounded: UWord = (value * 100000.0 + 0.5) as UWord
    if rounded >= 1000000 {
        rounded = 100000
        exponent++
    }
    let mut digits: UByte[6]
    let mut divisor: UWord = 100000
    for n: UWord in 0..6 {
        digits[n] = (48 + rounded / divisor) as UByte
        rounded %= divisor
        divisor /= 10
    }
    let mut count: UWord = 6
    while count > 1 && digits[count - 1] == '0' count--
    if exponent < -4 || exponent >= 6 {
        putChar(digits[0] as UWord)
        putChar(46)
        if count == 1 putChar(48)
        for n: UWord in 1..count putChar(digits[n] as UWord)
        putChar(101)
        if exponent >= 0 putChar(43)
        printInteger(exponent)
        return
    }
    if exponent < 0 {
        printText("0.")
        for n: Word in 0..(-exponent - 1) putChar(48)
        for n: UWord in 0..count putChar(digits[n] as UWord)
        return
    }
    let whole: UWord = (exponent + 1) as UWord
    for n: UWord in 0..whole {
        if n < count putChar(digits[n] as UWord)
        else putChar(48)
    }
    putChar(46)
    if count <= whole putChar(48)
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
            putChar(36)
            i += 2
            continue
        }
        if kind != 'i' && kind != 'f' && kind != 'h' && kind != 's' {
            putChar(36)
            i++
            continue
        }
        i += 2
        if argument >= count {
            putChar(36)
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
