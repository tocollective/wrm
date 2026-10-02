; ============================================================================
;  The UART's RX line from the emulator's stdin (a pipe here)
; ============================================================================
; @stdin ok\n

	.include "../common/harness.asm"

test_main:
	li r10, UART
	la r11, expected
.next:
	lbu r12, 0(r11)
	beqz r12, pass
	; ---- the next byte, within about a second of ticks
	li r28, 1
	li r5, TIMER
	lw r6, TIMER_FREQUENCY(r5)
	lw r3, TIMER_COUNT_LO(r5)
	add r6, r6, r3
.wait:
	lw r4, UART_STATUS(r10)
	andi r4, r4, UART_RX_READY
	bnez r4, .got
	lw r3, TIMER_COUNT_LO(r5)
	bltu r3, r6, .wait
	j fail
.got:
	li r28, 2
	lw r4, UART_DATA(r10)
	mv r1, r4
	mv r2, r12
	bne r4, r12, fail
	addi r11, r11, 1
	j .next

expected:       .asciz "ok\n"
	.align 4
