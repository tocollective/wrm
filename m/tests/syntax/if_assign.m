// Syntax error: an assignment is not a condition (expressions.m)
// @error 6: the 'if' condition is 'i', and a statement can't start with '='

let main(argc: UWord, argv: *UByte[]): Word {
    let mut i: UWord = 0
    if i = 0 i++
    return 0
}
