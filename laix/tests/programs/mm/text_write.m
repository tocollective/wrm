// Custom LA/IX runtime. Expected: CAUSE=10 (store page fault),
// BADADDR=&triggerTextWrite, EPC=&textWriteInstruction,
// stage=text-write-test, exit 254. Kernel W^X: .text is mapped RX.
import { kernelInit } from "../../../src/kernel/boot.m"
import { panic, setPanicStage } from "../../../src/kernel/panic.m"
extern let triggerTextWrite(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("text-write-test")
    triggerTextWrite()
    panic("store to kernel code unexpectedly returned", null)
    return 1
}
