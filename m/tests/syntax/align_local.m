// Syntax error: 'align' only on global variables (layout.m)
// @error 5: 'align' is only for global variables

let main(argc: UWord, argv: *UByte[]): Word {
    align(16) let mut local: UByte[64]
    return 0
}
