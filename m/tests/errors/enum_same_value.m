// Error: enums.m: same value twice
// @error 4: 'B' has the same value as 'A' (1)

enum Bad: UByte { A = 1, B = 1 }

let main(argc: UWord, argv: *UByte[]): Word {
    if Bad.A == Bad.B return 1
    return 0
}
