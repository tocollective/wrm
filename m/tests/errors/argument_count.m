// Error: the number of arguments
// @error 7: 'f' takes 1 argument, found 2

let f(a: UWord): Void {}

let main(argc: UWord, argv: *UByte[]): Word {
    f(1, 2)
    return 0
}
