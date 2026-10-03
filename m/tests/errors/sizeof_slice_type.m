// Error: 'sizeof(T[])': a pointer to an array of unknown length (7.2)
// @error 5: 'sizeof' of 'T[]'

let main(argc: UWord, argv: *UByte[]): Word {
    return sizeof(Word[]) as Word
}
