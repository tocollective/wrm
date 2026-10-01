// Number output for the code generation tests. Not a test itself: it has
// no directives.

import { puts } from "../../../examples/externs.m"

/// Writes n in decimal.
let putu(n: UWord): Void {
    let mut buf: UByte[11]
    let mut i: UWord = 10
    let mut v: UWord = n
    buf[10] = 0
    while true {
        i--
        buf[i] = '0' + (v % 10) as UByte
        v = v / 10
        if v == 0 break
    }
    puts(&buf[i])
}

/// Writes n in decimal, with '-' if it is negative.
let putd(n: Word): Void {
    if n < 0 {
        puts("-")
        putu(0 - (n as UWord))
    } else {
        putu(n as UWord)
    }
}

/// Writes n as 0x and 8 hex digits.
let putx(n: UWord): Void {
    let hex: *UByte = "0123456789ABCDEF"
    let mut buf: UByte[11] = ['0', 'x']
    for i: UWord in 0..8 buf[9 - i] = hex[n >> (4 * i) & 0xF]
    puts(&buf[0])
}

/// Writes a space, then n.
let say(n: Word): Void {
    puts(" ")
    putd(n)
}

/// Writes a space, then n unsigned.
let sayu(n: UWord): Void {
    puts(" ")
    putu(n)
}

let nl(): Void {
    puts("\n")
}

export { putu, putd, putx, say, sayu, nl }
