// Functions in functions and function literals (3.8).
//
//   let f(...): R { ... }        a function declared in a function: visible
//                                from here to the end of the block
//   let mut f(...): R { ... }    a variable of a function type that starts
//                                with this body; it can be given another
//                                function later. Also at the top level
//   (a: A): R { ... }            a function literal: a function without a
//                                name, as an expression
//
// There is no capture: inside, the locals and parameters of the function
// around are not visible, so their names can be used again. Everything at
// the top level is visible, and so are the nested functions declared above.
// A function value stays a plain pointer to code, 4 bytes, like a function
// pointer in C: it can be passed to 'extern' functions and to IVEC.

import { puts } from "externs.m"

type Action = (): Void
type OpFunc = (a: Word, b: Word): Word

// A handler that starts with a default body and can be replaced
let mut onKey(key: UByte): Void {
    puts("unhandled key\n")
}

// A function literal is a constant, like the name of a function, so a table
// of them can be a global
let ops: OpFunc[3] = [
    (a: Word, b: Word): Word { return a + b },
    (a: Word, b: Word): Word { return a - b },
    (a: Word, b: Word): Word { return a * b },
]

let apply(op: OpFunc, a: Word, b: Word): Word {
    return op(a, b)
}

let twice(f: Action): Void {
    f()
    f()
}

let main(argc: UWord, argv: *UByte[]): Word {
    let n: Word = 5

    // A nested function. 'n' here is its own parameter: the 'n' of main
    // is not visible inside, so the name is free
    let square(n: Word): Word {
        return n * n
    }

    // Recursion: a nested function sees its own name
    let factorial(n: Word): Word {
        if n <= 1 return 1
        return n * factorial(n - 1)
    }

    // A variable of a function type with a body to start with
    let mut greet(): Void {
        puts("hello\n")
    }
    greet()                                 // "hello"
    greet = (): Void { puts("hi\n") }
    greet()                                 // "hi"

    // A literal as an argument
    twice((): Void { puts("tick\n") })      // "tick" twice

    onKey('a')                              // "unhandled key"
    onKey = (key: UByte): Void { puts("key\n") }
    onKey('a')                              // "key"

    let sum: Word = apply(ops[0], 2, 3)                                 // 5
    let product: Word = apply((a: Word, b: Word): Word { return a * b }, 4, 5)    // 20

    // Compile errors:
    //     let peek(): Word { return n }    // 'n' is a local of 'main': no capture
    //     square = factorial               // a nested function is not a variable
    //     let f: (x: Word): Word = &square // no '&' before a function
    return square(n) + factorial(4) + sum + product - 74   // 25 + 24 + 5 + 20 - 74 = 0
}

// Test directives (m/tests/run.py)
// @output "hello\nhi\ntick\ntick\nunhandled key\nkey\n"
// @exit 0
