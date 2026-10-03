// More than 18 values at once (7.8): values past r10-r27 are spilled to
// the frame and reloaded. Calls with 25 arguments, an expression nested 30
// levels to the right, nested calls inside a call of 20 arguments, 20
// structs by value, an indirect call.
// @output "deep 325 -15 3180 6930 325\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, nl } from "lib/print.m"

type Rgb {
    r: UByte,
    g: UByte,
    b: UByte,
}

let sum25(a1: Word, a2: Word, a3: Word, a4: Word, a5: Word, a6: Word, a7: Word, a8: Word, a9: Word, a10: Word, a11: Word, a12: Word, a13: Word, a14: Word, a15: Word, a16: Word, a17: Word, a18: Word, a19: Word, a20: Word, a21: Word, a22: Word, a23: Word, a24: Word, a25: Word): Word {
    return a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9 + a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19 + a20 + a21 + a22 + a23 + a24 + a25
}

let inc(n: Word): Word {
    return n + 1
}

let twenty(b1: Word, b2: Word, b3: Word, b4: Word, b5: Word, b6: Word, b7: Word, b8: Word, b9: Word, b10: Word, b11: Word, b12: Word, b13: Word, b14: Word, b15: Word, b16: Word, b17: Word, b18: Word, b19: Word, b20: Word): Word {
    return b1 * 1 + b2 * 2 + b3 * 3 + b4 * 4 + b5 * 5 + b6 * 6 + b7 * 7 + b8 * 8 + b9 * 9 + b10 * 10 + b11 * 11 + b12 * 12 + b13 * 13 + b14 * 14 + b15 * 15 + b16 * 16 + b17 * 17 + b18 * 18 + b19 * 19 + b20 * 20
}

let rgb(n: Word): Rgb {
    let c: Rgb = { .r = n as UByte, .g = 0xFF, .b = (2 * n) as UByte }
    return c
}

let colors(c1: Rgb, c2: Rgb, c3: Rgb, w3: Word, c4: Rgb, c5: Rgb, c6: Rgb, w6: Word, c7: Rgb, c8: Rgb, c9: Rgb, w9: Word, c10: Rgb, c11: Rgb, c12: Rgb, w12: Word, c13: Rgb, c14: Rgb, c15: Rgb, w15: Word, c16: Rgb, c17: Rgb, c18: Rgb, w18: Word, c19: Rgb, c20: Rgb): Word {
    return (c1.r as Word) + (c1.b as Word) + (c2.r as Word) + (c2.b as Word) + (c3.r as Word) + (c3.b as Word) + w3 + (c4.r as Word) + (c4.b as Word) + (c5.r as Word) + (c5.b as Word) + (c6.r as Word) + (c6.b as Word) + w6 + (c7.r as Word) + (c7.b as Word) + (c8.r as Word) + (c8.b as Word) + (c9.r as Word) + (c9.b as Word) + w9 + (c10.r as Word) + (c10.b as Word) + (c11.r as Word) + (c11.b as Word) + (c12.r as Word) + (c12.b as Word) + w12 + (c13.r as Word) + (c13.b as Word) + (c14.r as Word) + (c14.b as Word) + (c15.r as Word) + (c15.b as Word) + w15 + (c16.r as Word) + (c16.b as Word) + (c17.r as Word) + (c17.b as Word) + (c18.r as Word) + (c18.b as Word) + w18 + (c19.r as Word) + (c19.b as Word) + (c20.r as Word) + (c20.b as Word)
}

type Sum25 = (a1: Word, a2: Word, a3: Word, a4: Word, a5: Word, a6: Word, a7: Word, a8: Word, a9: Word, a10: Word, a11: Word, a12: Word, a13: Word, a14: Word, a15: Word, a16: Word, a17: Word, a18: Word, a19: Word, a20: Word, a21: Word, a22: Word, a23: Word, a24: Word, a25: Word): Word

let main(argc: UWord, argv: *UByte[]): Word {
    puts("deep")
    say(sum25(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25))
    let mut x1: Word = 1
    let mut x2: Word = 2
    let mut x3: Word = 3
    let mut x4: Word = 4
    let mut x5: Word = 5
    let mut x6: Word = 6
    let mut x7: Word = 7
    let mut x8: Word = 8
    let mut x9: Word = 9
    let mut x10: Word = 10
    let mut x11: Word = 11
    let mut x12: Word = 12
    let mut x13: Word = 13
    let mut x14: Word = 14
    let mut x15: Word = 15
    let mut x16: Word = 16
    let mut x17: Word = 17
    let mut x18: Word = 18
    let mut x19: Word = 19
    let mut x20: Word = 20
    let mut x21: Word = 21
    let mut x22: Word = 22
    let mut x23: Word = 23
    let mut x24: Word = 24
    let mut x25: Word = 25
    let mut x26: Word = 26
    let mut x27: Word = 27
    let mut x28: Word = 28
    let mut x29: Word = 29
    let mut x30: Word = 30
    say(x1 - (x2 - (x3 - (x4 - (x5 - (x6 - (x7 - (x8 - (x9 - (x10 - (x11 - (x12 - (x13 - (x14 - (x15 - (x16 - (x17 - (x18 - (x19 - (x20 - (x21 - (x22 - (x23 - (x24 - (x25 - (x26 - (x27 - (x28 - (x29 - (x30))))))))))))))))))))))))))))))
    say(twenty(inc(1), inc(inc(2)), inc(inc(inc(3))), 4, inc(5), inc(inc(6)), inc(inc(inc(7))), 8, inc(9), inc(inc(10)), inc(inc(inc(11))), 12, inc(13), inc(inc(14)), inc(inc(inc(15))), 16, inc(17), inc(inc(18)), inc(inc(inc(19))), 20))
    say(colors(rgb(1), rgb(2), rgb(3), 300, rgb(4), rgb(5), rgb(6), 600, rgb(7), rgb(8), rgb(9), 900, rgb(10), rgb(11), rgb(12), 1200, rgb(13), rgb(14), rgb(15), 1500, rgb(16), rgb(17), rgb(18), 1800, rgb(19), rgb(20)))
    let f: Sum25 = sum25
    say(f(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25))
    nl()
    return 0
}
