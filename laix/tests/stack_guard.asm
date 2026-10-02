    .text
    .globl triggerStackGuardFault, stackGuardFaultInstruction
triggerStackGuardFault:
    la r1, kernelStackGuard
stackGuardFaultInstruction:
    sw r0, 0(r1)
    ret
