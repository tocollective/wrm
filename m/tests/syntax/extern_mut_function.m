// Syntax error: there is no 'extern let mut f()'
// @error 4: there is no 'extern let mut onTick(...)'

extern let mut onTick(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    return 0
}
