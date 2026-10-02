    .data
    .align 4
    .globl dataExecTarget
dataExecTarget:
    .word 0                         ; HLT, never fetched under W^X

    .text
    .globl triggerDataExec, dataExecReturn
triggerDataExec:
    addi sp, sp, -8
    sw ra, 0(sp)
    la r1, dataExecTarget
    jalr r1                         ; ra = dataExecReturn, pc = dataExecTarget
dataExecReturn:
    lw ra, 0(sp)
    addi sp, sp, 8
    ret
