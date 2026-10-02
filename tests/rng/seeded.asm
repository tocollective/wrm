; ============================================================================
;  Random number generator with a seed: the ChaCha20 stream of the seed,
;  the same on every run
; ============================================================================
; @args --seed=0
; With a zero key the stream is that of the ChaCha20 test vectors: block 0
; starts with the bytes 76 b8 e0 ad a0 f1 3d 90, block 1 with 9f 07 e7 be.

	.include "../common/harness.asm"

test_main:
	li r10, RNG

	li r28, 1
	lw r4, RNG_STATUS(r10)
	li r3, RNG_SEEDED
	bne r4, r3, fail

	li r28, 2                   ; block 0, words 0 and 1
	lw r4, RNG_DATA(r10)
	li r3, 0xADE0B876
	bne r4, r3, fail
	li r28, 3
	lw r4, RNG_DATA(r10)
	li r3, 0x903DF1A0
	bne r4, r3, fail

	li r28, 4                   ; words 2 to 15
	li r9, 14
.skip:
	lw r4, RNG_DATA(r10)
	addi r9, r9, -1
	bnez r9, .skip
	lw r4, RNG_DATA(r10)        ; block 1, word 0
	li r3, 0xBEE7079F
	bne r4, r3, fail

	j pass
