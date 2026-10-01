// Error: two 'default'
// @error 8: a second 'default'

let main(argc: UWord, argv: *UByte[]): Word {
    switch argc {
        default:
            return 1
        default:
            return 2
    }
    return 0
}
