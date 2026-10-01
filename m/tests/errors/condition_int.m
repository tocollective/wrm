// Error: expressions.m: the condition is not Bool
// @error 6: the condition of 'if' must be Bool, not 'UWord'

let main(argc: UWord, argv: *UByte[]): Word {
    let flags: UWord = argc
    if flags return 1
    return 0
}
