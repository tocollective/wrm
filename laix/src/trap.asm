; Included automatically by trap.m's object, not linked a second time.
    .include "trap_layout.inc"
    .text
    .globl trapEntry
trapEntry:
    mtcr scratch, sp
    mfcr sp, status
    andi sp, sp, STATUS_PUM
    beqz sp, .kernel_stack
    lw sp, KERNEL_SP(r0)             ; trusted current task stack, never user sp
    j .check_stack
.kernel_stack:
    mfcr sp, scratch
.check_stack:
    ; One core, EXL held: save r1 without touching either interrupted stack.
    sw r1, TRAP_SAVED_R1(r0)
    lw r1, KERNEL_STACK_BOTTOM(r0)
    addi r1, r1, TF_SIZE + TRAP_DISPATCH_HEADROOM + WORD_BYTES ; frame, dispatch headroom, bottom canary
    bltu sp, r1, .bad_stack
    lw r1, KERNEL_STACK_TOP(r0)
    bltu r1, sp, .bad_stack
    andi r1, sp, STACK_ALIGN_MASK
    bnez r1, .bad_stack
    addi sp, sp, -TF_SIZE
    lw r1, TRAP_SAVED_R1(r0)
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
    andi r1, r1, STATUS_TRAP_RETURN_MASK             ; clear IE, UM; retain PIE/PUM/SS/PSS and EXL
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
.bad_stack:
    ; sp is the rejected stack, never accessed. The interrupted sp is in
    ; SCRATCH and r1 in TRAP_SAVED_R1; r2-r29 and ra are still intact. Copy
    ; the context to a static frame, print the key fields without any
    ; dependency, then dump the frame from M on a static emergency stack.
    ; One core with EXL held: used at most once, the machine then halts.
    la r1, trapEmergencyFrame
    sw r0, TF_R0(r1)
    sw r2, TF_R2(r1)
    sw r3, TF_R3(r1)
    sw r4, TF_R4(r1)
    sw r5, TF_R5(r1)
    sw r6, TF_R6(r1)
    sw r7, TF_R7(r1)
    sw r8, TF_R8(r1)
    sw r9, TF_R9(r1)
    sw r10, TF_R10(r1)
    sw r11, TF_R11(r1)
    sw r12, TF_R12(r1)
    sw r13, TF_R13(r1)
    sw r14, TF_R14(r1)
    sw r15, TF_R15(r1)
    sw r16, TF_R16(r1)
    sw r17, TF_R17(r1)
    sw r18, TF_R18(r1)
    sw r19, TF_R19(r1)
    sw r20, TF_R20(r1)
    sw r21, TF_R21(r1)
    sw r22, TF_R22(r1)
    sw r23, TF_R23(r1)
    sw r24, TF_R24(r1)
    sw r25, TF_R25(r1)
    sw r26, TF_R26(r1)
    sw r27, TF_R27(r1)
    sw r28, TF_R28(r1)
    sw r29, TF_R29(r1)
    sw ra, TF_R31(r1)
    lw r2, TRAP_SAVED_R1(r0)
    sw r2, TF_R1(r1)
    mfcr r2, scratch
    sw r2, TF_R30(r1)
    mfcr r2, epc
    sw r2, TF_EPC(r1)
    mfcr r2, status
    sw r2, TF_STATUS(r1)
    mfcr r2, cause
    sw r2, TF_CAUSE(r1)
    mfcr r2, badaddr
    sw r2, TF_BADADDR(r1)
    mfcr r2, fcsr
    sw r2, TF_FCSR(r1)
    mfcr r2, ptbr
    sw r2, TF_PTBR(r1)
    sw r0, TF_RESERVED(r1)
    sw r0, TF_RESERVED + WORD_BYTES(r1)
    mv r14, r1                       ; the frame, kept by the early routines
    mv r15, sp                       ; the rejected stack pointer
    la r1, badKernelStackMessage
    la r13, .stack_fields
    j earlyTrapReport
.stack_fields:
    la r1, badStackSpMessage
    mv r6, r15
    la r12, .interrupted_sp
    j earlyField
.interrupted_sp:
    la r1, badStackScratchMessage
    lw r6, TF_R30(r14)
    la r12, .bottom
    j earlyField
.bottom:
    la r1, badStackBottomMessage
    lw r6, KERNEL_STACK_BOTTOM(r0)
    la r12, .top
    j earlyField
.top:
    la r1, badStackTopMessage
    lw r6, KERNEL_STACK_TOP(r0)
    la r12, .ra
    j earlyField
.ra:
    la r1, badStackRaMessage
    lw r6, TF_R31(r14)
    la r12, .full_dump
    j earlyField
.full_dump:
    la sp, trapEmergencyStackTop
    mtcr fcsr, r0                    ; independent floating-point environment
    mv r1, r14
    mv r2, r15
    call trapBadStack                ; panics: never returns
    j earlyStop

    .rodata
badKernelStackMessage: .asciz "\nLA/IX EARLY PANIC: invalid kernel stack"
badStackSpMessage:      .asciz "\nsp="
badStackScratchMessage: .asciz " scratch="
badStackBottomMessage:  .asciz " bottom="
badStackTopMessage:     .asciz " top="
badStackRaMessage:      .asciz " ra="

    .bss
    .align STACK_ALIGNMENT
trapEmergencyFrame:
    .space TF_SIZE
trapEmergencyStack:
    .space TRAP_EMERGENCY_STACK_BYTES
trapEmergencyStackTop:

    .include "trap_test.asm"
