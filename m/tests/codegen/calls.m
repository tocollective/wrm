// Calls (docs/ABI.md): recursion, stack arguments, function values,
// structs and arrays by value in registers and by reference, results of
// every size.
// @output "rec 120 55\n"
// @output "args 55 -10 -3 -3 298 1\n"
// @output "fn 7 12 -1 zero no\n"
// @output "small 255,128,64 9,8,7 1,2,3 | 1 2 | 3 4 5\n"
// @output "big 10 20 30 | 1 2 3 4 5 | 21 22 23 24 25 | 6\n"
// @output "array 10 20 30 40 | 2 4 6 8 | 99\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { putd, say, nl } from "lib/print.m"

let factorial(n: UWord): UWord {
    if n <= 1 return 1
    return n * factorial(n - 1)
}

let fib(n: UWord): UWord {
    if n < 2 return n
    return fib(n - 1) + fib(n - 2)
}

// Ten arguments: the last two go on the stack
let sum10(a: Word, b: Word, c: Word, d: Word, e: Word, f: Word, g: Word, h: Word,
          i: Word, j: Word): Word {
    return a + b + c + d + e + f + g + h + i + j
}

// Sub-word arguments are extended by their type
let mixed(a: Byte, b: UByte, c: Half, d: UHalf, e: Bool): Void {
    say(a as Word)
    say((b as Word) - 256)
    say(c as Word)
    say((d as Word) + (b as Word) - 255 + 255 - 255)
    say(e as Word)
}

type OpFunc = (a: Word, b: Word): Word

let add(a: Word, b: Word): Word {
    return a + b
}

let mul(a: Word, b: Word): Word {
    return a * b
}

let apply(op: OpFunc, a: Word, b: Word): Word {
    return op(a, b)
}

type Handler = (code: UWord): Void

let onZero(code: UWord): Void {
    puts(" zero")
}

let mut handlers: Handler[4]

let dispatch(code: UWord): Void {
    let h: Handler = handlers[code]
    if h != null h(code) else puts(" no")
}

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

let invert(c: Color): Color {
    let out: Color = { .r = 0xFF - c.r, .g = 0xFF - c.g, .b = 0xFF - c.b }
    return out
}

let showColor(c: Color): Void {
    puts(" ")
    putd(c.r as Word)
    puts(",")
    putd(c.g as Word)
    puts(",")
    putd(c.b as Word)
}

type Pair {
    a: Word,
    b: Word,
}

let swap(p: Pair): Pair {
    let q: Pair = { .a = p.b, .b = p.a }
    return q
}

type Triple {
    x: UHalf,
    y: UHalf,
    z: UHalf,
}

let triple(x: UHalf): Triple {
    let t: Triple = { .x = x, .y = x + 1, .z = x + 2 }
    return t
}

// Seven words of arguments, then a two-word struct: it doesn't fit in r8
// alone, so it and everything after it go on the stack
let late(a: Word, b: Word, c: Word, d: Word, e: Word, f: Word, g: Word, p: Pair, k: Word): Void {
    say(p.a)
    say(p.b)
}

type Big {
    v: Word[5],
}

let bump(b: Big, n: Word): Big {
    let mut out: Big = b
    for i: UWord in 0..5 out.v[i] = out.v[i] + n
    return out
}

let clobber(b: Big): Word {
    // the callee owns its copy
    let mut c: Big = b
    c.v[0] = 1000
    return b.v[0] + 5
}

let showBig(b: Big): Void {
    for i: UWord in 0..5 say(b.v[i])
}

let doubled(a: UByte[4]): UByte[4] {
    let mut out: UByte[4] = a
    for i: UWord in 0..4 out[i] = a[i] * 2
    return out
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("rec")
    say(factorial(5) as Word)
    say(fib(10) as Word)
    nl()

    puts("args")
    say(sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
    mixed(-10, 253, -3, 300, true)
    nl()

    puts("fn")
    say(apply(add, 3, 4))
    say(apply(mul, 3, 4))
    let op: OpFunc = add
    say(op(-3, 2))
    handlers[0] = onZero
    dispatch(0)
    dispatch(1)
    nl()

    puts("small")
    let c: Color = { .g = 0x7F, .b = 0xBF }
    showColor(invert(c))
    showColor({ .r = 9, .g = 8, .b = 7 })
    let colors: Color[2] = [{ .r = 1, .g = 2, .b = 3 }, {}]
    showColor(colors[0])
    puts(" |")
    let p: Pair = swap({ .a = 2, .b = 1 })
    late(0, 0, 0, 0, 0, 0, 0, p, 0)
    puts(" |")
    let t: Triple = triple(3)
    say(t.x as Word)
    say(t.y as Word)
    say(triple(3).z as Word)
    nl()

    puts("big")
    let mut b: Big = { .v = [10, 20, 30] }
    say(b.v[0])
    say(b.v[1])
    say(b.v[2])
    puts(" |")
    b = { .v = [1, 2, 3, 4, 5] }
    showBig(b)
    puts(" |")
    showBig(bump(b, 20))
    puts(" |")
    say(clobber(b))
    nl()

    puts("array")
    let a: UByte[4] = [10, 20, 30, 40]
    for i: UWord in 0..4 say(a[i] as Word)
    puts(" |")
    let d: UByte[4] = doubled([1, 2, 3, 4])
    for i: UWord in 0..4 say(d[i] as Word)
    puts(" |")
    say(doubled([0, 0, 99])[2] as Word - 99)
    nl()
    return 0
}
