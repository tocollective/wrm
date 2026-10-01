// Error: expressions.m: the condition is not Bool
// @error 6: the condition of 'if' must be Bool, not '*UByte'

let main(argc: UWord, argv: *UByte[]): Word {
    let p: *UByte = argv[0]
    if p return 1
    return 0
}
