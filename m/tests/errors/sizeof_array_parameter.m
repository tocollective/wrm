// Error: dynarray.m: a 'T[]' parameter is a pointer, its length isn't known
// @error 5: 'sizeof' of 'xs': a 'T[]' parameter is a pointer

let count(xs: Word[]): UWord {
    return sizeof(xs) / sizeof(xs[0])
}

let main(argc: UWord, argv: *UByte[]): Word {
    let a: Word[3] = [1, 2, 3]
    return count(a) as Word
}
