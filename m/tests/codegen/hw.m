// Hardware and the rest: Float, packed structs, volatile copies, atomics,
// control registers, asm, syscall (with the handler in hw.asm). The Float
// variables are 'let mut', so the arithmetic runs on the machine.
// @output "float 2500 -2 7 2147483647 -2147483648 1 1 0 3 255 0 255 -128 0 1\n"
// @output "packed 7 305419896 4660 2 7 | 12 4 | 9 3\n"
// @output "volatile 1 2 3\n"
// @output "atomic 5 9 5 12 3 12 4 7\n"
// @output "cpu 0 51966 77\n"
// @output "syscall 721 112 -1\n"
// @exit 0

import { puts } from "../../examples/externs.m"
import { putd, say, sayu, nl } from "lib/print.m"

let floats(): Void {
    puts("float")
    let mut a: Float = 1.5
    let mut b: Float = 3.5
    let mut avg: Float = (a + b) / 2.0
    say((avg * 1000.0) as Word)
    let mut h: Float = -2.75
    say(h as Word)
    let mut n: Word = 7
    say((n as Float) as Word)
    let mut big: Float = 3000000000.0
    say(big as Word)
    say(-big as Word)
    let mut zero: Float = 0.0
    let mut one: Float = 1.0
    let mut inf: Float = one / zero
    let mut nan: Float = zero / zero
    say((inf > big) as Word)
    say((nan != nan) as Word)
    say((nan == nan) as Word)
    let mut u: UWord = 3
    say((u as Float) as Word)
    // Float to a narrow integer saturates to its range; NaN is the maximum
    let mut f300: Float = 300.0
    say((f300 as UByte) as Word)
    say((-f300 as UByte) as Word)
    say((nan as UByte) as Word)
    say((-f300 as Byte) as Word)
    say((zero < -zero) as Word)
    say((zero == -zero) as Word)
    nl()
}

packed type Header {
    kind:   UByte,
    length: UWord,
    flags:  UHalf,
}

packed type Outer {
    tag:   UByte,
    inner: Header,
}

type Aligned {
    a: UByte,
    b: UWord,
}

let packedStructs(): Void {
    puts("packed")
    let mut h: Header = { .kind = 7, .length = 0x1234_5678, .flags = 0x1234 }
    sayu(h.kind as UWord)
    sayu(h.length)
    sayu(h.flags as UWord)
    h.length = 2
    sayu(h.length)
    let p: *UByte = &h.kind
    sayu(*p as UWord)
    puts(" |")
    let mut o: Outer = { .tag = 1, .inner = h }
    o.inner.length = o.inner.length + 10
    sayu(o.inner.length)
    sayu(sizeof(Header) as UWord - 3)
    puts(" |")
    let mut arr: Header[2]
    arr[1].flags = 9
    sayu(arr[1].flags as UWord)
    sayu(alignof(Aligned) - 1)
    nl()
}

type Regs {
    a: UWord,
    b: UByte,
    c: UHalf,
}

let volatiles(): Void {
    puts("volatile")
    let mut regs: Regs = { .a = 1, .b = 2, .c = 3 }
    let dev: *volatile mut Regs = &mut regs
    let copy: Regs = *dev
    sayu(copy.a)
    sayu(copy.b as UWord)
    *dev = copy
    sayu(dev.c as UWord)
    nl()
}

let mut counter: Word
let mut lock: UWord

let atomics(): Void {
    puts("atomic")
    atomicStore(&mut counter, 5)
    say(atomicLoad(&counter))
    say(atomicSwap(&mut counter, 9) + 4)
    say(atomicAdd(&mut counter, 3) - 4)
    say(counter)
    say(atomicCompareSwap(&mut counter, 0, 1) - 9)
    say(counter)
    say(atomicCompareSwap(&mut counter, 12, 4) - 8)
    say(counter + 3)
    nl()
}

let mut asmFlag: UWord
export { asmFlag }

let STATUS: UWord = 0
let IVEC: UWord = 2
let SCRATCH: UWord = 3
let STATUS_EXL: UWord = 0x10

let cpu(): Void {
    puts("cpu")
    sayu(mfcr(STATUS))
    mtcr(SCRATCH, 0xCAFE)
    sayu(mfcr(SCRATCH))
    asm {
        "li r8, 77"
        "la r9, asmFlag"
        "sw r8, 0(r9)"
    }
    sayu(asmFlag)
    nl()
}

extern let syscallHandler(): Void

let calls(): Void {
    puts("syscall")
    mtcr(IVEC, syscallHandler as UWord)
    mtcr(STATUS, mfcr(STATUS) & ~STATUS_EXL)
    say(syscall(7, 1, 2, 3, 4, 5, 6))
    // the handler adds all six registers, so every call passes six
    let keep: Word = 5
    say(syscall(1, 3, 4, 0, 0, 0, 0) + keep)
    let p: *UByte = "x"
    say(syscall(0, p, 0, 0, 0, 0, 0) - (p as UWord as Word) - 1)
    nl()
}

let main(argc: UWord, argv: *UByte[]): Word {
    floats()
    packedStructs()
    volatiles()
    atomics()
    cpu()
    calls()
    return 0
}
