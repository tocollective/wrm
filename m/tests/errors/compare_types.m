// Error: comparison of different types
// @error 6: '==' needs both operands of one type, found 'UByte' and 'UWord'

let main(argc: UWord, argv: *UByte[]): Word {
    let b: UByte = 1
    if b == argc return 1
    return 0
}
