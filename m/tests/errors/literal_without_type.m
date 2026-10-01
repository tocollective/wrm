// Error: a literal without a type from its context
// @error 6: the type of this literal is unknown

let main(argc: UWord, argv: *UByte[]): Word {
    let n: UWord = 3
    let b: Bool = (1 << n) == argc
    if b return 1
    return 0
}
