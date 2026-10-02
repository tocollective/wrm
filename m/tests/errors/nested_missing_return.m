// Error: a function literal with a result can't reach '}'
// @error 5: the function literal can reach its end without 'return'

let main(argc: UWord, argv: *UByte[]): Word {
    let f: (n: UWord): UWord = (n: UWord): UWord {
        if n > 0 return 1
    }
    return f(1) as Word
}
