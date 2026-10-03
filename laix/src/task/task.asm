; Included by task.m, never uses the M boot runtime as user crt0.
; The loader copies ONLY [userCodeStart, userCodeEnd) to a fresh user frame.
; Position independent: data comes in r1; branches remain inside this blob.
    .include "../arch/wrm081632/defs.inc"
    .text
    .align WORD_BYTES
    .globl userCodeStart, userCodeEnd
    .globl taskKernelResume
; Fresh supervisor entry with an empty boot stack and no user register values.
taskKernelResume:
    call taskReap
.halt:
    hlt
    j .halt
userCodeStart:
    addi sp, sp, -STACK_ALIGNMENT
    li r3, 1
    sw r3, 0(sp)
    lw r3, 0(sp)
    addi sp, sp, STACK_ALIGNMENT
    sw r3, 0(r1)                    ; observable ready marker in user data
    li r1, 'U'
    li r9, SYS_DEBUG_PUT_CHAR
    syscall
    li r1, 10
    li r9, SYS_DEBUG_PUT_CHAR
    syscall
    li r1, 0
    li r9, SYS_EXIT
    syscall
.exit_returned:
    j .exit_returned                 ; unreachable under the LA/IX exit ABI
userCodeEnd:
