// Error: a function with a result can't reach '}'
// @error 4: 'f' can reach its end without 'return'

let f(n: UWord): UWord {
    if n > 0 return 1
}

let main(argc: UWord, argv: *UByte[]): Word {
    if f(1) == 0 return 1
    return 0
}
