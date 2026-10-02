// Expected: CAUSE=3, BADADDR=00001001, EPC=&trapFaultInstruction, exit 254.
// No consoleInit: fatal diagnostics must not depend on the font/disk.
import { kernelInit } from "../src/boot.m"
import { panic, setPanicStage } from "../src/panic.m"
extern let triggerMisalignedLoad(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("trap-fault-test")
    triggerMisalignedLoad()
    panic("misaligned load unexpectedly returned", null)
    return 1
}
