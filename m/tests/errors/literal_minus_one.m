// Error: literals.m: the value does not fit
// @error 5: -1 doesn't fit in 'UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let y: UByte = -1
    return 0
}
