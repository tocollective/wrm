; ============================================================================
;  Real-time clock: the host's time and its latch, the alarm going off at
;  once for a time in the past, not before its time, and on time
; ============================================================================

	.include "../common/harness.asm"

EPOCH_2020      = 1577836800        ; 2020-01-01 00:00:00 UTC
MAX_OFFSET      = 14 * 3600         ; time zones go from UTC-12 to UTC+14

test_main:
	li r10, RTC

	; ---- reset state: the alarm disarmed, nothing pending, the line low
	li r28, 1
	lw r4, RTC_CONTROL(r10)
	bnez r4, fail
	lw r4, RTC_STATUS(r10)
	bnez r4, fail
	lw r4, RTC_ALARM_LO(r10)
	bnez r4, fail
	lw r4, RTC_ALARM_HI(r10)
	bnez r4, fail
	li r28, 2
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_RTC
	and r4, r4, r3
	bnez r4, fail

	; ---- the host's time: after 2020, before 2106 (SECONDS_HI = 0)
	li r28, 3
	lw r11, RTC_SECONDS_LO(r10)     ; latches
	lw r4, RTC_SECONDS_HI(r10)
	bnez r4, fail
	li r28, 4
	mv r4, r11
	li r3, EPOCH_2020
	bltu r4, r3, fail
	li r28, 5
	lw r12, RTC_NANOSECONDS(r10)
	mv r4, r12
	li r3, 1000000000
	bgeu r4, r3, fail
	li r28, 6                       ; a real time zone: within 14 hours
	lw r4, RTC_UTC_OFFSET(r10)
	li r3, MAX_OFFSET
	add r4, r4, r3
	li r3, 2 * MAX_OFFSET
	bgtu r4, r3, fail

	; ---- the latch holds while the host's clock moves on...
	li r28, 7
	li r1, 20000                    ; about 1ms of ticks
.spin:
	addi r1, r1, -1
	bnez r1, .spin
	lw r4, RTC_NANOSECONDS(r10)
	bne r4, r12, fail
	; ---- ... and the next read of SECONDS_LO takes a later time
	li r28, 8
	lw r4, RTC_SECONDS_LO(r10)
	bltu r4, r11, fail
	bne r4, r11, .moved
	lw r4, RTC_NANOSECONDS(r10)
	bleu r4, r12, fail
.moved:

	; ---- the time registers are read-only, and writes don't latch
	li r28, 9
	lw r11, RTC_SECONDS_LO(r10)
	lw r12, RTC_NANOSECONDS(r10)
	lw r13, RTC_UTC_OFFSET(r10)
	li r1, -1
	sw r1, RTC_SECONDS_LO(r10)
	sw r1, RTC_SECONDS_HI(r10)
	sw r1, RTC_NANOSECONDS(r10)
	sw r1, RTC_UTC_OFFSET(r10)
	lw r4, RTC_SECONDS_HI(r10)
	bnez r4, fail
	lw r4, RTC_NANOSECONDS(r10)
	bne r4, r12, fail
	lw r4, RTC_UTC_OFFSET(r10)
	bne r4, r13, fail

	; ---- ALARM keeps what is written, each half on its own
	li r28, 10
	li r1, 0x12345678
	sw r1, RTC_ALARM_LO(r10)
	lw r4, RTC_ALARM_LO(r10)
	bne r4, r1, fail
	li r1, 0x9ABCDEF0               ; far in the future
	sw r1, RTC_ALARM_HI(r10)
	lw r4, RTC_ALARM_HI(r10)
	bne r4, r1, fail
	lw r4, RTC_ALARM_LO(r10)
	li r3, 0x12345678
	bne r4, r3, fail

	; ---- CONTROL keeps only its bit 0
	li r28, 11
	li r1, -1
	sw r1, RTC_CONTROL(r10)
	lw r4, RTC_CONTROL(r10)
	li r3, RTC_ARMED
	bne r4, r3, fail

	; ---- an alarm in the future doesn't go off over several comparisons
	li r28, 12
	li r1, TIMER
	lw r1, TIMER_FREQUENCY(r1)
	shri r1, r1, 7                  ; about 8ms: 8 comparisons
	call wait_ticks
	lw r4, RTC_STATUS(r10)
	bnez r4, fail
	lw r4, RTC_CONTROL(r10)
	li r3, RTC_ARMED
	bne r4, r3, fail
	li r28, 13
	sw r0, RTC_CONTROL(r10)
	lw r4, RTC_CONTROL(r10)
	bnez r4, fail

	; ---- an alarm in the past goes off as it is armed
	li r28, 14
	sw r0, RTC_ALARM_HI(r10)
	li r1, 1                        ; 1970-01-01 00:00:01
	sw r1, RTC_ALARM_LO(r10)
	li r1, RTC_ARMED
	sw r1, RTC_CONTROL(r10)
	lw r4, RTC_STATUS(r10)
	li r3, RTC_ALARM
	bne r4, r3, fail
	li r28, 15                      ; once: it is disarmed
	lw r4, RTC_CONTROL(r10)
	bnez r4, fail
	li r28, 16                      ; the line follows STATUS
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_RTC
	and r4, r4, r3
	beqz r4, fail
	li r28, 17                      ; writing 0 leaves it set
	sw r0, RTC_STATUS(r10)
	lw r4, RTC_STATUS(r10)
	beqz r4, fail
	li r28, 18                      ; writing 1 clears it and drops the line
	li r1, RTC_ALARM
	sw r1, RTC_STATUS(r10)
	lw r4, RTC_STATUS(r10)
	bnez r4, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_RTC
	and r4, r4, r3
	bnez r4, fail

	; ---- an alarm 2 seconds ahead: not yet...
	li r28, 19
	lw r11, RTC_SECONDS_LO(r10)
	addi r11, r11, 2
	sw r11, RTC_ALARM_LO(r10)
	li r1, RTC_ARMED
	sw r1, RTC_CONTROL(r10)
	lw r4, RTC_STATUS(r10)
	bnez r4, fail
	; ---- ... but within 4 s of ticks, which is at least 4 s of host time
	li r28, 20
	li r12, TIMER
	lw r12, TIMER_FREQUENCY(r12)
	shri r12, r12, 3                ; 1/8 s
	li r13, 32
.alarm_wait:
	lw r4, RTC_STATUS(r10)
	bnez r4, .alarm_done
	beqz r13, fail
	addi r13, r13, -1
	mv r1, r12
	call wait_ticks
	j .alarm_wait
.alarm_done:
	li r28, 21                      ; not early
	lw r4, RTC_SECONDS_LO(r10)
	bltu r4, r11, fail
	li r28, 22
	lw r4, RTC_CONTROL(r10)
	bnez r4, fail
	li r1, RTC_ALARM
	sw r1, RTC_STATUS(r10)

	j pass

; waits r1 clock ticks by the timer's COUNT; clobbers r1-r3
wait_ticks:
	li r2, TIMER
	lw r3, TIMER_COUNT_LO(r2)
	add r1, r1, r3                  ; the count to wait for
.loop:
	lw r3, TIMER_COUNT_LO(r2)
	sub r3, r1, r3
	bgtz r3, .loop                  ; signed: survives COUNT wrapping
	ret
