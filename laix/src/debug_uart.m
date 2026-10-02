import { UART_BASE, HEX_WORD_DIGITS, HEX_TOP_SHIFT, HEX_DIGIT_BITS,
    HEX_DIGIT_MASK, DECIMAL_BASE } from "defs.m"
let FORMAT_MAX_WIDTH: UWord = 32
// Panic output must work before the screen, disk and allocator exist.
// WRM UART TX never blocks (docs/SPECIFICATION.md, UART).
let DEBUG_UART: *volatile mut UWord = UART_BASE as *volatile mut UWord

let debugPutChar(code: UWord): Void {
    *DEBUG_UART = code
}

let debugWriteText(text: *UByte): Void {
    let mut i: UWord = 0
    while text[i] != 0 {
        debugPutChar(text[i] as UWord)
        i++
    }
}

let debugWriteHex(value: UWord): Void {
    for i: UWord in 0..HEX_WORD_DIGITS {
        let digit: UWord = value >> (HEX_TOP_SHIFT - i * HEX_DIGIT_BITS) & HEX_DIGIT_MASK
        if digit < DECIMAL_BASE debugPutChar(('0' as UWord) + digit)
        else debugPutChar(('A' as UWord) + digit - DECIMAL_BASE)
    }
}

let debugWriteNumber(value: UWord, negative: Bool, width: UWord, zeroPad: Bool): Void {
    let mut divisor: UWord = 1
    let mut digits: UWord = 1
    while value / divisor >= DECIMAL_BASE {
        divisor *= DECIMAL_BASE
        digits++
    }
    if negative digits++
    if negative && zeroPad debugPutChar('-' as UWord)
    for i: UWord in digits..width {
        if zeroPad debugPutChar('0' as UWord)
        else debugPutChar(' ' as UWord)
    }
    if negative && !zeroPad debugPutChar('-' as UWord)
    let mut rest: UWord = value
    while divisor != 0 {
        debugPutChar(('0' as UWord) + rest / divisor)
        rest %= divisor
        divisor /= DECIMAL_BASE
    }
}

// Integer-only UART formatting: no screen, allocation or Float operations.
// $h keeps the dump's eight uppercase hex digits, without a prefix.
// Decimal widths are capped at 32; $02i zero-pads register numbers.
let debugPrint(text: *UByte, args: ...): Void {
    let mut i: UWord = 0
    let mut argument: UWord = 0
    let count: UWord = vaCount(args)
    while text[i] != 0 {
        if text[i] != '$' {
            debugPutChar(text[i] as UWord)
            i++
            continue
        }
        let start: UWord = i
        i++
        if text[i] == '$' {
            debugPutChar('$' as UWord)
            i++
            continue
        }
        let zeroPad: Bool = text[i] == '0'
        let mut width: UWord = 0
        while text[i] >= '0' && text[i] <= '9' {
            width = width * DECIMAL_BASE + (text[i] as UWord) - ('0' as UWord)
            if width > FORMAT_MAX_WIDTH width = FORMAT_MAX_WIDTH
            i++
        }
        let kind: UByte = text[i]
        let decimal: Bool = kind == 'i' || kind == 'u'
        let plain: Bool = i == start + 1 && (kind == 's' || kind == 'h')
        if !decimal && !plain || argument >= count {
            // Keep malformed or missing placeholders byte-for-byte literal.
            debugPutChar('$' as UWord)
            i = start + 1
            continue
        }
        i++
        switch kind {
            case 's': {
                let value: *UByte = vaArg(args, argument, *UByte)
                if value == null debugWriteText("(null)")
                else debugWriteText(value)
                break
            }
            case 'h':
                debugWriteHex(vaArg(args, argument, UWord))
                break
            case 'u':
                debugWriteNumber(vaArg(args, argument, UWord), false, width, zeroPad)
                break
            case 'i': {
                let value: Word = vaArg(args, argument, Word)
                let mut magnitude: UWord = value as UWord
                if value < 0 magnitude = 0 - magnitude
                debugWriteNumber(magnitude, value < 0, width, zeroPad)
                break
            }
        }
        argument++
    }
}

export { debugPutChar, debugPrint }
