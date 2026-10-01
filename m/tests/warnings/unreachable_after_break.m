// Warning: code after 'break'
// @warning 7: unreachable code

let main(argc: UWord, argv: *UByte[]): Word {
    while true {
        break
        return 1
    }
    return 0
}
