; ============================================================================
;  [8] Timer and cycle counters
; ============================================================================

TIMER_HZ        = 100               ; periodic interrupt rate
TIMER_TICKS     = 10                ; interrupts to wait for: 0.1s

demo_timer:
	addi r30, r30, -12
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)

	la r1, s_timer_title
	call puts

	; CYCLE and INSTRET run freely; the difference of two reads measures
	; the code in between (a taken branch costs 2 extra cycles)
	mfcr r10, cycle
	mfcr r11, instret
	li r2, 100
.loop:
	addi r2, r2, -1
	bnez r2, .loop
	mfcr r3, cycle
	mfcr r4, instret
	sub r10, r3, r10
	sub r11, r4, r11
	la r1, s_loop_cycles
	mv r2, r10
	call show
	la r1, s_loop_instret
	mv r2, r11
	call show

	li r9, TIMER
	la r1, s_timer_freq
	lw r2, TIMER_FREQUENCY(r9)  ; = the clock rate: the timer counts ticks
	call show

	; periodic interrupt, TIMER_HZ times a second
	sw r0, VAR_TICKS(r0)
	la r1, irq_handler
	mtcr ivec, r1
	li r9, TIMER
	lw r2, TIMER_FREQUENCY(r9)
	li r3, TIMER_HZ
	divu r2, r2, r3
	sw r2, TIMER_RELOAD(r9)     ; period in ticks
	li r2, TIMER_ENABLE | TIMER_PERIODIC
	sw r2, TIMER_CONTROL(r9)    ; counts down from RELOAD
	li r9, PIC
	li r2, 1 << IRQ_TIMER
	sw r2, PIC_ENABLE(r9)
	call rdcycle
	mv r10, r1
	li r2, STATUS_IE
	mtcr status, r2
.wait:
	wfi                         ; sleeps until the next tick
	lw r2, VAR_TICKS(r0)
	sltiu r2, r2, TIMER_TICKS
	bnez r2, .wait

	mtcr status, r0
	call rdcycle
	sub r11, r1, r10            ; elapsed, fits in the low half
	li r9, TIMER
	sw r0, TIMER_CONTROL(r9)    ; stop
	li r2, TIMER_EXPIRED
	sw r2, TIMER_STATUS(r9)     ; drop a tick that came after IE = 0
	li r9, PIC
	sw r0, PIC_ENABLE(r9)

	la r1, s_timer_ticks
	lw r2, VAR_TICKS(r0)
	call show
	la r1, s_timer_cycles
	mv r2, r11
	call show

	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 12
	ret

; Acknowledges the tick, which drops the line, and counts it.
on_timer:
	li r9, TIMER
	li r1, TIMER_EXPIRED
	sw r1, TIMER_STATUS(r9)
	lw r1, VAR_TICKS(r0)
	addi r1, r1, 1
	sw r1, VAR_TICKS(r0)
	ret

; ---- data -----------------------------------------------------------------

s_timer_title:  .asciz "\n[8] timer and cycle counters\n"
s_loop_cycles:  .asciz "100-pass loop, cycles"
s_loop_instret: .asciz "  instructions"
s_timer_freq:   .asciz "timer FREQUENCY, Hz"
s_timer_ticks:  .asciz "ticks at 100 Hz"
s_timer_cycles: .asciz "cycles for them"

	.align 4
