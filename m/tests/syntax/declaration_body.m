// Syntax error: a declaration as the body without braces
// @error 5: a declaration can't be the body

let main(argc: UWord, argv: *UByte[]): Word {
    if argc > 0 let x: UWord = 1
    return 0
}
