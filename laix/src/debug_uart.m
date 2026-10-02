// Panic output must work before the screen, disk and allocator exist.
// WRM UART TX never blocks (docs/SPECIFICATION.md, UART).
let DEBUG_UART: *volatile mut UWord = 0xFD002000 as *volatile mut UWord

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
    for i: UWord in 0..8 {
        let digit: UWord = value >> (28 - i * 4) & 15
        if digit < 10 debugPutChar(48 + digit)
        else debugPutChar(65 + digit - 10)
    }
}

let debugWriteNumber(value: UWord, negative: Bool, width: UWord, zeroPad: Bool): Void {
    let mut divisor: UWord = 1
    let mut digits: UWord = 1
    while value / divisor >= 10 {
        divisor *= 10
        digits++
    }
    if negative digits++
    if negative && zeroPad debugPutChar(45)
    for i: UWord in digits..width {
        if zeroPad debugPutChar(48)
        else debugPutChar(32)
    }
    if negative && !zeroPad debugPutChar(45)
    let mut rest: UWord = value
    while divisor != 0 {
        debugPutChar(48 + rest / divisor)
        rest %= divisor
        divisor /= 10
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
            debugPutChar(36)
            i++
            continue
        }
        let zeroPad: Bool = text[i] == '0'
        let mut width: UWord = 0
        while text[i] >= '0' && text[i] <= '9' {
            width = width * 10 + (text[i] as UWord) - 48
            if width > 32 width = 32
            i++
        }
        let kind: UByte = text[i]
        let decimal: Bool = kind == 'i' || kind == 'u'
        let plain: Bool = i == start + 1 && (kind == 's' || kind == 'h')
        if !decimal && !plain || argument >= count {
            // Keep malformed or missing placeholders byte-for-byte literal.
            debugPutChar(36)
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
