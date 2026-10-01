// Error: 'break' outside a loop
// @error 5: 'break' outside a loop or 'switch'

let main(argc: UWord, argv: *UByte[]): Word {
    break
    return 0
}
