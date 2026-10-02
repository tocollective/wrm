// Bit manipulation built-ins and the floating-point environment: FCSR's
// flags and rounding mode through mfcr/mtcr.
// @output "bits 24 4 13 2018915346 -2147483648 2147483649 1073741824 305419896 32 32\n"
// @output "fenv 8 97 1 0 0\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { say, sayu, nl } from "lib/print.m"

let bits(x: UWord, w: Word, zero: UWord): Void {
    puts("bits")
    sayu(clz(x))
    sayu(ctz(x))
    sayu(popcount(0x12345678))
    sayu(bswap(0x12345678))
    say(bswap(w))
    sayu(rotl(0xC0000000, 1))
    sayu(rotr(1, 2))
    sayu(rotl(0x12345678, 32))
    sayu(clz(zero))
    sayu(ctz(zero))
    nl()
}

let FCSR: UWord = 17
let FCSR_DZ: UWord = 0x08
let FRM_RUP: UWord = 3 << 5

let fenv(one: Float, zero: Float, tiny: Float): Void {
    puts("fenv")
    mtcr(FCSR, 0)
    let inf: Float = one / zero
    sayu(mfcr(FCSR))
    // a tie: up in RUP, to even in RNE
    mtcr(FCSR, FRM_RUP)
    let up: Float = one + tiny
    sayu(mfcr(FCSR))
    say((up > one) as Word)
    mtcr(FCSR, 0)
    let even: Float = one + tiny
    say((even > one) as Word)
    say((inf < one) as Word)
    nl()
}

let main(argc: UWord, argv: *UByte[]): Word {
    bits(0xF0, 0x80, 0)
    // 2^-24 is exact
    fenv(1.0, 0.0, 1.0 / 16777216.0)
    return 0
}
