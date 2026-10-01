// Error: literals.m: the value does not fit
// @error 5: 128 doesn't fit in 'Byte'

let main(argc: UWord, argv: *UByte[]): Word {
    let w: Byte = 128
    return 0
}
