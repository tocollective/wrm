; ============================================================================
;  The virtual RTC (--rtc=SECONDS): the time starts at the given second
;  and follows the clock ticks, and so does the alarm
; ============================================================================
; @args --rtc=1700000000 --unthrottled

	.include "../common/harness.asm"

START           = 1700000000        ; 2023-11-14 22:13:20 UTC

test_main:
	li r10, RTC
	li r11, TIMER

	; ---- the given second, no time zone
	li r28, 1
	lw r4, RTC_SECONDS_LO(r10)
	li r3, START
	bne r4, r3, fail
	lw r4, RTC_SECONDS_HI(r10)
	bnez r4, fail
	lw r4, RTC_UTC_OFFSET(r10)
	bnez r4, fail

	; ---- NANOSECONDS is the ticks since power-on in ns
	li r28, 2
	lw r5, TIMER_COUNT_LO(r11)      ; the ticks before the latch...
	lw r4, RTC_SECONDS_LO(r10)
	lw r6, TIMER_COUNT_LO(r11)      ; ... and after it
	lw r7, RTC_NANOSECONDS(r10)
	lw r8, TIMER_FREQUENCY(r11)
	li r3, 1000000000
	divu r8, r3, r8                 ; whole ns per tick
	mul r5, r5, r8
	bltu r7, r5, fail
	addi r8, r8, 1
	mul r6, r6, r8
	bgtu r7, r6, fail

	; ---- a second of ticks is a second
	li r28, 3
	lw r1, TIMER_FREQUENCY(r11)
	call wait_ticks
	lw r4, RTC_SECONDS_LO(r10)
	li r3, START + 1
	bne r4, r3, fail

	; ---- an alarm at START + 2: not after half a second...
	li r28, 4
	li r1, START + 2
	sw r1, RTC_ALARM_LO(r10)
	li r1, RTC_ARMED
	sw r1, RTC_CONTROL(r10)
	lw r1, TIMER_FREQUENCY(r11)
	shri r1, r1, 1
	call wait_ticks
	lw r4, RTC_STATUS(r10)
	bnez r4, fail
	; ---- ... but within the second after
	li r28, 5
	lw r1, TIMER_FREQUENCY(r11)
	call wait_ticks
	lw r4, RTC_STATUS(r10)
	li r3, RTC_ALARM
	bne r4, r3, fail
	li r28, 6
	lw r4, RTC_SECONDS_LO(r10)
	li r3, START + 2
	bne r4, r3, fail
	sw r3, RTC_STATUS(r10)

	j pass

; waits r1 clock ticks by the timer's COUNT; clobbers r1-r3
wait_ticks:
	li r2, TIMER
	lw r3, TIMER_COUNT_LO(r2)
	add r1, r1, r3                  ; the count to wait for
.loop:
	lw r3, TIMER_COUNT_LO(r2)
	sub r3, r1, r3
	bgtz r3, .loop
	ret
