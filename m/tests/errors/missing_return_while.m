// Error: 'while' with 'break' can end
// @error 4: 'f' can reach its end without 'return'

let f(n: UWord): UWord {
    while true {
        if n > 0 break
    }
}

let main(argc: UWord, argv: *UByte[]): Word {
    if f(1) == 0 return 1
    return 0
}
