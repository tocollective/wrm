// Literals:
//   - integers: decimal, 0x... and 0b...; '_' may go between digits;
//     no octal, and a decimal number cannot start with 0
//   - an integer literal has no type until the context gives one
//   - a constant expression of literals is computed exactly, and the result
//     must fit in the type of the context
//   - 'a' is a UByte
//   - source files are UTF-8, but characters and strings may contain only
//     ASCII; other bytes are written as '\xNN'
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

    let upper: UByte = a - 'a' + 'A'  // 'A'
}

let strings(): Void {
    puts("Hello, M!\n")
    puts("tab\tquote\" backslash\\\n")

    // Bytes outside ASCII are written as \xNN. The video font is
    // Windows-1252, so this shows "café" on the screen.
    puts("caf\xE9\n")

    // Compile error: non-ASCII character in a string
    //     puts("café\n")
}

let main(argc: UWord, argv: *UByte[]): Word {
    integers()
    characters()
    strings()
    return 0
}

// Test directives (m/tests/run.py)
// @output "Hello, M!\ntab\tquote\" backslash\\\ncaf\xE9\n"
// @exit 0
