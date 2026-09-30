; ============================================================================
;  Pipeline timing: stalls and penalties, counted with CYCLE
; ============================================================================
; Each measurement reads CYCLE, runs a block, four NOPs and reads CYCLE
; again. The NOPs keep the block's bubbles apart from the wait of the
; second MFCR, so the difference with an empty block is the number of
; instructions the block executed plus its penalty.
; On failure: r1 = cycles, r2 = instructions, r3 = expected penalty,
; r4 = measured penalty.

	.include "../common/harness.asm"

DATA            = 0x1000

test_main:
	li r10, DATA
	sw r0, 0(r10)
	li r1, DATA + 12
	sw r1, 8(r10)               ; a pointer
	la r1, .t24
	sw r1, 16(r10)              ; a jump target

	; the empty block: 4 NOPs, and MFCR waits 2 cycles for them to drain
	li r28, 0
	mfcr r11, cycle
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	sub r20, r12, r11
	li r3, 7
	mv r4, r20
	bne r4, r3, fail

	; one NOP
	li r28, 1
	mfcr r11, cycle
	nop
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 1
	li r3, 0
	call penalty

	; eight NOPs: one instruction per cycle
	li r28, 2
	mfcr r11, cycle
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 8
	li r3, 0
	call penalty

	; MUL and DIV take one cycle
	li r28, 3
	li r5, 1000
	li r6, 7
	mfcr r11, cycle
	mul r1, r5, r6
	div r2, r5, r6
	remu r3, r5, r6
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 3
	li r3, 0
	call penalty

	; load-use: 1 stall
	li r28, 10
	mfcr r11, cycle
	lw r1, 0(r10)
	addi r2, r1, 1
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 1
	call penalty

	; load, then its value two instructions later: no stall
	li r28, 11
	mfcr r11, cycle
	lw r1, 0(r10)
	nop
	addi r2, r1, 1
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 3
	li r3, 0
	call penalty

	; load -> store data: 1 stall
	li r28, 12
	mfcr r11, cycle
	lw r1, 0(r10)
	sw r1, 4(r10)
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 1
	call penalty

	; load -> store base: 1 stall
	li r28, 13
	mfcr r11, cycle
	lw r1, 8(r10)
	sw r0, 0(r1)
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 1
	call penalty

	; load -> branch, not taken: 1 stall
	li r28, 14
	mfcr r11, cycle
	lw r1, 0(r10)
	bne r1, r1, fail
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 1
	call penalty

	; load of r0 -> use of r0: no stall
	li r28, 15
	mfcr r11, cycle
	lw r0, 0(r10)
	addi r2, r0, 1
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 0
	call penalty

	; store, then a load of the same word: no stall
	li r28, 16
	mfcr r11, cycle
	sw r10, 12(r10)
	lw r1, 12(r10)
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 0
	call penalty

	; branch not taken: no penalty
	li r28, 20
	mfcr r11, cycle
	bne r0, r0, fail
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 1
	li r3, 0
	call penalty

	; branch taken: 2 cycles
	li r28, 21
	mfcr r11, cycle
	beq r0, r0, .t21
	nop
	nop
.t21:
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 1
	li r3, 2
	call penalty

	; JAL: 2 cycles
	li r28, 22
	mfcr r11, cycle
	j .t22
	nop
	nop
.t22:
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 1
	li r3, 2
	call penalty

	; JALR: 2 cycles
	li r28, 23
	la r5, .t23
	mfcr r11, cycle
	jr r5
	nop
	nop
.t23:
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 1
	li r3, 2
	call penalty

	; load -> JALR: 1 stall and 2 cycles
	li r28, 24
	mfcr r11, cycle
	lw r1, 16(r10)
	jr r1
	nop
	nop
.t24:
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 3
	call penalty

	; load -> taken branch: 1 stall and 2 cycles
	li r28, 25
	mfcr r11, cycle
	lw r1, 0(r10)
	beq r1, r1, .t25
	nop
.t25:
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 3
	call penalty

	; MTCR waits for EX and MEM to drain: 2 cycles
	li r28, 30
	mfcr r11, cycle
	nop
	mtcr scratch, r0
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 2
	call penalty

	; MFCR too
	li r28, 31
	mfcr r11, cycle
	nop
	mfcr r1, scratch
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 2
	call penalty

	; MTCR STATUS: 2 cycles, and it refetches when it retires: 4 more
	li r28, 32
	mfcr r11, cycle
	nop
	mtcr status, r0
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 6
	call penalty

	; MTCR PTBR: the same
	li r28, 33
	mfcr r11, cycle
	nop
	mtcr ptbr, r0
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 6
	call penalty

	; TLBI refetches (4 cycles) but doesn't wait
	li r28, 34
	mfcr r11, cycle
	nop
	tlbi r0
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 4
	call penalty

	; IRET: 2 cycles of waiting, and it jumps when it retires: 4 more
	li r28, 35
	la r5, .t35
	mtcr epc, r5
	mfcr r11, cycle
	nop
	iret
.t35:
	nop
	nop
	nop
	nop
	mfcr r12, cycle
	li r2, 2
	li r3, 6
	call penalty

	j pass

; penalty(r11, r12 = CYCLE before and after, r2 = instructions executed,
; r3 = expected penalty): r20 = cycles of the empty block
penalty:
	sub r1, r12, r11
	sub r4, r1, r20
	sub r4, r4, r2
	bne r4, r3, fail
	ret
