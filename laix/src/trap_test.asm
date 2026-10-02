; Boot-time context check through the real BREAK -> M -> IRET path.
; Result 0 = OK, 1..31 = damaged GPR, 32 = SP, 33 = FCSR.
; Retains callee-saved registers, tp and the caller's FCSR as required.
    .text
    .globl trapRegisterSelfTest
trapRegisterSelfTest:
    addi sp, sp, -224
    sw r10, 128(sp)
    sw r11, 132(sp)
    sw r12, 136(sp)
    sw r13, 140(sp)
    sw r14, 144(sp)
    sw r15, 148(sp)
    sw r16, 152(sp)
    sw r17, 156(sp)
    sw r18, 160(sp)
    sw r19, 164(sp)
    sw r20, 168(sp)
    sw r21, 172(sp)
    sw r22, 176(sp)
    sw r23, 180(sp)
    sw r24, 184(sp)
    sw r25, 188(sp)
    sw r26, 192(sp)
    sw r27, 196(sp)
    sw r28, 200(sp)
    sw r29, 204(sp)
    sw ra, 208(sp)
    mfcr r1, fcsr
    sw r1, 212(sp)
    sw sp, 216(sp)
    li r1, 0x61                   ; RUP and NX, distinguish from kernel FCSR
    mtcr fcsr, r1
    li r1, 4097
    li r2, 4098
    li r3, 4099
    li r4, 4100
    li r5, 4101
    li r6, 4102
    li r7, 4103
    li r8, 4104
    li r9, 4105
    li r10, 4106
    li r11, 4107
    li r12, 4108
    li r13, 4109
    li r14, 4110
    li r15, 4111
    li r16, 4112
    li r17, 4113
    li r18, 4114
    li r19, 4115
    li r20, 4116
    li r21, 4117
    li r22, 4118
    li r23, 4119
    li r24, 4120
    li r25, 4121
    li r26, 4122
    li r27, 4123
    li r28, 4124
    li r29, 4125
    li ra, 4127
    break
    ; Capture every returned register before using any as temporaries.
    sw r0, 0(sp)
    sw r1, 4(sp)
    sw r2, 8(sp)
    sw r3, 12(sp)
    sw r4, 16(sp)
    sw r5, 20(sp)
    sw r6, 24(sp)
    sw r7, 28(sp)
    sw r8, 32(sp)
    sw r9, 36(sp)
    sw r10, 40(sp)
    sw r11, 44(sp)
    sw r12, 48(sp)
    sw r13, 52(sp)
    sw r14, 56(sp)
    sw r15, 60(sp)
    sw r16, 64(sp)
    sw r17, 68(sp)
    sw r18, 72(sp)
    sw r19, 76(sp)
    sw r20, 80(sp)
    sw r21, 84(sp)
    sw r22, 88(sp)
    sw r23, 92(sp)
    sw r24, 96(sp)
    sw r25, 100(sp)
    sw r26, 104(sp)
    sw r27, 108(sp)
    sw r28, 112(sp)
    sw r29, 116(sp)
    sw sp, 120(sp)
    sw ra, 124(sp)
    li r1, 0                      ; check r0, then seeded r1..r29
    mv r2, sp
.check:
    lw r3, 0(r2)
    beqz r1, .zero
    addi r4, r1, 4096
    j .compare
.zero:
    li r4, 0
.compare:
    bne r3, r4, .done
    addi r1, r1, 1
    addi r2, r2, 4
    li r4, 30
    bltu r1, r4, .check
    li r1, 31
    lw r3, 124(sp)
    li r4, 4127
    bne r3, r4, .done
    li r1, 32
    lw r3, 120(sp)
    lw r4, 216(sp)
    bne r3, r4, .done
    li r1, 33
    mfcr r3, fcsr
    li r4, 0x61
    bne r3, r4, .done
    li r1, 0
.done:
    lw r2, 212(sp)
    mtcr fcsr, r2
    lw r10, 128(sp)
    lw r11, 132(sp)
    lw r12, 136(sp)
    lw r13, 140(sp)
    lw r14, 144(sp)
    lw r15, 148(sp)
    lw r16, 152(sp)
    lw r17, 156(sp)
    lw r18, 160(sp)
    lw r19, 164(sp)
    lw r20, 168(sp)
    lw r21, 172(sp)
    lw r22, 176(sp)
    lw r23, 180(sp)
    lw r24, 184(sp)
    lw r25, 188(sp)
    lw r26, 192(sp)
    lw r27, 196(sp)
    lw r28, 200(sp)
    lw r29, 204(sp)
    lw ra, 208(sp)
    addi sp, sp, 224
    ret
