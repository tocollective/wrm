; ============================================================================
;  Precise interrupts under load
; ============================================================================
; A workload with loads, stores, stalls, branches, calls, MUL/DIV and
; MFCR/MTCR runs once with interrupts off and once with the timer
; interrupting it every 1-32 cycles, the delay moving by one each time, so
; the interrupts land on every kind of instruction and pipeline state.
; If every interrupt is precise, both runs give the same result.
; On failure: r1 = result with interrupts, r2 = without, r3 = seed,
; r4 = interrupts taken.

	.include "../common/harness.asm"

WORK            = 0x2000            ; 64 words
WORK_COUNT      = 64
IRQS            = 0x0100            ; interrupts taken
PHASE           = 0x0104            ; the handler's delay counter
MIN_IRQS        = 1000              ; per run (about 3700 happen)

test_main:
	la r1, stress_handler
	mtcr ivec, r1
	li r9, PIC
	li r1, 1 << IRQ_TIMER
	sw r1, PIC_ENABLE(r9)

	li r28, 1
	la r10, seeds
.seed:
	lw r1, 0(r10)
	call workload               ; the reference, IE clear
	mv r11, r1

	sw r0, IRQS(r0)
	sw r0, PHASE(r0)
	li r9, TIMER
	li r1, 1
	sw r1, TIMER_RELOAD(r9)
	li r1, TIMER_ENABLE
	sw r1, TIMER_CONTROL(r9)
	li r1, STATUS_IE
	mtcr status, r1
	lw r1, 0(r10)
	call workload
	mtcr status, r0
	li r9, TIMER
	sw r0, TIMER_CONTROL(r9)
	li r2, TIMER_EXPIRED
	sw r2, TIMER_STATUS(r9)

	mv r2, r11
	lw r3, 0(r10)
	lw r4, IRQS(r0)
	bne r1, r2, fail
	li r5, MIN_IRQS
	bltu r4, r5, fail
	addi r28, r28, 1
	addi r10, r10, 4
	la r2, seeds_end
	bltu r10, r2, .seed
	j pass

seeds:
	.dw 1, 0x12345678, 0xDEADBEEF
seeds_end:

; ---- the workload: uses r1-r9 and the stack --------------------------------------

; workload(r1 = seed) -> r1 = checksum
workload:
	addi r30, r30, -4
	sw ra, 0(r30)

	; fill WORK with pseudo-random numbers
	li r2, WORK
	li r3, WORK_COUNT
	li r4, 1103515245
	li r6, 12345
	mv r5, r1
.fill:
	mul r5, r5, r4
	add r5, r5, r6
	sari r7, r5, 7
	sw r7, 0(r2)
	addi r2, r2, 4
	addi r3, r3, -1
	bnez r3, .fill

	li r1, WORK
	li r2, WORK_COUNT
	call sort                   ; lib.asm: bubble sort, loads and stores

	; fold the sorted array into a checksum
	li r2, WORK
	li r3, 0
	li r1, 0
.sum:
	lw r4, 0(r2)
	shli r5, r1, 5              ; rotate left by 5
	shri r6, r1, 27
	or r1, r5, r6
	xor r1, r1, r4
	addi r7, r3, 1
	div r8, r4, r7
	add r1, r1, r8
	li r9, 7
	rem r8, r4, r9
	xor r1, r1, r8
	lb r8, 1(r2)
	add r1, r1, r8              ; load-use
	sh r1, 2(r2)                ; store, then load it back at once
	lhu r8, 2(r2)
	add r1, r1, r8
	call mix
	addi r2, r2, 4
	addi r3, r3, 1
	li r9, WORK_COUNT
	bltu r3, r9, .sum

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; mix(r1) -> r1: a data-dependent branch and a trip through SCRATCH
mix:
	bltz r1, .negative
	xori r1, r1, 0x155
	j .done
.negative:
	sub r1, r0, r1
.done:
	mtcr scratch, r1
	mfcr r9, scratch
	add r1, r1, r9
	ret

; ---- the handler: acks the timer and starts it again, r26 and r27 only ----------

stress_handler:
	mfcr r26, cause
	bnez r26, unexpected_trap   ; a fault in the workload
	li r26, TIMER
	li r27, TIMER_EXPIRED
	sw r27, TIMER_STATUS(r26)
	lw r27, PHASE(r0)
	addi r27, r27, 1
	andi r27, r27, 31
	sw r27, PHASE(r0)
	addi r27, r27, 1            ; the next delay: 1-32 cycles
	sw r27, TIMER_RELOAD(r26)
	li r27, TIMER_ENABLE
	sw r27, TIMER_CONTROL(r26)
	lw r27, IRQS(r0)
	addi r27, r27, 1
	sw r27, IRQS(r0)
	iret
