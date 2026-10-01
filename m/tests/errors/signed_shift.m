// Error: the shift amount is unsigned
// @error 6: the shift amount must be an unsigned integer, not 'Word'

let main(argc: UWord, argv: *UByte[]): Word {
    let n: Word = 1
    let x: UWord = argc << n
    if x == 0 return 1
    return 0
}
