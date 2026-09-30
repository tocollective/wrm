; ============================================================================
;  MMU: 4KB pages, superpages, permissions and page faults
; ============================================================================
; trap_record (see the harness) records the faults; IE is set so that
; supervisor faults are handled.

	.include "../common/harness.asm"
	.include "../common/mmu.asm"

test_main:
	la r1, trap_record
	mtcr ivec, r1
	li r1, STATUS_IE
	mtcr status, r1
	li r24, 0
	li r25, 0

	; ---- page tables
	li r1, DIR
	call mmu_init
	li r1, TABLE
	call clear_page
	li r1, DIR
	li r2, VA_T
	li r3, TABLE | PTE_V        ; no R, W or X: a page table
	call map_dir
	li r2, VA_S
	li r3, 0x00000000 | PTE_RW  ; RAM again, as a superpage
	call map_dir
	li r2, 0x00C00000
	li r3, 0x00001000 | PTE_RW  ; a superpage that isn't 4MB aligned
	call map_dir
	li r2, 0x01000000
	li r3, NO_RAM | PTE_V       ; a page table that can't be read
	call map_dir

	li r1, TABLE
	li r2, VA_T + 0x0000
	li r3, PAGE0 | PTE_RW
	call map_page
	li r2, VA_T + 0x1000
	li r3, PAGE1 | PTE_RW
	call map_page
	; VA_T + 0x2000 stays invalid
	li r2, VA_T + 0x3000
	li r3, PAGE2 | PTE_V        ; valid, but no R, W or X
	call map_page
	li r2, VA_T + 0x4000
	li r3, PAGE2 | PTE_V | PTE_R
	call map_page
	li r2, VA_T + 0x5000
	li r3, PAGE2 | PTE_V | PTE_W
	call map_page
	li r2, VA_T + 0x6000
	la r3, x_page | PTE_V | PTE_X
	call map_page
	li r2, VA_T + 0x7000
	li r3, PAGE3 | PTE_RW | PTE_U
	call map_page
	li r2, VA_T + 0x8000
	li r3, PAGE3 | PTE_R | PTE_W | PTE_X  ; everything but V
	call map_page

	li r1, 0xAAAA0000
	li r2, PAGE0
	sw r1, 0(r2)
	li r1, 0xBBBB0000
	li r2, PAGE1
	sw r1, 0(r2)
	li r1, 0xCCCC0000
	li r2, PAGE2
	sw r1, 0(r2)
	li r1, 0xDDDD0000
	li r2, PAGE3
	sw r1, 0(r2)

	; ---- translation on: the code goes on through the ROM mapping
	li r28, 1
	li r1, DIR | PTBR_EN
	mtcr ptbr, r1
	mfcr r4, ptbr
	bne r4, r1, fail

	; ---- 4KB pages
	li r10, VA_T
	li r28, 2
	lw r4, 0(r10)
	li r3, 0xAAAA0000
	bne r4, r3, fail
	li r28, 3
	li r11, VA_T + 0x1000
	lw r4, 0(r11)
	li r3, 0xBBBB0000
	bne r4, r3, fail
	li r28, 4
	li r1, 0x12345678
	sw r1, 0x10(r10)
	li r2, PAGE0                ; RAM is also mapped one to one
	lw r4, 0x10(r2)
	bne r4, r1, fail
	li r28, 5
	li r1, 0x0FFC0FFC
	sw r1, 0xFFC(r10)           ; the last word of the page
	lw r4, 0xFFC(r2)
	bne r4, r1, fail
	li r28, 6
	lbu r4, 0x11(r10)           ; narrow accesses
	li r3, 0x56
	bne r4, r3, fail
	li r28, 7
	li r1, 0xBEEF
	sh r1, 0x12(r10)
	lw r4, 0x10(r2)
	li r3, 0xBEEF5678
	bne r4, r3, fail
	li r28, 8
	bnez r24, fail

	; ---- a superpage
	li r28, 10
	li r12, VA_S + PAGE0
	lw r4, 0x10(r12)
	li r3, 0xBEEF5678
	bne r4, r3, fail
	li r28, 11
	li r1, 0x5E5E5E5E
	sw r1, 0x20(r12)
	lw r4, 0x20(r10)            ; the same physical word through VA_T
	bne r4, r1, fail
	li r28, 12
	li r12, VA_S + PAGE1
	lw r4, 0(r12)
	li r3, 0xBBBB0000
	bne r4, r3, fail
	li r28, 13
	bnez r24, fail

	; ---- page faults: BADADDR is the virtual address
	li r28, 20
	li r11, VA_T + 0x2000
