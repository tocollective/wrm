; ============================================================================
;  Interrupts: WFI, the PIC mask, the MTCR STATUS window, IRET with the
;  line still asserted, interrupting user mode
; ============================================================================
; The timer (IRQ 2) is the only source. irq_handler records each interrupt:
;   r20 = CAUSE, r21 = EPC, r22 = the previous EPC, r23 = STATUS on entry,
;   r24 += 1, r18 = r5 of the interrupted code
; and acks the timer, unless r19 is set: then it clears r19 and returns
; with the line still asserted. A SYSCALL makes it return to r25 in
; supervisor mode. It owns r18-r27.

	.include "../common/harness.asm"

STATUS_PIE      = 1 << 1
SYS_EXIT        = 0x0E

test_main:
	la r1, irq_handler
	mtcr ivec, r1
	li r9, PIC
	li r1, 1 << IRQ_TIMER
	sw r1, PIC_ENABLE(r9)
	li r19, 0
	li r24, 0

	; ---- WFI with IE set: sleeps, then takes the interrupt after it
	li r28, 1
	li r1, STATUS_IE
	mtcr status, r1
	mfcr r12, cycle
	li r1, 100
	call timer_start
	wfi
.after_wfi:
	mfcr r13, cycle
	mtcr status, r0
	li r3, 1
	bne r24, r3, fail
	li r28, 2
	la r3, .after_wfi
	bne r21, r3, fail
	li r28, 3
	bnez r20, fail              ; CAUSE = 0 for interrupts
	li r28, 4
	li r3, STATUS_PIE | STATUS_EXL
	bne r23, r3, fail
	li r28, 5                   ; CYCLE went on while sleeping
	sub r4, r13, r12
	li r3, 100
	bltu r4, r3, fail

	; ---- WFI with IE clear: wakes up and goes on, no interrupt
	li r28, 10
	li r24, 0
	li r1, 50
	call timer_start
	wfi
	bnez r24, fail
	li r28, 11
	li r9, TIMER
	lw r4, TIMER_STATUS(r9)
	li r3, TIMER_EXPIRED
	bne r4, r3, fail
	li r28, 12
	li r9, PIC
	lw r4, PIC_CLAIM(r9)
	li r3, IRQ_TIMER
	bne r4, r3, fail
	call timer_ack

	; ---- a line masked in the PIC doesn't interrupt; unmasking it does
	li r28, 20
	li r9, PIC
	sw r0, PIC_ENABLE(r9)
	li r1, STATUS_IE
	mtcr status, r1
	li r1, 10
	call timer_start
	li r1, 50
	call delay
	bnez r24, fail
	li r28, 21
	li r9, PIC
	lw r4, PIC_PENDING(r9)
	li r3, 1 << IRQ_TIMER
	bne r4, r3, fail
	li r28, 22
	lw r4, PIC_ACTIVE(r9)
	bnez r4, fail
	li r28, 23
	lw r4, PIC_CLAIM(r9)
	li r3, -1
	bne r4, r3, fail
	li r28, 24
	li r1, 1 << IRQ_TIMER
	sw r1, PIC_ENABLE(r9)       ; taken within a few instructions
.unmasked:
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
.unmasked_end:
	mtcr status, r0
	li r3, 1
	bne r24, r3, fail
	li r28, 25
	la r3, .unmasked
	bltu r21, r3, fail
	la r3, .unmasked_end
	bgeu r21, r3, fail

	; ---- MTCR STATUS setting IE with the line up: the interrupt comes
	; right after it, before the next instruction
	li r28, 30
	li r24, 0
	li r1, 5
	call timer_start
	call timer_wait
	li r5, 0
	li r1, STATUS_IE
	mtcr status, r1
.after_ie:
	addi r5, r5, 1
	mtcr status, r0
	li r3, 1
	bne r24, r3, fail
	li r28, 31
	la r3, .after_ie
	bne r21, r3, fail
	li r28, 32
	bnez r18, fail              ; ADDI had not run yet
	li r28, 33
	li r3, 1
	bne r5, r3, fail            ; and ran once after IRET

	; ---- MTCR STATUS clearing IE: an interrupt may come before it, never
	; after. The timer expires 1, 2, ... 24 cycles after it is started.
	li r28, 40
	li r24, 0
	li r16, 0                   ; runs that were interrupted
	li r17, 0                   ; runs that were not
	li r15, 1                   ; the delay
