// Warning: the result of a built-in function is lost
// @warning 6: the result of 'atomicSwap' is lost

let main(argc: UWord, argv: *UByte[]): Word {
    let mut l: UWord = 0
    atomicSwap(&mut l, 1)
    return 0
}
