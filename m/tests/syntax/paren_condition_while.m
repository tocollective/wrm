// Syntax error: the same for 'while'
// @error 6: the 'while' condition is '(n + 1)', and '* 2 > 10 ...' is not a statement

let main(argc: UWord, argv: *UByte[]): Word {
    let mut n: Word = 5
    while (n + 1) * 2 > 10 n = n - 1
    return 0
}
