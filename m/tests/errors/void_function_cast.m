// Error: a function converts with 'as' to *Void and *mut Void only
// @error 7: '(): Void' can't be converted to '*volatile Void'

let f(): Void {}

let main(argc: UWord, argv: *UByte[]): Word {
    let p: *volatile Void = f as *volatile Void
    let q: *Void = f as *Void
    if p == q return 1
    return 0
}
