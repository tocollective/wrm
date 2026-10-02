; ============================================================================
;  crt0: main gets (0, null) and an 8-aligned stack, and its result
;  becomes the exit code
; ============================================================================
; @output "main(0, null)\n"
; @exit 42

	.globl main
main:
	bnez r1, .bad_argc
	bnez r2, .bad_argv
	andi r3, sp, 7
	bnez r3, .bad_sp
	beqz ra, .bad_ra
	addi sp, sp, -8
	sw ra, 4(sp)
	la r1, s_main
	call t_puts
	lw ra, 4(sp)
	addi sp, sp, 8
	li r1, 42
	ret
.bad_argc:
	li r1, 1
	ret
.bad_argv:
	li r1, 2
	ret
.bad_sp:
	li r1, 3
	ret
.bad_ra:
	li r1, 4
	ret

	.include "../common/uart.asm"

s_main:         .asciz "main(0, null)\n"
