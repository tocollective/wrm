// Error: 'continue' in a switch outside a loop
// @error 7: 'continue' outside a loop

let main(argc: UWord, argv: *UByte[]): Word {
    switch argc {
        case 0:
            continue
    }
    return 0
}
