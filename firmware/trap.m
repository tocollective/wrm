// Traps: trapEntry (trap.asm) saves the registers and calls trap(), which
// dispatches interrupts to handlers by PIC line and everything else to
// the handler a demo installs.

import { pic, power, CR_IVEC, CR_CAUSE, CR_EPC, CAUSE_INTERRUPT } from "defs.m"
import { puts, show } from "lib.m"

/// What trapEntry saves: r1-r9, ra and the interrupted sp. The other
/// registers are kept by trap() itself, as by any M function.
type TrapFrame {
    regs: UWord[9],     // r1-r9
    ra:   UWord,
    sp:   UWord,
}

type IrqHandler = (): Void
type FaultHandler = (frame: *mut TrapFrame, cause: UWord): Void

let IRQ_LINES: UWord = 16
let EXIT_TRAP: UWord = 254

let mut irqHandlers: IrqHandler[16]
let mut faultHandler: FaultHandler = null

/// Interrupts taken, of any line.
let mut irqCount: UWord

extern let trapEntry(): Void

/// Sends every trap to trapEntry.
let trapInstall(): Void {
    mtcr(CR_IVEC, trapEntry as UWord)
}

let setIrqHandler(irq: UWord, handler: IrqHandler): Void {
    irqHandlers[irq] = handler
}

/// The handler of system calls and faults, null for none.
let setFaultHandler(handler: FaultHandler): Void {
    faultHandler = handler
}

/// Called by trapEntry with interrupts off; EPC is the interrupted
/// instruction.
let trap(frame: *mut TrapFrame): Void {
    let cause: UWord = mfcr(CR_CAUSE)
    if cause == CAUSE_INTERRUPT {
        irqCount++
        while true {
            let irq: UWord = pic.claim      // the lowest active line
            if irq >= IRQ_LINES || irqHandlers[irq] == null return
            irqHandlers[irq]()
        }
    }
    if faultHandler != null {
        faultHandler(frame, cause)
        return
    }
    puts("unexpected trap\n")
    show("  CAUSE", cause)
    show("  EPC", mfcr(CR_EPC))
    power.off = EXIT_TRAP
}

export { TrapFrame, IrqHandler, FaultHandler, irqCount, trapInstall, setIrqHandler }
export { setFaultHandler, trap }
