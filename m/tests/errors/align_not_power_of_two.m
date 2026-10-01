// Error: align(N): a power of two
// @error 4: the alignment must be a power of two, not 12

align(12) let mut buf: UByte[16]

let main(argc: UWord, argv: *UByte[]): Word {
    buf[0] = 1
    return 0
}
