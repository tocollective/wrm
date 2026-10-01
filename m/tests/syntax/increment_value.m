// Syntax error: '++' has no value (expressions.m)
// @error 6: '++' is a statement and has no value

let main(argc: UWord, argv: *UByte[]): Word {
    let mut i: UWord = 0
    let j: UWord = i++
    return 0
}
