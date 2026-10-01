// Error: only functions can be called
// @error 5: 'argc' is 'UWord', not a function

let main(argc: UWord, argv: *UByte[]): Word {
    argc()
    return 0
}
