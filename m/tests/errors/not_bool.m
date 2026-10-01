// Error: '!' needs a Bool
// @error 5: '!' needs a Bool, not 'UWord'

let main(argc: UWord, argv: *UByte[]): Word {
    if !argc return 1
    return 0
}
