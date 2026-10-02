// Syntax error: 'align' is only for global variables, also not for 'let mut f()'
// @error 4: 'align' is only for global variables, not for functions

align(16) let mut onTick(): Void {}

let main(argc: UWord, argv: *UByte[]): Word {
    onTick()
    onTick = null
    return 0
}
