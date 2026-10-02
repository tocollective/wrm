; ============================================================================
;  The trap handler of programs without a kernel: boot images (crt0.asm)
;  and ROM images (rom0.asm) put it in IVEC before main.
;
;  SYSCALL returns -ENOSYS, BREAK does nothing, anything else is reported
;  on the UART ("trap: cause 0x.. at 0x........") and powers the machine
;  off with exit code 254.
; ============================================================================

__TRAP_UART     = 0xFD002000        ; UART DATA
__TRAP_POWER    = 0xFD004000        ; power controller, OFF register
__CAUSE_SYSCALL = 12
__CAUSE_BREAK   = 13
__ENOSYS        = 38
__EXIT_TRAP     = 254

; Traps. r1 is saved in SCRATCH; SYSCALL may change r1 and r2 (docs/ABI.md,
; "System calls"), BREAK keeps every register.
	.text
	.globl __trap
__trap:
	mtcr scratch, r1
	mfcr r1, cause
	addi r1, r1, -__CAUSE_SYSCALL
	beqz r1, .syscall
	addi r1, r1, __CAUSE_SYSCALL - __CAUSE_BREAK
	beqz r1, .break
	la r1, __trap_cause         ; anything else: report and power off
	call __trap_puts
	mfcr r1, cause
	li r2, 2
	call __trap_hex
	la r1, __trap_at
	call __trap_puts
	mfcr r1, epc
	li r2, 8
	call __trap_hex
	li r1, '\n'
	li r9, __TRAP_UART
	sw r1, 0(r9)
	li r1, __EXIT_TRAP
	li r9, __TRAP_POWER
	sw r1, 0(r9)
	hlt
.syscall:
	mfcr r2, epc
	addi r2, r2, 4
	mtcr epc, r2
	li r1, -__ENOSYS
	iret
.break:
	mfcr r1, epc
	addi r1, r1, 4
	mtcr epc, r1
	mfcr r1, scratch
	iret

; __trap_puts(r1 = string)
__trap_puts:
	li r9, __TRAP_UART
.next:
	lbu r2, 0(r1)
	beqz r2, .done
	sw r2, 0(r9)
	addi r1, r1, 1
	j .next
.done:
	ret

; __trap_hex(r1 = value, r2 = number of hex digits)
__trap_hex:
	li r9, __TRAP_UART
.digit:
	addi r2, r2, -1
	shli r3, r2, 2
	shr r4, r1, r3
	andi r4, r4, 15
	addi r5, r4, -10
	bltz r5, .decimal
	addi r4, r4, 'A' - 10 - '0'
.decimal:
	addi r4, r4, '0'
	sw r4, 0(r9)
	bnez r2, .digit
	ret

__trap_cause:   .asciz "trap: cause 0x"
__trap_at:      .asciz " at 0x"
	.align 4
