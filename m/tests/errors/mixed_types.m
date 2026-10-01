// Error: arith.m: UByte + UWord
// @error 7: '+' needs both operands of one type, found 'UByte' and 'UWord'

let main(argc: UWord, argv: *UByte[]): Word {
    let a: UByte = 200
    let b: UWord = 1000
    let e: UWord = a + b
    return 0
}
