; ============================================================================
;  Floating point: arithmetic, rounding, NaN, comparisons, conversions,
;  FCLASS, forwarding and reserved bits
; ============================================================================
; The instructions run over tables of (rs1, rs2, rd, expected rd), one
; table per instruction: rd is the third source of FMADD/FMSUB, the others
; ignore it. Check N*100 + row fails for the Nth instruction, with r1 = rs1,
; r2 = rs2, r3 = expected, r4 = result. The other checks are numbered from
; 2100 up.

	.include "../common/harness.asm"

DATA = 0x1000

test_main:
	li r28, 100
	la r10, t_fadd
	la r11, t_fadd_end
	la r12, op_fadd
	call check_table

	li r28, 200
	la r10, t_fsub
	la r11, t_fsub_end
	la r12, op_fsub
	call check_table

	li r28, 300
	la r10, t_fmul
	la r11, t_fmul_end
	la r12, op_fmul
	call check_table

	li r28, 400
	la r10, t_fdiv
	la r11, t_fdiv_end
	la r12, op_fdiv
	call check_table

	li r28, 500
	la r10, t_fsqrt
	la r11, t_fsqrt_end
	la r12, op_fsqrt
	call check_table

	li r28, 600
	la r10, t_fmin
	la r11, t_fmin_end
	la r12, op_fmin
	call check_table

	li r28, 700
	la r10, t_fmax
	la r11, t_fmax_end
	la r12, op_fmax
	call check_table

	li r28, 800
	la r10, t_fmadd
	la r11, t_fmadd_end
	la r12, op_fmadd
	call check_table

	li r28, 900
	la r10, t_fmsub
	la r11, t_fmsub_end
	la r12, op_fmsub
	call check_table

	li r28, 1000
	la r10, t_fsgnj
	la r11, t_fsgnj_end
	la r12, op_fsgnj
	call check_table

	li r28, 1100
	la r10, t_fsgnjn
	la r11, t_fsgnjn_end
	la r12, op_fsgnjn
	call check_table

	li r28, 1200
	la r10, t_fsgnjx
	la r11, t_fsgnjx_end
	la r12, op_fsgnjx
	call check_table

	li r28, 1300
	la r10, t_feq
	la r11, t_feq_end
	la r12, op_feq
	call check_table

	li r28, 1400
	la r10, t_flt
	la r11, t_flt_end
	la r12, op_flt
	call check_table

	li r28, 1500
	la r10, t_fle
	la r11, t_fle_end
	la r12, op_fle
	call check_table

	li r28, 1600
	la r10, t_fclass
	la r11, t_fclass_end
	la r12, op_fclass
	call check_table

	li r28, 1700
	la r10, t_ftoi
	la r11, t_ftoi_end
	la r12, op_ftoi
	call check_table

	li r28, 1800
	la r10, t_ftou
	la r11, t_ftou_end
	la r12, op_ftou
	call check_table

	li r28, 1900
	la r10, t_itof
	la r11, t_itof_end
	la r12, op_itof
	call check_table

	li r28, 2000
	la r10, t_utof
	la r11, t_utof_end
	la r12, op_utof
	call check_table

	; ---- forwarding: back-to-back results, FMADD's rd from EX/MEM, MEM/WB
	; and a load (which stalls)
	li r28, 2100
	fli r1, 2.0
	fli r2, 3.0
	fadd r4, r1, r2             ; 5
	fmul r4, r4, r4             ; 25, rs1 and rs2 from EX/MEM
	fli r3, 25.0
	bne r4, r3, fail
	li r28, 2101
	fadd r4, r1, r2             ; 5
	fmadd r4, r1, r2            ; 5 + 6, rd from EX/MEM
	fli r3, 11.0
	bne r4, r3, fail
	li r28, 2102
	fadd r4, r1, r2             ; 5
	nop
	fmsub r4, r1, r2            ; 5 - 6, rd from MEM/WB
	fli r3, -1.0
	bne r4, r3, fail
	li r28, 2103
	li r10, DATA
	fli r5, 0.5
	sw r5, 0(r10)
	lw r4, 0(r10)
	fmadd r4, r1, r2            ; 0.5 + 6, rd from a load
	fli r3, 6.5
	bne r4, r3, fail
	li r28, 2104
	lw r4, 0(r10)
	ftoi r4, r4                 ; rs1 from a load
	bnez r4, fail
	li r28, 2105
	itof r4, r1                 ; 0x40000000 as an integer
	ftoi r4, r4
	li r3, 0x40000000
	bne r4, r3, fail

	; ---- rd = r0 stays zero, rs = r0 is +0
	li r28, 2106
	fadd r0, r1, r2
	bnez r0, fail
	li r28, 2107
	fadd r4, r0, r0
	bnez r4, fail
	li r28, 2108
	fclass r4, r0
	li r3, 0x10
	bne r4, r3, fail

	; ---- assembler: .float and fli agree
	li r28, 2109
	la r10, pi
	lw r4, 0(r10)
	fli r3, 3.14159265
	bne r4, r3, fail
	li r3, 0x40490FDB
	bne r4, r3, fail

	; ---- reserved bits: rs2 of a one-source instruction
	li r28, 2110
	la r1, trap_record
	mtcr ivec, r1
	mtcr status, r0             ; clear reset EXL
	li r24, 0
	li r25, 0
