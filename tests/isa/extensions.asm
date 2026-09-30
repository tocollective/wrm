; Multiplication high halves, atomic words, FENCE and BREAK.

	.include "../common/harness.asm"

DATA = 0x1800

test_main:
	la r1, trap_record
	mtcr ivec, r1
	mtcr status, r0             ; clear reset EXL

	li r28, 1
	li r1, -1
	li r2, 2
	mulh r3, r1, r2
	li r4, -1
	bne r3, r4, fail
	li r28, 2
	mulhu r3, r1, r2
	li r4, 1
	bne r3, r4, fail
	li r28, 3
	mulhsu r3, r1, r2
	li r4, -1
	bne r3, r4, fail
	li r28, 4
	li r2, 0x80000000
	mulhsu r3, r1, r2
	bne r3, r4, fail

	li r10, DATA
	li r1, 10
	sw r1, 0(r10)
	li r28, 5
	ll r2, (r10)
	li r3, 20
	sc r4, r3, (r10)
	bnez r4, fail
	li r5, 10
	bne r2, r5, fail
	lw r5, 0(r10)
	bne r5, r3, fail

	li r28, 6
	sc r4, r1, (r10)            ; reservation consumed
	li r5, 1
	bne r4, r5, fail
	lw r5, 0(r10)
	bne r5, r3, fail

	li r28, 7
	ll r2, (r10)
	sb r1, 1(r10)              ; overlapping byte invalidates it
	sc r4, r3, (r10)
	li r5, 1
	bne r4, r5, fail

	li r28, 8
	li r1, 30
	; Swap with the selected LL/SC primitive.
.swap:
	ll r2, (r10)
	sc r4, r1, (r10)
	bnez r4, .swap
	li r3, 0x0A14              ; byte store above made 0x00000A14
	bne r2, r3, fail
	lw r3, 0(r10)
	bne r3, r1, fail

	li r28, 9
	li r1, 12
	; Fetch-add is also a short LL/SC loop.
.add:
	ll r2, (r10)
	add r3, r2, r1
	sc r4, r3, (r10)
	bnez r4, .add
	li r3, 30
	bne r2, r3, fail
	li r3, 42
	lw r4, 0(r10)
	bne r4, r3, fail
	fence

	li r28, 10
	li r24, 0
.break:
	break
	li r1, CAUSE_BREAK
	la r2, .break
	li r3, 0
	call check_trap
	j pass

check_trap:
	bne r20, r1, fail
	bne r21, r2, fail
	bne r22, r3, fail
	li r1, 1
	bne r24, r1, fail
	ret
