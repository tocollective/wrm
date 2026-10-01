// Error: arith.m: signed index
// @error 7: an index must be an unsigned integer, not 'Word'

let main(argc: UWord, argv: *UByte[]): Word {
    let table: UByte[4] = []
    let s: Word = 1
    let v: UByte = table[s]
    return 0
}
