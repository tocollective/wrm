// Error: the body of 'let mut f()' doesn't see 'f': it is a local of the
// function around (no capture), so there is no recursion
// @error 7: 'countDown' is a local of 'main': a nested function can't capture it

let main(argc: UWord, argv: *UByte[]): Word {
    let mut countDown(n: UWord): Void {
        if n > 0 countDown(n - 1)
    }
    countDown(3)
    countDown = countDown
    return 0
}
