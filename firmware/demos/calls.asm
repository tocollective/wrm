; ============================================================================
;  [3] Calls, recursion, loops, jump tables
; ============================================================================

demo_calls:
	addi r30, r30, -20
	sw ra, 16(r30)
	sw r10, 12(r30)
	sw r11, 8(r30)
	sw r12, 4(r30)
	sw r13, 0(r30)

	la r1, s_calls_title
	call puts

	li r1, 10
	jal ra, factorial           ; the long form of CALL
	mv r2, r1
	la r1, s_fact
	call show

	li r1, 1071
	li r2, 462
	call gcd
	mv r2, r1
	la r1, s_gcd
	call show

	; call every function in op_table with (25, -40)
	li r10, 0                   ; index
.next_op:
	shli r11, r10, 2            ; byte offset into the tables
	la r1, op_table
	add r1, r1, r11
	lw r12, 0(r1)               ; function pointer
	la r1, op_names
	add r1, r1, r11
	lw r13, 0(r1)               ; its name
	li r1, 25
	li r2, -40
	jalr ra, r12, 0             ; indirect call
	mv r2, r1
	mv r1, r13
	call show
	addi r10, r10, 1
	slti r1, r10, OP_COUNT
	bnez r1, .next_op

	lw r13, 0(r30)
	lw r12, 4(r30)
	lw r11, 8(r30)
	lw r10, 12(r30)
	lw ra, 16(r30)
	addi r30, r30, 20
	ret

; factorial(r1 = n) -> r1 = n!, recursive to exercise the stack
factorial:
	slti r2, r1, 2
	beqz r2, .recurse
	li r1, 1
	ret
.recurse:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r1, 0(r30)
	addi r1, r1, -1
	call factorial
	lw r2, 0(r30)
	mul r1, r1, r2
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; gcd(r1, r2) -> r1, Euclid's algorithm
gcd:
	beqz r2, .done
	remu r3, r1, r2
	mv r1, r2
	mv r2, r3
	j gcd
.done:
	ret

; op_*(r1, r2) -> r1, called through op_table
op_add:
	add r1, r1, r2
	ret
op_sub:
	sub r1, r1, r2
	ret
op_max:
	bge r1, r2, .keep
	mv r1, r2
.keep:
	ret
op_min:
	ble r1, r2, .keep
	mv r1, r2
.keep:
	ret
op_mulh:                        ; (r1 * r2) >> 16, arithmetic
	mul r1, r1, r2
	sari r1, r1, 16
	ret

; ---- data -----------------------------------------------------------------

	.align 4
op_table:       .word op_add, op_sub, op_max, op_min, op_mulh
op_table_end:
op_names:       .word s_op_add, s_op_sub, s_op_max, s_op_min, s_op_mulh
OP_COUNT = (op_table_end - op_table) / 4

s_calls_title:  .asciz "\n[3] calls\n"
s_fact:         .asciz "factorial(10)"
s_gcd:          .asciz "gcd(1071, 462)"
s_op_add:       .asciz "op_add(25, -40)"
s_op_sub:       .asciz "op_sub(25, -40)"
s_op_max:       .asciz "op_max(25, -40)"
s_op_min:       .asciz "op_min(25, -40)"
s_op_mulh:      .asciz "op_mulh(25, -40)"

	.align 4
