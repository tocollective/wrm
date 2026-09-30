; ============================================================================
;  Loads and stores: widths, sign extension, byte order, offsets
; ============================================================================

	.include "../common/harness.asm"

DATA            = 0x1000            ; scratch RAM, reachable as DATA(r0)

test_main:
	li r10, DATA
	li r1, 0x89ABCDEF
	sw r1, 0(r10)

	; ---- little-endian bytes and halves
	li r28, 1
	lbu r4, 0(r10)
	li r3, 0xEF
	bne r4, r3, fail
	li r28, 2
	lbu r4, 1(r10)
	li r3, 0xCD
	bne r4, r3, fail
	li r28, 3
	lbu r4, 2(r10)
	li r3, 0xAB
	bne r4, r3, fail
	li r28, 4
	lbu r4, 3(r10)
	li r3, 0x89
	bne r4, r3, fail
	li r28, 5
	lhu r4, 0(r10)
	li r3, 0xCDEF
	bne r4, r3, fail
	li r28, 6
	lhu r4, 2(r10)
	li r3, 0x89AB
	bne r4, r3, fail
	li r28, 7
	lw r4, 0(r10)
	bne r4, r1, fail

	; ---- sign extension
	li r28, 10
	lb r4, 0(r10)
	li r3, 0xFFFFFFEF
	bne r4, r3, fail
	li r28, 11
	lb r4, 3(r10)
	li r3, 0xFFFFFF89
	bne r4, r3, fail
	li r28, 12
	lh r4, 0(r10)
	li r3, 0xFFFFCDEF
	bne r4, r3, fail
	li r28, 13
	lh r4, 2(r10)
	li r3, 0xFFFF89AB
	bne r4, r3, fail
	li r28, 14
	li r1, 0x127F347F           ; positive bytes and halves stay positive
	sw r1, 4(r10)
	lb r4, 4(r10)
	li r3, 0x7F
	bne r4, r3, fail
	li r28, 15
	lh r4, 6(r10)
	li r3, 0x127F
	bne r4, r3, fail

	; ---- narrow stores touch only their bytes and use the low bits of rd
	li r28, 20
	li r1, 0x89ABCDEF
	sw r1, 0(r10)
	li r2, 0x12345655
	sb r2, 1(r10)
	lw r4, 0(r10)
	li r3, 0x89AB55EF
	bne r4, r3, fail
	li r28, 21
	li r2, 0xCAFEBEEF
	sh r2, 2(r10)
	lw r4, 0(r10)
	li r3, 0xBEEF55EF
	bne r4, r3, fail
	li r28, 22
	li r2, 0xFFFFFF00
	sb r2, 0(r10)
	sb r2, 3(r10)
	lw r4, 0(r10)
	li r3, 0x00EF5500
	bne r4, r3, fail
	li r28, 23
	sh r0, 0(r10)
	lw r4, 0(r10)
	li r3, 0x00EF0000
	bne r4, r3, fail
	li r28, 24
	sw r0, 0(r10)
	lw r4, 0(r10)
	bnez r4, fail

	; ---- offsets: negative and the ends of the imm14 range
	li r28, 30
	li r1, 0x11223344
	sw r1, 0(r10)
	addi r11, r10, 16
	lw r4, -16(r11)
	bne r4, r1, fail
	li r28, 31
	li r11, DATA + 8192
	lw r4, -8192(r11)
	bne r4, r1, fail
	li r28, 32
	li r2, 0x55667788
	sw r2, 8188(r10)
	li r12, DATA + 8188
	lw r4, 0(r12)
	bne r4, r2, fail
	li r28, 33
	li r2, 0xA5
	sb r2, 8191(r10)
	lbu r4, 3(r12)
	bne r4, r2, fail
	li r28, 34
	lw r4, DATA(r0)             ; offset from r0: an absolute address
	bne r4, r1, fail

	; ---- register roles
	li r28, 40
	sw r10, 0(r10)              ; store the base register itself
	lw r4, 0(r10)
	bne r4, r10, fail
	li r28, 41
	mv r5, r10
	lw r5, 0(r5)                ; load into the base register
	bne r5, r10, fail
	li r28, 42
	lw r0, 0(r10)               ; r0 stays zero
	bnez r0, fail
	li r28, 43
	li r1, 0x0BADF00D
	sw r1, 0(r10)
	lbu r4, 0(r10)
	lbu r4, 1(r10)              ; overwrite the result of the previous load
	li r3, 0xF0
	bne r4, r3, fail

	; ---- loads from ROM
	li r28, 50
	la r11, rom_data
	lw r4, 0(r11)
	li r3, 0xFEDCBA98
	bne r4, r3, fail
	li r28, 51
	lh r4, 4(r11)
	li r3, 0xFFFF8001
	bne r4, r3, fail
	li r28, 52
	lb r4, 7(r11)
	li r3, 0xFFFFFF80
	bne r4, r3, fail

	; ---- a sequence of stores then loads (a small copy loop)
	li r28, 60
	la r1, DATA + 0x100
	la r2, rom_data
	li r3, 8
	call memcpy
	lw r4, DATA + 0x100(r0)
	li r3, 0xFEDCBA98
	bne r4, r3, fail
	li r28, 61
	lw r4, DATA + 0x104(r0)
	li r3, 0x80338001
	bne r4, r3, fail

	j pass

rom_data:
	.dw 0xFEDCBA98
	.dh 0x8001
	.db 0x33, 0x80