.fsqrt_rs2:
	.dw 0x00042274              ; fsqrt r2, r1, rs2 = r1
	li r1, 1
	bne r24, r1, fail
	bne r20, r1, fail           ; CAUSE: illegal instruction
	la r1, .fsqrt_rs2
	bne r21, r1, fail
	li r1, 0x00042274
	bne r22, r1, fail

	j pass

; Runs the rows from r10 to r11 through the routine at r12 (r12 must not be
; ra); r28 counts rows.
check_table:
	addi r30, r30, -4
	sw ra, 0(r30)
.row:
	addi r28, r28, 1
	lw r1, 0(r10)
	lw r2, 4(r10)
	lw r4, 8(r10)
	lw r3, 12(r10)
	jalr ra, r12
	bne r4, r3, fail
	addi r10, r10, 16
	bltu r10, r11, .row
	lw ra, 0(r30)
	addi r30, r30, 4
	ret

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
op_fmin:
	fmin r4, r1, r2
	ret
op_fmax:
	fmax r4, r1, r2
	ret
op_fmadd:
	fmadd r4, r1, r2
	ret
op_fmsub:
	fmsub r4, r1, r2
	ret
op_fsgnj:
	fsgnj r4, r1, r2
	ret
op_fsgnjn:
	fsgnjn r4, r1, r2
	ret
op_fsgnjx:
	fsgnjx r4, r1, r2
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

	.align 4
pi:	.float 3.14159265

; Bit patterns used below:
;   7F800000 +inf             FF800000 -inf
;   7FC00000 canonical NaN    7FC12345 quiet NaN with a payload
;   7F800001 signaling NaN    7F7FFFFF largest normal
;   00800000 smallest normal  00000001 smallest subnormal
;   80000000 -0
; Every row is rs1, rs2, rd, expected.

t_fadd:
	.float 1.0, 2.0, 0, 3.0
	.float 0.1, 0.2, 0, 0.3000000119
	.float -1.5, 1.5, 0, 0
	.dw 0x80000000, 0x80000000, 0, 0x80000000  ; -0 + -0 = -0
	.dw 0x00000000, 0x80000000, 0, 0x00000000  ; +0 + -0 = +0
	.dw 0x7F800000, 0xFF800000, 0, 0x7FC00000  ; inf - inf = NaN
	.dw 0x3F800000, 0x7FC12345, 0, 0x7FC00000  ; payload dropped
	.dw 0xFFC12345, 0x3F800000, 0, 0x7FC00000  ; sign dropped
	.dw 0x7F800001, 0x3F800000, 0, 0x7FC00000  ; signaling NaN
	.dw 0x7F7FFFFF, 0x7F7FFFFF, 0, 0x7F800000  ; overflow
	.dw 0x00000001, 0x00000001, 0, 0x00000002  ; subnormals
	.dw 0x3F800000, 0x33800000, 0, 0x3F800000  ; 1 + 2^-24: tie to even
	.dw 0x3F800000, 0x33800001, 0, 0x3F800001  ; just above the tie
	.dw 0x3F800001, 0x33800000, 0, 0x3F800002  ; tie, rounded up to even
