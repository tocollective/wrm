; ============================================================================
;  Mouse in absolute mode: the host's pointer as positions, moves merged,
;  every event with the position it happened at (POSITION, latched by
;  DATA), relative motion ignored
; ============================================================================
; @args --deterministic
; @input 200000 point 100 50
; @input +0 point 120 60
; @input +0 button left down
; @input 300000 mouse 5 5
; @input +0 point 7 8
; @input 400000 wheel 1

	.include "../common/harness.asm"

TIMEOUT         = 2000000           ; ticks: well after the last event

test_main:
	li r10, MOUSE
	li r1, MOUSE_ENABLE | MOUSE_ABSOLUTE
	sw r1, MOUSE_CONTROL(r10)

	; ---- two moves in a row are one event, at the newer position
	li r28, 1
	li r1, MOUSE + MOUSE_STATUS
	li r2, MOUSE_READY
	li r6, 200000
	call wait_bit
	li r28, 2
	lw r4, MOUSE_DATA(r10)
	li r3, MOUSE_EV_VALID | MOUSE_EV_ABSOLUTE
	bne r4, r3, fail
	li r28, 3
	lw r4, MOUSE_POSITION(r10)
	li r3, 120 | 60 << 16
	bne r4, r3, fail

	; ---- the button, where the pointer was
	li r28, 4
	lw r4, MOUSE_DATA(r10)
	li r3, MOUSE_EV_VALID | MOUSE_EV_ABSOLUTE | 1 << 24
	bne r4, r3, fail
	li r28, 5
	lw r4, MOUSE_POSITION(r10)
	li r3, 120 | 60 << 16
	bne r4, r3, fail
	li r28, 6
	lw r4, MOUSE_STATUS(r10)
	bnez r4, fail

	; ---- relative motion doesn't count; a move with the button held
	li r28, 7
	li r1, MOUSE + MOUSE_STATUS
	li r2, MOUSE_READY
	li r6, 300000
	call wait_bit
	li r28, 8
	lw r4, MOUSE_DATA(r10)
	li r3, MOUSE_EV_VALID | MOUSE_EV_ABSOLUTE | 1 << 24
	bne r4, r3, fail
	li r28, 9
	lw r4, MOUSE_POSITION(r10)
	li r3, 7 | 8 << 16
	bne r4, r3, fail
	li r28, 10
	lw r4, MOUSE_STATUS(r10)
	bnez r4, fail

	; ---- the wheel, at the same place
	li r28, 11
	li r1, MOUSE + MOUSE_STATUS
	li r2, MOUSE_READY
	li r6, 400000
	call wait_bit
	li r28, 12
	lw r4, MOUSE_DATA(r10)
	li r3, MOUSE_EV_VALID | MOUSE_EV_ABSOLUTE | 1 << 24 | 1 << 16
	bne r4, r3, fail
	lw r4, MOUSE_POSITION(r10)
	li r3, 7 | 8 << 16
	bne r4, r3, fail

	; ---- an empty FIFO reads 0 and leaves POSITION alone
	li r28, 13
	lw r4, MOUSE_DATA(r10)
	bnez r4, fail
	lw r4, MOUSE_POSITION(r10)
	bne r4, r3, fail

	j pass

; wait_bit(r1 = register, r2 = bit, r6 = tick): waits until the bit is set
; in the register; fails if it isn't set by TIMEOUT, or if the timer's
; COUNT, read right after the bit is seen, is still below r6: the event
; came early. Clobbers r3-r5.
wait_bit:
	li r5, TIMER
.loop:
	lw r4, 0(r1)
	and r4, r4, r2
	bnez r4, .seen
	lw r3, TIMER_COUNT_LO(r5)
	li r4, TIMEOUT
	bltu r3, r4, .loop
	j fail
.seen:
	lw r3, TIMER_COUNT_LO(r5)
	bltu r3, r6, fail
	ret
