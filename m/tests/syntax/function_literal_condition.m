// Syntax error: a function literal in a condition must be in parentheses
// @error 8: a function literal here must be in parentheses

type Action = (): Void

let main(argc: UWord, argv: *UByte[]): Word {
    let f: Action = null
    if f == (): Void {} { return 1 }
    if f == ((): Void {}) { return 1 }
    return 0
}
