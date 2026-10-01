// Error: a local can't take a top-level name
// @error 7: 'N' is a top-level name of this file

let N: UWord = 1

let main(argc: UWord, argv: *UByte[]): Word {
    let N: UWord = 2
    if N == 0 return 1
    return 0
}
