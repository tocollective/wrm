// Built-in functions for special instructions. Their names are reserved:
// you cannot declare your own 'mfcr' or 'fence'.
//
//   mfcr(N): UWord          MFCR rd, N    N must be a constant (it is imm14)
//   mtcr(N, x: UWord)       MTCR N, rx
//   syscall(n, a1, ..., a6) SYSCALL       0 to 6 arguments, result in r1
//   wfi(), hlt()            WFI, HLT
//   tlbi(addr: UWord)       TLBI
//   fence()                 FENCE
//   breakpoint()            BREAK
//
// Atomics work on Word, UWord and pointers, aligned to 4 bytes. The compiler
// expands them into an LL/SC loop:
//   atomicLoad(p), atomicStore(p, v)
//   atomicSwap(p, v), atomicAdd(p, v)        return the old value
//   atomicCompareSwap(p, expected, v)        writes v only if *p == expected,
//                                            returns the old value
//
// 'asm { ... }' copies lines of assembly into the output. It has no operands,
// and the compiler treats it like a function call: it may change memory and
// every caller-saved register.

// Control registers (INSTRUCTIONS, "Control registers")
let CR_STATUS: UWord   = 0
let CR_EPC: UWord      = 1
let CR_CAUSE: UWord    = 4
let CR_PTBR: UWord     = 6
let CR_CYCLE: UWord    = 7
let CR_CYCLEH: UWord   = 8

let STATUS_IE: UWord   = 1 << 0

let SYS_WRITE: UWord   = 1  // the number is defined by the kernel

let enableInterrupts(): Void {
    mtcr(CR_STATUS, mfcr(CR_STATUS) | STATUS_IE)
}

// Returns the old STATUS, to restore it later
let disableInterrupts(): UWord {
    let old: UWord = mfcr(CR_STATUS)
    mtcr(CR_STATUS, old & ~STATUS_IE)
    return old
}

let restoreInterrupts(status: UWord): Void {
    mtcr(CR_STATUS, status)
}

// The 64-bit cycle counter is read as two words. Read the high half twice
// and retry if it changed in between (INSTRUCTIONS, "Counters").
type Cycles {
    lo: UWord,
    hi: UWord,
}

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

// Compile error: the register number must be a constant
//     let mut n: UWord = 4             // not a constant: it can change
//     let x: UWord = mfcr(n)

let write(fd: Word, buf: *UByte, len: UWord): Word {
    return syscall(SYS_WRITE, fd, buf, len)
}

let idle(): Void {
    while true wfi()
}

let check(ok: Bool): Void {
    if !ok breakpoint()
}

let switchAddressSpace(pageDir: UWord): Void {
    mtcr(CR_PTBR, pageDir)
}

let unmapPage(addr: UWord): Void {
    // ...clear the PTE, then drop the old translation
    tlbi(addr)
}

let haltMachine(): Void {
    asm {
        "fence"
        "hlt"
    }
}

// A spinlock
let mut lock: UWord

let acquire(l: *mut UWord): Void {
    while atomicSwap(l, 1) != 0 {}
}

let release(l: *mut UWord): Void {
    atomicStore(l, 0)
}

// A counter shared with an interrupt handler
let mut events: UWord

let nextEvent(): UWord {
    return atomicAdd(&mut events, 1)
}

// Raise *p to v, if v is larger, without a lock
let atomicMax(p: *mut UWord, v: UWord): Void {
    let mut old: UWord = atomicLoad(p)
    while old < v {
        let seen: UWord = atomicCompareSwap(p, old, v)
        if seen == old return
        old = seen
    }
}

// Compile error: atomics work only on words and pointers
//     let mut flag: UByte = 0
//     atomicSwap(&mut flag, 1)

let main(argc: UWord, argv: *UByte[]): Word {
    let status: UWord = disableInterrupts()
    acquire(&mut lock)
    let id: UWord = nextEvent()
    atomicMax(&mut events, 100)
    release(&mut lock)
    restoreInterrupts(status)

    let start: Cycles = readCycles()
    if write(1, "hi\n", 3) < 0 breakpoint()
    check(argc > 0)
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
