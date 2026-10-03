// Error: two names in the same block; shadowing is only from an inner one
// @error 6: 'x' is already declared at line 5 in the same block

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UWord = 1
    let x: UWord = 2
    if x == 0 return 1
    return 0
}
