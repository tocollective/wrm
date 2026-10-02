; LA/IX boot runtime. This object must be FIRST in the boot link.
; Before the full entry is installed, diagnostics never use a stack or BSS.
    .text
    .globl kernelStart, earlyTrapEntry, earlyPanic
    .globl bootInfoAddress, kernelStackBottom, kernelStackTop, trapSavedR1
kernelHeader:
    .word 0x424D5257
    .word __image_sectors
    .word kernelStart - kernelHeader
    .word 0

kernelStart:
    mv r10, r1
    la r2, earlyTrapEntry
    mtcr ivec, r2
    mtcr status, r0
    li r2, 0xFD000004
    sw r0, 0(r2)                  ; PIC ENABLE: IRQ handling is not ready
    li r2, 0x1000
    bne r10, r2, .bad_info
    lw r2, 0(r10)
    li r3, 0x4F464E49
    bne r2, r3, .bad_info
    lw r2, 4(r10)
    li r3, 40
    bltu r2, r3, .bad_info
    li r3, 4096
    bltu r3, r2, .bad_info
    lw r2, 8(r10)
    la r3, __bss_end
    bltu r2, r3, .bad_ram

    la r1, __bss_start
    la r2, __bss_end
    j .zero_test
.zero:
    sw r0, 0(r1)
    addi r1, r1, 4
.zero_test:
    bltu r1, r2, .zero
    la r1, bootInfoAddress
    sw r10, 0(r1)
    la r1, kernelStackBottom
    li r2, 0x4C414958
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
    li r2, 16
    mtcr status, r2
    li r9, 0xFD002000
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
    li r2, 10
    sw r2, 0(r9)
    ; Boot failure must not look like success to a headless caller.
    li r9, 0xFD004000
    li r2, 254
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
    li r7, 28
.digit:
    shr r2, r6, r7
    andi r2, r2, 15
    li r3, 10
    bltu r2, r3, .decimal
    addi r2, r2, 55
    j .write
.decimal:
    addi r2, r2, 48
.write:
    sw r2, 0(r9)
    addi r7, r7, -4
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
    .align 8
kernelStackBottom:
    .space 8192
kernelStackTop:
bootInfoAddress:
    .space 4
trapSavedR1:
    .space 4                     ; one core, EXL held: entry scratch storage
