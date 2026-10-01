// Error: enums.m: C = 1 is B again
// @error 4: 'C' has the same value as 'B' (1)

enum Bad2: UByte { A, B, C = 1 }

let main(argc: UWord, argv: *UByte[]): Word {
    if Bad2.A == Bad2.C return 1
    return 0
}
