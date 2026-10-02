; ============================================================================
;  Floating-point environment: FCSR's exception flags and rounding modes,
;  HARTID
; ============================================================================
; Each row of the table runs one instruction with FCSR set to a rounding
; mode and no flags: (routine, rs1, rs2, rd, FCSR before, expected rd,
; expected FCSR after). Check 100 + row fails with r1 = the row's address,
; r2 = FCSR after, r3 = the expected value, r4 = the result. The other
; checks are numbered from 1 up.

	.include "../common/harness.asm"

test_main:
	; ---- after reset: rounding to nearest, no flags
	li r28, 1
	mfcr r4, fcsr
	bnez r4, fail

	li r28, 100
	la r10, table
	la r11, table_end
.row:
	addi r28, r28, 1
	lw r12, 0(r10)
	lw r1, 4(r10)
	lw r2, 8(r10)
	lw r4, 12(r10)
	lw r5, 16(r10)
	mtcr fcsr, r5
	jalr ra, r12
	mfcr r2, fcsr
	lw r3, 20(r10)
	bne r4, r3, .wrong
	lw r3, 24(r10)
	mv r4, r2
	bne r4, r3, .wrong
	addi r10, r10, 28
	bltu r10, r11, .row
	j .table_done
.wrong:
	mv r1, r10
	j fail
.table_done:

	; ---- the flags are sticky: they add up until software clears them
	li r28, 2
	mtcr fcsr, r0
	fli r1, 1.0
	li r2, 0x33800000           ; 2^-24
	fdiv r4, r1, r0             ; DZ
	fadd r4, r1, r2             ; NX
	fadd r4, r1, r1             ; exact: nothing
	mfcr r4, fcsr
	li r3, FCSR_DZ | FCSR_NX
	bne r4, r3, fail
	li r28, 3
	mtcr fcsr, r0
	mfcr r4, fcsr
	bnez r4, fail

	; ---- MTCR writes the flags; other bits read as zero, a reserved FRM
	; isn't taken
	li r28, 4
	li r1, -1                   ; FRM = 7: reserved
	mtcr fcsr, r1
	mfcr r4, fcsr
	li r3, 0x1F
	bne r4, r3, fail
	li r28, 5
	li r1, FRM_RUP << FCSR_FRM_SHIFT
	mtcr fcsr, r1
	li r1, 5 << FCSR_FRM_SHIFT | FCSR_NV
	mtcr fcsr, r1
	mfcr r4, fcsr
	li r3, FRM_RUP << FCSR_FRM_SHIFT | FCSR_NV
	bne r4, r3, fail

	; ---- the instruction right after MTCR FCSR rounds in the new mode
	li r28, 6
	fli r1, 1.0
	li r2, 0x33800000           ; 2^-24: a tie
	li r5, FRM_RUP << FCSR_FRM_SHIFT
	mtcr fcsr, r5
	fadd r4, r1, r2             ; was in EX when the MTCR retired
	li r3, 0x3F800001
	bne r4, r3, fail
	li r28, 7
	mtcr fcsr, r0
	fadd r4, r1, r2
	li r3, 0x3F800000
	bne r4, r3, fail

	; ---- an instruction that doesn't retire sets no flags: the FDIV is
	; in EX when the load before it faults
	li r28, 8
	la r1, trap_record
	mtcr ivec, r1
	mtcr status, r0             ; clear reset EXL
	li r24, 0
	la r25, .resumed
	fli r1, 1.0
	mtcr fcsr, r0
	lw r9, 1(r0)                ; misaligned
	fdiv r4, r1, r0
	j fail
.resumed:
	li r28, 9
	li r3, 1
	bne r24, r3, fail
	mfcr r4, fcsr
	bnez r4, fail

	; ---- user mode reads and writes FCSR
	li r28, 10
	la r1, user_trap
	mtcr ivec, r1
	la r1, user_code
	mtcr epc, r1
	li r1, STATUS_PUM
	mtcr status, r1
	li r5, FRM_RTZ << FCSR_FRM_SHIFT | FCSR_OF
	li r6, 0
	iret
