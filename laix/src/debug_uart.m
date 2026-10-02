// Panic output must work before the screen, disk and allocator exist.
// WRM UART TX never blocks (docs/SPECIFICATION.md, UART).
let DEBUG_UART: *volatile mut UWord = 0xFD002000 as *volatile mut UWord

let debugPutChar(code: UWord): Void {
    *DEBUG_UART = code
}

let debugPrint(text: *UByte): Void {
    let mut i: UWord = 0
    while text[i] != 0 {
        debugPutChar(text[i] as UWord)
        i++
    }
}

let debugHex(value: UWord): Void {
    for i: UWord in 0..8 {
        let digit: UWord = value >> (28 - i * 4) & 15
        if digit < 10 debugPutChar(48 + digit)
        else debugPutChar(65 + digit - 10)
    }
}

export { debugPutChar, debugPrint, debugHex }
