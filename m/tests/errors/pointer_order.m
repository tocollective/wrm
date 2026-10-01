// Error: pointers can't be ordered
// @error 7: pointers can't be ordered

let main(argc: UWord, argv: *UByte[]): Word {
    let a: *UByte = argv[0]
    let b: *UByte = argv[1]
    if a < b return 1
    return 0
}
