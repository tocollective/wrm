// Error: a nested function is visible only after its declaration
// @error 5: 'later' is not declared

let main(argc: UWord, argv: *UByte[]): Word {
    later()
    let later(): Void {}
    later()
    return 0
}
