; ============================================================================
;  Control flow: branches, JAL, JALR, the ends of the offset ranges
; ============================================================================
; Branches run over tables of (rd, rs1, taken), one per instruction: check
; N*100 + row fails for the Nth branch, with r1 = rd, r2 = rs1,
; r3 = expected, r4 = 1 if it was taken.

	.include "../common/harness.asm"

test_main:
	li r28, 100
	la r10, t_beq
	la r11, t_beq_end
	la r12, br_beq
	call check_table

	li r28, 200
	la r10, t_bne
	la r11, t_bne_end
	la r12, br_bne
	call check_table

	li r28, 300
	la r10, t_blt
	la r11, t_blt_end
	la r12, br_blt
	call check_table

	li r28, 400
	la r10, t_bge
	la r11, t_bge_end
	la r12, br_bge
	call check_table

	li r28, 500
	la r10, t_bltu
	la r11, t_bltu_end
	la r12, br_bltu
	call check_table

	li r28, 600
	la r10, t_bgeu
	la r11, t_bgeu_end
	la r12, br_bgeu
	call check_table

	; ---- a backward branch: a counted loop
	li r28, 700
	li r5, 10
	li r6, 0
.loop:
	addi r6, r6, 1
	addi r5, r5, -1
	bnez r5, .loop
	li r3, 10
	bne r6, r3, fail
	li r28, 701
	li r4, 0
	beq r0, r0, .next           ; taken to the very next instruction
.next:
	addi r4, r4, 1
	li r3, 1
	bne r4, r3, fail

	; ---- JAL
	li r28, 800
	jal r6, .jal_target
.jal_link:
	j fail
.jal_target:
	la r3, .jal_link
	bne r6, r3, fail
	li r28, 801
	li r6, 0x1234
	jal r0, .jal_nolink         ; J: no link, r0 stays zero
	j fail
.jal_nolink:
	bnez r0, fail
	li r3, 0x1234
	bne r6, r3, fail

	; ---- JALR
	li r28, 900
	la r5, .jalr0
	jalr r6, r5, 0
.jalr0_link:
	j fail
.jalr0:
	la r3, .jalr0_link
	bne r6, r3, fail
	li r28, 901
	la r5, .jalr1 - 8           ; positive offset
	jalr r6, r5, 8
	j fail
.jalr1:
	li r28, 902
	la r5, .jalr2 + 16          ; negative offset
	jalr r6, r5, -16
	j fail
.jalr2:
	li r28, 903
	la r5, .jalr3 + 3           ; the low two bits of the target are dropped
	jalr r6, r5, 0
	j fail
.jalr3:
	li r28, 904
	la r5, .jalr4
	jalr r6, r5, 2
	j fail
.jalr4:
	li r28, 905
	la r5, .jalr5
	jalr r5, r5, 0              ; rd = rs1: jumps to the old value
.jalr5_link:
	j fail
.jalr5:
	la r3, .jalr5_link
	bne r5, r3, fail
	li r28, 906
	la r5, .jalr6
	jr r5                       ; JALR r0: no link
	j fail
.jalr6:
	bnez r0, fail

	; ---- nested calls through the stack
	li r28, 1000
	li r1, 5
	call fact
	li r3, 120
	bne r1, r3, fail
	li r3, STACK_TOP
	bne r30, r3, fail

	; ---- the ends of the offset ranges, in routines at the end of the
	; image: the fillers would put fail out of reach of the checks
	li r28, 1100
	call far_branches
	li r3, 2
	bne r4, r3, fail

	li r28, 1200
	call far_jumps
	li r3, 2
	bne r4, r3, fail
	li r28, 1201
	la r3, jfar_back
	bne r6, r3, fail
	li r28, 1202
	la r3, jfar_after
	bne r7, r3, fail
	li r28, 1203
	li r3, jfar_fwd - jfar      ; the layout the offsets rely on
	li r1, 0xFFFFC
	bne r3, r1, fail
	li r28, 1204
	li r3, jfar_back - (jfar_fwd + 8)
	li r1, -0x100000
	bne r3, r1, fail
	j pass

; fact(r1 = n) -> r1 = n!, recursive
fact:
	li r2, 1
	bgt r1, r2, .recurse
	li r1, 1
	ret
.recurse:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r1, 0(r30)
	addi r1, r1, -1
	call fact
	lw r2, 0(r30)
	mul r1, r1, r2
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

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

; r4 = 1 if the branch is taken; the LI after it must be squashed
br_beq:
	li r4, 1
	beq r1, r2, .taken
	li r4, 0
.taken:
	ret
br_bne:
	li r4, 1
	bne r1, r2, .taken
	li r4, 0
.taken:
	ret
br_blt:
	li r4, 1
	blt r1, r2, .taken
	li r4, 0
.taken:
	ret
br_bge:
	li r4, 1
	bge r1, r2, .taken
	li r4, 0
.taken:
	ret
br_bltu:
	li r4, 1
	bltu r1, r2, .taken
	li r4, 0
.taken:
	ret
br_bgeu:
	li r4, 1
	bgeu r1, r2, .taken
	li r4, 0
