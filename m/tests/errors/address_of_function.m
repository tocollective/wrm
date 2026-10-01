// Error: functions.m: no '&' before a function
// @error 9: 'foo' is already a pointer to its code

type Action = (): Void

let foo(): Void {}

let main(argc: UWord, argv: *UByte[]): Word {
    let g: Action = &foo
    g()
    return 0
}
