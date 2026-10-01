// Syntax error: an expression that is not a call
// @error 6: 'x + 1' is not a statement

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UWord = 1
    x + 1
    return 0
}
