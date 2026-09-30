; ============================================================================
;  [2] Loads and stores
; ============================================================================

demo_memory:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r10, 0(r30)

	la r1, s_mem_title
	call puts

	; copy the table from ROM to RAM, print it, sort it, print it again
	li r1, BUFFER
	la r2, numbers
	li r3, numbers_end - numbers
	call memcpy
	la r1, s_ram_copy
	call puts
	li r1, BUFFER
	li r2, NUMBER_COUNT
	call print_array
	li r1, BUFFER
	li r2, NUMBER_COUNT
	call sort
	la r1, s_sorted
	call puts
	li r1, BUFFER
	li r2, NUMBER_COUNT
	call print_array

	; sum it (32-bit wrap-around)
	li r3, BUFFER
	li r4, BUFFER + NUMBER_COUNT * 4
	li r2, 0
.sum:
	lw r5, 0(r3)                ; load-use: the pipeline stalls 1 cycle, invisibly
	add r2, r2, r5
	addi r3, r3, 4
	bltu r3, r4, .sum
	la r1, s_sum
	call show

	; sign and zero extension
	la r10, sign_demo
	la r1, s_lb
	lb r2, 0(r10)
	call show
	la r1, s_lbu
	lbu r2, 0(r10)
	call show
	la r1, s_lh
	lh r2, 2(r10)
	call show
	la r1, s_lhu
	lhu r2, 2(r10)
	call show

	; the machine is little-endian
	li r10, BUFFER + 0x100
	li r2, 0x11
	sb r2, 0(r10)
	li r2, 0x22
	sb r2, 1(r10)
	li r2, 0x33
	sb r2, 2(r10)
	li r2, 0x44
	sb r2, 3(r10)
	la r1, s_sb_lw
	lw r2, 0(r10)
	call show
	li r2, 0xBEEF
	sh r2, 0(r10)
	la r1, s_sh_lw
	lw r2, 0(r10)
	call show

	lw r10, 0(r30)
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; ---- data -----------------------------------------------------------------

	.align 4
numbers:        .word 42, -17, 1000000, 0, -2147483648, 7, 0x7FFFFFFF, -1
numbers_end:
NUMBER_COUNT = (numbers_end - numbers) / 4

sign_demo:      .byte 0x80, 0x7F
	.half 0x8001                ; offset 2: naturally aligned

s_mem_title:    .asciz "\n[2] memory\n"
s_ram_copy:     .asciz "copied to RAM: "
s_sorted:       .asciz "sorted:        "
s_sum:          .asciz "sum"
s_lb:           .asciz "LB    0x80"
s_lbu:          .asciz "LBU   0x80"
s_lh:           .asciz "LH    0x8001"
s_lhu:          .asciz "LHU   0x8001"
s_sb_lw:        .asciz "SB 11 22 33 44, LW"
s_sh_lw:        .asciz "SH 0xBEEF, LW"

	.align 4
