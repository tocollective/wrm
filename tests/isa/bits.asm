; ============================================================================
;  Bit manipulation: CLZ, CTZ, POPCNT, BSWAP, SEXT.B, SEXT.H, ROL, ROR,
;  RORI, MIN, MAX, MINU, MAXU
; ============================================================================
; The register forms run over a table of (routine, rs1, rs2, expected rd).
; Check 100 + row fails with r1 = rs1, r2 = rs2, r3 = expected, r4 = the
; result. The other checks are numbered from 1 up.

	.include "../common/harness.asm"

test_main:
	li r28, 100
	la r10, table
	la r11, table_end
.row:
	addi r28, r28, 1
	lw r12, 0(r10)
	lw r1, 4(r10)
	lw r2, 8(r10)
	lw r3, 12(r10)
	li r4, 0x5A5A5A5A
	jalr ra, r12
	bne r4, r3, fail
	addi r10, r10, 16
	bltu r10, r11, .row

	; ---- RORI: the amount is zero-extended, the low 5 bits count
	li r28, 1
	li r1, 0x12345678
	rori r4, r1, 4
	li r3, 0x81234567
	bne r4, r3, fail
	li r28, 2
	rori r4, r1, 0
	bne r4, r1, fail
	li r28, 3
	rori r4, r1, 31
	li r3, 0x2468ACF0
	bne r4, r3, fail
	li r28, 4
.rori_36:
	.dw 0x00902498              ; rori r4, r1, 36 (encodable, not by asm.py)
	li r3, 0x81234567
	bne r4, r3, fail

	; ---- forwarding: results feed the next instruction, rd = r0 stays 0
	li r28, 5
	li r1, 0x00F0
	clz r4, r1                  ; 24
	ctz r4, r4                  ; 3
	popcnt r4, r4               ; 2
	li r3, 2
	bne r4, r3, fail
	li r28, 6
	li r5, 0x1000
	li r1, 0x80
	sw r1, 0(r5)
	lw r4, 0(r5)
	sext.b r4, r4               ; rs1 from a load, which stalls
	li r3, -128
	bne r4, r3, fail
	li r28, 7
	clz r0, r1
	bnez r0, fail

	; ---- reserved bits: rs2 of a one-source instruction
	li r28, 8
	la r1, trap_record
	mtcr ivec, r1
	mtcr status, r0             ; clear reset EXL
	li r24, 0
	li r25, 0
.clz_rs2:
	.dw 0x00042290              ; clz r2, r1, rs2 = r1
	li r3, 1
	bne r24, r3, fail
	mv r4, r20                  ; CAUSE: illegal instruction
	bne r4, r3, fail
	la r3, .clz_rs2
	mv r4, r21
	bne r4, r3, fail

	j pass

; op_<name>(r1, r2) -> r4
op_clz:
	clz r4, r1
	ret
op_ctz:
	ctz r4, r1
	ret
op_popcnt:
	popcnt r4, r1
	ret
op_bswap:
	bswap r4, r1
	ret
op_sextb:
	sext.b r4, r1
	ret
op_sexth:
	sext.h r4, r1
	ret
op_rol:
	rol r4, r1, r2
	ret
op_ror:
	ror r4, r1, r2
	ret
op_min:
	min r4, r1, r2
	ret
op_max:
	max r4, r1, r2
	ret
op_minu:
	minu r4, r1, r2
	ret
op_maxu:
	maxu r4, r1, r2
	ret

; routine, rs1, rs2, expected rd
table:
	.dw op_clz, 0x00000000, 0x00000000, 0x00000020
	.dw op_clz, 0x00000001, 0x00000000, 0x0000001F
	.dw op_clz, 0x80000000, 0x00000000, 0x00000000
	.dw op_clz, 0x00010000, 0x00000000, 0x0000000F
	.dw op_clz, 0xFFFFFFFF, 0x00000000, 0x00000000
	.dw op_ctz, 0x00000000, 0x00000000, 0x00000020
	.dw op_ctz, 0x00000001, 0x00000000, 0x00000000
	.dw op_ctz, 0x80000000, 0x00000000, 0x0000001F
	.dw op_ctz, 0x00010000, 0x00000000, 0x00000010
	.dw op_ctz, 0xFFFF0000, 0x00000000, 0x00000010
	.dw op_popcnt, 0x00000000, 0x00000000, 0x00000000
	.dw op_popcnt, 0xFFFFFFFF, 0x00000000, 0x00000020
	.dw op_popcnt, 0x80000001, 0x00000000, 0x00000002
	.dw op_popcnt, 0x12345678, 0x00000000, 0x0000000D
	.dw op_bswap, 0x12345678, 0x00000000, 0x78563412
	.dw op_bswap, 0x000000FF, 0x00000000, 0xFF000000
	.dw op_sextb, 0x0000007F, 0x00000000, 0x0000007F
	.dw op_sextb, 0x00000080, 0x00000000, 0xFFFFFF80
	.dw op_sextb, 0x12345680, 0x00000000, 0xFFFFFF80
	.dw op_sexth, 0x00007FFF, 0x00000000, 0x00007FFF
	.dw op_sexth, 0x00008000, 0x00000000, 0xFFFF8000
	.dw op_sexth, 0xABCD1234, 0x00000000, 0x00001234
	.dw op_rol, 0x80000001, 0x00000001, 0x00000003
	.dw op_rol, 0x12345678, 0x00000008, 0x34567812
	.dw op_rol, 0x12345678, 0x00000000, 0x12345678
	.dw op_rol, 0x12345678, 0x00000020, 0x12345678
	.dw op_rol, 0x12345678, 0x00000024, 0x23456781
	.dw op_ror, 0x80000001, 0x00000001, 0xC0000000
	.dw op_ror, 0x12345678, 0x00000008, 0x78123456
	.dw op_ror, 0x12345678, 0x00000000, 0x12345678
	.dw op_ror, 0x12345678, 0x0000001F, 0x2468ACF0
	.dw op_min, 0x00000001, 0x00000002, 0x00000001
	.dw op_min, 0xFFFFFFFF, 0x00000001, 0xFFFFFFFF
	.dw op_min, 0x80000000, 0x7FFFFFFF, 0x80000000
	.dw op_min, 0x00000005, 0x00000005, 0x00000005
	.dw op_max, 0x00000001, 0x00000002, 0x00000002
	.dw op_max, 0xFFFFFFFF, 0x00000001, 0x00000001
	.dw op_max, 0x80000000, 0x7FFFFFFF, 0x7FFFFFFF
	.dw op_minu, 0x00000001, 0x00000002, 0x00000001
	.dw op_minu, 0xFFFFFFFF, 0x00000001, 0x00000001
	.dw op_minu, 0x80000000, 0x7FFFFFFF, 0x7FFFFFFF
	.dw op_maxu, 0x00000001, 0x00000002, 0x00000002
	.dw op_maxu, 0xFFFFFFFF, 0x00000001, 0xFFFFFFFF
	.dw op_maxu, 0x80000000, 0x7FFFFFFF, 0x80000000
table_end:
