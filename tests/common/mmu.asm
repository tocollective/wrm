; ============================================================================
;  Page table helpers for the MMU tests (after the harness)
; ============================================================================
; mmu_init builds the supervisor view every MMU test starts from, all of it
; mapped one to one and without U:
;   0x00000000-0x003FFFFF  RAM   superpage     R W X
;   0xFD000000-0xFD3FFFFF  I/O   superpage     R W
;   0xFE000000-0xFFFFFFFF  ROM   8 superpages  R X
; so the harness (and trap_record) keep working with translation on, and
; page tables in RAM can be edited at their physical addresses.

; physical pages used by the tests
DIR             = 0x00010000
DIR2            = 0x00011000
TABLE           = 0x00012000
TABLE2          = 0x00013000
TABLE3          = 0x00014000
PAGE0           = 0x00020000
PAGE1           = 0x00021000
PAGE2           = 0x00022000
PAGE3           = 0x00023000
NO_RAM          = 0x00800000        ; not backed by anything

; virtual regions
VA_T            = 0x00400000        ; 4KB pages, through a page table
VA_S            = 0x00800000        ; a superpage

PTE_RW          = PTE_V | PTE_R | PTE_W

; mmu_init(r1 = directory): clears it and maps RAM, I/O and ROM
mmu_init:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r1, 0(r30)
	call clear_page
	lw r1, 0(r30)
	li r2, 0x00000000 | PTE_V | PTE_R | PTE_W | PTE_X
	sw r2, 0(r1)
	li r2, PIC | PTE_V | PTE_R | PTE_W
	sw r2, DIR_IO(r1)
	li r2, ROM_BASE | PTE_V | PTE_R | PTE_X
	li r4, SUPERPAGE_SIZE
	addi r3, r1, DIR_ROM
	li r5, PAGE_SIZE
	add r5, r1, r5
.rom:
	sw r2, 0(r3)
	add r2, r2, r4
	addi r3, r3, 4
	bltu r3, r5, .rom
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; clear_page(r1 = physical page)
clear_page:
	li r2, PAGE_SIZE
	add r2, r1, r2
.next:
	sw r0, 0(r1)
	addi r1, r1, 4
	bltu r1, r2, .next
	ret

; map_dir(r1 = directory, r2 = virtual address, r3 = entry): sets the
; directory entry of r2 (a superpage or a page table pointer)
map_dir:
	shri r2, r2, 22
	shli r2, r2, 2
	add r2, r1, r2
	sw r3, 0(r2)
	ret

; map_page(r1 = page table, r2 = virtual address, r3 = entry): sets the
; page table entry of r2
map_page:
	shri r2, r2, 12
	andi r2, r2, 0x3FF
	shli r2, r2, 2
	add r2, r1, r2
	sw r3, 0(r2)
	ret
