// Warning: code after 'while true' without 'break'
// @warning 6: unreachable code

let spin(): UWord {
    while true {}
    return 1
}

let main(argc: UWord, argv: *UByte[]): Word {
    if spin() == 0 return 1
    return 0
}
