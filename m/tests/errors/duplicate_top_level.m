// Error: two top-level names
// @error 5: 'x' is already declared at line 4

let x: UWord = 1
let x: UWord = 2

let main(argc: UWord, argv: *UByte[]): Word {
    if x == 0 return 1
    return 0
}
