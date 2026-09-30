; ============================================================================
;  ALU: register and immediate forms, LUI, AUIPC, r0 and register fields
; ============================================================================
; The register forms run over tables of (rs1, rs2, expected rd), one table
; per instruction: check N*100 + row fails for the Nth instruction, with
; r1 = rs1, r2 = rs2, r3 = expected, r4 = result. The other checks are
; numbered from 1600 up.

	.include "../common/harness.asm"

test_main:
	li r28, 100
	la r10, t_add
	la r11, t_add_end
	la r12, op_add
	call check_table

	li r28, 200
	la r10, t_sub
	la r11, t_sub_end
	la r12, op_sub
	call check_table

	li r28, 300
	la r10, t_and
	la r11, t_and_end
	la r12, op_and
	call check_table

	li r28, 400
	la r10, t_or
	la r11, t_or_end
	la r12, op_or
	call check_table

	li r28, 500
	la r10, t_xor
	la r11, t_xor_end
	la r12, op_xor
	call check_table

	li r28, 600
	la r10, t_shl
	la r11, t_shl_end
	la r12, op_shl
	call check_table

	li r28, 700
	la r10, t_shr
	la r11, t_shr_end
	la r12, op_shr
	call check_table

	li r28, 800
	la r10, t_sar
	la r11, t_sar_end
	la r12, op_sar
	call check_table

	li r28, 900
	la r10, t_slt
	la r11, t_slt_end
	la r12, op_slt
	call check_table

	li r28, 1000
	la r10, t_sltu
	la r11, t_sltu_end
	la r12, op_sltu
	call check_table

	li r28, 1100
	la r10, t_mul
	la r11, t_mul_end
	la r12, op_mul
	call check_table

	li r28, 1200
	la r10, t_div
	la r11, t_div_end
	la r12, op_div
	call check_table

	li r28, 1300
	la r10, t_divu
	la r11, t_divu_end
	la r12, op_divu
	call check_table

	li r28, 1400
	la r10, t_rem
	la r11, t_rem_end
	la r12, op_rem
	call check_table

	li r28, 1500
	la r10, t_remu
	la r11, t_remu_end
	la r12, op_remu
	call check_table

	; ---- immediate forms: logical and shift immediates are zero-extended
	li r28, 1600
	li r1, 0x00000000
	addi r4, r1, 0
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1601
	li r1, 0x00000001
	addi r4, r1, -1
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1602
	li r1, 0x7FFFFFFF
	addi r4, r1, 1
	li r3, 0x80000000
	bne r4, r3, fail
	li r28, 1603
	li r1, 0x00000005
	addi r4, r1, 8191
	li r3, 0x00002004
	bne r4, r3, fail
	li r28, 1604
	li r1, 0x00000005
	addi r4, r1, -8192
	li r3, 0xFFFFE005
	bne r4, r3, fail
	li r28, 1605
	li r1, 0xFFFFFFFF
	addi r4, r1, 1
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1606
	li r1, 0xFFFFFFFF
	andi r4, r1, 0x3FFF
	li r3, 0x00003FFF
	bne r4, r3, fail
	li r28, 1607
	li r1, 0x12345678
	andi r4, r1, 0xFF
	li r3, 0x00000078
	bne r4, r3, fail
	li r28, 1608
	li r1, 0x80002000
	andi r4, r1, 0x2000
	li r3, 0x00002000
	bne r4, r3, fail
	li r28, 1609
	li r1, 0x00000000
	ori r4, r1, 0x3FFF
	li r3, 0x00003FFF
	bne r4, r3, fail
	li r28, 1610
	li r1, 0x80000000
	ori r4, r1, 0x1
	li r3, 0x80000001
	bne r4, r3, fail
	li r28, 1611
	li r1, 0x12340000
	ori r4, r1, 0x2A5A
	li r3, 0x12342A5A
	bne r4, r3, fail
	li r28, 1612
	li r1, 0xFFFFFFFF
	xori r4, r1, 0x3FFF
	li r3, 0xFFFFC000
	bne r4, r3, fail
	li r28, 1613
	li r1, 0x12345678
	xori r4, r1, 0x3FFF
	li r3, 0x12346987
	bne r4, r3, fail
	li r28, 1614
	li r1, 0x00000000
	xori r4, r1, 0x0
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1615
	li r1, 0x00000001
	shli r4, r1, 31
	li r3, 0x80000000
	bne r4, r3, fail
	li r28, 1616
	li r1, 0x12345678
	shli r4, r1, 4
	li r3, 0x23456780
	bne r4, r3, fail
	li r28, 1617
	li r1, 0x12345678
	shli r4, r1, 0
	li r3, 0x12345678
	bne r4, r3, fail
	li r28, 1618
	li r1, 0x80000000
	shri r4, r1, 31
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1619
	li r1, 0x80000000
	shri r4, r1, 0
	li r3, 0x80000000
	bne r4, r3, fail
	li r28, 1620
	li r1, 0xFFFFFFFF
	shri r4, r1, 4
	li r3, 0x0FFFFFFF
	bne r4, r3, fail
	li r28, 1621
	li r1, 0x80000000
	sari r4, r1, 31
	li r3, 0xFFFFFFFF
	bne r4, r3, fail
	li r28, 1622
	li r1, 0x40000000
	sari r4, r1, 30
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1623
	li r1, 0xF0000000
	sari r4, r1, 4
	li r3, 0xFF000000
	bne r4, r3, fail
	li r28, 1624
	li r1, 0x80000000
	sari r4, r1, 0
	li r3, 0x80000000
	bne r4, r3, fail
	li r28, 1625
	li r1, 0xFFFFFFFF
	slti r4, r1, 0
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1626
	li r1, 0x00000000
	slti r4, r1, -1
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1627
	li r1, 0x00000005
	slti r4, r1, 5
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1628
	li r1, 0x00000004
	slti r4, r1, 5
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1629
	li r1, 0x80000000
	slti r4, r1, -8192
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1630
	li r1, 0x7FFFFFFF
	slti r4, r1, 8191
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1631
	li r1, 0x00000000
	sltiu r4, r1, 1
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1632
	li r1, 0x00000005
	sltiu r4, r1, -1
	li r3, 0x00000001
	bne r4, r3, fail
	li r28, 1633
	li r1, 0xFFFFFFFF
	sltiu r4, r1, -1
	li r3, 0x00000000
	bne r4, r3, fail
	li r28, 1634
	li r1, 0x00002000
	sltiu r4, r1, 8191
	li r3, 0x00000000
	bne r4, r3, fail

	; ---- LUI, AUIPC
	li r28, 1700
	lui r4, 1
	li r3, 0x00002000
	bne r4, r3, fail
	li r28, 1701
	lui r4, 0x7FFFF
	li r3, 0xFFFFE000
	bne r4, r3, fail
	li r28, 1702
	lui r4, 0x12345             ; LUI + ORI build any constant
	ori r4, r4, 0x1678
	li r3, 0x2468B678
	bne r4, r3, fail
	li r28, 1703
