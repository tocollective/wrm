// Syntax error: there is no '+|='
// @error 6: there is no '+|='

let main(argc: UWord, argv: *UByte[]): Word {
    let mut x: UByte = 1
    x +|= 1
    return 0
}
