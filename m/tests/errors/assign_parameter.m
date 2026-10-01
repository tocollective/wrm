// Error: parameters are immutable
// @error 5: 'n' is a parameter, and parameters can't be changed

let f(n: UWord): UWord {
    n = 2
    return n
}

let main(argc: UWord, argv: *UByte[]): Word {
    if f(1) == 0 return 1
    return 0
}
