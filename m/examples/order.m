// Top-level declarations can come in any order: a function can call one
// declared below, a field can have a type declared below, a constant can use
// a constant declared below. There are no forward declarations.
//
// Inside a function the order is the usual one: a variable is visible only
// after its declaration.

import { puts } from "externs.m"

let main(argc: UWord, argv: *UByte[]): Word {
    // 'isEven' is declared below
    if isEven(argc) puts("even\n") else puts("odd\n")

    let mut list: List = { .first = null, .count = 0 }
    listInit(&mut list)
    return 0
}

// Mutual recursion without forward declarations
let isEven(n: UWord): Bool {
    if n == 0 return true
    return isOdd(n - 1)
}

let isOdd(n: UWord): Bool {
    if n == 0 return false
    return isEven(n - 1)
}

// 'List' uses 'Node', which is declared below
type List {
    first: *mut Node,
    count: UWord,
}

// A struct can point to itself, but cannot contain itself by value
type Node {
    next:  *mut Node,
    value: UWord,
}

// Compile error: 'Loop' contains itself, its size would be infinite
//     type Loop {
//         inner: Loop,
//     }

let listInit(list: *mut List): Void {
    list.first = null
    list.count = 0
}

// A constant can use one declared below
let BUFFER_SIZE: UWord = PAGE_SIZE * 2
let PAGE_SIZE: UWord = 4096

// Compile error: a cycle between constants
//     let A: UWord = B
//     let B: UWord = A

let insideFunction(): Void {
    // Inside a function, a variable is visible only after its declaration
    //     let a: UWord = b         // compile error: 'b' is not declared yet
    let b: UWord = 1
    let a: UWord = b
}

// Test directives (m/tests/run.py)
// @output "even\n"
// @exit 0
