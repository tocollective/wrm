// Error: a field name twice
// @error 6: field 'x' is already in 'P'

type P {
    x: UWord,
    x: UWord,
}

let main(argc: UWord, argv: *UByte[]): Word {
    if sizeof(P) == 0 return 1
    return 0
}
