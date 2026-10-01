// Error: a struct literal with an unknown field
// @error 7: 'Color' has no field 'a'

type Color { r: UByte, g: UByte, b: UByte }

let main(argc: UWord, argv: *UByte[]): Word {
    let c: Color = { .a = 1 }
    if c.r == 0 return 1
    return 0
}
