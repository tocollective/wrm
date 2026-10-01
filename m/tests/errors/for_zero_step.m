// Error: ranges.m: zero step
// @error 5: the step of 'for' can't be 0

let main(argc: UWord, argv: *UByte[]): Word {
    for i: UWord in 0...9 by 0 {}
    return 0
}
