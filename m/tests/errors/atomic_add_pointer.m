// Error: 'atomicAdd' only on Word and UWord
// @error 6: 'atomicAdd' works only on Word and UWord, not on '*UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let mut p: *UByte = null
    if atomicAdd(&mut p, null) == null return 1
    return 0
}
