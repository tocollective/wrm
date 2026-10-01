// Error: bitwise operators are not defined for Float
// @error 6: '|' is not defined for Float

let main(argc: UWord, argv: *UByte[]): Word {
    let a: Float = 1.5
    let b: Float = a | a
    if b == 0.0 return 1
    return 0
}