.auipc0:
	auipc r4, 0                 ; pc of the AUIPC itself
	la r3, .auipc0
	bne r4, r3, fail
	li r28, 1704
.auipc1:
	auipc r4, 1
	la r3, .auipc1 + 0x2000
	bne r4, r3, fail
	li r28, 1705
.auipc2:
	auipc r4, 0x7FFFF           ; wraps around: pc - 0x2000
	la r3, .auipc2 - 0x2000
	bne r4, r3, fail

	; ---- r0 reads as zero, writes are dropped
	li r28, 1800
	addi r0, r0, 5
	lui r0, 1
	add r4, r0, r0
	bnez r4, fail
	li r28, 1801
	li r1, 7
	sub r0, r1, r0
	mv r4, r0
	bnez r4, fail
	li r28, 1802
	or r4, r1, r0               ; r0 as rs2
	bne r4, r1, fail

	; ---- rd equal to a source
	li r28, 1900
	li r5, 3
	add r5, r5, r5
	li r3, 6
	bne r5, r3, fail
	li r28, 1901
	sub r5, r5, r5
	bnez r5, fail
	li r28, 1902
	li r5, -5
	mul r5, r5, r5
	li r3, 25
	bne r5, r3, fail
	li r28, 1903
	li r5, 0x100
	addi r5, r5, -1
	xori r5, r5, 0xFF
	bnez r5, fail

	; ---- every register: rd through LI, then each one as rs2 and rs1
	; (r28 and r30 of the harness are restored before the checks)
	li r1, 1 << 0
	li r2, 1 << 1
	li r3, 1 << 2
	li r4, 1 << 3
	li r5, 1 << 4
	li r6, 1 << 5
	li r7, 1 << 6
	li r8, 1 << 7
	li r9, 1 << 8
	li r10, 1 << 9
	li r11, 1 << 10
	li r12, 1 << 11
	li r13, 1 << 12
	li r14, 1 << 13
	li r15, 1 << 14
	li r16, 1 << 15
	li r17, 1 << 16
	li r18, 1 << 17
	li r19, 1 << 18
	li r20, 1 << 19
	li r21, 1 << 20
	li r22, 1 << 21
	li r23, 1 << 22
	li r24, 1 << 23
	li r25, 1 << 24
	li r26, 1 << 25
	li r27, 1 << 26
	li r28, 1 << 27
	li r29, 1 << 28
	li r30, 1 << 29
	li r31, 1 << 30
	or r1, r1, r2
	or r1, r1, r3
	or r1, r1, r4
	or r1, r1, r5
	or r1, r1, r6
	or r1, r1, r7
	or r1, r1, r8
	or r1, r1, r9
	or r1, r1, r10
	or r1, r1, r11
	or r1, r1, r12
	or r1, r1, r13
	or r1, r1, r14
	or r1, r1, r15
	or r1, r1, r16
	or r1, r1, r17
	or r1, r1, r18
	or r1, r1, r19
	or r1, r1, r20
	or r1, r1, r21
	or r1, r1, r22
	or r1, r1, r23
	or r1, r1, r24
	or r1, r1, r25
	or r1, r1, r26
	or r1, r1, r27
	or r1, r1, r28
	or r1, r1, r29
	or r1, r1, r30
	or r1, r1, r31
	li r28, 2000
	li r30, STACK_TOP
	li r3, 0x7FFFFFFF           ; r1-r31
	bne r1, r3, fail
	li r1, 1 << 0
	li r2, 1 << 1
	li r3, 1 << 2
	li r4, 1 << 3
	li r5, 1 << 4
	li r6, 1 << 5
	li r7, 1 << 6
	li r8, 1 << 7
	li r9, 1 << 8
	li r10, 1 << 9
	li r11, 1 << 10
	li r12, 1 << 11
	li r13, 1 << 12
	li r14, 1 << 13
	li r15, 1 << 14
	li r16, 1 << 15
	li r17, 1 << 16
	li r18, 1 << 17
	li r19, 1 << 18
	li r20, 1 << 19
	li r21, 1 << 20
	li r22, 1 << 21
	li r23, 1 << 22
	li r24, 1 << 23
	li r25, 1 << 24
	li r26, 1 << 25
	li r27, 1 << 26
	li r28, 1 << 27
	li r29, 1 << 28
	li r30, 1 << 29
	li r31, 1 << 30
	li r31, 0
	or r31, r1, r31
	or r31, r2, r31
	or r31, r3, r31
	or r31, r4, r31
	or r31, r5, r31
	or r31, r6, r31
	or r31, r7, r31
	or r31, r8, r31
	or r31, r9, r31
	or r31, r10, r31
	or r31, r11, r31
	or r31, r12, r31
	or r31, r13, r31
	or r31, r14, r31
	or r31, r15, r31
	or r31, r16, r31
	or r31, r17, r31
	or r31, r18, r31
	or r31, r19, r31
	or r31, r20, r31
	or r31, r21, r31
	or r31, r22, r31
	or r31, r23, r31
	or r31, r24, r31
	or r31, r25, r31
	or r31, r26, r31
	or r31, r27, r31
	or r31, r28, r31
	or r31, r29, r31
	or r31, r30, r31
	li r28, 2001
	li r30, STACK_TOP
	li r3, 0x3FFFFFFF           ; r1-r30
	bne r31, r3, fail
	j pass

