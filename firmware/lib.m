// UART output and helpers for the firmware and the demos.

import { uart, UART_TX_READY, CR_CYCLE, CR_CYCLEH } from "defs.m"

/// Writes a zero-terminated string to the UART (m/runtime/rt.m).
extern let puts(s: *UByte): Void

let NAME_WIDTH: UWord = 24          // the column where show() prints values
let HEX_DIGITS: *UByte = "0123456789ABCDEF"

/// Writes a byte to the UART. TX never blocks, but TX ready is polled for
/// good form.
let putc(c: UByte): Void {
    while uart.status & UART_TX_READY == 0 {}
    uart.data = c as UWord
}

let strlen(s: *UByte): UWord {
    let mut n: UWord = 0
    while s[n] != 0 n++
    return n
}

/// Writes n spaces.
let pad(n: UWord): Void {
    for i: UWord in 0..n putc(' ')
}

/// Writes the low 'digits' hex digits of v.
let printHex(v: UWord, digits: UWord): Void {
    for i: UWord in digits..0 by -1 putc(HEX_DIGITS[v >> (4 * (i - 1)) & 0xF])
}

/// Writes v in decimal.
let printDec(v: UWord): Void {
    let mut buf: UByte[11]
    let mut i: UWord = 10
    let mut n: UWord = v
    buf[10] = 0
    while true {
        i--
        buf[i] = '0' + (n % 10) as UByte
        n = n / 10
        if n == 0 break
    }
    puts(&buf[i])
}

/// Writes v in decimal, with '-' if it is negative.
let printInt(v: Word): Void {
    if v < 0 {
        putc('-')
        printDec(0 - (v as UWord))      // 0x80000000 stays as is and prints unsigned
    } else {
        printDec(v as UWord)
    }
}

/// "name                    = value (0xVALUE)\n", value signed in decimal.
let show(name: *UByte, value: UWord): Void {
    puts(name)
    let width: UWord = strlen(name)
    if width < NAME_WIDTH pad(NAME_WIDTH - width)
    puts("= ")
    printInt(value as Word)
    puts(" (0x")
    printHex(value, 8)
    puts(")\n")
}

/// Signed values on one line.
let printArray(words: Word[], n: UWord): Void {
    for i: UWord in 0..n {
        printInt(words[i])
        putc(' ')
    }
    putc('\n')
}

/// Bubble sort, signed, ascending.
let sort(words: mut Word[], n: UWord): Void {
    for pass: UWord in n..1 by -1 {
        for i: UWord in 0..pass - 1 {
            if words[i] > words[i + 1] {
                let t: Word = words[i]
                words[i] = words[i + 1]
                words[i + 1] = t
            }
        }
    }
}

type Cycles {
    lo: UWord,
    hi: UWord,
}

/// CYCLE and CYCLEH from the same moment: read again if CYCLE wrapped in
/// between.
let readCycles(): Cycles {
    let mut c: Cycles = {}
    let mut again: Bool = true
    while again {
        c.hi = mfcr(CR_CYCLEH)
        c.lo = mfcr(CR_CYCLE)
        again = mfcr(CR_CYCLEH) != c.hi
    }
    return c
}

export { puts, putc, strlen, pad, printHex, printDec, printInt, show, printArray, sort }
export { Cycles, readCycles }
