// Error: align(N): not below the natural alignment
// @error 4: the alignment 2 is less than the natural alignment of 'UWord[4]' (4)

align(2) let mut buf: UWord[4]

let main(argc: UWord, argv: *UByte[]): Word {
    buf[0] = 1
    return 0
}
