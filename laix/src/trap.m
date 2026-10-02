import { TrapFrame } from "trap_frame.m"
import { panic } from "panic.m"

extern let trapEntry(): Void
extern let trapRegisterSelfTest(): Word
extern let kernelStackBottom: UWord
let STACK_CANARY: UWord = 0x4C414958
let mut breakCount: UWord

let trapDispatch(frame: *mut TrapFrame): Void {
    // Entry currently supports only a trusted supervisor stack, no nesting.
    if kernelStackBottom != STACK_CANARY {
        panic("kernel stack canary damaged", frame)
        return
    }
    if frame.status & 8 != 0 {
        panic("user tasks are not supported yet", frame)
        return
    }
    switch frame.cause {
        case 13: {
            breakCount++
            frame.epc += 4
            return
        }
        case 12: {
            frame.regs[1] = (-38 as Word) as UWord
            frame.epc += 4
            return
        }
        default: panic("unexpected exception", frame)
    }
}

let trapBreakCount(): UWord {
    return breakCount
}

export { trapEntry, trapRegisterSelfTest, trapDispatch, trapBreakCount }
