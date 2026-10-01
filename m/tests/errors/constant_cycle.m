// Error: order.m: a cycle between constants
// @error 4: the value of 'A' depends on itself

let A: UWord = B
let B: UWord = A

let main(argc: UWord, argv: *UByte[]): Word {
    if A == 0 return 1
    return 0
}
