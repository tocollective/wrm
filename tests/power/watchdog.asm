; ============================================================================
;  Watchdog: kicked in time it stays quiet; not kicked it barks (STATUS,
;  IRQ 12) and, after the grace period, resets the machine with
;  RESET_CAUSE 4; LOCK keeps software from turning it off
; ============================================================================

	.include "../common/harness.asm"

TIMEOUT_TICKS   = 1000
GRACE_TICKS     = 500
LONG            = 200000            ; ticks to give up waiting

test_main:
	li r10, WATCHDOG
	li r1, POWER
	lw r4, POWER_RESET_CAUSE(r1)
	li r3, RESET_WATCHDOG
	beq r4, r3, after_bite

	; ---- reset state: off, nothing set
	li r28, 1
	lw r4, WATCHDOG_CONTROL(r10)
	bnez r4, fail
	lw r4, WATCHDOG_TIMEOUT(r10)
	bnez r4, fail
	lw r4, WATCHDOG_GRACE(r10)
	bnez r4, fail
	lw r4, WATCHDOG_VALUE(r10)
	bnez r4, fail
	lw r4, WATCHDOG_STATUS(r10)
	bnez r4, fail
	lw r4, WATCHDOG_KICK(r10)       ; write-only
	bnez r4, fail

	; ---- turned on, it counts TIMEOUT down
	li r28, 2
	li r1, TIMEOUT_TICKS
	sw r1, WATCHDOG_TIMEOUT(r10)
	li r1, GRACE_TICKS
	sw r1, WATCHDOG_GRACE(r10)
	li r1, WATCHDOG_ENABLE
	sw r1, WATCHDOG_CONTROL(r10)
	lw r4, WATCHDOG_VALUE(r10)
	beqz r4, fail
	li r3, TIMEOUT_TICKS
	bltu r3, r4, fail

	; ---- kicked often enough, it never barks
	li r28, 3
	call timer_now
	li r11, 10 * TIMEOUT_TICKS
	add r11, r11, r1
.kicking:
	sw r0, WATCHDOG_KICK(r10)
	lw r4, WATCHDOG_STATUS(r10)
	bnez r4, fail
	call timer_now
	bltu r1, r11, .kicking

	; ---- left alone it barks: STATUS, the IRQ line, the grace period
	li r28, 4
	call wait_bark
	li r28, 5
	lw r4, WATCHDOG_STATUS(r10)
	li r3, WATCHDOG_BARK | WATCHDOG_IN_GRACE
	bne r4, r3, fail
	li r28, 6
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_WATCHDOG
	and r4, r4, r3
	beqz r4, fail

	; ---- a kick ends it all and starts again
	li r28, 7
	sw r0, WATCHDOG_KICK(r10)
	lw r4, WATCHDOG_STATUS(r10)
	bnez r4, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_WATCHDOG
	and r4, r4, r3
	bnez r4, fail

	; ---- clearing BARK quiets the line but doesn't kick
	li r28, 8
	call wait_bark
	li r28, 9
	li r1, WATCHDOG_BARK
	sw r1, WATCHDOG_STATUS(r10)
	lw r4, WATCHDOG_STATUS(r10)
	li r3, WATCHDOG_IN_GRACE
	bne r4, r3, fail

	; ---- turned off it stops where it is
	li r28, 10
	sw r0, WATCHDOG_CONTROL(r10)
	lw r5, WATCHDOG_VALUE(r10)
	lw r4, WATCHDOG_STATUS(r10)
	bnez r4, fail                   ; not counting the grace any more
	li r1, 1000
.idle:
	addi r1, r1, -1
	bnez r1, .idle
	lw r4, WATCHDOG_VALUE(r10)
	bne r4, r5, fail

	; ---- locked: CONTROL, TIMEOUT and GRACE don't change any more
	li r28, 11
	li r1, WATCHDOG_ENABLE | WATCHDOG_LOCK
	sw r1, WATCHDOG_CONTROL(r10)
	sw r0, WATCHDOG_CONTROL(r10)
	sw r0, WATCHDOG_TIMEOUT(r10)
	sw r0, WATCHDOG_GRACE(r10)
	lw r4, WATCHDOG_CONTROL(r10)
	bne r4, r1, fail
	li r28, 12
	lw r4, WATCHDOG_TIMEOUT(r10)
	li r3, TIMEOUT_TICKS
	bne r4, r3, fail
	lw r4, WATCHDOG_GRACE(r10)
	li r3, GRACE_TICKS
	bne r4, r3, fail

	; ---- and it bites: the machine starts again at after_bite
	li r28, 13
	call timer_now
	li r11, LONG
	add r11, r11, r1
.waiting:
	call timer_now
	bltu r1, r11, .waiting
	j fail

after_bite:
	; ---- reset: the watchdog is off and unlocked again
	li r28, 20
	lw r4, WATCHDOG_CONTROL(r10)
	bnez r4, fail
	lw r4, WATCHDOG_STATUS(r10)
	bnez r4, fail
	lw r4, WATCHDOG_TIMEOUT(r10)
	bnez r4, fail
	j pass

; timer_now() -> r1: the timer's COUNT, low half
timer_now:
	li r1, TIMER
	lw r1, TIMER_COUNT_LO(r1)
	ret

; wait_bark(): waits for STATUS.BARK, fails after LONG ticks. Clobbers
; r1-r5, r11.
wait_bark:
	addi r30, r30, -4
	sw ra, 0(r30)
	call timer_now
	li r11, LONG
	add r11, r11, r1
.loop:
	lw r4, WATCHDOG_STATUS(r10)
	andi r4, r4, WATCHDOG_BARK
	bnez r4, .done
	call timer_now
	bltu r1, r11, .loop
	j fail
.done:
	lw ra, 0(r30)
	addi r30, r30, 4
	ret
