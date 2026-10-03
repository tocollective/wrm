    .rodata
    .align 4
    .globl rodataWriteTarget
rodataWriteTarget:
    .word 0x12345678
    .text
    .globl triggerRodataWrite, rodataWriteInstruction
triggerRodataWrite:
    la r1, rodataWriteTarget
rodataWriteInstruction:
    sw r0, 0(r1)
    ret
