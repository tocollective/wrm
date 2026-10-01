// Error: arith.m: no implicit widening
// @error 6: expected 'UWord', found 'UByte'; convert it with 'as'

let main(argc: UWord, argv: *UByte[]): Word {
    let a: UByte = 200
    let f: UWord = a
    return 0
}
