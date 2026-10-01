// Error: an integer doesn't become Bool with 'as'
// @error 5: 'UWord' can't be converted to 'Bool': compare it

let main(argc: UWord, argv: *UByte[]): Word {
    let b: Bool = argc as Bool
    if b return 1
    return 0
}
