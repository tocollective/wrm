import { STACK_CANARY, KERNEL_STACK_BOTTOM, KERNEL_STACK_TOP, CAUSE_BREAKPOINT, CAUSE_SYSCALL,
    INSTRUCTION_BYTES, REG_RESULT, REG_SYSCALL, ERRNO_ENOSYS, ERRNO_EINVAL,
    SYS_DEBUG_PUT_CHAR, SYS_EXIT, STATUS_PUM } from "../arch/wrm081632/defs.m"
import { TrapFrame } from "trap_frame.m"
import { panic } from "../kernel/panic.m"
import { taskSaveContext, taskOwnsTrap, taskFinish } from "../task/task.m"
import { debugPutChar } from "../drivers/debug_uart.m"

extern let trapEntry(): Void
extern let trapRegisterSelfTest(): Word
// BSS starts at zero = nothing expected: BREAK and SYSCALL are never cause 0.
let NO_EXPECTED_TRAP: UWord = 0
let mut expectedTrap: UWord

// Arms one supervisor BREAK or SYSCALL for a self-test. Any other one is a
// kernel bug and panics instead of being skipped.
let trapExpect(cause: UWord): Void {
    expectedTrap = cause
}

let trapExpectationMet(): Bool {
    return expectedTrap == NO_EXPECTED_TRAP
}

let takeExpectedTrap(frame: *TrapFrame): Bool {
    if frame.status & STATUS_PUM != 0 || frame.cause != expectedTrap return false
    expectedTrap = NO_EXPECTED_TRAP
    return true
}

let userSyscall(frame: *mut TrapFrame): Void {
    // Read the saved ABI registers, never live dispatcher argument registers.
    // All outcomes consume this instruction exactly once, including exit.
    frame.epc += INSTRUCTION_BYTES
    switch frame.regs[REG_SYSCALL] {
        case SYS_DEBUG_PUT_CHAR: {
            let code: UWord = frame.regs[1]
            if code > 255 frame.regs[REG_RESULT] = (-ERRNO_EINVAL) as UWord
            else {
                debugPutChar(code)
                frame.regs[REG_RESULT] = 0
            }
            taskSaveContext(frame)
            return
        }
        case SYS_EXIT:
            taskFinish(frame, frame.regs[1] as Word, false)
            return
        default:
            frame.regs[REG_RESULT] = (-ERRNO_ENOSYS) as UWord
            taskSaveContext(frame)
            return
    }
}

let trapDispatch(frame: *mut TrapFrame): Void {
    // The entry selected and checked the current task's trusted kernel stack.
    // No nesting: low entry state remains stable until IRET.
    let bottomSlot: *UWord = KERNEL_STACK_BOTTOM as *UWord
    let bottom: *UWord = *bottomSlot as *UWord
    if *bottom != STACK_CANARY {
        panic("kernel stack canary damaged", frame)
        return
    }
    if frame.status & STATUS_PUM != 0 {
        if !taskOwnsTrap(frame) {
            panic("user trap without running task", frame)
            return
        }
        taskSaveContext(frame)
        if frame.cause == CAUSE_SYSCALL userSyscall(frame)
        else taskFinish(frame, frame.cause as Word, true)
        return
    }
    switch frame.cause {
        case CAUSE_BREAKPOINT: {
            if !takeExpectedTrap(frame) {
                panic("unexpected breakpoint", frame)
                return
            }
            frame.epc += INSTRUCTION_BYTES
            return
        }
        case CAUSE_SYSCALL: {
            if !takeExpectedTrap(frame) {
                panic("unexpected syscall", frame)
                return
            }
            frame.regs[REG_RESULT] = (-ERRNO_ENOSYS) as UWord
            frame.epc += INSTRUCTION_BYTES
            return
        }
        default: panic("unexpected exception", frame)
    }
}

// trapEntry's .bad_stack path, on its static emergency stack after the early
// UART line: the trusted kernel stack failed its checks. frame is a static
// copy of the interrupted context; its r30 is the interrupted sp.
let trapBadStack(frame: *TrapFrame, rejectedSp: UWord): Void {
    let bottom: *UWord = KERNEL_STACK_BOTTOM as *UWord
    let top: *UWord = KERNEL_STACK_TOP as *UWord
    panic("invalid kernel stack: sp=$h, bounds $h..$h", frame, rejectedSp, *bottom, *top)
}

export { trapEntry, trapRegisterSelfTest, trapDispatch, trapBadStack, trapExpect,
    trapExpectationMet }
