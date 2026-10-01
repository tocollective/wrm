; ============================================================================
;  MMU: the TLBI modes. TLBI.ASID drops the entries of any address space,
;  so a recycled ASID starts clean without switching to it; TLBI.ALL drops
;  global entries too, a global superpage among them, which TLBI of one
;  page can't do in one go.
; ============================================================================

	.include "../common/harness.asm"
	.include "../common/mmu.asm"

T_ASID1         = 1 << PTBR_ASID_SHIFT
T_ASID2         = 2 << PTBR_ASID_SHIFT

test_main:
	la r1, trap_record
	mtcr ivec, r1
	li r1, STATUS_IE
	mtcr status, r1
	li r24, 0
	li r25, 0

	; ---- DIR (ASID 1) maps VA_T through TABLE, DIR2 (ASID 2) through
	; TABLE2; both map VA_S as a global superpage over the first 4MB
	li r1, DIR
	call mmu_init
	li r1, DIR2
	call mmu_init
	li r1, TABLE
	call clear_page
	li r1, TABLE2
	call clear_page
	li r1, DIR
	li r2, VA_T
	li r3, TABLE | PTE_V
	call map_dir
	li r1, DIR
	li r2, VA_S
	li r3, 0x00000000 | PTE_RW | PTE_G
	call map_dir
	li r1, DIR2
	li r2, VA_T
	li r3, TABLE2 | PTE_V
	call map_dir
	li r1, DIR2
	li r2, VA_S
	li r3, 0x00000000 | PTE_RW | PTE_G
	call map_dir
	li r1, TABLE
	li r2, VA_T
	li r3, PAGE0 | PTE_RW
	call map_page
	li r1, TABLE2
	li r2, VA_T
	li r3, PAGE1 | PTE_RW
	call map_page

	li r1, 0xA0
	li r2, PAGE0
	sw r1, 0(r2)
	li r1, 0xB0
	li r2, PAGE1
	sw r1, 0(r2)
	li r1, 0xC0
	li r2, PAGE2
	sw r1, 0(r2)
	li r1, 0xD0
	li r2, PAGE3
	sw r1, 0(r2)

	li r10, VA_T
	li r13, TABLE               ; the entry of VA_T in each table
	li r14, TABLE2

	; ---- TLBI.ASID of the current ASID: the next instruction sees the
	; new entry
	li r28, 1
	li r1, DIR | PTBR_EN | T_ASID1
	mtcr ptbr, r1
	lw r4, 0(r10)               ; cached now
	li r3, 0xA0
	bne r4, r3, fail
	li r28, 2
	li r1, PAGE2 | PTE_RW
	sw r1, 0(r13)
	li r1, 1
	tlbi.asid r1
	lw r4, 0(r10)
	li r3, 0xC0
	bne r4, r3, fail

	; ---- TLBI.ASID of another ASID: switching to it finds the new entry,
	; although a switch keeps the entries of the ASID switched to
	li r28, 3
	li r1, DIR2 | PTBR_EN | T_ASID2
	mtcr ptbr, r1
	lw r4, 0(r10)               ; cached in ASID 2
	li r3, 0xB0
	bne r4, r3, fail
	li r1, DIR | PTBR_EN | T_ASID1
	mtcr ptbr, r1
	li r28, 4
	li r1, PAGE3 | PTE_RW
	sw r1, 0(r14)
	li r1, 2
	tlbi.asid r1
	li r1, DIR2 | PTBR_EN | T_ASID2
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xD0
	bne r4, r3, fail
	li r28, 5                   ; only rs1[7:0] names the ASID
	li r1, DIR | PTBR_EN | T_ASID1
	mtcr ptbr, r1
	li r1, PAGE1 | PTE_RW
	sw r1, 0(r14)
	li r1, 0x102
	tlbi.asid r1
	li r1, DIR2 | PTBR_EN | T_ASID2
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xB0
	bne r4, r3, fail

	; ---- TLBI.ALL: global entries too, a superpage among them...
	li r28, 6
	li r12, VA_S + PAGE0
	lw r4, 0(r12)               ; cached, global
	li r3, 0xA0
	bne r4, r3, fail
	li r28, 7
	li r1, DIR2
	li r2, VA_S
	li r3, 0
	call map_dir                ; no VA_S in ASID 2 any more
	li r1, PAGE0 | PTE_RW       ; and VA_T back on PAGE0 in ASID 1
	sw r1, 0(r13)
	tlbi.all
.f7:
	lw r4, 0(r12)
	li r1, 9                    ; load page fault
	la r2, .f7
	call check_trap
	; ---- ... and the entries of every ASID
	li r28, 8
	li r1, DIR | PTBR_EN | T_ASID1
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xA0
	bne r4, r3, fail
	bnez r24, fail
	j pass

; check_trap(r1 = CAUSE, r2 = EPC): exactly one trap was recorded since the
; last check and it matches; r4 = the mismatching value
check_trap:
	li r4, 1
	bne r24, r4, .count
	mv r4, r20
	bne r4, r1, fail
	mv r4, r21
	bne r4, r2, fail
	li r24, 0
	ret
.count:
	mv r4, r24
	j fail
