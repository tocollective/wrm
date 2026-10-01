// Error: two exports with one external name
// @error 7: 'f' is already exported

let a(): Void {}
let b(): Void {}
export { a as f }
export { b as f }

let main(argc: UWord, argv: *UByte[]): Word {

    return 0
}
