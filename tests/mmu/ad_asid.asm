; Accessed/dirty bits, ASID-tagged TLB entries and global mappings.

	.include "../common/harness.asm"
	.include "../common/mmu.asm"

VA_LOCAL  = VA_T
VA_GLOBAL = VA_T + PAGE_SIZE
ENTRY1    = TABLE
ENTRY2    = TABLE2

test_main:
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
	li r1, DIR2
	li r2, VA_T
	li r3, TABLE2 | PTE_V
	call map_dir

	li r1, TABLE
	li r2, VA_LOCAL
	li r3, PAGE0 | PTE_RW
	call map_page
	li r2, VA_GLOBAL
	li r3, PAGE2 | PTE_RW | PTE_G
	call map_page
	li r1, TABLE2
	li r2, VA_LOCAL
	li r3, PAGE1 | PTE_RW
	call map_page
	li r2, VA_GLOBAL
	li r3, PAGE3 | PTE_RW
	call map_page

	li r1, 11
	li r2, PAGE0
	sw r1, 0(r2)
	li r1, 22
	li r2, PAGE1
	sw r1, 0(r2)
	li r1, 33
	li r2, PAGE2
	sw r1, 0(r2)
	li r1, 44
	li r2, PAGE3
	sw r1, 0(r2)

	li r10, VA_LOCAL
	li r11, VA_GLOBAL
	li r12, ENTRY1
	li r1, DIR | PTBR_EN | (1 << PTBR_ASID_SHIFT)
	mtcr ptbr, r1
	li r28, 1
	lw r4, 0(r10)
	li r3, 11
	bne r4, r3, fail
	li r1, 99
	sc r5, r1, (r10)            ; failed SC must not set D
	li r3, 1
	bne r5, r3, fail
	lw r4, 0(r12)
	andi r4, r4, PTE_A | PTE_D
	li r3, PTE_A
	bne r4, r3, fail

	li r28, 2
	li r1, 55
	sw r1, 0(r10)
	lw r4, 0(r12)
	andi r4, r4, PTE_A | PTE_D
	li r3, PTE_A | PTE_D
	bne r4, r3, fail

	li r28, 3
	lw r4, 0(r11)              ; cache a global mapping in ASID 1
	li r3, 33
	bne r4, r3, fail
	li r1, DIR2 | PTBR_EN | (2 << PTBR_ASID_SHIFT)
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 22
	bne r4, r3, fail
	lw r4, 0(r11)              ; global mapping survives ASID switch
	li r3, 33
	bne r4, r3, fail

	li r28, 4
	tlbi r11                    ; remove global mapping
	lw r4, 0(r11)
	li r3, 44
	bne r4, r3, fail

	li r28, 5
	li r1, PAGE2 | PTE_RW
	sw r1, 0(r12)                ; edit inactive ASID's cached PTE
	li r1, DIR | PTBR_EN | (1 << PTBR_ASID_SHIFT)
	mtcr ptbr, r1
	lw r4, 0(r10)              ; old cached mapping is still valid
	li r3, 55
	bne r4, r3, fail
	tlbi r10
	lw r4, 0(r10)
	li r3, 33
	bne r4, r3, fail

	mtcr ptbr, r0
	j pass
