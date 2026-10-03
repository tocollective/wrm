// Expected: CAUSE=10, BADADDR=rodataWriteTarget,
// EPC=rodataWriteInstruction, stage=rodata-write-test, exit 254.
import { kernelInit } from "../../../src/kernel/boot.m"
import { panic, setPanicStage } from "../../../src/kernel/panic.m"
extern let triggerRodataWrite(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("rodata-write-test")
    triggerRodataWrite()
    panic("store to kernel constant unexpectedly returned", null)
    return 1
}
