// Error: '&' of a temporary value
// @error 9: 'f(...)' is a temporary value: it has no address

let f(): UWord {
    return 1
}

let main(argc: UWord, argv: *UByte[]): Word {
    let p: *UWord = &f()
    if *p == 0 return 1
    return 0
}
