// Error: 'syscall' arguments are words and pointers
// @error 6: a 'syscall' argument must be Word, UWord or a pointer, not 'UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let b: UByte = 1
    if syscall(1, b) < 0 return 1
    return 0
}
