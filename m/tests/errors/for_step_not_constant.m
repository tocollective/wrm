// Error: ranges.m: step is not a constant
// @error 6: the step of 'for' must be a constant

let main(argc: UWord, argv: *UByte[]): Word {
    let mut n: Word = 2
    for i: UWord in 0...9 by n {}
    return 0
}
