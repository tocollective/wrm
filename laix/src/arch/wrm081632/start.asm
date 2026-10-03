    .include "defs.inc"
; LA/IX boot runtime. This object must be FIRST in the boot link.
; Before the full entry is installed, diagnostics never use a stack or BSS.
    .text
    .globl kernelStart, earlyTrapEntry, earlyPanic, earlyTrapPanic, earlyTrapReport
    .globl earlyStop, earlyField, earlyString, earlyHex
    .globl bootInfoAddress, kernelStackGuard, kernelStackBottom, kernelStackTop
    .globl taskKernelStackGuard, taskKernelStackBottom, taskKernelStackTop
kernelHeader:
    .word BOOT_MAGIC
    .word __image_sectors
    .word kernelStart - kernelHeader
    .word 0

kernelStart:
    mv r10, r1
    la r2, earlyTrapEntry
    mtcr ivec, r2
    mtcr status, r0
    mtcr ptbr, r0                 ; BSS is cleared through physical addresses
    li r2, PIC_ENABLE
    sw r0, 0(r2)                  ; PIC ENABLE: IRQ handling is not ready
    li r2, BOOT_INFO
    bne r10, r2, .bad_info
    lw r2, BOOT_FIELD_MAGIC(r10)
    li r3, BOOT_INFO_MAGIC
    bne r2, r3, .bad_info
    lw r2, BOOT_FIELD_SIZE(r10)
    li r3, BOOT_INFO_MIN_SIZE
    bltu r2, r3, .bad_info
    li r3, BOOT_INFO_BYTES
    bltu r3, r2, .bad_info
    lw r2, BOOT_FIELD_RAM_SIZE(r10)
    la r3, __bss_end
    bltu r2, r3, .bad_ram

    la r1, __bss_start
    la r2, __bss_end
    j .zero_test
.zero:
    sw r0, 0(r1)
    addi r1, r1, WORD_BYTES
.zero_test:
    bltu r1, r2, .zero
    la r1, bootInfoAddress
    sw r10, 0(r1)
    la r1, kernelStackBottom
    li r2, STACK_CANARY
    sw r2, 0(r1)
    sw r1, KERNEL_STACK_BOTTOM(r0)
    la sp, kernelStackTop
    sw sp, KERNEL_SP(r0)
    sw sp, KERNEL_STACK_TOP(r0)
    sw r0, TRAP_SAVED_R1(r0)        ; low entry state is outside the BSS zero loop
    mtcr fcsr, r0
    la r1, trapEntry
    mtcr ivec, r1
    li r1, 0                      ; retain main(0, null); boot info is saved
    li r2, 0
    call main
    la r1, earlyReturnedMessage
    j earlyPanic
.bad_info:
    la r1, earlyBootInfoMessage
    j earlyPanic
.bad_ram:
    la r1, earlyRamMessage
    j earlyPanic

earlyTrapEntry:
    la r1, earlyFaultMessage
    j earlyTrapPanic

; Early diagnostics: jump-only, no stack, BSS, calls, pushes or locks. Every
; routine takes its continuation in a register and clobbers r1-r3, r6-r9, r12.

; r1 = trusted static ASCII message, without a trap: CAUSE, EPC and BADADDR
; are stale (reset or firmware values) and are not printed.
earlyPanic:
    li r2, STATUS_EXL
    mtcr status, r2
    li r9, UART_BASE
    la r12, earlyStop
    j earlyString

; r1 = message after a trap: also prints its CAUSE, EPC and BADADDR.
earlyTrapPanic:
    li r2, STATUS_EXL
    mtcr status, r2
    la r13, earlyStop
    j earlyTrapReport

; r1 = message, r13 = continuation: the message, then the trap registers.
; Leaves r9 = UART_BASE for further earlyField output.
earlyTrapReport:
    li r9, UART_BASE
    la r12, .cause
    j earlyString
.cause:
    la r1, earlyCauseMessage
    mfcr r6, cause
    la r12, .epc
    j earlyField
.epc:
    la r1, earlyEpcMessage
    mfcr r6, epc
    la r12, .badaddr
    j earlyField
.badaddr:
    la r1, earlyBadaddrMessage
    mfcr r6, badaddr
    mv r12, r13
    j earlyField

; Ends every early panic. Boot failure must not look like success to a
; headless caller.
earlyStop:
    li r9, UART_BASE
    li r2, ASCII_NEWLINE
    sw r2, 0(r9)
    li r9, POWER_BASE
    li r2, PANIC_EXIT_CODE
    sw r2, 0(r9)
.halt:
    hlt
    j .halt

; r1 = label, r6 = value, r9 = UART_BASE, r12 = continuation: "label" then
; the value in hex. r8 keeps the continuation while the label is printed.
earlyField:
    mv r8, r12
    la r12, .value
    j earlyString
.value:
    mv r12, r8
    j earlyHex

; r1 = NUL-terminated string, r9 = UART_BASE, r12 = continuation.
earlyString:
.next:
    lbu r2, 0(r1)
    beqz r2, .done
    sw r2, 0(r9)
    addi r1, r1, 1
    j .next
.done:
    jr r12

; r6 = value, r9 = UART_BASE, r12 = continuation: eight hex digits.
earlyHex:
    li r7, HEX_TOP_SHIFT
.digit:
    shr r2, r6, r7
    andi r2, r2, HEX_DIGIT_MASK
    li r3, DECIMAL_BASE
    bltu r2, r3, .decimal
    addi r2, r2, ASCII_HEX_ALPHA_OFFSET
    j .write
.decimal:
    addi r2, r2, ASCII_ZERO
.write:
    sw r2, 0(r9)
    addi r7, r7, -HEX_DIGIT_BITS
    bgez r7, .digit
    jr r12

    ; This object is linked first: its page alignment starts the whole
    ; .rodata and .data output sections on pages of their own, so the MMU
    ; can map code RX, read-only data R and writable data RW (mmu.m).
    .rodata
    .align PAGE_SIZE
earlyFaultMessage:    .asciz "\nLA/IX EARLY PANIC: exception"
earlyBootInfoMessage: .asciz "\nLA/IX EARLY PANIC: invalid boot info"
earlyRamMessage:      .asciz "\nLA/IX EARLY PANIC: kernel does not fit in RAM"
earlyReturnedMessage: .asciz "\nLA/IX EARLY PANIC: main returned"
earlyCauseMessage:    .asciz "\ncause="
earlyEpcMessage:      .asciz " epc="
earlyBadaddrMessage:  .asciz " badaddr="

    .data
    .align PAGE_SIZE

    .bss
    .align PAGE_SIZE
kernelStackGuard:
    .space PAGE_SIZE                  ; reserved now, unmapped once MMU is enabled
kernelStackBottom:
    .space KERNEL_STACK_BYTES
kernelStackTop:
bootInfoAddress:
    .space WORD_BYTES
    ; One task for stage 3. Reserved with BSS, separate from the boot stack.
    .align PAGE_SIZE
taskKernelStackGuard:
    .space PAGE_SIZE
taskKernelStackBottom:
    .space KERNEL_STACK_BYTES
taskKernelStackTop:
