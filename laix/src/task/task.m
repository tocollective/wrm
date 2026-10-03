// Stage 3: one task, one reserved kernel stack, no scheduler or IRQs yet.
import { PAGE_SIZE, WORD_BYTES, GPR_COUNT, REG_SP, STATUS_IE, STATUS_PUM,
    STATUS_EXL, CR_STATUS, CR_PTBR, PTBR_ENABLE, PTE_U, PTE_RX, PTE_RW,
    STACK_CANARY, KERNEL_SP, KERNEL_STACK_BOTTOM, KERNEL_STACK_TOP, PIC_ENABLE } from "../arch/wrm081632/defs.m"
import { TrapFrame } from "../trap/trap_frame.m"
import { PAGE_NONE, PAGE_USER, PAGE_USER_STACK, allocTaskPages, freePage,
    physicalPageOwned } from "../mm/memory.m"
import { USER_VA_START, USER_VA_END, mmuCreateAddressSpace, mmuDestroyAddressSpace,
    mmuSwitchAddressSpace, mmuActivateKernel, mapPage } from "../mm/mmu.m"
import { panic } from "../kernel/panic.m"
import { debugPrint } from "../drivers/debug_uart.m"

let TASK_EMPTY: UWord = 0
let TASK_READY: UWord = 1
let TASK_RUNNING: UWord = 2
let TASK_EXITED: UWord = 3
let TASK_FAULTED: UWord = 4
let TASK_ID: UWord = 1
let USER_CODE: UWord = USER_VA_START
let USER_DATA: UWord = USER_CODE + PAGE_SIZE
let USER_STACK_TOP: UWord = USER_VA_END
let USER_STACK_BOTTOM: UWord = USER_STACK_TOP - PAGE_SIZE
let USER_STACK_GUARD: UWord = USER_STACK_BOTTOM - PAGE_SIZE
let TASK_PAGE_COUNT: UWord = 3

type Task {
    id: UWord,
    directory: *mut UWord,
    userCode: UWord,
    userData: UWord,
    userStackBottom: UWord,
    userStackTop: UWord,
    kernelStackBottom: UWord,
    kernelStackTop: UWord,
    context: TrapFrame,
    state: UWord,
    exitCode: Word,
}

align(8) let mut firstTask: Task
// Constructed before user entry, never derived from the interrupted user GPRs.
align(8) let mut kernelContext: TrapFrame
// Trusted creation ledger; MMU owns references after mapping.
let taskPurposes: UWord[TASK_PAGE_COUNT] = [PAGE_USER, PAGE_USER, PAGE_USER_STACK]
let mut taskPages: UWord[TASK_PAGE_COUNT]
extern let taskKernelStackBottom: UWord
extern let taskKernelStackTop: UByte
extern let kernelStackBottom: UWord
extern let kernelStackTop: UByte
extern let taskKernelResume: UByte
extern let userCodeStart: UByte
extern let userCodeEnd: UByte
extern let trapRestoreFrame(frame: *TrapFrame): Void

let taskIrqsDisabled(): Bool {
    let enabled: *volatile UWord = PIC_ENABLE as *volatile UWord
    return mfcr(CR_STATUS) & STATUS_IE == 0 && *enabled == 0
}

// Release an inactive task root: preparation rollback or terminal cleanup
// after leaving its kernel stack. Destroy releases mapped frames; remaining
// ledger entries are still owned.
let taskRollback(): Void {
    if firstTask.directory != null && !mmuDestroyAddressSpace(firstTask.directory, TASK_ID) {
        panic("could not roll back task directory", null)
        return
    }
    firstTask.directory = null
    for i: UWord in 0..TASK_PAGE_COUNT {
        if physicalPageOwned(taskPages[i], TASK_ID, taskPurposes[i]) &&
            !freePage(taskPages[i], TASK_ID, taskPurposes[i]) {
            panic("could not roll back task page", null)
            return
        }
        taskPages[i] = PAGE_NONE
    }
}

let taskPrepare(): Bool {
    if firstTask.state != TASK_EMPTY || !taskIrqsDisabled() return false
    let codeBytes: UWord = (&userCodeEnd as UWord) - (&userCodeStart as UWord)
    if codeBytes == 0 || codeBytes > PAGE_SIZE || codeBytes % WORD_BYTES != 0 return false
    firstTask.directory = mmuCreateAddressSpace(TASK_ID) as *mut UWord
    if firstTask.directory == null return false
    if !allocTaskPages(TASK_ID, &taskPurposes[0], &mut taskPages[0], TASK_PAGE_COUNT) {
        taskRollback()
        return false
    }
    // Copy before granting X: afterwards the shared kernel alias is read-only.
    let source: *UWord = &userCodeStart as *UWord
    let code: *mut UWord = taskPages[0] as *mut UWord
    for i: UWord in 0..(codeBytes / WORD_BYTES) code[i] = source[i]
    if !mapPage(firstTask.directory, TASK_ID, USER_CODE, taskPages[0], PTE_RX | PTE_U) ||
        !mapPage(firstTask.directory, TASK_ID, USER_DATA, taskPages[1], PTE_RW | PTE_U) ||
        !mapPage(firstTask.directory, TASK_ID, USER_STACK_BOTTOM, taskPages[2], PTE_RW | PTE_U) {
        taskRollback()
        return false
    }
    firstTask.id = TASK_ID
    firstTask.userCode = USER_CODE
    firstTask.userData = USER_DATA
    firstTask.userStackBottom = USER_STACK_BOTTOM
    firstTask.userStackTop = USER_STACK_TOP
    firstTask.kernelStackBottom = &taskKernelStackBottom as UWord
    firstTask.kernelStackTop = &taskKernelStackTop as UWord
    let stack: *mut UWord = firstTask.kernelStackBottom as *mut UWord
    let stackWords: UWord = (firstTask.kernelStackTop - firstTask.kernelStackBottom) / WORD_BYTES
    for i: UWord in 0..stackWords stack[i] = 0
    stack[0] = STACK_CANARY
    // Private entry ABI: r1=data base, r2=data bytes, sp=aligned stack top.
    // No TLS: tp/r28=0, fp/r29=0, ra=0; no argc/argv or boot pointers.
    for i: UWord in 0..GPR_COUNT firstTask.context.regs[i] = 0
    firstTask.context.regs[1] = USER_DATA
    firstTask.context.regs[2] = PAGE_SIZE
    firstTask.context.regs[REG_SP] = USER_STACK_TOP
    firstTask.context.epc = USER_CODE
    firstTask.context.status = STATUS_EXL | STATUS_PUM // PIE=PSS=IE=UM=SS=0
    firstTask.context.cause = 0
    firstTask.context.badaddr = 0
    firstTask.context.fcsr = 0
    firstTask.context.ptbr = (firstTask.directory as UWord) | PTBR_ENABLE // ASID 0
    firstTask.context.reserved[0] = 0
    firstTask.context.reserved[1] = 0
    firstTask.state = TASK_READY
    return true
}

