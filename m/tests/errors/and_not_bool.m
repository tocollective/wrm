// Error: '&&' needs Bool operands
// @error 5: '&&' needs Bool operands, not 'UWord'

let main(argc: UWord, argv: *UByte[]): Word {
    if argc > 0 && argc return 1
    return 0
}
