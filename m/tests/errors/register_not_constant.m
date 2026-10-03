// Error: cpu.m: the register number must be a constant
// @error 6: the register number of 'mfcr' must be a constant

let main(argc: UWord, argv: *UByte[]): Word {
    let mut n: UWord = 4
    let x: UWord = mfcr(n)
    if x == 0 return 1
    return 0
}