; check_table(r10 = first row, r11 = end, r12 = routine): calls the routine
; for each row of (r1, r2, expected r3); it computes r4. r28 += 1 per row.
check_table:
	addi r30, r30, -4
	sw ra, 0(r30)
.row:
	addi r28, r28, 1
	lw r1, 0(r10)
	lw r2, 4(r10)
	lw r3, 8(r10)
	jalr ra, r12
	bne r4, r3, fail
	addi r10, r10, 12
	bltu r10, r11, .row
	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; op_<name>(r1, r2) -> r4
op_add:
	add r4, r1, r2
	ret
op_sub:
	sub r4, r1, r2
	ret
op_and:
	and r4, r1, r2
	ret
op_or:
	or r4, r1, r2
	ret
op_xor:
	xor r4, r1, r2
	ret
op_shl:
	shl r4, r1, r2
	ret
op_shr:
	shr r4, r1, r2
	ret
op_sar:
	sar r4, r1, r2
	ret
op_slt:
	slt r4, r1, r2
	ret
op_sltu:
	sltu r4, r1, r2
	ret
op_mul:
	mul r4, r1, r2
	ret
op_div:
	div r4, r1, r2
	ret
op_divu:
	divu r4, r1, r2
	ret
op_rem:
	rem r4, r1, r2
	ret