t_fadd_end:

t_fsub:
	.float 3.0, 1.0, 0, 2.0
	.dw 0x3F800000, 0x3F800000, 0, 0x00000000  ; 1 - 1 = +0
	.dw 0x80000000, 0x00000000, 0, 0x80000000  ; -0 - +0 = -0
	.dw 0x7F800000, 0x7F800000, 0, 0x7FC00000  ; inf - inf = NaN
	.dw 0x00800000, 0x00000001, 0, 0x007FFFFF  ; down to a subnormal
t_fsub_end:

t_fmul:
	.float 1.5, -2.0, 0, -3.0
	.float 0.1, 10.0, 0, 1.0
	.dw 0x00000000, 0x7F800000, 0, 0x7FC00000  ; 0 * inf = NaN
	.dw 0x80000000, 0x40A00000, 0, 0x80000000  ; -0 * 5 = -0
	.dw 0x7F7FFFFF, 0x40000000, 0, 0x7F800000  ; overflow
	.dw 0x00800000, 0x3F000000, 0, 0x00400000  ; 2^-126 * 0.5 subnormal
	.dw 0x00000001, 0x3F000000, 0, 0x00000000  ; underflow, tie to even
	.dw 0x00000003, 0x3F000000, 0, 0x00000002  ; 1.5 ulp, tie to even
t_fmul_end:

t_fdiv:
	.float 1.0, 3.0, 0, 0.3333333433
	.float -6.0, 2.0, 0, -3.0
	.dw 0x3F800000, 0x00000000, 0, 0x7F800000  ; 1 / 0 = inf
	.dw 0xBF800000, 0x00000000, 0, 0xFF800000  ; -1 / 0 = -inf
	.dw 0x3F800000, 0x80000000, 0, 0xFF800000  ; 1 / -0 = -inf
	.dw 0x00000000, 0x00000000, 0, 0x7FC00000  ; 0 / 0 = NaN
	.dw 0x7F800000, 0x7F800000, 0, 0x7FC00000  ; inf / inf = NaN
	.dw 0x3F800000, 0x7F800000, 0, 0x00000000  ; 1 / inf = 0
t_fdiv_end:

t_fsqrt:
	.float 4.0, 0, 0, 2.0
	.float 2.0, 0, 0, 1.41421353816986083984375
	.dw 0xBF800000, 0, 0, 0x7FC00000           ; sqrt(-1) = NaN
	.dw 0x80000000, 0, 0, 0x80000000           ; sqrt(-0) = -0
	.dw 0x7F800000, 0, 0, 0x7F800000           ; sqrt(inf) = inf
	.dw 0x00000001, 0, 0, 0x1A3504F3           ; sqrt(2^-149)
t_fsqrt_end:

t_fmin:
	.float 1.0, 2.0, 0, 1.0
	.float 2.0, -1.0, 0, -1.0
	.dw 0x80000000, 0x00000000, 0, 0x80000000  ; min(-0, +0) = -0
	.dw 0x00000000, 0x80000000, 0, 0x80000000
	.dw 0x7FC12345, 0x3F800000, 0, 0x3F800000  ; NaN is ignored
	.dw 0x3F800000, 0x7FC12345, 0, 0x3F800000
	.dw 0x7F800001, 0x40000000, 0, 0x40000000  ; signaling too
	.dw 0x7FC12345, 0xFFC00001, 0, 0x7FC00000  ; both NaN
	.dw 0xFF800000, 0xFF7FFFFF, 0, 0xFF800000
