; ============================================================================
;  memcpy: every source and destination alignment, lengths 0 to 20; the
;  bytes around the destination stay as they were
; ============================================================================
; @output "memcpy ok\n"
; @exit 0

BUF     = 32
GUARD   = 0xEE
MAX_N   = 20

; r10 = source offset, r11 = destination offset, r12 = length,
; r13 = the number of the check, the exit code if it fails
	.globl main
main:
	addi sp, sp, -24
	sw ra, 20(sp)
	sw r10, 16(sp)
	sw r11, 12(sp)
	sw r12, 8(sp)
	sw r13, 4(sp)

	li r10, 0
.src:
	li r11, 0
.dst:
	li r12, 0
.len:
	la r1, t_src                ; t_src[i] = i + 1, t_dst[i] = GUARD
	la r2, t_dst
	li r3, 0
	li r5, GUARD
	li r6, BUF
.fill:
	addi r4, r3, 1
	sb r4, 0(r1)
	sb r5, 0(r2)
	addi r1, r1, 1
	addi r2, r2, 1
	addi r3, r3, 1
	bltu r3, r6, .fill

	la r1, t_dst
	add r1, r1, r11
	la r2, t_src
	add r2, r2, r10
	mv r3, r12
	call memcpy

	li r13, 1                   ; the result is the destination
	la r2, t_dst
	add r2, r2, r11
	bne r1, r2, .fail

	li r13, 2                   ; t_dst[i] is t_src[i - r11 + r10] inside
	li r2, 0                    ; the copy and GUARD outside it
.check:
	la r3, t_dst
	add r3, r3, r2
	lbu r4, 0(r3)
	li r5, GUARD
	sub r6, r2, r11             ; unsigned: below 0 is past the end too
	bgeu r6, r12, .compare
	add r5, r6, r10
	addi r5, r5, 1
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
	addi r10, r10, 1
	bltu r10, r3, .src

	la r1, s_ok
	call t_puts
	li r1, 0
	j .return
.fail:
	mv r1, r13
.return:
	lw r13, 4(sp)
	lw r12, 8(sp)
	lw r11, 12(sp)
	lw r10, 16(sp)
	lw ra, 20(sp)
	addi sp, sp, 24
	ret

	.include "../common/uart.asm"

s_ok:           .asciz "memcpy ok\n"
	.align 4
t_src:          .space BUF
t_dst:          .space BUF
