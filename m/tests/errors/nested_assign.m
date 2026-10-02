// Error: a nested function without 'mut' is a function, not a variable
// @error 7: 'f' is a function, not a variable

let main(argc: UWord, argv: *UByte[]): Word {
    let f(): Void {}
    let g(): Void {}
    f = g
    f()
    return 0
}
