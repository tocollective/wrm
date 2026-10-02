; ============================================================================
;  Random number generator: bits from the host, new ones on every read;
;  read-only registers
; ============================================================================

	.include "../common/harness.asm"

READS           = 64

test_main:
	li r10, RNG

	; ---- not seeded
	li r28, 1
	lw r4, RNG_STATUS(r10)
	bnez r4, fail

	; ---- 64 reads: not all the same, and some bits set. Random bits fail
	;      this once in 2^2000 runs.
	li r28, 2
	lw r12, RNG_DATA(r10)       ; the first word
	li r13, 0                   ; OR of all of them
	li r14, 0                   ; reads that differ from the first
	li r9, READS
.next:
	lw r4, RNG_DATA(r10)
	or r13, r13, r4
	beq r4, r12, .same
	addi r14, r14, 1
.same:
	addi r9, r9, -1
	bnez r9, .next
	mv r4, r14
	beqz r14, fail
	li r28, 3
	mv r4, r13
	beqz r13, fail

	; ---- writes are ignored
	li r28, 4
	li r1, 0x12345678
	sw r1, RNG_STATUS(r10)
	lw r4, RNG_STATUS(r10)
	bnez r4, fail
	sw r1, RNG_DATA(r10)
	lw r4, RNG_DATA(r10)
	beq r4, r1, fail            ; once in 2^32 runs

	; ---- a narrow read gets the low bits and uses up a word
	li r28, 5
	lbu r4, RNG_DATA(r10)
	li r3, 0xFF
	bgtu r4, r3, fail

	j pass
