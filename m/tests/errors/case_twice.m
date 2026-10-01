// Error: the same 'case' twice
// @error 8: this 'case' value is already used at line 6

let main(argc: UWord, argv: *UByte[]): Word {
    switch argc {
        case 1:
            return 1
        case 1:
            return 2
    }
    return 0
}