.taken:
	ret

; ---- tables: rd, rs1, taken ------------------------------------------------

t_beq:
	.dw 0x00000000, 0x00000000, 1
	.dw 0x00000001, 0x00000000, 0
	.dw 0x00000000, 0x00000001, 0
	.dw 0xFFFFFFFF, 0x00000000, 0
	.dw 0x00000000, 0xFFFFFFFF, 0
	.dw 0x80000000, 0x7FFFFFFF, 0
	.dw 0x7FFFFFFF, 0x80000000, 0
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 1
	.dw 0x00000005, 0x00000005, 1
	.dw 0x80000000, 0x80000000, 1
	.dw 0xFFFFFFFF, 0xFFFFFFFE, 0
t_beq_end:

t_bne:
	.dw 0x00000000, 0x00000000, 0
	.dw 0x00000001, 0x00000000, 1
	.dw 0x00000000, 0x00000001, 1
	.dw 0xFFFFFFFF, 0x00000000, 1
	.dw 0x00000000, 0xFFFFFFFF, 1
	.dw 0x80000000, 0x7FFFFFFF, 1
	.dw 0x7FFFFFFF, 0x80000000, 1
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0
	.dw 0x00000005, 0x00000005, 0
	.dw 0x80000000, 0x80000000, 0
	.dw 0xFFFFFFFF, 0xFFFFFFFE, 1
t_bne_end:

t_blt:
	.dw 0x00000000, 0x00000000, 0
	.dw 0x00000001, 0x00000000, 0
	.dw 0x00000000, 0x00000001, 1
	.dw 0xFFFFFFFF, 0x00000000, 1
	.dw 0x00000000, 0xFFFFFFFF, 0
	.dw 0x80000000, 0x7FFFFFFF, 1
	.dw 0x7FFFFFFF, 0x80000000, 0
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0
	.dw 0x00000005, 0x00000005, 0
	.dw 0x80000000, 0x80000000, 0
	.dw 0xFFFFFFFF, 0xFFFFFFFE, 0
t_blt_end:

t_bge:
	.dw 0x00000000, 0x00000000, 1
	.dw 0x00000001, 0x00000000, 1
	.dw 0x00000000, 0x00000001, 0
	.dw 0xFFFFFFFF, 0x00000000, 0
	.dw 0x00000000, 0xFFFFFFFF, 1
	.dw 0x80000000, 0x7FFFFFFF, 0
	.dw 0x7FFFFFFF, 0x80000000, 1
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 1
	.dw 0x00000005, 0x00000005, 1
	.dw 0x80000000, 0x80000000, 1
	.dw 0xFFFFFFFF, 0xFFFFFFFE, 1
t_bge_end:

t_bltu:
	.dw 0x00000000, 0x00000000, 0
	.dw 0x00000001, 0x00000000, 0
	.dw 0x00000000, 0x00000001, 1
	.dw 0xFFFFFFFF, 0x00000000, 0
	.dw 0x00000000, 0xFFFFFFFF, 1
	.dw 0x80000000, 0x7FFFFFFF, 0
	.dw 0x7FFFFFFF, 0x80000000, 1
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 0
	.dw 0x00000005, 0x00000005, 0
	.dw 0x80000000, 0x80000000, 0
	.dw 0xFFFFFFFF, 0xFFFFFFFE, 0
t_bltu_end:

t_bgeu:
	.dw 0x00000000, 0x00000000, 1
	.dw 0x00000001, 0x00000000, 1
	.dw 0x00000000, 0x00000001, 0
	.dw 0xFFFFFFFF, 0x00000000, 1
	.dw 0x00000000, 0xFFFFFFFF, 0
	.dw 0x80000000, 0x7FFFFFFF, 1
	.dw 0x7FFFFFFF, 0x80000000, 0
	.dw 0xFFFFFFFF, 0xFFFFFFFF, 1
	.dw 0x00000005, 0x00000005, 1
	.dw 0x80000000, 0x80000000, 1
	.dw 0xFFFFFFFF, 0xFFFFFFFE, 1
t_bgeu_end:

; ---- far jumps ----------------------------------------------------------------

; far_branches() -> r4 = 2 when branches with offsets of +32764 and -32768
; bytes both went to their targets
far_branches:
	li r4, 0
	beq r0, r0, .fwd            ; the largest forward offset
	.space 32760                ; HLTs, never executed
.fwd:
	addi r4, r4, 1
	j .back_branch
.back:
	addi r4, r4, 1
	ret
	.space 32760
.back_branch:
	beq r0, r0, .back           ; the largest backward offset
	li r4, 0
	ret

; far_jumps() -> r4 = 2 when JALs with offsets of +1MB-4 and -1MB both went
; to their targets; r6, r7 = their links
far_jumps:
	li r4, 0
jfar:
	jal r6, jfar_fwd            ; the largest forward offset
jfar_back:
	addi r4, r4, 1
	ret
	.space 0xFFFFC - 12
jfar_fwd:
	addi r4, r4, 1
	nop
	jal r7, jfar_back           ; the largest backward offset
jfar_after:
	li r4, 0
	ret
