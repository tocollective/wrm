// [3] Calls, recursion, loops, a table of functions.

import { puts, show } from "../lib.m"

/// n!, recursive to exercise the stack.
let factorial(n: UWord): UWord {
    if n < 2 return 1
    return n * factorial(n - 1)
}

/// Euclid's algorithm.
let gcd(a: UWord, b: UWord): UWord {
    let mut x: UWord = a
    let mut y: UWord = b
    while y != 0 {
        let r: UWord = x % y
        x = y
        y = r
    }
    return x
}

type OpFunc = (a: Word, b: Word): Word

let opAdd(a: Word, b: Word): Word {
    return a + b
}

let opSub(a: Word, b: Word): Word {
    return a - b
}

let opMax(a: Word, b: Word): Word {
    if a >= b return a
    return b
}

let opMin(a: Word, b: Word): Word {
    if a <= b return a
    return b
}

/// (a * b) >> 16, arithmetic.
let opMulh(a: Word, b: Word): Word {
    return (a * b) >> 16
}

let OPS: OpFunc[5] = [opAdd, opSub, opMax, opMin, opMulh]
let OP_NAMES: *UByte[5] = [
    "op_add(25, -40)", "op_sub(25, -40)", "op_max(25, -40)", "op_min(25, -40)",
    "op_mulh(25, -40)",
]

let demoCalls(): Void {
    puts("\n[3] calls\n")
    show("factorial(10)", factorial(10))
    show("gcd(1071, 462)", gcd(1071, 462))
    for i: UWord in 0..5 show(OP_NAMES[i], OPS[i](25, -40) as UWord)    // indirect calls
}

export { demoCalls }
