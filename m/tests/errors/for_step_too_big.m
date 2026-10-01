// Error: ranges.m: step does not fit in UByte
// @error 5: the step 300 doesn't fit in 'UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    for i: UByte in 0...9 by 300 {}
    return 0
}
