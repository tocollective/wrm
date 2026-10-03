import { CR_STATUS, STATUS_EXL, STATUS_PUM, POWER_BASE, PANIC_EXIT_CODE, GPR_COUNT,
    CAUSE_INTERRUPT, CAUSE_ILLEGAL_INSTRUCTION, CAUSE_MISALIGNED_FETCH, CAUSE_MISALIGNED_LOAD,
    CAUSE_MISALIGNED_STORE, CAUSE_FETCH_BUS_ERROR, CAUSE_LOAD_BUS_ERROR, CAUSE_STORE_BUS_ERROR,
    CAUSE_FETCH_PAGE_FAULT, CAUSE_LOAD_PAGE_FAULT, CAUSE_STORE_PAGE_FAULT, CAUSE_PRIVILEGED_INSTRUCTION,
    CAUSE_SYSCALL, CAUSE_BREAKPOINT, CAUSE_SINGLE_STEP, CAUSE_DEBUG_TRIGGER } from "../arch/wrm081632/defs.m"
import { TrapFrame } from "../trap/trap_frame.m"
import { debugPrint } from "../drivers/debug_uart.m"

let mut panicStage: *UByte = "startup"
let PANIC_POWER: *volatile mut UWord = POWER_BASE as *volatile mut UWord
let PANIC_REGS_PER_LINE: UWord = 4

let setPanicStage(stage: *UByte): Void {
    panicStage = stage
}

let causeName(cause: UWord): *UByte {
    switch cause {
        case CAUSE_INTERRUPT: return "interrupt"
        case CAUSE_ILLEGAL_INSTRUCTION: return "illegal instruction"
        case CAUSE_MISALIGNED_FETCH: return "misaligned fetch"
        case CAUSE_MISALIGNED_LOAD: return "misaligned load"
        case CAUSE_MISALIGNED_STORE: return "misaligned store"
        case CAUSE_FETCH_BUS_ERROR: return "fetch bus error"
        case CAUSE_LOAD_BUS_ERROR: return "load bus error"
        case CAUSE_STORE_BUS_ERROR: return "store bus error"
        case CAUSE_FETCH_PAGE_FAULT: return "fetch page fault"
        case CAUSE_LOAD_PAGE_FAULT: return "load page fault"
        case CAUSE_STORE_PAGE_FAULT: return "store page fault"
        case CAUSE_PRIVILEGED_INSTRUCTION: return "privileged instruction"
        case CAUSE_SYSCALL: return "syscall"
        case CAUSE_BREAKPOINT: return "breakpoint"
        case CAUSE_SINGLE_STEP: return "single step"
        case CAUSE_DEBUG_TRIGGER: return "debug trigger"
    }
    return "unknown"
}

let panic(reason: *UByte, frame: *TrapFrame, args: ...): Void {
    // Fatal path: supervisor, IRQs off, no nested exceptions.
    mtcr(CR_STATUS, STATUS_EXL)
    debugPrint("\nLA/IX PANIC: ")
    debugPrint(reason, args)
    debugPrint("\nstage=$s", panicStage)
    if frame != null {
        let mut origin: *UByte = "supervisor"
        if frame.status & STATUS_PUM != 0 origin = "user"
        debugPrint(" origin=$s\ncause=$h ($s)\n", origin, frame.cause, causeName(frame.cause))
        debugPrint("epc=$h badaddr=$h", frame.epc, frame.badaddr)
        if frame.cause == CAUSE_INTERRUPT debugPrint(" (unchanged by IRQ)")
        debugPrint("\nstatus=$h ptbr=$h fcsr=$h\n", frame.status, frame.ptbr, frame.fcsr)
        for i: UWord in 0..GPR_COUNT {
            debugPrint("r$02i=$h", i, frame.regs[i])
            if i % PANIC_REGS_PER_LINE == PANIC_REGS_PER_LINE - 1 debugPrint("\n")
            else debugPrint(" ")
        }
    } else {
        debugPrint("\n(no trap frame)\n")
    }
    // No dereference of faulting EPC, BADADDR, SP or FP, no screen/disk I/O.
    // A bare headless HLT exits with 0; fatal errors must return failure.
    *PANIC_POWER = PANIC_EXIT_CODE
    while true { hlt() }
}

export { panic, setPanicStage }
