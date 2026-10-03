    .text
    .globl triggerTextWrite, textWriteInstruction
triggerTextWrite:
    la r1, triggerTextWrite
textWriteInstruction:
    sw r0, 0(r1)
    ret
