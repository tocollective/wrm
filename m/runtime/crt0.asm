; ============================================================================
;  crt0 of an M boot image (m/docs/COMPILER.md, "Цель: boot-образ")
;
;  tools/m.py puts this file first in its output and assembles the image
;  at BOOT_LOAD. It defines __image_start and expects the compiler to
;  define __image_end (sector aligned), __bss_start, __bss_end (both word
;  aligned) and main.
;
;  On entry (docs/SPECIFICATION.md#state-at-the-entry-point): r1 = boot
;  info block, sp = 0x00010000 (8-aligned, empty), supervisor mode,
;  .bss not zeroed.
;
;  There is no kernel, so crt0 handles traps itself: SYSCALL returns
;  -ENOSYS, BREAK does nothing, anything else is reported on the UART and
;  powers the machine off with exit code 254. A program can install its
;  own handler in IVEC.
; ============================================================================

__BOOT_LOAD     = 0x00010000
__BOOT_MAGIC    = 0x424D5257        ; "WRMB"
__SECTOR_SIZE   = 512
__POWER_OFF     = 0xFD004000        ; power controller, OFF register
__UART_DATA     = 0xFD002000
__CAUSE_SYSCALL = 12
__CAUSE_BREAK   = 13
__ENOSYS        = 38
__EXIT_TRAP     = 254

	.org __BOOT_LOAD
__image_start:
	.dw __BOOT_MAGIC
	.dw (__image_end - __image_start) / __SECTOR_SIZE
	.dw __start - __image_start
	.dw 0                       ; flags

__start:
	la r1, __bss_start
	la r2, __bss_end
	j .zero_test
.zero:
	sw r0, 0(r1)
	addi r1, r1, 4
.zero_test:
	bltu r1, r2, .zero

	la r1, __trap
	mtcr ivec, r1
	mtcr status, r0             ; clear EXL: traps go to __trap

	li r1, 0                    ; main(0, null)
	li r2, 0
	call main
	li r9, __POWER_OFF
	sw r1, 0(r9)                ; the low 8 bits are the exit code
	hlt                         ; not reached

; Traps. r1 is saved in SCRATCH; SYSCALL may change r1 and r2 (docs/ABI.md,
; "System calls"), BREAK keeps every register.
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
	li r9, __UART_DATA
	sw r1, 0(r9)
	li r1, __EXIT_TRAP
	li r9, __POWER_OFF
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
	li r9, __UART_DATA
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
	li r9, __UART_DATA
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
