; ============================================================================
;  memset: every destination alignment, lengths 0 to 20, only the low
;  byte of the value; the bytes around the destination stay as they were
; ============================================================================
; @output "memset ok\n"
; @exit 0

BUF     = 32
GUARD   = 0xEE
VALUE   = 0x123456A5            ; memset writes 0xA5
MAX_N   = 20

; r11 = destination offset, r12 = length, r13 = the number of the check,
; the exit code if it fails
	.globl main
main:
	addi sp, sp, -16
	sw ra, 12(sp)
	sw r11, 8(sp)
	sw r12, 4(sp)
	sw r13, 0(sp)

	li r11, 0
.dst:
	li r12, 0
.len:
	la r1, t_dst                ; t_dst[i] = GUARD
	li r3, 0
	li r5, GUARD
	li r6, BUF
.fill:
	sb r5, 0(r1)
	addi r1, r1, 1
	addi r3, r3, 1
	bltu r3, r6, .fill

	la r1, t_dst
	add r1, r1, r11
	li r2, VALUE
	mv r3, r12
	call memset

	li r13, 1                   ; the result is the destination
	la r2, t_dst
	add r2, r2, r11
	bne r1, r2, .fail

	li r13, 2                   ; t_dst[i] is 0xA5 inside, GUARD outside
	li r2, 0
.check:
	la r3, t_dst
	add r3, r3, r2
	lbu r4, 0(r3)
	li r5, GUARD
	sub r6, r2, r11             ; unsigned: below 0 is past the end too
	bgeu r6, r12, .compare
	li r5, VALUE & 0xFF
.compare:
	bne r4, r5, .fail
	addi r2, r2, 1
	li r3, BUF
	bltu r2, r3, .check

	addi r12, r12, 1
	li r3, MAX_N
	bleu r12, r3, .len
	addi r11, r11, 1
	li r3, 4
	bltu r11, r3, .dst

	la r1, s_ok
	call t_puts
	li r1, 0
	j .return
.fail:
	mv r1, r13
.return:
	lw r13, 0(sp)
	lw r12, 4(sp)
	lw r11, 8(sp)
	lw ra, 12(sp)
	addi sp, sp, 16
	ret

	.include "../common/uart.asm"

s_ok:           .asciz "memset ok\n"
	.align 4
t_dst:          .space BUF
