// Function types are written as a signature without a name, with parameter
// names: '(a: Color, b: Color): Color', '(): Void'. The names are only
// documentation: two function types with the same parameter and return types
// are the same type.
//
// A function value is a pointer to code, 4 bytes, like a function pointer in C.
// It can be 'null', like any pointer. Calling 'null' is a page fault.
// The name of a function is already a value of its type, without '&'.
//
// 'type Name = T' gives a short name to any type. It is an alias: 'Name' and
// 'T' are the same type, no 'as' is needed between them.

import { puts } from "externs.m"

// Short names for long function types
type Action = (): Void
type OpFunc = (left: Word, right: Word): Word
type Handler = (code: UWord): Void

let foo(): Void {
    puts("foo\n")
}

let bar(): Void {
    puts("bar\n")
}

let add(a: Word, b: Word): Word {
    return a + b
}

let sub(a: Word, b: Word): Word {
    return a - b
}

// A function as a parameter
let apply(op: OpFunc, a: Word, b: Word): Word {
    return op(a, b)
}

// A table of handlers: a global without '=' is in .bss, so every slot is null
let mut handlers: Handler[4]

let onZero(code: UWord): Void {
    puts("zero\n")
}

let dispatch(code: UWord): Void {
    let h: Handler = handlers[code]
    if h != null h(code) else puts("no handler\n")
}

let main(argc: UWord, argv: *UByte[]): Word {
    let mut func: Action = foo
    func()
    func = bar
    func()

    let five: Word = apply(add, 2, 3)
    let one: Word = apply(sub, 3, 2)

    let op: OpFunc = add

    // An alias is the same type as what it names: no 'as' between them.
    // Parameter names do not matter for the type either.
    let longForm: (x: Word, y: Word): Word = op
    let back: OpFunc = longForm

    handlers[0] = onZero
    dispatch(0)  // "zero"
    dispatch(1)  // "no handler"

    let mut maybe: Action = null
    if maybe != null maybe()

    // Compile errors:
    //     func = add                   // OpFunc is not Action
    //     let g: Action = &foo         // no '&': 'foo' is already a pointer
    return 0
}

// Test directives (m/tests/run.py)
// @output "foo\nbar\nzero\nno handler\n"
// @exit 0
