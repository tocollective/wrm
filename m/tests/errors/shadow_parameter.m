// Error: a local can't take a parameter name
// @error 5: 'n' is a parameter

let f(n: UWord): UWord {
    let n: UWord = 2
    return n
}

let main(argc: UWord, argv: *UByte[]): Word {
    if f(1) == 0 return 1
    return 0
}
