// Error: functions.m: OpFunc is not Action
// @error 14: expected '(): Void', found '(Word, Word): Word'

type Action = (): Void

let foo(): Void {}

let add(a: Word, b: Word): Word {
    return a + b
}

let main(argc: UWord, argv: *UByte[]): Word {
    let mut func: Action = foo
    func = add
    func()
    return 0
}
