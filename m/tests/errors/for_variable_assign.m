// Error: ranges.m: 'i' without 'mut' can't be assigned
// @error 6: 'i' is the variable of a 'for' without 'mut'

let main(argc: UWord, argv: *UByte[]): Word {
    for i: UWord in 0...9 {
        i = 5
    }
    return 0
}
