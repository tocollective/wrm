// Error: cpu.m: atomics work only on words and pointers
// @error 6: 'atomicSwap' works only on Word, UWord and pointers, not on 'UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let mut flag: UByte = 0
    if atomicSwap(&mut flag, 1) == 0 return 1
    return 0
}
