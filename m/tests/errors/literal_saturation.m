// Error: literals.m: saturation happens only at run time
// @error 5: 256 doesn't fit in 'UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let z: UByte = 0x10 *| 0x10
    return 0
}
