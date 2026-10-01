// Error: a struct literal needs a type
// @error 5: a struct literal needs a struct type

let main(argc: UWord, argv: *UByte[]): Word {
    let b: Bool = { .x = 1 } == argc
    if b return 1
    return 0
}
