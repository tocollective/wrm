// Warning: '///' not before a declaration
// @warning 6: a '///' comment must go right before a declaration

/// fine: before a function
let f(): Void {
    /// not here
    let x: UWord = 1
    if x == 0 return
}

let main(argc: UWord, argv: *UByte[]): Word {
    f()
    return 0
}
