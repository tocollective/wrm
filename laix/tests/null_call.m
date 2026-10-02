// Custom LA/IX runtime. Expected: CAUSE=8 (fetch page fault), EPC=00000000,
// BADADDR=00000000, r31=&nullCallReturn, stage=null-call-test, exit 254.
// Page zero is unmapped: a NULL call must fault, not run its word 0x00 (HLT)
// and exit 0 like a clean shutdown.
import { kernelInit } from "../src/boot.m"
import { panic, setPanicStage } from "../src/panic.m"
extern let triggerNullCall(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("null-call-test")
    triggerNullCall()
    panic("NULL call unexpectedly returned", null)
    return 1
}
