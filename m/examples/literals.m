// Literals:
//   - integers: decimal, 0x... and 0b...; '_' may go between digits;
//     no octal, and a decimal number cannot start with 0
//   - an integer literal has no type until the context gives one
//   - a constant expression of literals is computed exactly, and the result
//     must fit in the type of the context
//   - ASCII and escaped byte characters are UByte; non-ASCII characters
//     written directly are UWord Unicode codes ('д' = 0x0434)
//   - strings encode Unicode characters as UTF-8; character literals
//     contain one Unicode code or an escaped byte
//   - "..." is a zero-terminated array of bytes in .rodata, of type *UByte

import { puts } from "externs.m"

let integers(): Void {
    // The type comes from the variable
    let a: UByte = 0xFF
    let b: Word = -42
    let c: UHalf = 0xAAAA
    let d: UWord = 4096

    // Bases and '_'
    let mask: UWord = 0b1010_1010
    let uartBase: UWord = 0xFD00_2000
    let million: UWord = 1_000_000

    // ...or from the other operand
    let e: UByte = a + 1            // 1 is a UByte here; the sum wraps to 0x00

    // Constant expressions are exact, only the result must fit
    let f: UByte = 300 - 100        // 200
    let g: UWord = 1 << 31
    let h: Byte = -128

    // Compile errors: the value does not fit
    //     let x: UByte = 300
    //     let y: UByte = -1
    //     let z: UByte = 0x10 *| 0x10   // 256: saturation happens only at run time
    //     let w: Byte = 128
    //     let o: UWord = 010             // leading zero: not octal, just an error
    //     let u: UWord = 0x_FF           // '_' only between digits
}

let characters(): Void {
    let a: UByte = 'a'              // 0x61
    let nl: UByte = '\n'            // 0x0A
    let zero: UByte = '\0'          // 0x00
    let quote: UByte = '\''
    let backslash: UByte = '\\'
    let esc: UByte = '\x1B'
    let cyrillic: UWord = 'д'       // 0x0434
    let accented: UWord = 'é'       // 0x00E9, not a UTF-8 byte
    let emoji: UWord = '😀'         // 0x1F600

    let upper: UByte = a - 'a' + 'A'  // 'A'
}

let strings(): Void {
    puts("Hello, M!\n")
    puts("tab\tquote\" backslash\\\n")

    // Raw bytes can be written as \xNN. The video font is Windows-1252,
    // so this shows "café" on the screen.
    puts("caf\xE9\n")

    // UTF-8 bytes, for output to a UTF-8 terminal through the UART.
    puts("café\n")
    puts("Привет 日本語 😀\n")
}

let main(argc: UWord, argv: *UByte[]): Word {
    integers()
    characters()
    strings()
    return 0
}

// Test directives (m/tests/run.py)
// @output "Hello, M!\ntab\tquote\" backslash\\\ncaf\xE9\ncaf\xC3\xA9\n"
// @output "\xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82 \xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E \xF0\x9F\x98\x80\n"
// @exit 0
