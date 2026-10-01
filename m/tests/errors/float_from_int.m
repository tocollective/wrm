// Error: float.m: no implicit conversion
// @error 6: expected 'Float', found 'Word'

let main(argc: UWord, argv: *UByte[]): Word {
    let n: Word = 7
    let e: Float = n
    return 0
}