op_remu:
	remu r4, r1, r2
	ret

; ---- tables: rs1, rs2, expected ---------------------------------------------

t_add:
	.dw 0x00000000, 0x00000000, 0x00000000
	.dw 0x00000001, 0x00000002, 0x00000003
	.dw 0xFFFFFFFF, 0x00000001, 0x00000000
	.dw 0x7FFFFFFF, 0x00000001, 0x80000000
	.dw 0x80000000, 0xFFFFFFFF, 0x7FFFFFFF
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFE
	.dw 0x12345678, 0x87654321, 0x99999999
t_add_end:

t_sub:
	.dw 0x00000000, 0x00000000, 0x00000000
	.dw 0x00000005, 0x00000003, 0x00000002
	.dw 0x00000003, 0x00000005, 0xFFFFFFFE
	.dw 0x00000000, 0x00000001, 0xFFFFFFFF
	.dw 0x80000000, 0x00000001, 0x7FFFFFFF
	.dw 0x7FFFFFFF, 0xFFFFFFFF, 0x80000000
	.dw 0x12345678, 0x87654321, 0x8ACF1357
t_sub_end:

t_and:
	.dw 0x00000000, 0xFFFFFFFF, 0x00000000
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
	.dw 0xF0F0F0F0, 0xFF00FF00, 0xF000F000
	.dw 0x12345678, 0x0F0F0F0F, 0x02040608
t_and_end:

t_or:
	.dw 0x00000000, 0x00000000, 0x00000000
	.dw 0x00000000, 0xFFFFFFFF, 0xFFFFFFFF
	.dw 0xF0F0F0F0, 0xFF00FF00, 0xFFF0FFF0
	.dw 0x12345678, 0x0F0F0F0F, 0x1F3F5F7F
t_or_end:

t_xor:
	.dw 0x00000000, 0x00000000, 0x00000000
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000
	.dw 0xF0F0F0F0, 0xFF00FF00, 0x0FF00FF0
	.dw 0x12345678, 0xFFFFFFFF, 0xEDCBA987
t_xor_end:

t_shl:
	.dw 0x80000001, 0x00000000, 0x80000001
	.dw 0x80000001, 0x00000001, 0x00000002
	.dw 0x12345678, 0x00000004, 0x23456780
	.dw 0x00000001, 0x0000001F, 0x80000000
	.dw 0x12345678, 0x00000020, 0x12345678
	.dw 0x12345678, 0x00000021, 0x2468ACF0
	.dw 0x12345678, 0xFFFFFFFF, 0x00000000
	.dw 0xFFFFFFFF, 0x0000001F, 0x80000000
t_shl_end:

t_shr:
	.dw 0x80000001, 0x00000000, 0x80000001
	.dw 0x80000001, 0x00000001, 0x40000000
	.dw 0x12345678, 0x00000004, 0x01234567
	.dw 0x80000000, 0x0000001F, 0x00000001
	.dw 0x80000000, 0x00000020, 0x80000000
	.dw 0x80000000, 0x00000021, 0x40000000
	.dw 0x80000000, 0xFFFFFFFF, 0x00000001
	.dw 0xFFFFFFFF, 0x0000001F, 0x00000001
t_shr_end:

t_sar:
	.dw 0x80000001, 0x00000000, 0x80000001
	.dw 0x80000001, 0x00000001, 0xC0000000
	.dw 0x92345678, 0x00000004, 0xF9234567
	.dw 0x12345678, 0x00000004, 0x01234567
	.dw 0x80000000, 0x0000001F, 0xFFFFFFFF
	.dw 0x80000000, 0x00000020, 0x80000000
	.dw 0x80000000, 0x00000021, 0xC0000000
	.dw 0x80000000, 0xFFFFFFFF, 0xFFFFFFFF
	.dw 0x7FFFFFFF, 0x0000001F, 0x00000000
t_sar_end:

