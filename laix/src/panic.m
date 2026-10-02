import { TrapFrame } from "trap_frame.m"
import { debugPrint, debugHex, debugPutChar } from "debug_uart.m"

let mut panicStage: *UByte = "startup"
let PANIC_POWER: *volatile mut UWord = 0xFD004000 as *volatile mut UWord

let setPanicStage(stage: *UByte): Void {
    panicStage = stage
}

let causeName(cause: UWord): *UByte {
    switch cause {
        case 0: return "interrupt"
        case 1: return "illegal instruction"
        case 2: return "misaligned fetch"
        case 3: return "misaligned load"
        case 4: return "misaligned store"
        case 5: return "fetch bus error"
        case 6: return "load bus error"
        case 7: return "store bus error"
        case 8: return "fetch page fault"
        case 9: return "load page fault"
        case 10: return "store page fault"
        case 11: return "privileged instruction"
        case 12: return "syscall"
        case 13: return "breakpoint"
        case 14: return "single step"
        case 15: return "debug trigger"
    }
    return "unknown"
}

let panic(reason: *UByte, frame: *TrapFrame): Void {
    // Fatal path: supervisor, IRQs off, no nested exceptions.
    mtcr(0, 0x10)
    debugPrint("\nLA/IX PANIC: ")
    debugPrint(reason)
    debugPrint("\nstage=")
    debugPrint(panicStage)
    if frame != null {
        if frame.status & 8 != 0 debugPrint(" origin=user\n")
        else debugPrint(" origin=supervisor\n")
        debugPrint("cause=")
        debugHex(frame.cause)
        debugPrint(" (")
        debugPrint(causeName(frame.cause))
        debugPrint(")\nepc=")
        debugHex(frame.epc)
        debugPrint(" badaddr=")
        debugHex(frame.badaddr)
        if frame.cause == 0 debugPrint(" (unchanged by IRQ)")
        debugPrint("\nstatus=")
        debugHex(frame.status)
        debugPrint(" ptbr=")
        debugHex(frame.ptbr)
        debugPrint(" fcsr=")
        debugHex(frame.fcsr)
        debugPutChar(10)
        for i: UWord in 0..32 {
            debugPutChar(114)
            debugPutChar(48 + i / 10)
            debugPutChar(48 + i % 10)
            debugPutChar(61)
            debugHex(frame.regs[i])
            if i % 4 == 3 debugPutChar(10)
            else debugPutChar(32)
        }
    } else {
        debugPrint("\n(no trap frame)\n")
    }
    // No dereference of faulting EPC, BADADDR, SP or FP, no screen/disk I/O.
    // A bare headless HLT exits with 0; fatal errors must return failure.
    *PANIC_POWER = 254
    while true { hlt() }
}

export { panic, setPanicStage }
