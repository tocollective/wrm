// Initializers:
//   - fields are separated by commas, the last comma is optional
//   - fields that are not named are zero, like in C; '{}' is all zeros
//   - 'let mut x: T' without '=' has no initial value: whatever was on the stack
//   - 'let x: T' without '=' and without 'mut' is an error: it could never get
//     a value

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

let colorRed(): Color {
    // One line, no trailing comma
    let c: Color = { .r = 0xFF, .g = 0x00, .b = 0x00 }
    return c
}

let colorGreen(): Color {
    // One field per line, trailing comma allowed
    let c: Color = {
        .r = 0x00,
        .g = 0xFF,
        .b = 0x00,
    }
    return c
}

let colorBlue(): Color {
    // .r and .g are not named, so they are 0x00
    let c: Color = { .b = 0xFF }
    return c
}

let colorBlack(): Color {
    let c: Color = {}  // all fields are 0x00
    return c
}

let buffers(): Void {
    // No '=': no initial value. Use it for buffers that are written
    // before they are read, to skip zeroing them.
    let mut buf: UByte[256]
    for i: UWord in 0..256 buf[i] = 0x20

    let mut c: Color
    c = colorBlue()

    // Compile error: 'let' without 'mut' and without '=' never gets a value
    //     let x: UWord
}

// Compile error: missing commas
//     let c: Color = { .r = 0x00 .g = 0x00 .b = 0xFF }
//     let c: Color = {
//         .r = 0x00
//         .g = 0x00
//     }

let main(argc: UWord, argv: *UByte[]): Word {
    let red: Color = colorRed()
    let green: Color = colorGreen()
    let blue: Color = colorBlue()
    let black: Color = colorBlack()
    buffers()
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
