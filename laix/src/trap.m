import { STACK_CANARY, STATUS_PUM, CAUSE_BREAKPOINT, CAUSE_SYSCALL,
    INSTRUCTION_BYTES, REG_RESULT, ERRNO_ENOSYS } from "defs.m"
import { TrapFrame } from "trap_frame.m"
import { panic } from "panic.m"

extern let trapEntry(): Void
extern let trapRegisterSelfTest(): Word
extern let kernelStackBottom: UWord
let mut breakCount: UWord

let trapDispatch(frame: *mut TrapFrame): Void {
    // Entry currently supports only a trusted supervisor stack, no nesting.
    if kernelStackBottom != STACK_CANARY {
        panic("kernel stack canary damaged", frame)
        return
    }
    if frame.status & STATUS_PUM != 0 {
        panic("user tasks are not supported yet", frame)
        return
    }
    switch frame.cause {
        case CAUSE_BREAKPOINT: {
            breakCount++
            frame.epc += INSTRUCTION_BYTES
            return
        }
        case CAUSE_SYSCALL: {
            frame.regs[REG_RESULT] = (-ERRNO_ENOSYS) as UWord
            frame.epc += INSTRUCTION_BYTES
            return
        }
        default: panic("unexpected exception", frame)
    }
}

let trapBreakCount(): UWord {
    return breakCount
}

export { trapEntry, trapRegisterSelfTest, trapDispatch, trapBreakCount }
