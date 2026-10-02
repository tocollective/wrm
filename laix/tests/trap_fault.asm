    .text
    .globl triggerMisalignedLoad, trapFaultInstruction
triggerMisalignedLoad:
    li r1, 0x1001
trapFaultInstruction:
    lw r1, 0(r1)
    ret
