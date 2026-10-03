// Error: 'sizeof' of a literal: it has no type yet (7.2)
// @error 5: 'sizeof' needs a type or a value of a known type

let main(argc: UWord, argv: *UByte[]): Word {
    return sizeof(1) as Word
}
