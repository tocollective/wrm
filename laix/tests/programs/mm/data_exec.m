// Custom LA/IX runtime. Expected: CAUSE=8 (fetch page fault),
// EPC=BADADDR=&dataExecTarget, r31=&dataExecReturn, stage=data-exec-test,
// exit 254. Kernel W^X: .data is mapped RW without X. The target word is
// 0x00 (HLT), so an executable mapping would exit 0 instead.
import { kernelInit } from "../../../src/kernel/boot.m"
import { panic, setPanicStage } from "../../../src/kernel/panic.m"
extern let triggerDataExec(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("data-exec-test")
    triggerDataExec()
    panic("call into kernel data unexpectedly returned", null)
    return 1
}
