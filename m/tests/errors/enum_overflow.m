// Error: enums.m: B would be 256
// @error 4: 'B' would be 256, which doesn't fit in 'UByte'

enum Big: UByte { A = 255, B }

let main(argc: UWord, argv: *UByte[]): Word {
    if Big.A == Big.B return 1
    return 0
}
