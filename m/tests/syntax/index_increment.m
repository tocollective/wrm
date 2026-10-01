// Syntax error: 'buf[i++]' (expressions.m)
// @error 7: '++' is a statement and has no value

let main(argc: UWord, argv: *UByte[]): Word {
    let mut buf: UByte[4]
    let mut i: UWord = 0
    buf[i++] = 0
    return 0
}
