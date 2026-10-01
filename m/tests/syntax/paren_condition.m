// Syntax error: a condition that only starts with '(' (if.m, 8.3)
// @error 6: the 'if' condition is '(n + 1)', and '* 2 > 10 ...' is not a statement

let main(argc: UWord, argv: *UByte[]): Word {
    let n: Word = 5
    if (n + 1) * 2 > 10 return 1
    return 0
}
