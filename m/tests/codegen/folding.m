// The same operations as ints.m on local 'let' constants (4.2): the
// compiler folds them, and the result must be what the machine computes.
// @output "wrap 0 -128 0 32767 0 -2147483648\n"
// @output "sat 255 0 255 -128 127 -32768 0 4294967295 0 4294967295 2147483647 -2147483648 2147483647 -2147483648 2147483647 1000000 -8\n"
// @output "div 4294967295 7 -1 -7 -2147483648 0 -3 -1 -3 1 255 -128\n"
// @output "shift 2 2 0 0 -4 60 -1 1\n"
// @output "bits 240 -6 -5 255 65535 65534 240 61695 3855\n"
// @output "cmp 1 0 1 1 0 1 1 0\n"
// @output "as 4294967295 65535 -1 120 -16 -32767 1\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, sayu, nl } from "lib/print.m"

let wrapping(): Void {
    let a: UByte = 0xFF
    let b: UByte = a + 1
    let s: Byte = 127
    let t: Byte = s + 1
    let mut h: UHalf = 0xFFFF
    h++
    let hs: Half = -32768
    let hn: Half = hs - 1
    let w: UWord = 0xFFFF_FFFF
    let w1: UWord = w + 1
    let sw: Word = 0x7FFF_FFFF
    let sw1: Word = sw + 1
    puts("wrap")
    say(b as Word)
    say(t as Word)
    say(h as Word)
    say(hn as Word)
    say(w1 as Word)
    say(sw1)
    nl()
}

let saturating(): Void {
    let a: UByte = 0xFF
    let sx: UByte = 0x10
    let s: Byte = 127
    let t: Byte = -128
    let hs: Half = -32768
    let h: UHalf = 0
    let big: UWord = 0xFFFF_FFF0
    let five: UWord = 5
    let sw: Word = 0x7FFF_FFFF
    let mn: Word = -2147483648
    let neg: Word = -1
    let k: Word = 1000
    let m5: Word = -5
    puts("sat")
    say((a +| 1) as Word)
    say((0 -| a) as Word)
    say((sx *| sx) as Word)
    say((t -| 1) as Word)
    say((s +| 1) as Word)
    say((hs -| 1) as Word)
    say((h -| 1) as Word)
    sayu(big +| 0x20)
    sayu(five -| big)
    sayu(big *| 2)
    say(sw +| 1)
    say(mn -| 1)
    say(sw *| 2)
    say(mn *| 2)
    say(mn *| neg)
    say(k *| k)
    say(m5 -| 3)
    nl()
}

let division(): Void {
    let n7: UWord = 7
    let z: UWord = 0
    let m7: Word = -7
    let zw: Word = 0
    let mn: Word = -2147483648
    let neg: Word = -1
    let p7: Word = 7
    let neg2: Word = -2
    let b9: UByte = 9
    let bz: UByte = 0
    let bm: Byte = -128
    let bneg: Byte = -1
    puts("div")
    sayu(n7 / z)
    sayu(n7 % z)
    say(m7 / zw)
    say(m7 % zw)
    say(mn / neg)
    say(mn % neg)
    say(m7 / 2)
    say(m7 % 2)
    say(p7 / neg2)
    say(p7 % neg2)
    say((b9 / bz) as Word)
    say((bm / bneg) as Word)
    nl()
}

let shifts(): Void {
    let one: UWord = 1
    let n33: UWord = 33
    let x81: UByte = 0x81
    let k1: UByte = 1
    let s16: Byte = -16
    let uf0: UByte = 0xF0
    let wneg: Word = -1
    let k31: UWord = 31
    puts("shift")
    sayu(one << n33)
    say((x81 << k1) as Word)
    say((x81 >> 8) as Word)
    say((x81 << 8) as Word)
    say((s16 >> 2) as Word)
    say((uf0 >> 2) as Word)
    say(wneg >> k31)
    sayu((wneg as UWord) >> k31)
    nl()
}

let bits(): Void {
    let f0: UByte = 0x0F
    let bb: Byte = 5
    let ub: UByte = 1
    let mh: UHalf = 1
    let wx: UWord = 0xF0F0
    puts("bits")
    say((~f0) as Word)
    say((~bb) as Word)
    say((-bb) as Word)
    say((-ub) as Word)
    say((-mh) as Word)
    say((~mh) as Word)
    sayu(wx & 0xFF)
    sayu(wx | 0xF)
    sayu(wx ^ 0xFFFF)
    nl()
}

let flag(b: Bool): Void {
    say(b as Word)
}

let comparisons(): Void {
    let ua: UWord = 0xFFFF_FFFF
    let sa: Word = -1
    let u200: UByte = 200
    let bm1: Byte = -1
    let hb: UHalf = 0x8000
    puts("cmp")
    flag(ua > 1)
    flag(sa > 1)
    flag(u200 > 100)
    flag(bm1 < 1)
    flag(bm1 >= 0)
    flag(hb > 0x7FFF)
    flag(ua != 0 && sa == -1)
    flag(ua == 0 || sa != -1)
    nl()
}

let casts(): Void {
    let neg1: Byte = -1
    let big: UWord = 0x1234_5678
    let big2: UWord = 0x1234_56F0
    let h2: UHalf = 0x8001
    let yes: Bool = true
    puts("as")
    sayu(neg1 as UWord)
    say((neg1 as UHalf) as Word)
    say(neg1 as Word)
    say((big as UByte) as Word)
    say((big2 as Byte) as Word)
    say((h2 as Half) as Word)
    say((yes as UByte) as Word)
    nl()
}

let main(argc: UWord, argv: *UByte[]): Word {
    wrapping()
    saturating()
    division()
    shifts()
    bits()
    comparisons()
    casts()
    return 0
}