t_fmin_end:

t_fmax:
	.float 1.0, 2.0, 0, 2.0
	.float 2.0, -1.0, 0, 2.0
	.dw 0x80000000, 0x00000000, 0, 0x00000000  ; max(-0, +0) = +0
	.dw 0x00000000, 0x80000000, 0, 0x00000000
	.dw 0x7FC12345, 0x3F800000, 0, 0x3F800000
	.dw 0x3F800000, 0x7FC12345, 0, 0x3F800000
	.dw 0x7FC12345, 0xFFC00001, 0, 0x7FC00000
	.dw 0x7F800000, 0x7F7FFFFF, 0, 0x7F800000
t_fmax_end:

t_fmadd:
	.float 2.0, 3.0, 1.0, 7.0                  ; rd + rs1 * rs2
	.float -2.0, 3.0, 1.0, -5.0
	; (1 + 2^-12)^2 - (1 + 2^-11) = 2^-24, rounded once; rounding the
	; product first would give 0
	.dw 0x3F800800, 0x3F800800, 0xBF801000, 0x33800000
	.dw 0x00000000, 0x7F800000, 0x3F800000, 0x7FC00000  ; 0 * inf
	.dw 0x3F800000, 0x7F800000, 0xFF800000, 0x7FC00000  ; inf - inf
	.dw 0x3F800000, 0x3F800000, 0x7FC12345, 0x7FC00000  ; NaN in rd
	.dw 0x7F7FFFFF, 0x40000000, 0xFF7FFFFF, 0x7F7FFFFF  ; no overflow inside
t_fmadd_end:

t_fmsub:
	.float 2.0, 3.0, 10.0, 4.0                 ; rd - rs1 * rs2
	.float 2.0, -3.0, 1.0, 7.0
	.dw 0x3F800800, 0x3F800800, 0x3F801000, 0xB3800000  ; -2^-24
	.dw 0x3F800000, 0x3F800000, 0x3F800000, 0x00000000  ; 1 - 1 = +0
t_fmsub_end:

t_fsgnj:
	.float 1.0, -2.0, 0, -1.0
	.float -1.0, 2.0, 0, 1.0
	.dw 0x7FC12345, 0xBF800000, 0, 0xFFC12345  ; NaN bits kept
	.dw 0x7F800001, 0x00000000, 0, 0x7F800001
t_fsgnj_end:

t_fsgnjn:
	.float 1.0, 2.0, 0, -1.0
	.float 1.0, -2.0, 0, 1.0
	.dw 0x80000000, 0x80000000, 0, 0x00000000  ; fneg -0
	.dw 0xFFC12345, 0xFFC12345, 0, 0x7FC12345
t_fsgnjn_end:

t_fsgnjx:
	.float -1.0, -2.0, 0, 1.0
	.float -1.0, 2.0, 0, -1.0
	.float 1.0, -2.0, 0, -1.0
	.dw 0xFF800000, 0xFF800000, 0, 0x7F800000  ; fabs -inf
t_fsgnjx_end:

t_feq:
	.float 1.0, 1.0, 0
	.dw 1
	.float 1.0, 2.0, 0
	.dw 0
	.dw 0x80000000, 0x00000000, 0, 1           ; -0 == +0
	.dw 0x7FC00000, 0x7FC00000, 0, 0           ; NaN != NaN
	.dw 0x7F800001, 0x3F800000, 0, 0
t_feq_end:

t_flt:
	.float 1.0, 2.0, 0
	.dw 1
	.float 2.0, 1.0, 0
	.dw 0
	.float 1.0, 1.0, 0
	.dw 0
	.dw 0x80000000, 0x00000000, 0, 0           ; -0 < +0 is false
	.dw 0x7FC00000, 0x3F800000, 0, 0
	.dw 0x3F800000, 0x7FC00000, 0, 0
	.dw 0xFF800000, 0xFF7FFFFF, 0, 1
	.dw 0x00000001, 0x00000002, 0, 1