let taskStart(): Void {
    if firstTask.state != TASK_READY || !taskIrqsDisabled() {
        panic("invalid first task entry", null)
        return
    }
    for i: UWord in 0..GPR_COUNT kernelContext.regs[i] = 0
    kernelContext.regs[REG_SP] = &kernelStackTop as UWord
    kernelContext.epc = &taskKernelResume as UWord
    kernelContext.status = STATUS_EXL // IRET: supervisor, IRQs and single-step off
    kernelContext.cause = 0
    kernelContext.badaddr = 0
    kernelContext.fcsr = 0
    kernelContext.ptbr = mfcr(CR_PTBR)
    kernelContext.reserved[0] = 0
    kernelContext.reserved[1] = 0
    // Boot stack and all entry/restore instructions survive the root switch.
    if !mmuSwitchAddressSpace(firstTask.directory, firstTask.id, 0) {
        panic("could not activate task directory", null)
        return
    }
    if mfcr(CR_PTBR) != firstTask.context.ptbr {
        panic("task PTBR does not match saved context", null)
        return
    }
    let bottom: *mut UWord = KERNEL_STACK_BOTTOM as *mut UWord
    let top: *mut UWord = KERNEL_STACK_TOP as *mut UWord
    let spSlot: *mut UWord = KERNEL_SP as *mut UWord
    bottom[0] = firstTask.kernelStackBottom
    top[0] = firstTask.kernelStackTop
    spSlot[0] = firstTask.kernelStackTop
    firstTask.state = TASK_RUNNING
    fence()
    trapRestoreFrame(&firstTask.context)
}

// The live trap stays on the task kernel stack; keep its last saved context
// in the TCB as well. Supervisor self-tests do not belong to this task.
let taskSaveContext(frame: *TrapFrame): Void {
    if firstTask.state == TASK_RUNNING && frame.status & STATUS_PUM != 0 {
        firstTask.context = *frame
    }
}

let taskOwnsTrap(frame: *TrapFrame): Bool {
    return firstTask.state == TASK_RUNNING && frame.status & STATUS_PUM != 0 &&
        frame.ptbr == firstTask.context.ptbr && mfcr(CR_PTBR) == frame.ptbr
}

// The current stack and frame are common supervisor mappings in both roots.
// Retain the terminal user context for diagnostics; IRET uses only trusted data.
let taskFinish(frame: *mut TrapFrame, code: Word, faulted: Bool): Void {
    if !taskOwnsTrap(frame) {
        panic("user trap without running task", frame)
        return
    }
    taskSaveContext(frame)
    firstTask.exitCode = code
    if faulted firstTask.state = TASK_FAULTED
    else firstTask.state = TASK_EXITED
    if !mmuActivateKernel() || mfcr(CR_PTBR) != kernelContext.ptbr {
        panic("could not restore kernel directory", frame)
        return
    }
    let bottom: *mut UWord = KERNEL_STACK_BOTTOM as *mut UWord
    let top: *mut UWord = KERNEL_STACK_TOP as *mut UWord
    let spSlot: *mut UWord = KERNEL_SP as *mut UWord
    bottom[0] = &kernelStackBottom as UWord
    top[0] = &kernelStackTop as UWord
    spSlot[0] = &kernelStackTop as UWord
    frame[0] = kernelContext
    fence()
}

// Called only by taskKernelResume, after IRET onto the boot kernel stack.
let taskReap(): Void {
    if ((firstTask.state != TASK_EXITED && firstTask.state != TASK_FAULTED) ||
        mfcr(CR_PTBR) != kernelContext.ptbr || !taskIrqsDisabled()) {
        panic("invalid task cleanup context", null)
        return
    }
    taskRollback()
    debugPrint("LA/IX: task $u stopped, state=$u code=$i cause=$u epc=$h\n",
        firstTask.id, firstTask.state, firstTask.exitCode,
        firstTask.context.cause, firstTask.context.epc)
}

export { Task, firstTask, TASK_EMPTY, TASK_READY, TASK_RUNNING, TASK_EXITED, TASK_FAULTED, TASK_ID,
    USER_CODE, USER_DATA, USER_STACK_BOTTOM, USER_STACK_TOP, USER_STACK_GUARD,
    taskPrepare, taskStart, taskSaveContext, taskOwnsTrap, taskFinish, taskReap }
