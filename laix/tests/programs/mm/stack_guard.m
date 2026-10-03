// Custom LA/IX runtime. Expected: CAUSE=10, BADADDR=&kernelStackGuard,
// EPC=&stackGuardFaultInstruction, stage=stack-guard-test, exit 254.
// Keep SP valid so the normal trap handler can report the deliberate fault.
import { kernelInit } from "../../../src/kernel/boot.m"
import { panic, setPanicStage } from "../../../src/kernel/panic.m"
extern let triggerStackGuardFault(): Void

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("stack-guard-test")
    triggerStackGuardFault()
    panic("kernel stack guard write unexpectedly returned", null)
    return 1
}
