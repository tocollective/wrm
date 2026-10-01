// Syntax error: 'a = b = 0' (expressions.m)
// @error 7: a statement can't start with '='

let main(argc: UWord, argv: *UByte[]): Word {
    let mut a: UWord = 1
    let mut b: UWord = 1
    a = b = 0
    return 0
}
