// Error: arrays.m: 5 elements do not fit in UByte[4]
// @error 5: 5 elements don't fit in 'UByte[4]'

let main(argc: UWord, argv: *UByte[]): Word {
    let tooMany: UByte[4] = [1, 2, 3, 4, 5]
    return 0
}