.window:
	li r9, TIMER
	sw r15, TIMER_RELOAD(r9)
	li r1, STATUS_IE
	mtcr status, r1
	mv r14, r24
	li r2, TIMER_ENABLE
.window_start:
	sw r2, TIMER_CONTROL(r9)
.window_clear:
	mtcr status, r0
.window_after:
	li r1, 20
	call delay                  ; the timer has surely expired by now
	beq r14, r24, .missed
	addi r16, r16, 1
	la r3, .window_start        ; the interrupt came before the MTCR...
	bltu r21, r3, fail
	la r3, .window_after        ; ...never after it
	bgeu r21, r3, fail
	j .window_next
.missed:
	addi r17, r17, 1
	li r9, TIMER
	lw r4, TIMER_STATUS(r9)
	beqz r4, fail
	call timer_ack
.window_next:
	addi r15, r15, 1
	li r3, 24
	bgeu r3, r15, .window
	li r28, 41                  ; the delays cover both outcomes
	beqz r16, fail
	beqz r17, fail

	; ---- IRET with the line still asserted: taken again at once, before
	; the instruction at EPC
	li r28, 50
	li r24, 0
	li r1, 5
	call timer_start
	call timer_wait
	li r19, 1                   ; the first time, the handler doesn't ack
	li r5, 0
	li r1, STATUS_IE
	mtcr status, r1
.again:
	addi r5, r5, 1
	mtcr status, r0
	li r3, 2
	bne r24, r3, fail
	li r28, 51
	la r3, .again
	bne r21, r3, fail
	bne r22, r3, fail
	li r28, 52
	li r3, 1
	bne r5, r3, fail

	; ---- an interrupt in user mode: the handler runs in supervisor mode
	; and IRET goes back to user mode
	li r28, 60
	li r24, 0
	la r25, .user_back
	li r1, STATUS_PUM | STATUS_PIE
	mtcr status, r1
	la r1, user_prog
	mtcr epc, r1
	li r1, 50
	call timer_start
	iret
	j fail
.user_back:
	mtcr status, r0
	li r3, 1
	bne r24, r3, fail
	li r28, 61
	li r3, STATUS_PUM | STATUS_PIE | STATUS_EXL
	bne r23, r3, fail
	li r28, 62                  ; the user loop counted on after IRET
	beqz r5, fail
	j pass

; ---- helpers --------------------------------------------------------------------

; timer_start(r1 = ticks): one-shot
timer_start:
	li r9, TIMER
	sw r1, TIMER_RELOAD(r9)
	li r2, TIMER_ENABLE
	sw r2, TIMER_CONTROL(r9)
	ret

; timer_wait(): until the timer has expired (with IE clear)
timer_wait:
	li r9, TIMER
.poll:
	lw r2, TIMER_STATUS(r9)
	beqz r2, .poll
	ret

timer_ack:
	li r9, TIMER
	li r2, TIMER_EXPIRED
	sw r2, TIMER_STATUS(r9)
	ret

; delay(r1 = loops)
delay:
	addi r1, r1, -1
	bnez r1, delay
	ret

; ---- the handler ----------------------------------------------------------------

irq_handler:
	mfcr r20, cause
	bnez r20, .syscall
	mv r22, r21
	mfcr r21, epc
	mfcr r23, status
	mv r18, r5
	addi r24, r24, 1
	bnez r19, .no_ack
	li r26, TIMER
	li r27, TIMER_EXPIRED
	sw r27, TIMER_STATUS(r26)
	iret
.no_ack:
	li r19, 0
	iret
.syscall:
	mfcr r26, status            ; back to supervisor mode at r25
	andi r26, r26, STATUS_IE | STATUS_PIE | STATUS_EXL
	mtcr status, r26
	mtcr epc, r25
	iret

; ---- user code ----------------------------------------------------------------

user_prog:
	li r5, 0
.spin:
	addi r5, r5, 1
	beqz r24, .spin             ; the handler counts in r24
	li r1, SYS_EXIT
	syscall
