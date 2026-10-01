// Syntax error: 'let' without 'mut' and without '=' (init.m)
// @error 5: never gets a value

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UWord
    return 0
}
