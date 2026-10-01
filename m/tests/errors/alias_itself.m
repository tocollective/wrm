// Error: an alias that refers to itself
// @error 4: type 'A' refers to itself

type A = *A

let main(argc: UWord, argv: *UByte[]): Word {
    if sizeof(A) == 0 return 1
    return 0
}