.f20:
	lw r4, 8(r11)               ; invalid entry
	li r1, 9
	la r2, .f20
	li r3, VA_T + 0x2008
	call check_trap
	li r28, 21
.f21:
	sw r0, 0(r11)
	li r1, 10
	la r2, .f21
	li r3, VA_T + 0x2000
	call check_trap
	li r28, 22
	li r11, VA_T + 0x3000
.f22:
	lw r4, 0(r11)               ; valid, no R, W or X
	li r1, 9
	la r2, .f22
	li r3, VA_T + 0x3000
	call check_trap
	li r28, 23
.f23:
	sw r0, 0(r11)
	li r1, 10
	la r2, .f23
	li r3, VA_T + 0x3000
	call check_trap

	; ---- permissions
	li r28, 30
	li r11, VA_T + 0x4000
	lw r4, 0(r11)               ; R: loads work
	li r3, 0xCCCC0000
	bne r4, r3, fail
	bnez r24, fail
	li r28, 31
.f31:
	sw r0, 0(r11)               ; stores don't
	li r1, 10
	la r2, .f31
	li r3, VA_T + 0x4000
	call check_trap
	li r28, 32
	la r25, .f32_back
	li r11, VA_T + 0x4000
	jalr ra, r11                ; nor fetches
	j fail
.f32_back:
	li r1, 8
	li r2, VA_T + 0x4000
	li r3, VA_T + 0x4000
	call check_trap
	li r28, 33
	li r1, 0x0000C0DE
	li r11, VA_T + 0x5000
	sw r1, 4(r11)               ; W: stores work
	li r2, PAGE2
	lw r4, 4(r2)
	bne r4, r1, fail
	bnez r24, fail
	li r28, 34
.f34:
	lhu r4, 4(r11)              ; loads don't
	li r1, 9
	la r2, .f34
	li r3, VA_T + 0x5004
	call check_trap
	li r28, 35
	li r4, 0
	li r11, VA_T + 0x6000
	jalr ra, r11                ; X: the code runs
	li r3, 77
	bne r4, r3, fail
	bnez r24, fail
	li r28, 36
.f36:
	lw r4, 0(r11)               ; but can't be read
	li r1, 9
	la r2, .f36
	li r3, VA_T + 0x6000
	call check_trap
	li r28, 37
	li r11, VA_T + 0x7000
	lw r4, 0(r11)               ; supervisor mode can use U pages
	li r3, 0xDDDD0000
	bne r4, r3, fail
	bnez r24, fail
	li r28, 38
	li r11, VA_T + 0x8000
.f38:
	lw r4, 0(r11)               ; V clear, RWX set
	li r1, 9
	la r2, .f38
	li r3, VA_T + 0x8000
	call check_trap

	; ---- directory entries that can't be used
	li r28, 40
	li r11, 0x00C00000
.f40:
	lw r4, 0(r11)               ; superpage not aligned to 4MB
	li r1, 9
	la r2, .f40
	li r3, 0x00C00000
	call check_trap
	li r28, 41
	li r11, 0x01000000
.f41:
	lw r4, 0x1234(r11)          ; its page table isn't in memory
	li r1, 9
	la r2, .f41
	li r3, 0x01001234
	call check_trap
	li r28, 42
	li r11, 0x01400000
.f42:
	sw r4, 0(r11)               ; invalid directory entry
	li r1, 10
	la r2, .f42
	li r3, 0x01400000
	call check_trap
	li r28, 43
	la r25, .f43_back
	jalr ra, r11
	j fail
.f43_back:
	li r1, 8
	li r2, 0x01400000
	li r3, 0x01400000
	call check_trap

	; ---- the faults left the valid translations alone
	li r28, 50
	lw r4, 0(r10)
	li r3, 0xAAAA0000
	bne r4, r3, fail

	; ---- translation off: VA_T is an unmapped physical address again
	li r28, 60
	mtcr ptbr, r0
.f60:
	lw r4, 0(r10)
	li r1, 6                    ; load bus error, not a page fault
	la r2, .f60
	li r3, VA_T
	call check_trap
	j pass

; check_trap(r1 = CAUSE, r2 = EPC, r3 = BADADDR): exactly one trap was
; recorded since the last check and it matches; r4 = the mismatching value
check_trap:
	li r4, 1
	bne r24, r4, .count
	mv r4, r20
	bne r4, r1, fail
	mv r4, r21
	bne r4, r2, fail
	mv r4, r22
	bne r4, r3, fail
	li r24, 0
	ret
.count:
	mv r4, r24
	j fail

; an execute-only page: runs at VA_T + 0x6000
	.align PAGE_SIZE
x_page:
	li r4, 77
	ret
