// Error: 'syscall' takes at most 6 arguments
// @error 5: 'syscall' takes 1 to 7 arguments, found 8

let main(argc: UWord, argv: *UByte[]): Word {
    if syscall(1, 1, 2, 3, 4, 5, 6, 7) < 0 return 1
    return 0
}
