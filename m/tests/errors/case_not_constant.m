// Error: a 'case' label is a constant
// @error 7: a 'case' label must be a constant

let main(argc: UWord, argv: *UByte[]): Word {
    let mut n: UWord = 1
    switch argc {
        case n:
            return 1
    }
    return 0
}
