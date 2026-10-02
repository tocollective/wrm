; ============================================================================
;  crt0's trap handler: SYSCALL returns -ENOSYS and resumes after it,
;  BREAK does nothing; every other register survives both
; ============================================================================
; @output "traps ok\n"
; @exit 0

	.globl main
main:
	addi sp, sp, -8
	sw ra, 4(sp)
	li r3, 333
	li r9, 1
	syscall
	li r4, -38
	bne r1, r4, .bad_syscall
	li r4, 333
	bne r3, r4, .bad_keep
	li r1, 111
	break
	li r4, 111
	bne r1, r4, .bad_break
	la r1, s_ok
	call t_puts
	li r1, 0
	j .return
.bad_syscall:
	li r1, 1
	j .return
.bad_keep:
	li r1, 2
	j .return
.bad_break:
	li r1, 3
.return:
	lw ra, 4(sp)
	addi sp, sp, 8
	ret

	.include "../common/uart.asm"

s_ok:           .asciz "traps ok\n"
