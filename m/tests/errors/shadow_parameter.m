// Error: the parameters and the body of a function are one block, as in C:
// a local of the body itself can't take a parameter name
// @error 5: 'n' is a parameter

let f(n: UWord): UWord {
    let n: UWord = 2
    return n
}

let main(argc: UWord, argv: *UByte[]): Word {
    if f(1) == 0 return 1
    return 0
}
