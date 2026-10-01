// Error: order.m: 'b' is not declared yet
// @error 5: 'b' is not declared

let main(argc: UWord, argv: *UByte[]): Word {
    let a: UWord = b
    let b: UWord = 1
    if a == b return 1
    return 0
}
