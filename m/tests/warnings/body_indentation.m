// Warning: a body on its own line with the same indentation
// @warning 6: the body of 'if' is on its own line with the same indentation

let f(n: UWord): Void {
    if n > 0
    f(n - 1)
}

let main(argc: UWord, argv: *UByte[]): Word {
    f(1)
    return 0
}
