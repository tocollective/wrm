// Error: a local can't take a visible local name
// @error 7: 'x' is already declared at line 5

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UWord = 1
    if x == 1 {
        let x: UWord = 2
        if x == 2 return 1
    }
    return 0
}