user_code:
	mtcr fcsr, r5
	mfcr r6, fcsr
	syscall
user_trap:                      ; supervisor, EXL set
	mfcr r1, cause
	li r3, CAUSE_SYSCALL
	mv r4, r1
	bne r4, r3, fail
	mtcr status, r0
	li r28, 11
	mv r4, r6
	bne r4, r5, fail
	li r28, 12
	mfcr r4, fcsr
	bne r4, r5, fail
	mtcr fcsr, r0

	; ---- HARTID: the only core is 0, and it is read-only
	li r28, 13
	mfcr r4, hartid
	bnez r4, fail
	li r28, 14
	la r1, trap_record
	mtcr ivec, r1
	mtcr status, r0
	li r24, 0
	li r25, 0
.mtcr_hartid:
	.dw 0x00400005              ; mtcr hartid, r0
	li r3, 1
	bne r24, r3, fail
	mv r4, r20                  ; CAUSE: illegal instruction
	bne r4, r3, fail
	la r3, .mtcr_hartid
	mv r4, r21
	bne r4, r3, fail

	j pass

; op_<name>(r1, r2, r4) -> r4
op_fadd:
	fadd r4, r1, r2
	ret
op_fsub:
	fsub r4, r1, r2
	ret
op_fmul:
	fmul r4, r1, r2
	ret
op_fdiv:
	fdiv r4, r1, r2
	ret
op_fsqrt:
	fsqrt r4, r1
	ret
op_fmadd:
	fmadd r4, r1, r2
	ret
op_fmsub:
	fmsub r4, r1, r2
	ret
op_fmin:
	fmin r4, r1, r2
	ret
op_fmax:
	fmax r4, r1, r2
	ret
op_feq:
	feq r4, r1, r2
	ret
op_flt:
	flt r4, r1, r2
	ret
op_fle:
	fle r4, r1, r2
	ret
op_fclass:
	fclass r4, r1
	ret
op_fsgnj:
	fsgnj r4, r1, r2
	ret
op_ftoi:
	ftoi r4, r1
	ret
op_ftou:
	ftou r4, r1
	ret
op_itof:
	itof r4, r1
	ret
op_utof:
	utof r4, r1
	ret

