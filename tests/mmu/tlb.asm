; ============================================================================
;  MMU: dropping stale translations, switching page tables, many pages
; ============================================================================
; The architecture leaves the TLB size open, so these only check what
; software may rely on: after TLBI or a write to PTBR the new entries are
; used, invalid entries are never cached, and translation stays right with
; more pages in use than any small TLB holds.

	.include "../common/harness.asm"
	.include "../common/mmu.asm"

; The page the TLBI and PTBR checks use. Few other pages are active here, so
; a missing TLBI would leave the stale translation visible.
VA_TLB          = VA_T + 0x5000
MANY_VA         = 0x01000000        ; 128 pages through TABLE3...
MANY_PA         = 0x00040000        ; ...onto 128 physical pages
MANY_COUNT      = 128

test_main:
	la r1, trap_record
	mtcr ivec, r1
	li r1, STATUS_IE
	mtcr status, r1
	li r24, 0
	li r25, 0

	; ---- two address spaces: VA_TLB is PAGE0 in DIR and PAGE1 in DIR2
	li r1, DIR
	call mmu_init
	li r1, DIR2
	call mmu_init
	li r1, TABLE
	call clear_page
	li r1, TABLE2
	call clear_page
	li r1, TABLE3
	call clear_page
	li r1, DIR
	li r2, VA_T
	li r3, TABLE | PTE_V
	call map_dir
	li r2, VA_S
	li r3, 0x00000000 | PTE_RW
	call map_dir
	li r2, MANY_VA
	li r3, TABLE3 | PTE_V
	call map_dir
	li r1, DIR2
	li r2, VA_T
	li r3, TABLE2 | PTE_V
	call map_dir
	li r1, TABLE
	li r2, VA_TLB
	li r3, PAGE0 | PTE_RW
	call map_page
	li r2, VA_T + 0x2000
	la r3, x_page1 | PTE_V | PTE_X
	call map_page
	li r1, TABLE2
	li r2, VA_TLB
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

	li r1, DIR | PTBR_EN
	mtcr ptbr, r1
	li r10, VA_TLB
	li r13, TABLE + 5 * 4       ; its entry, at the physical address
	li r14, TABLE

	; ---- TLBI: the next instruction sees the new entry
	li r28, 1
	lw r4, 0(r10)               ; cached now
	li r3, 0xA0
	bne r4, r3, fail
	li r28, 2
	li r1, PAGE2 | PTE_RW
	sw r1, 0(r13)
	tlbi r10
	lw r4, 0(r10)
	li r3, 0xC0
	bne r4, r3, fail
	li r28, 3
	li r1, PAGE0 | PTE_RW
	sw r1, 0(r13)
	addi r1, r10, 0xABC         ; any address in the page
	tlbi r1
	lw r4, 0(r10)
	li r3, 0xA0
	bne r4, r3, fail

	; ---- a write to PTBR switches the address space
	li r28, 10
	li r1, DIR2 | PTBR_EN
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xB0
	bne r4, r3, fail
	li r28, 11
	li r1, DIR | PTBR_EN
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xA0
	bne r4, r3, fail

	; ---- writing the same PTBR drops everything: needed after a change
	; to the directory
	li r28, 20
	li r1, DIR
	li r2, VA_T
	li r3, TABLE2 | PTE_V
	call map_dir
	li r1, DIR | PTBR_EN
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xB0
	bne r4, r3, fail
	li r28, 21
	li r1, DIR
	li r2, VA_T
	li r3, TABLE | PTE_V
	call map_dir
	li r1, DIR | PTBR_EN
	mtcr ptbr, r1
	lw r4, 0(r10)
	li r3, 0xA0
	bne r4, r3, fail
	li r28, 22                  ; a superpage is dropped the same way
	li r12, VA_S + PAGE0
	lw r4, 0(r12)
	li r3, 0xA0
	bne r4, r3, fail
	li r28, 23
	li r1, DIR
	li r2, VA_S
	li r3, 0
	call map_dir
	li r1, DIR | PTBR_EN
	mtcr ptbr, r1
.f23:
	lw r4, 0(r12)
	li r1, 9
	la r2, .f23
	call check_trap

	; ---- invalid entries are never cached: making one valid needs no TLBI
	li r28, 30
	li r11, VA_T + 0x1000
.f30:
	lw r4, 0(r11)
	li r1, 9
	la r2, .f30
	call check_trap
	li r28, 31
	li r1, PAGE1 | PTE_RW
	sw r1, 4(r14)
	lw r4, 0(r11)
	li r3, 0xB0
	bne r4, r3, fail
	bnez r24, fail

	; ---- code: remapping an executable page
	li r28, 40
	li r11, VA_T + 0x2000
	li r4, 0
	jalr ra, r11
	li r3, 1
	bne r4, r3, fail
	li r28, 41
	la r1, x_page2 | PTE_V | PTE_X
	sw r1, 8(r14)
	tlbi r11
	jalr ra, r11
	li r3, 2
	bne r4, r3, fail

	; ---- more pages than a TLB holds: MANY_VA + i pages -> MANY_PA + i
	; pages, each holding its number; read forwards, backwards, then
	; written through the mapping
	li r28, 50
	li r1, TABLE3
	li r2, MANY_PA | PTE_RW
	li r3, MANY_COUNT
	li r4, MANY_PA
	li r5, 0
	li r6, PAGE_SIZE
.fill:
	sw r2, 0(r1)                ; the entry
	sw r5, 0(r4)                ; and the number in the page
	addi r1, r1, 4
	add r2, r2, r6
	add r4, r4, r6
	addi r5, r5, 1
	bltu r5, r3, .fill

	li r28, 51
	li r1, MANY_VA
	li r5, 0
.forwards:
	lw r4, 0(r1)
	bne r4, r5, fail
	add r1, r1, r6
	addi r5, r5, 1
	bltu r5, r3, .forwards
	li r28, 52
.backwards:
	sub r1, r1, r6
	addi r5, r5, -1
	lw r4, 0(r1)
	bne r4, r5, fail
	bnez r5, .backwards
	li r28, 53
	li r1, MANY_VA
.write:
	xori r2, r5, 0x3FFF
	sw r2, 4(r1)
	add r1, r1, r6
	addi r5, r5, 1
	bltu r5, r3, .write
	li r28, 54
	li r1, MANY_PA
	li r5, 0
.check:
	lw r4, 4(r1)
	xori r2, r5, 0x3FFF
	bne r4, r2, fail
	add r1, r1, r6
	addi r5, r5, 1
	bltu r5, r3, .check
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

; two versions of an execute-only page at VA_T + 0x2000
	.align PAGE_SIZE
x_page1:
	li r4, 1
	ret
	.align PAGE_SIZE
x_page2:
	li r4, 2
	ret
