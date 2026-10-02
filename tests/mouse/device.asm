; ============================================================================
;  Mouse: registers, enabling and flushing (headless, so the host never
;  sends an event and the FIFO stays empty)
; ============================================================================

	.include "../common/harness.asm"

test_main:
	li r10, MOUSE

	; ---- reset state: disabled, nothing queued, the line low
	li r28, 1
	lw r4, MOUSE_STATUS(r10)
	bnez r4, fail
	lw r4, MOUSE_DATA(r10)          ; an empty FIFO reads as 0
	bnez r4, fail
	lw r4, MOUSE_CONTROL(r10)
	bnez r4, fail
	li r28, 2
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_MOUSE
	and r4, r4, r3
	bnez r4, fail

	; ---- CONTROL keeps the enable bit; flush reads as 0
	li r28, 3
	li r1, MOUSE_ENABLE
	sw r1, MOUSE_CONTROL(r10)
	lw r4, MOUSE_CONTROL(r10)
	bne r4, r1, fail
	li r28, 4
	li r1, MOUSE_ENABLE | MOUSE_FLUSH
	sw r1, MOUSE_CONTROL(r10)
	lw r4, MOUSE_CONTROL(r10)
	li r3, MOUSE_ENABLE
	bne r4, r3, fail
	li r28, 5                       ; other bits are dropped
	li r1, -1
	sw r1, MOUSE_CONTROL(r10)
	lw r4, MOUSE_CONTROL(r10)
	li r3, MOUSE_ENABLE | MOUSE_ABSOLUTE
	bne r4, r3, fail
	li r28, 8                       ; POSITION is 0 and read-only
	sw r1, MOUSE_POSITION(r10)
	lw r4, MOUSE_POSITION(r10)
	bnez r4, fail
	li r1, MOUSE_ENABLE
	sw r1, MOUSE_CONTROL(r10)

	; ---- STATUS and DATA are read-only
	li r28, 6
	li r1, -1
	sw r1, MOUSE_STATUS(r10)
	sw r1, MOUSE_DATA(r10)
	lw r4, MOUSE_STATUS(r10)
	bnez r4, fail
	lw r4, MOUSE_DATA(r10)
	bnez r4, fail

	; ---- disabled again
	li r28, 7
	sw r0, MOUSE_CONTROL(r10)
	lw r4, MOUSE_CONTROL(r10)
	bnez r4, fail

	j pass
