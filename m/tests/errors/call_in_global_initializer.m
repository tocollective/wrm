// Error: globals.m: a function call is not a constant
// @error 11: a function call is not a constant expression

type Color { r: UByte, g: UByte, b: UByte }

let makeBlue(): Color {
    let c: Color = { .b = 0xFF }
    return c
}

let BLUE: Color = makeBlue()

let main(argc: UWord, argv: *UByte[]): Word {
    if BLUE.b == 0 return 1
    return 0
}