t_slt:
	.dw 0x00000000, 0x00000000, 0x00000000
	.dw 0x00000000, 0x00000001, 0x00000001
	.dw 0x00000001, 0x00000000, 0x00000000
	.dw 0xFFFFFFFF, 0x00000000, 0x00000001
	.dw 0x00000000, 0xFFFFFFFF, 0x00000000
	.dw 0x80000000, 0x7FFFFFFF, 0x00000001
	.dw 0x7FFFFFFF, 0x80000000, 0x00000000
	.dw 0xFFFFFFFE, 0xFFFFFFFF, 0x00000001
t_slt_end:

t_sltu:
	.dw 0x00000000, 0x00000000, 0x00000000
	.dw 0x00000000, 0x00000001, 0x00000001
	.dw 0x00000001, 0x00000000, 0x00000000
	.dw 0xFFFFFFFF, 0x00000000, 0x00000000
	.dw 0x00000000, 0xFFFFFFFF, 0x00000001
	.dw 0x80000000, 0x7FFFFFFF, 0x00000000
	.dw 0x7FFFFFFF, 0x80000000, 0x00000001
	.dw 0xFFFFFFFE, 0xFFFFFFFF, 0x00000001
t_sltu_end:

t_mul:
	.dw 0x00000000, 0x12345678, 0x00000000
	.dw 0x00000003, 0x00000007, 0x00000015
	.dw 0xFFFFFFFD, 0x00000007, 0xFFFFFFEB
	.dw 0xFFFFFFFD, 0xFFFFFFF9, 0x00000015
	.dw 0x00010000, 0x00010000, 0x00000000
	.dw 0x12345678, 0x9ABCDEF0, 0x242D2080
	.dw 0x80000000, 0xFFFFFFFF, 0x80000000
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0x00000001
t_mul_end:

t_div:
	.dw 0x00000014, 0x00000006, 0x00000003
	.dw 0xFFFFFFEC, 0x00000006, 0xFFFFFFFD
	.dw 0x00000014, 0xFFFFFFFA, 0xFFFFFFFD
	.dw 0xFFFFFFEC, 0xFFFFFFFA, 0x00000003
	.dw 0x00000005, 0x00000007, 0x00000000
	.dw 0x7FFFFFFF, 0x00000001, 0x7FFFFFFF
	.dw 0x80000000, 0xFFFFFFFF, 0x80000000
	.dw 0x80000000, 0x00000001, 0x80000000
	.dw 0x00000007, 0x00000000, 0xFFFFFFFF
	.dw 0x00000000, 0x00000000, 0xFFFFFFFF
	.dw 0xFFFFFFF9, 0x00000000, 0xFFFFFFFF
t_div_end:

t_divu:
	.dw 0x00000014, 0x00000006, 0x00000003
	.dw 0xFFFFFFEC, 0x00000006, 0x2AAAAAA7
	.dw 0x00000014, 0xFFFFFFFA, 0x00000000
	.dw 0xFFFFFFFF, 0x00000001, 0xFFFFFFFF
	.dw 0xFFFFFFFF, 0x00000010, 0x0FFFFFFF
	.dw 0x80000000, 0xFFFFFFFF, 0x00000000
	.dw 0x00000007, 0x00000000, 0xFFFFFFFF
	.dw 0x00000000, 0x00000000, 0xFFFFFFFF
t_divu_end:

t_rem:
	.dw 0x00000014, 0x00000006, 0x00000002
	.dw 0xFFFFFFEC, 0x00000006, 0xFFFFFFFE
	.dw 0x00000014, 0xFFFFFFFA, 0x00000002
	.dw 0xFFFFFFEC, 0xFFFFFFFA, 0xFFFFFFFE
	.dw 0x00000005, 0x00000007, 0x00000005
	.dw 0x80000000, 0xFFFFFFFF, 0x00000000
	.dw 0x80000000, 0x00000003, 0xFFFFFFFE
	.dw 0x00000007, 0x00000000, 0x00000007
	.dw 0xFFFFFFF9, 0x00000000, 0xFFFFFFF9
t_rem_end:

t_remu:
	.dw 0x00000014, 0x00000006, 0x00000002
	.dw 0xFFFFFFEC, 0x00000006, 0x00000002
	.dw 0x00000014, 0xFFFFFFFA, 0x00000014
	.dw 0xFFFFFFFF, 0x00000010, 0x0000000F
	.dw 0x80000000, 0xFFFFFFFF, 0x80000000
	.dw 0x00000007, 0x00000000, 0x00000007
	.dw 0x00000000, 0x00000000, 0x00000000
t_remu_end:
