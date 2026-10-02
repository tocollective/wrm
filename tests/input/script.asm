; ============================================================================
;  The input script (--input) in deterministic mode: every event reaches
;  its device at the tick the script gives, never before; the RTC counts
;  ticks from 1970
; ============================================================================
; @args --deterministic
; @input 200000 key 4 down
; @input +1000 key 4 up
; @input 300000 uart hi\n
; @input 400000 mouse 5 -3
; @input +0 button left down
; @input +0 wheel -1
; @input 500000 power

	.include "../common/harness.asm"

TIMEOUT         = 2000000           ; ticks: well after the last event

test_main:
	; mouse events only come while it is enabled
	li r1, MOUSE
	li r2, MOUSE_ENABLE
	sw r2, MOUSE_CONTROL(r1)

	; ---- the virtual RTC: 0 seconds, no time zone
	li r28, 1
	li r1, RTC
	lw r4, RTC_SECONDS_LO(r1)
	bnez r4, fail
	lw r4, RTC_UTC_OFFSET(r1)
	bnez r4, fail

	; ---- the key, pressed at tick 200000 and released 1000 ticks later
	li r28, 2
	li r1, KBD + KBD_STATUS
	li r2, KBD_READY
	li r6, 200000
	call wait_bit
	li r28, 3
	li r1, KBD
	lw r4, KBD_DATA(r1)
	li r3, 4                        ; usage 4 (A), pressed
	bne r4, r3, fail
	li r28, 4
	li r1, KBD + KBD_STATUS
	li r2, KBD_READY
	li r6, 201000
	call wait_bit
	li r28, 5
	li r1, KBD
	lw r4, KBD_DATA(r1)
	li r3, 4 | 0x80000000           ; released
	bne r4, r3, fail

	; ---- three bytes on the UART at once
	li r28, 6
	li r1, UART + UART_STATUS
	li r2, UART_RX_READY
	li r6, 300000
	call wait_bit
	li r28, 7
	li r1, UART
	lw r4, UART_DATA(r1)
	li r3, 'h'
	bne r4, r3, fail
	lw r4, UART_DATA(r1)
	li r3, 'i'
	bne r4, r3, fail
	lw r4, UART_DATA(r1)
	li r3, '\n'
	bne r4, r3, fail
	lw r4, UART_STATUS(r1)
	andi r4, r4, UART_RX_READY
	bnez r4, fail

	; ---- the mouse: motion, a button, the wheel, as three events
	li r28, 8
	li r1, MOUSE + MOUSE_STATUS
	li r2, MOUSE_READY
	li r6, 400000
	call wait_bit
	li r28, 9
	li r1, MOUSE
	lw r4, MOUSE_DATA(r1)
	li r3, 0x8000FD05               ; dx 5, dy -3
	bne r4, r3, fail
	li r28, 10
	lw r4, MOUSE_DATA(r1)
	li r3, 0x81000000               ; the left button down
	bne r4, r3, fail
	li r28, 11
	lw r4, MOUSE_DATA(r1)
	li r3, 0x81FF0000               ; one wheel step towards the user
	bne r4, r3, fail

	; ---- the power button asks to power off
	li r28, 12
	li r1, POWER + POWER_STATUS
	li r2, POWER_OFF_REQUEST
	li r6, 500000
	call wait_bit
	li r1, POWER
	li r2, POWER_OFF_REQUEST
	sw r2, POWER_STATUS(r1)

	j pass

; wait_bit(r1 = register, r2 = bit, r6 = tick): waits until the bit is set
; in the register; fails if it isn't set by TIMEOUT, or if the timer's
; COUNT, read right after the bit is seen, is still below r6: the event
; came early (by more than a turn of the loop). Clobbers r3-r5.
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
