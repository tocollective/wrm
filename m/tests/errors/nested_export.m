// Error: only top-level names are exported
// @error 4: 'inner' is not declared in this file

export { inner }

let main(argc: UWord, argv: *UByte[]): Word {
    let inner(): Void {}
    inner()
    return 0
}