t_flt_end:

t_fle:
	.float 1.0, 1.0, 0
	.dw 1
	.float 2.0, 1.0, 0
	.dw 0
	.dw 0x80000000, 0x00000000, 0, 1
	.dw 0x3F800000, 0x7FC00000, 0, 0
	.dw 0x7F800000, 0x7F800000, 0, 1
t_fle_end:

t_fclass:
	.dw 0xFF800000, 0, 0, 0x001                ; -inf
	.dw 0xBF800000, 0, 0, 0x002                ; negative normal
	.dw 0x80000001, 0, 0, 0x004                ; negative subnormal
	.dw 0x80000000, 0, 0, 0x008                ; -0
	.dw 0x00000000, 0, 0, 0x010                ; +0
	.dw 0x007FFFFF, 0, 0, 0x020                ; positive subnormal
	.dw 0x7F7FFFFF, 0, 0, 0x040                ; positive normal
	.dw 0x7F800000, 0, 0, 0x080                ; +inf
	.dw 0x7F800001, 0, 0, 0x100                ; signaling NaN
	.dw 0xFFBFFFFF, 0, 0, 0x100
	.dw 0x7FC00000, 0, 0, 0x200                ; quiet NaN
	.dw 0xFFC12345, 0, 0, 0x200
t_fclass_end:

t_ftoi:
	.float 1.9, 0, 0
	.dw 1                                      ; toward zero
	.float -1.9, 0, 0
	.dw -1
	.float 0.5, 0, 0
	.dw 0
	.float -0.5, 0, 0
	.dw 0
	.dw 0x4EFFFFFF, 0, 0, 0x7FFFFF80           ; largest below 2^31
	.dw 0x4F000000, 0, 0, 0x7FFFFFFF           ; 2^31 saturates
	.dw 0xCF000000, 0, 0, 0x80000000           ; -2^31 fits
	.dw 0xCF000001, 0, 0, 0x80000000           ; below saturates
	.dw 0x7F800000, 0, 0, 0x7FFFFFFF           ; +inf
	.dw 0xFF800000, 0, 0, 0x80000000           ; -inf
	.dw 0x7FC00000, 0, 0, 0x7FFFFFFF           ; NaN
	.dw 0xFFC00000, 0, 0, 0x7FFFFFFF
t_ftoi_end:

t_ftou:
	.float 1.9, 0, 0
	.dw 1
	.float 3e9, 0, 0
	.dw 3000000000
	.float -0.5, 0, 0
	.dw 0
	.float -1.0, 0, 0
	.dw 0                                      ; saturates
	.dw 0x4F7FFFFF, 0, 0, 0xFFFFFF00           ; largest below 2^32
	.dw 0x4F800000, 0, 0, 0xFFFFFFFF           ; 2^32 saturates
	.dw 0xFF800000, 0, 0, 0x00000000           ; -inf
	.dw 0x7F800000, 0, 0, 0xFFFFFFFF           ; +inf
	.dw 0x7FC00000, 0, 0, 0xFFFFFFFF           ; NaN
t_ftou_end:

t_itof:
	.dw 1, 0, 0, 0x3F800000
	.dw -1, 0, 0, 0xBF800000
	.dw 0, 0, 0, 0x00000000
	.dw 0x7FFFFFFF, 0, 0, 0x4F000000           ; rounded up to 2^31
	.dw 0x80000000, 0, 0, 0xCF000000
	.dw 16777217, 0, 0, 0x4B800000             ; 2^24 + 1: tie to even
	.dw 16777219, 0, 0, 0x4B800002             ; 2^24 + 3: tie to even
t_itof_end:

t_utof:
	.dw 3, 0, 0, 0x40400000
	.dw 0x80000000, 0, 0, 0x4F000000
	.dw 0xFFFFFFFF, 0, 0, 0x4F800000           ; rounded up to 2^32
	.dw 0xFFFFFF7F, 0, 0, 0x4F7FFFFF           ; rounded down
t_utof_end:
