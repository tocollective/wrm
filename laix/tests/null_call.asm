    .text
    .globl triggerNullCall, nullCallReturn
triggerNullCall:
    addi sp, sp, -8
    sw ra, 0(sp)
    li r1, 0
    jalr r1                         ; ra = nullCallReturn, pc = 0
nullCallReturn:
    lw ra, 0(sp)
    addi sp, sp, 8
    ret
