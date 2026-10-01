// Syntax error: 'T[]' only in parameters
// @error 5: only for parameter types

let f(p: *UByte): Void {
    let q: UByte[] = p
}