; routine, rs1, rs2, rd, FCSR before, expected rd, expected FCSR
; FCSR: NX = 0x01, UF = 0x02, OF = 0x04, DZ = 0x08, NV = 0x10, FRM << 5
table:
	.dw op_fadd, 0x3F800000, 0x33800000, 0x00000000, 0x00, 0x3F800000, 0x01  ; fadd RNE: 1 + 2^-24: a tie
	.dw op_fadd, 0x3F800000, 0x33800000, 0x00000000, 0x20, 0x3F800000, 0x21  ; fadd RTZ: 1 + 2^-24: a tie
	.dw op_fadd, 0x3F800000, 0x33800000, 0x00000000, 0x40, 0x3F800000, 0x41  ; fadd RDN: 1 + 2^-24: a tie
	.dw op_fadd, 0x3F800000, 0x33800000, 0x00000000, 0x60, 0x3F800001, 0x61  ; fadd RUP: 1 + 2^-24: a tie
	.dw op_fadd, 0x3F800000, 0x33800000, 0x00000000, 0x80, 0x3F800001, 0x81  ; fadd RMM: 1 + 2^-24: a tie
	.dw op_fadd, 0xBF800000, 0xB3800000, 0x00000000, 0x00, 0xBF800000, 0x01  ; fadd RNE: -1 - 2^-24
	.dw op_fadd, 0xBF800000, 0xB3800000, 0x00000000, 0x20, 0xBF800000, 0x21  ; fadd RTZ: -1 - 2^-24
	.dw op_fadd, 0xBF800000, 0xB3800000, 0x00000000, 0x40, 0xBF800001, 0x41  ; fadd RDN: -1 - 2^-24
	.dw op_fadd, 0xBF800000, 0xB3800000, 0x00000000, 0x60, 0xBF800000, 0x61  ; fadd RUP: -1 - 2^-24
	.dw op_fadd, 0xBF800000, 0xB3800000, 0x00000000, 0x80, 0xBF800001, 0x81  ; fadd RMM: -1 - 2^-24
	.dw op_fadd, 0x3F800000, 0xBF800000, 0x00000000, 0x00, 0x00000000, 0x00  ; fadd RNE: exact cancellation: +0
	.dw op_fadd, 0x3F800000, 0xBF800000, 0x00000000, 0x40, 0x80000000, 0x40  ; fadd RDN: ... -0 rounding down
	.dw op_fsub, 0x3F800000, 0x3F800000, 0x00000000, 0x40, 0x80000000, 0x40  ; fsub RDN
	.dw op_fadd, 0x3F800000, 0x40000000, 0x00000000, 0x00, 0x40400000, 0x00  ; fadd RNE: exact: no flags
	.dw op_fadd, 0x7F7FFFFF, 0x7F7FFFFF, 0x00000000, 0x00, 0x7F800000, 0x05  ; fadd RNE: overflow
	.dw op_fadd, 0x7F7FFFFF, 0x7F7FFFFF, 0x00000000, 0x20, 0x7F7FFFFF, 0x25  ; fadd RTZ: overflow
	.dw op_fadd, 0x7F7FFFFF, 0x7F7FFFFF, 0x00000000, 0x40, 0x7F7FFFFF, 0x45  ; fadd RDN: overflow
	.dw op_fadd, 0x7F7FFFFF, 0x7F7FFFFF, 0x00000000, 0x60, 0x7F800000, 0x65  ; fadd RUP: overflow
	.dw op_fadd, 0x7F7FFFFF, 0x7F7FFFFF, 0x00000000, 0x80, 0x7F800000, 0x85  ; fadd RMM: overflow
	.dw op_fadd, 0xFF7FFFFF, 0xFF7FFFFF, 0x00000000, 0x40, 0xFF800000, 0x45  ; fadd RDN: negative overflow
	.dw op_fadd, 0xFF7FFFFF, 0xFF7FFFFF, 0x00000000, 0x60, 0xFF7FFFFF, 0x65  ; fadd RUP: negative overflow
	.dw op_fadd, 0x7F800000, 0xFF800000, 0x00000000, 0x00, 0x7FC00000, 0x10  ; fadd RNE: inf - inf
	.dw op_fadd, 0x7F800001, 0x3F800000, 0x00000000, 0x00, 0x7FC00000, 0x10  ; fadd RNE: signaling NaN
	.dw op_fadd, 0x7FC00000, 0x3F800000, 0x00000000, 0x00, 0x7FC00000, 0x00  ; fadd RNE: quiet NaN: no flags
	.dw op_fmul, 0x00000000, 0x7F800000, 0x00000000, 0x00, 0x7FC00000, 0x10  ; fmul RNE: 0 * inf
	.dw op_fmul, 0x00800000, 0x3F000000, 0x00000000, 0x00, 0x00400000, 0x00  ; fmul RNE: exact subnormal: no UF
	.dw op_fmul, 0x00800000, 0x3F7FFFFF, 0x00000000, 0x00, 0x00800000, 0x03  ; fmul RNE: rounds up to the smallest normal: UF (tiny before rounding)
	.dw op_fmul, 0x00000001, 0x3F000000, 0x00000000, 0x00, 0x00000000, 0x03  ; fmul RNE: 2^-150
	.dw op_fmul, 0x00000001, 0x3F000000, 0x00000000, 0x60, 0x00000001, 0x63  ; fmul RUP: 2^-150
	.dw op_fmul, 0x00000001, 0x3F000000, 0x00000000, 0x80, 0x00000001, 0x83  ; fmul RMM: 2^-150
	.dw op_fmul, 0x00000001, 0x3F000000, 0x00000000, 0x40, 0x00000000, 0x43  ; fmul RDN: 2^-150
	.dw op_fdiv, 0x3F800000, 0x00000000, 0x00000000, 0x00, 0x7F800000, 0x08  ; fdiv RNE: 1 / 0
	.dw op_fdiv, 0xBF800000, 0x00000000, 0x00000000, 0x00, 0xFF800000, 0x08  ; fdiv RNE: -1 / 0
	.dw op_fdiv, 0x00000000, 0x00000000, 0x00000000, 0x00, 0x7FC00000, 0x10  ; fdiv RNE: 0 / 0
	.dw op_fdiv, 0x7F800000, 0x7F800000, 0x00000000, 0x00, 0x7FC00000, 0x10  ; fdiv RNE: inf / inf
	.dw op_fdiv, 0x7F800000, 0x00000000, 0x00000000, 0x00, 0x7F800000, 0x00  ; fdiv RNE: inf / 0: no DZ
	.dw op_fdiv, 0x3F800000, 0x40400000, 0x00000000, 0x00, 0x3EAAAAAB, 0x01  ; fdiv RNE: 1 / 3
	.dw op_fdiv, 0x3F800000, 0x40400000, 0x00000000, 0x20, 0x3EAAAAAA, 0x21  ; fdiv RTZ: 1 / 3
	.dw op_fdiv, 0x3F800000, 0x40400000, 0x00000000, 0x40, 0x3EAAAAAA, 0x41  ; fdiv RDN: 1 / 3
	.dw op_fdiv, 0x3F800000, 0x40400000, 0x00000000, 0x60, 0x3EAAAAAB, 0x61  ; fdiv RUP: 1 / 3
	.dw op_fdiv, 0x3F800000, 0x40400000, 0x00000000, 0x80, 0x3EAAAAAB, 0x81  ; fdiv RMM: 1 / 3
	.dw op_fsqrt, 0x40000000, 0x00000000, 0x00000000, 0x00, 0x3FB504F3, 0x01  ; fsqrt RNE: sqrt 2
	.dw op_fsqrt, 0x40000000, 0x00000000, 0x00000000, 0x20, 0x3FB504F3, 0x21  ; fsqrt RTZ: sqrt 2
	.dw op_fsqrt, 0x40000000, 0x00000000, 0x00000000, 0x40, 0x3FB504F3, 0x41  ; fsqrt RDN: sqrt 2
	.dw op_fsqrt, 0x40000000, 0x00000000, 0x00000000, 0x60, 0x3FB504F4, 0x61  ; fsqrt RUP: sqrt 2
	.dw op_fsqrt, 0x40000000, 0x00000000, 0x00000000, 0x80, 0x3FB504F3, 0x81  ; fsqrt RMM: sqrt 2
	.dw op_fsqrt, 0xBF800000, 0x00000000, 0x00000000, 0x00, 0x7FC00000, 0x10  ; fsqrt RNE: sqrt -1
	.dw op_fsqrt, 0x80000000, 0x00000000, 0x00000000, 0x00, 0x80000000, 0x00  ; fsqrt RNE: sqrt -0 = -0
	.dw op_fsqrt, 0x40800000, 0x00000000, 0x00000000, 0x00, 0x40000000, 0x00  ; fsqrt RNE: sqrt 4 exact
	.dw op_fmadd, 0x3F800001, 0x3F7FFFFE, 0xBF800000, 0x00, 0xA8800000, 0x00  ; fmadd RNE: single rounding
	.dw op_fmadd, 0x7F800000, 0x00000000, 0x7FC00000, 0x00, 0x7FC00000, 0x10  ; fmadd RNE: inf * 0 + qNaN
	.dw op_fmadd, 0x7F800000, 0x3F800000, 0xFF800000, 0x00, 0x7FC00000, 0x10  ; fmadd RNE: inf - inf
	.dw op_fmsub, 0x3F800000, 0x3F800000, 0x3F800000, 0x40, 0x80000000, 0x40  ; fmsub RDN: 1 - 1: -0 rounding down
	.dw op_ftoi, 0x3FC00000, 0x00000000, 0x00000000, 0x00, 0x00000001, 0x01  ; ftoi RNE: 1.5
	.dw op_ftoi, 0xBFC00000, 0x00000000, 0x00000000, 0x00, 0xFFFFFFFF, 0x01  ; ftoi RNE: -1.5
	.dw op_ftoi, 0x4F000000, 0x00000000, 0x00000000, 0x00, 0x7FFFFFFF, 0x10  ; ftoi RNE: 2^31
	.dw op_ftoi, 0xCF000000, 0x00000000, 0x00000000, 0x00, 0x80000000, 0x00  ; ftoi RNE: -2^31 fits
	.dw op_ftoi, 0x7FC00000, 0x00000000, 0x00000000, 0x00, 0x7FFFFFFF, 0x10  ; ftoi RNE: NaN
	.dw op_ftoi, 0xFF800000, 0x00000000, 0x00000000, 0x00, 0x80000000, 0x10  ; ftoi RNE: -inf
	.dw op_ftou, 0xBF000000, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x01  ; ftou RNE: -0.5
	.dw op_ftou, 0xBF800000, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x10  ; ftou RNE: -1
	.dw op_ftou, 0x4F800000, 0x00000000, 0x00000000, 0x00, 0xFFFFFFFF, 0x10  ; ftou RNE: 2^32
	.dw op_ftou, 0x3F800000, 0x00000000, 0x00000000, 0x00, 0x00000001, 0x00  ; ftou RNE: 1 exact
	.dw op_itof, 0x01000001, 0x00000000, 0x00000000, 0x00, 0x4B800000, 0x01  ; itof RNE: 2^24 + 1
	.dw op_itof, 0x01000001, 0x00000000, 0x00000000, 0x60, 0x4B800001, 0x61  ; itof RUP: 2^24 + 1
	.dw op_itof, 0x01000001, 0x00000000, 0x00000000, 0x20, 0x4B800000, 0x21  ; itof RTZ: 2^24 + 1
	.dw op_itof, 0xFEFFFFFF, 0x00000000, 0x00000000, 0x40, 0xCB800001, 0x41  ; itof RDN: -(2^24 + 1)
	.dw op_itof, 0x80000000, 0x00000000, 0x00000000, 0x00, 0xCF000000, 0x00  ; itof RNE: INT_MIN exact
	.dw op_utof, 0xFFFFFFFF, 0x00000000, 0x00000000, 0x00, 0x4F800000, 0x01  ; utof RNE: UINT_MAX
	.dw op_utof, 0xFFFFFFFF, 0x00000000, 0x00000000, 0x20, 0x4F7FFFFF, 0x21  ; utof RTZ: UINT_MAX
	.dw op_feq, 0x7F800001, 0x3F800000, 0x00000000, 0x00, 0x00000000, 0x10  ; feq RNE: signaling NaN
	.dw op_feq, 0x7FC00000, 0x3F800000, 0x00000000, 0x00, 0x00000000, 0x00  ; feq RNE: quiet NaN: quiet
	.dw op_flt, 0x7FC00000, 0x3F800000, 0x00000000, 0x00, 0x00000000, 0x10  ; flt RNE: any NaN
	.dw op_fle, 0x3F800000, 0x3F800000, 0x00000000, 0x00, 0x00000001, 0x00  ; fle RNE
	.dw op_fle, 0x80000000, 0x00000000, 0x00000000, 0x00, 0x00000001, 0x00  ; fle RNE: -0 <= +0
	.dw op_flt, 0x80000000, 0x00000000, 0x00000000, 0x00, 0x00000000, 0x00  ; flt RNE: -0 < +0 is false
	.dw op_fmin, 0x7F800001, 0x3F800000, 0x00000000, 0x00, 0x3F800000, 0x10  ; fmin RNE: signaling NaN
	.dw op_fmax, 0x7FC00000, 0x3F800000, 0x00000000, 0x00, 0x3F800000, 0x00  ; fmax RNE
	.dw op_fclass, 0x7F800001, 0x00000000, 0x00000000, 0x00, 0x00000100, 0x00  ; fclass RNE: no flags
	.dw op_fsgnj, 0x7F800001, 0x80000000, 0x00000000, 0x00, 0xFF800001, 0x00  ; fsgnj RNE: no flags, NaN kept
table_end:
