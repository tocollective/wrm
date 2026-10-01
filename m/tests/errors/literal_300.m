// Error: literals.m: the value does not fit
// @error 5: 300 doesn't fit in 'UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UByte = 300
    return 0
}
