// Syntax error: comparisons don't chain (expressions.m)
// @error 6: comparisons don't chain

let main(argc: UWord, argv: *UByte[]): Word {
    let b: UWord = 5
    if 0 < b < 10 return 1
    return 0
}
