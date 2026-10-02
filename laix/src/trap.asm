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
    sw r1, 0(sp)
    mfcr sp, scratch
    la r1, kernelStackBottom
    addi r1, r1, TF_SIZE + 512 + 4 ; frame, dispatch headroom, bottom canary
    bltu sp, r1, .bad_stack
    la r1, kernelStackTop
    bltu r1, sp, .bad_stack
    andi r1, sp, 7
    bnez r1, .bad_stack
    addi sp, sp, -TF_SIZE
    la r1, trapSavedR1
    lw r1, 0(r1)
    sw r1, 4(sp)
    mfcr r1, scratch
    sw r1, 120(sp)                ; interrupted sp, not frame address
    sw r0, 0(sp)
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
    sw ra, 124(sp)
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
    sw r0, TF_RESERVED + 4(sp)
    mtcr fcsr, r0                 ; independent floating-point environment
    mv r1, sp
    call trapDispatch
    ; Never enable IRQs or user mode before all registers are restored.
    lw r1, TF_STATUS(sp)
    andi r1, r1, 0x7A             ; clear IE, UM; retain PIE/PUM/PSS and EXL
    ori r1, r1, STATUS_EXL
    mtcr status, r1
    lw r1, TF_EPC(sp)
    mtcr epc, r1
    lw r1, TF_FCSR(sp)
    mtcr fcsr, r1
    lw r2, 8(sp)
    lw r3, 12(sp)
    lw r4, 16(sp)
    lw r5, 20(sp)
    lw r6, 24(sp)
    lw r7, 28(sp)
    lw r8, 32(sp)
    lw r9, 36(sp)
    lw r10, 40(sp)
    lw r11, 44(sp)
    lw r12, 48(sp)
    lw r13, 52(sp)
    lw r14, 56(sp)
    lw r15, 60(sp)
    lw r16, 64(sp)
    lw r17, 68(sp)
    lw r18, 72(sp)
    lw r19, 76(sp)
    lw r20, 80(sp)
    lw r21, 84(sp)
    lw r22, 88(sp)
    lw r23, 92(sp)
    lw r24, 96(sp)
    lw r25, 100(sp)
    lw r26, 104(sp)
    lw r27, 108(sp)
    lw r28, 112(sp)
    lw r29, 116(sp)
    lw ra, 124(sp)
    lw r1, 4(sp)
    lw sp, 120(sp)                ; final memory access, uses the old base
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
