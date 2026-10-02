; Self-test stack: returned GPR snapshot followed by preserved ABI state.
TEST_GPR_SEED = 4096
TEST_FCSR = FCSR_ROUND_UP | FCSR_NX
TEST_SAVE_BASE = GPR_COUNT * WORD_BYTES
TEST_SAVE_R10 = TEST_SAVE_BASE + 0 * WORD_BYTES
TEST_SAVE_R11 = TEST_SAVE_BASE + 1 * WORD_BYTES
TEST_SAVE_R12 = TEST_SAVE_BASE + 2 * WORD_BYTES
TEST_SAVE_R13 = TEST_SAVE_BASE + 3 * WORD_BYTES
TEST_SAVE_R14 = TEST_SAVE_BASE + 4 * WORD_BYTES
TEST_SAVE_R15 = TEST_SAVE_BASE + 5 * WORD_BYTES
TEST_SAVE_R16 = TEST_SAVE_BASE + 6 * WORD_BYTES
TEST_SAVE_R17 = TEST_SAVE_BASE + 7 * WORD_BYTES
TEST_SAVE_R18 = TEST_SAVE_BASE + 8 * WORD_BYTES
TEST_SAVE_R19 = TEST_SAVE_BASE + 9 * WORD_BYTES
TEST_SAVE_R20 = TEST_SAVE_BASE + 10 * WORD_BYTES
TEST_SAVE_R21 = TEST_SAVE_BASE + 11 * WORD_BYTES
TEST_SAVE_R22 = TEST_SAVE_BASE + 12 * WORD_BYTES
TEST_SAVE_R23 = TEST_SAVE_BASE + 13 * WORD_BYTES
TEST_SAVE_R24 = TEST_SAVE_BASE + 14 * WORD_BYTES
TEST_SAVE_R25 = TEST_SAVE_BASE + 15 * WORD_BYTES
TEST_SAVE_R26 = TEST_SAVE_BASE + 16 * WORD_BYTES
TEST_SAVE_R27 = TEST_SAVE_BASE + 17 * WORD_BYTES
TEST_SAVE_R28 = TEST_SAVE_BASE + 18 * WORD_BYTES
TEST_SAVE_R29 = TEST_SAVE_BASE + 19 * WORD_BYTES
TEST_SAVE_RA = TEST_SAVE_BASE + 20 * WORD_BYTES
TEST_SAVE_FCSR = TEST_SAVE_RA + WORD_BYTES
TEST_SAVE_SP = TEST_SAVE_FCSR + WORD_BYTES
TEST_FRAME_BYTES = TEST_SAVE_SP + STACK_ALIGNMENT
TEST_FAIL_SP = GPR_COUNT
TEST_FAIL_FCSR = GPR_COUNT + 1
; Boot-time context check through the real BREAK -> M -> IRET path.
; Result 0 = OK, 1..31 = damaged GPR, 32 = SP, 33 = FCSR.
; Retains callee-saved registers, tp and the caller's FCSR as required.
    .text
    .globl trapRegisterSelfTest
trapRegisterSelfTest:
    addi sp, sp, -TEST_FRAME_BYTES
    sw r10, TEST_SAVE_R10(sp)
    sw r11, TEST_SAVE_R11(sp)
    sw r12, TEST_SAVE_R12(sp)
    sw r13, TEST_SAVE_R13(sp)
    sw r14, TEST_SAVE_R14(sp)
    sw r15, TEST_SAVE_R15(sp)
    sw r16, TEST_SAVE_R16(sp)
    sw r17, TEST_SAVE_R17(sp)
    sw r18, TEST_SAVE_R18(sp)
    sw r19, TEST_SAVE_R19(sp)
    sw r20, TEST_SAVE_R20(sp)
    sw r21, TEST_SAVE_R21(sp)
    sw r22, TEST_SAVE_R22(sp)
    sw r23, TEST_SAVE_R23(sp)
    sw r24, TEST_SAVE_R24(sp)
    sw r25, TEST_SAVE_R25(sp)
    sw r26, TEST_SAVE_R26(sp)
    sw r27, TEST_SAVE_R27(sp)
    sw r28, TEST_SAVE_R28(sp)
    sw r29, TEST_SAVE_R29(sp)
    sw ra, TEST_SAVE_RA(sp)
    mfcr r1, fcsr
    sw r1, TEST_SAVE_FCSR(sp)
    sw sp, TEST_SAVE_SP(sp)
    li r1, TEST_FCSR                   ; RUP and NX, distinguish from kernel FCSR
    mtcr fcsr, r1
    li r1, TEST_GPR_SEED + 1
    li r2, TEST_GPR_SEED + 2
    li r3, TEST_GPR_SEED + 3
    li r4, TEST_GPR_SEED + 4
    li r5, TEST_GPR_SEED + 5
    li r6, TEST_GPR_SEED + 6
    li r7, TEST_GPR_SEED + 7
    li r8, TEST_GPR_SEED + 8
    li r9, TEST_GPR_SEED + 9
    li r10, TEST_GPR_SEED + 10
    li r11, TEST_GPR_SEED + 11
    li r12, TEST_GPR_SEED + 12
    li r13, TEST_GPR_SEED + 13
    li r14, TEST_GPR_SEED + 14
    li r15, TEST_GPR_SEED + 15
    li r16, TEST_GPR_SEED + 16
    li r17, TEST_GPR_SEED + 17
    li r18, TEST_GPR_SEED + 18
    li r19, TEST_GPR_SEED + 19
    li r20, TEST_GPR_SEED + 20
    li r21, TEST_GPR_SEED + 21
    li r22, TEST_GPR_SEED + 22
    li r23, TEST_GPR_SEED + 23
    li r24, TEST_GPR_SEED + 24
    li r25, TEST_GPR_SEED + 25
    li r26, TEST_GPR_SEED + 26
    li r27, TEST_GPR_SEED + 27
    li r28, TEST_GPR_SEED + 28
    li r29, TEST_GPR_SEED + 29
    li ra, TEST_GPR_SEED + 31
    break
    ; Capture every returned register before using any as temporaries.
    sw r0, TF_R0(sp)
    sw r1, TF_R1(sp)
    sw r2, TF_R2(sp)
    sw r3, TF_R3(sp)
    sw r4, TF_R4(sp)
    sw r5, TF_R5(sp)
    sw r6, TF_R6(sp)
    sw r7, TF_R7(sp)
    sw r8, TF_R8(sp)
    sw r9, TF_R9(sp)
    sw r10, TF_R10(sp)
    sw r11, TF_R11(sp)
    sw r12, TF_R12(sp)
    sw r13, TF_R13(sp)
    sw r14, TF_R14(sp)
    sw r15, TF_R15(sp)
    sw r16, TF_R16(sp)
    sw r17, TF_R17(sp)
    sw r18, TF_R18(sp)
    sw r19, TF_R19(sp)
    sw r20, TF_R20(sp)
    sw r21, TF_R21(sp)
    sw r22, TF_R22(sp)
    sw r23, TF_R23(sp)
    sw r24, TF_R24(sp)
    sw r25, TF_R25(sp)
    sw r26, TF_R26(sp)
    sw r27, TF_R27(sp)
    sw r28, TF_R28(sp)
    sw r29, TF_R29(sp)
    sw sp, TF_R30(sp)
    sw ra, TF_R31(sp)
    li r1, 0                      ; check r0, then seeded r1..r29
    mv r2, sp
.check:
    lw r3, 0(r2)
    beqz r1, .zero
    addi r4, r1, TEST_GPR_SEED
    j .compare
.zero:
    li r4, 0
.compare:
    bne r3, r4, .done
    addi r1, r1, 1
    addi r2, r2, WORD_BYTES
    li r4, REG_SP
    bltu r1, r4, .check
    li r1, REG_RA
    lw r3, TF_R31(sp)
    li r4, TEST_GPR_SEED + 31
    bne r3, r4, .done
    li r1, TEST_FAIL_SP
    lw r3, TF_R30(sp)
    lw r4, TEST_SAVE_SP(sp)
    bne r3, r4, .done
    li r1, TEST_FAIL_FCSR
    mfcr r3, fcsr
    li r4, TEST_FCSR
    bne r3, r4, .done
    li r1, 0
.done:
    lw r2, TEST_SAVE_FCSR(sp)
    mtcr fcsr, r2
    lw r10, TEST_SAVE_R10(sp)
    lw r11, TEST_SAVE_R11(sp)
    lw r12, TEST_SAVE_R12(sp)
    lw r13, TEST_SAVE_R13(sp)
    lw r14, TEST_SAVE_R14(sp)
    lw r15, TEST_SAVE_R15(sp)
    lw r16, TEST_SAVE_R16(sp)
    lw r17, TEST_SAVE_R17(sp)
    lw r18, TEST_SAVE_R18(sp)
    lw r19, TEST_SAVE_R19(sp)
    lw r20, TEST_SAVE_R20(sp)
    lw r21, TEST_SAVE_R21(sp)
    lw r22, TEST_SAVE_R22(sp)
    lw r23, TEST_SAVE_R23(sp)
    lw r24, TEST_SAVE_R24(sp)
    lw r25, TEST_SAVE_R25(sp)
    lw r26, TEST_SAVE_R26(sp)
    lw r27, TEST_SAVE_R27(sp)
    lw r28, TEST_SAVE_R28(sp)
    lw r29, TEST_SAVE_R29(sp)
    lw ra, TEST_SAVE_RA(sp)
    addi sp, sp, TEST_FRAME_BYTES
    ret
