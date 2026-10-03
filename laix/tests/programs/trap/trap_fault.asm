    .include "../../../src/arch/wrm081632/defs.inc"
    .text
    .globl triggerMisalignedLoad, trapFaultInstruction
triggerMisalignedLoad:
    li r1, BOOT_INFO + 1
trapFaultInstruction:
    lw r1, 0(r1)
    ret
