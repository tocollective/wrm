// [1] Arithmetic and logic. Each line is one instruction: M compiles the
// expression to it.

import { puts, show } from "../lib.m"

let demoAlu(): Void {
    puts("\n[1] ALU: a = 1000, b = -7, m = 0x0FF0, s = 4\n")
    let a: Word = 1000
    let b: Word = -7
    let m: Word = 0x0FF0
    let s: UWord = 4
    let zero: Word = 0
    let min: Word = -2147483648
    let minusOne: Word = -1

    // register forms
    show("ADD   a + b", (a + b) as UWord)
    show("SUB   a - b", (a - b) as UWord)
    show("MUL   a * b", (a * b) as UWord)
    show("DIV   a / b", (a / b) as UWord)
    show("REM   a % b", (a % b) as UWord)
    show("DIVU  a / b", (a as UWord) / (b as UWord))
    show("REMU  a % b", (a as UWord) % (b as UWord))
    show("SLT   b < a", (b < a) as UWord)
    show("SLTU  b < a", ((b as UWord) < (a as UWord)) as UWord)
    show("AND   a & m", (a & m) as UWord)
    show("OR    a | m", (a | m) as UWord)
    show("XOR   a ^ m", (a ^ m) as UWord)
    show("SHL   b << s", (b << s) as UWord)
    show("SHR   b >> s", (b as UWord) >> s)
    show("SAR   b >> s", (b >> s) as UWord)

    // immediate forms
    show("ADDI  a + -1", (a + -1) as UWord)
    show("ANDI  a & 0xF", (a & 0xF) as UWord)
    show("ORI   a | 0x3000", (a | 0x3000) as UWord)
    show("XORI  a ^ 0x3FFF", (a ^ 0x3FFF) as UWord)
    show("SHLI  a << 20", (a << 20) as UWord)
    show("SHRI  b >> 28", (b as UWord) >> 28)
    show("SARI  b >> 1", (b >> 1) as UWord)
    show("SLTI  b < 0", (b < 0) as UWord)
    show("SLTIU b < 1", ((b as UWord) < 1) as UWord)

    // upper immediates and 32-bit constants
    show("LUI   0x7FFFF", 0x7FFFF << 13)
    show("LI    0xDEADBEEF", 0xDEAD_BEEF)

    // corner cases: division never traps
    show("DIV   a / 0", (a / zero) as UWord)
    show("REM   a % 0", (a % zero) as UWord)
    show("DIV   INT_MIN / -1", (min / minusOne) as UWord)
}

export { demoAlu }
