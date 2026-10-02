    .include "defs.inc"
; LA/IX boot runtime. This object must be FIRST in the boot link.
; Before the full entry is installed, diagnostics never use a stack or BSS.
    .text
    .globl kernelStart, earlyTrapEntry, earlyPanic
    .globl bootInfoAddress, kernelStackGuard, kernelStackBottom, kernelStackTop, trapSavedR1
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
    la sp, kernelStackTop
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
    j earlyPanic

; r1 = trusted static ASCII message. No calls, pushes, globals or locks.
earlyPanic:
    li r2, STATUS_EXL
    mtcr status, r2
    li r9, UART_BASE
.message:
    lbu r2, 0(r1)
    beqz r2, .cause
    sw r2, 0(r9)
    addi r1, r1, 1
    j .message
.cause:
    la r1, earlyCauseMessage
    la r12, .cause_value
    j earlyString
.cause_value:
    mfcr r6, cause
    la r12, .epc
    j earlyHex
.epc:
    la r1, earlyEpcMessage
    la r12, .epc_value
    j earlyString
.epc_value:
    mfcr r6, epc
    la r12, .badaddr
    j earlyHex
.badaddr:
    la r1, earlyBadaddrMessage
    la r12, .badaddr_value
    j earlyString
.badaddr_value:
    mfcr r6, badaddr
    la r12, .stop
    j earlyHex
.stop:
    li r2, ASCII_NEWLINE
    sw r2, 0(r9)
    ; Boot failure must not look like success to a headless caller.
    li r9, POWER_BASE
    li r2, PANIC_EXIT_CODE
    sw r2, 0(r9)
.halt:
    hlt
    j .halt

; Jump-only formatting: r12 is the continuation, never a stack return.
earlyString:
.next:
    lbu r2, 0(r1)
    beqz r2, .done
    sw r2, 0(r9)
    addi r1, r1, 1
    j .next
.done:
    jr r12

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

    .rodata
earlyFaultMessage:    .asciz "\nLA/IX EARLY PANIC: exception"
earlyBootInfoMessage: .asciz "\nLA/IX EARLY PANIC: invalid boot info"
earlyRamMessage:      .asciz "\nLA/IX EARLY PANIC: kernel does not fit in RAM"
earlyReturnedMessage: .asciz "\nLA/IX EARLY PANIC: main returned"
earlyCauseMessage:    .asciz "\ncause="
earlyEpcMessage:      .asciz " epc="
earlyBadaddrMessage:  .asciz " badaddr="

    .bss
    .align PAGE_SIZE
kernelStackGuard:
    .space PAGE_SIZE                  ; reserved now, unmapped once MMU is enabled
kernelStackBottom:
    .space KERNEL_STACK_BYTES
kernelStackTop:
bootInfoAddress:
    .space WORD_BYTES
trapSavedR1:
    .space WORD_BYTES                     ; one core, EXL held: entry scratch storage
