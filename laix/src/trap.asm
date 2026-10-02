; Included automatically by trap.m's object, not linked a second time.
    .include "trap_layout.inc"
    .text
    .globl trapEntry
trapEntry:
    mtcr scratch, sp
    mfcr sp, status
    andi sp, sp, STATUS_PUM
    bnez sp, .unsupported_user
    ; Save r1 in trusted BSS so bounds can be checked without using old sp.
    ; This single scratch word is safe only while entry is non-nested.
    la sp, trapSavedR1
    sw r1, TF_R0(sp)
    mfcr sp, scratch
    la r1, kernelStackBottom
    addi r1, r1, TF_SIZE + TRAP_DISPATCH_HEADROOM + WORD_BYTES ; frame, dispatch headroom, bottom canary
    bltu sp, r1, .bad_stack
    la r1, kernelStackTop
    bltu r1, sp, .bad_stack
    andi r1, sp, STACK_ALIGN_MASK
    bnez r1, .bad_stack
    addi sp, sp, -TF_SIZE
    la r1, trapSavedR1
    lw r1, 0(r1)
    sw r1, TF_R1(sp)
    mfcr r1, scratch
    sw r1, TF_R30(sp)                ; interrupted sp, not frame address
    sw r0, TF_R0(sp)
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
    sw ra, TF_R31(sp)
    mfcr r1, epc
    sw r1, TF_EPC(sp)
    mfcr r1, status
    sw r1, TF_STATUS(sp)
    mfcr r1, cause
    sw r1, TF_CAUSE(sp)
    mfcr r1, badaddr
    sw r1, TF_BADADDR(sp)
    mfcr r1, fcsr
    sw r1, TF_FCSR(sp)
    mfcr r1, ptbr
    sw r1, TF_PTBR(sp)
    sw r0, TF_RESERVED(sp)
    sw r0, TF_RESERVED + WORD_BYTES(sp)
    mtcr fcsr, r0                 ; independent floating-point environment
    mv r1, sp
    call trapDispatch
    ; Never enable IRQs or user mode before all registers are restored.
    lw r1, TF_STATUS(sp)
    andi r1, r1, STATUS_TRAP_RETURN_MASK             ; clear IE, UM; retain PIE/PUM/PSS and EXL
    ori r1, r1, STATUS_EXL
    mtcr status, r1
    lw r1, TF_EPC(sp)
    mtcr epc, r1
    lw r1, TF_FCSR(sp)
    mtcr fcsr, r1
    lw r2, TF_R2(sp)
    lw r3, TF_R3(sp)
    lw r4, TF_R4(sp)
    lw r5, TF_R5(sp)
    lw r6, TF_R6(sp)
    lw r7, TF_R7(sp)
    lw r8, TF_R8(sp)
    lw r9, TF_R9(sp)
    lw r10, TF_R10(sp)
    lw r11, TF_R11(sp)
    lw r12, TF_R12(sp)
    lw r13, TF_R13(sp)
    lw r14, TF_R14(sp)
    lw r15, TF_R15(sp)
    lw r16, TF_R16(sp)
    lw r17, TF_R17(sp)
    lw r18, TF_R18(sp)
    lw r19, TF_R19(sp)
    lw r20, TF_R20(sp)
    lw r21, TF_R21(sp)
    lw r22, TF_R22(sp)
    lw r23, TF_R23(sp)
    lw r24, TF_R24(sp)
    lw r25, TF_R25(sp)
    lw r26, TF_R26(sp)
    lw r27, TF_R27(sp)
    lw r28, TF_R28(sp)
    lw r29, TF_R29(sp)
    lw ra, TF_R31(sp)
    lw r1, TF_R1(sp)
    lw sp, TF_R30(sp)                ; final memory access, uses the old base
    iret
.unsupported_user:
    ; Do not write to an untrusted user sp. Fatal until MMU/tasks exist.
    la r1, unsupportedUserMessage
    j earlyPanic
.bad_stack:
    la r1, badKernelStackMessage
    j earlyPanic

    .rodata
unsupportedUserMessage: .asciz "\nLA/IX EARLY PANIC: unsupported user entry"
badKernelStackMessage: .asciz "\nLA/IX EARLY PANIC: invalid kernel stack"

    .include "trap_test.asm"
