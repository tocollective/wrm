; ============================================================================
;  Beeper: registers, DURATION counting down while on and turning it off
;  (no sound is made headless, but the device runs the same)
; ============================================================================

	.include "../common/harness.asm"

TIMED           = 200               ; ticks

test_main:
	li r10, BEEPER

	; ---- reset state
	li r28, 1
	lw r4, BEEPER_CONTROL(r10)
	bnez r4, fail
	lw r4, BEEPER_FREQUENCY(r10)
	bnez r4, fail
	lw r4, BEEPER_DURATION(r10)
	bnez r4, fail

	; ---- registers keep what is written, CONTROL only its bit 0
	li r28, 2
	li r1, 440
	sw r1, BEEPER_FREQUENCY(r10)
	lw r4, BEEPER_FREQUENCY(r10)
	bne r4, r1, fail
	li r28, 3
	li r1, -1
	sw r1, BEEPER_CONTROL(r10)
	lw r4, BEEPER_CONTROL(r10)
	li r3, BEEPER_ON
	bne r4, r3, fail

	; ---- DURATION = 0: sounds until turned off
	li r28, 4
	li r1, 500
.spin:
	addi r1, r1, -1
	bnez r1, .spin
	lw r4, BEEPER_CONTROL(r10)
	li r3, BEEPER_ON
	bne r4, r3, fail
	li r28, 5
	sw r0, BEEPER_CONTROL(r10)
	lw r4, BEEPER_CONTROL(r10)
	bnez r4, fail

	; ---- DURATION stands still while off
	li r28, 6
	li r1, TIMED
	sw r1, BEEPER_DURATION(r10)
	li r1, 100
.idle:
	addi r1, r1, -1
	bnez r1, .idle
	lw r4, BEEPER_DURATION(r10)
	li r3, TIMED
	bne r4, r3, fail

	; ---- ... and counts down while on: one tick each, then turns it off
	li r28, 7
	li r1, BEEPER_ON
	mfcr r12, cycle
	sw r1, BEEPER_CONTROL(r10)
	lw r4, BEEPER_DURATION(r10)
	li r3, TIMED
	bgeu r4, r3, fail
	beqz r4, fail
.wait:
	lw r4, BEEPER_CONTROL(r10)
	bnez r4, .wait
	mfcr r13, cycle
	li r28, 8
	lw r4, BEEPER_DURATION(r10)
	bnez r4, fail
	li r28, 9
	sub r4, r13, r12
	li r3, TIMED
	bltu r4, r3, fail
	li r28, 10
	li r3, TIMED + 64
	bgeu r4, r3, fail

	; ---- turning it off early keeps what is left of DURATION
	li r28, 11
	li r1, 100000
	sw r1, BEEPER_DURATION(r10)
	li r1, BEEPER_ON
	sw r1, BEEPER_CONTROL(r10)
	sw r0, BEEPER_CONTROL(r10)
	lw r4, BEEPER_DURATION(r10)
	beqz r4, fail
	li r3, 100000
	bgeu r4, r3, fail

	j pass
