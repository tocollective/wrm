; ============================================================================
;  [1] Arithmetic and logic
; ============================================================================

demo_alu:
	addi r30, r30, -20
	sw ra, 16(r30)
	sw r10, 12(r30)
	sw r11, 8(r30)
	sw r12, 4(r30)
	sw r13, 0(r30)

	la r1, s_alu_title
	call puts

	li r10, 1000                ; a
	li r11, -7                  ; b
	li r12, 0x0FF0              ; m
	li r13, 4                   ; s

	; register forms
	la r1, s_add
	add r2, r10, r11
	call show
	la r1, s_sub
	sub r2, r10, r11
	call show
	la r1, s_mul
	mul r2, r10, r11
	call show
	la r1, s_div
	div r2, r10, r11
	call show
	la r1, s_rem
	rem r2, r10, r11
	call show
	la r1, s_divu
	divu r2, r10, r11
	call show
	la r1, s_remu
	remu r2, r10, r11
	call show
	la r1, s_slt
	slt r2, r11, r10
	call show
	la r1, s_sltu
	sltu r2, r11, r10
	call show
	la r1, s_and
	and r2, r10, r12
	call show
	la r1, s_or
	or r2, r10, r12
	call show
	la r1, s_xor
	xor r2, r10, r12
	call show
	la r1, s_shl
	shl r2, r11, r13
	call show
	la r1, s_shr
	shr r2, r11, r13
	call show
	la r1, s_sar
	sar r2, r11, r13
	call show

	; immediate forms
	la r1, s_addi
	addi r2, r10, -1
	call show
	la r1, s_andi
	andi r2, r10, 0xF
	call show
	la r1, s_ori
	ori r2, r10, 0x3000
	call show
	la r1, s_xori
	xori r2, r10, 0x3FFF
	call show
	la r1, s_shli
	shli r2, r10, 20
	call show
	la r1, s_shri
	shri r2, r11, 28
	call show
	la r1, s_sari
	sari r2, r11, 1
	call show
	la r1, s_slti
	slti r2, r11, 0
	call show
	la r1, s_sltiu
	sltiu r2, r11, 1
	call show

	; upper immediates and 32-bit constants
	la r1, s_lui
	lui r2, 0x7FFFF
	call show
	la r1, s_li
	li r2, 0xDEADBEEF           ; LUI %hi + ORI %lo
	call show

	; corner cases: division never traps
	la r1, s_div0
	div r2, r10, r0
	call show
	la r1, s_rem0
	rem r2, r10, r0
	call show
	la r1, s_div_ovf
	li r2, 0x80000000
	li r3, -1
	div r2, r2, r3
	call show

	lw r13, 0(r30)
	lw r12, 4(r30)
	lw r11, 8(r30)
	lw r10, 12(r30)
	lw ra, 16(r30)
	addi r30, r30, 20
	ret

; ---- data -----------------------------------------------------------------

s_alu_title:    .asciz "\n[1] ALU: a = 1000, b = -7, m = 0x0FF0, s = 4\n"
s_add:          .asciz "ADD   a + b"
s_sub:          .asciz "SUB   a - b"
s_mul:          .asciz "MUL   a * b"
s_div:          .asciz "DIV   a / b"
s_rem:          .asciz "REM   a % b"
s_divu:         .asciz "DIVU  a / b"
s_remu:         .asciz "REMU  a % b"
s_slt:          .asciz "SLT   b < a"
s_sltu:         .asciz "SLTU  b < a"
s_and:          .asciz "AND   a & m"
s_or:           .asciz "OR    a | m"
s_xor:          .asciz "XOR   a ^ m"
s_shl:          .asciz "SHL   b << s"
s_shr:          .asciz "SHR   b >> s"
s_sar:          .asciz "SAR   b >> s"
s_addi:         .asciz "ADDI  a + -1"
s_andi:         .asciz "ANDI  a & 0xF"
s_ori:          .asciz "ORI   a | 0x3000"
s_xori:         .asciz "XORI  a ^ 0x3FFF"
s_shli:         .asciz "SHLI  a << 20"
s_shri:         .asciz "SHRI  b >> 28"
s_sari:         .asciz "SARI  b >> 1"
s_slti:         .asciz "SLTI  b < 0"
s_sltiu:        .asciz "SLTIU b < 1"
s_lui:          .asciz "LUI   0x7FFFF"
s_li:           .asciz "LI    0xDEADBEEF"
s_div0:         .asciz "DIV   a / 0"
s_rem0:         .asciz "REM   a % 0"
s_div_ovf:      .asciz "DIV   INT_MIN / -1"

	.align 4
