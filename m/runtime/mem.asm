; ============================================================================
;  memcpy and memset (docs/ABI.md#runtime-functions)
;
;  The compiler calls them to copy and zero large structs and arrays.
;  Both go word by word when they can: memcpy when the source and the
;  destination are equally aligned, memset always, after the bytes up to
;  the first word boundary.
; ============================================================================

; memcpy(r1 = dst, r2 = src, r3 = n) -> r1 = dst
	.text
	.globl memcpy, memset
memcpy:
	mv r4, r1                   ; r4 = next destination byte
	xor r5, r1, r2
	andi r5, r5, 3
	bnez r5, .bytes             ; never both aligned at once
.head:
	andi r5, r4, 3
	beqz r5, .words
	beqz r3, .done
	lbu r5, 0(r2)
	sb r5, 0(r4)
	addi r2, r2, 1
	addi r4, r4, 1
	addi r3, r3, -1
	j .head
.words:
	li r6, 4
.word:
	bltu r3, r6, .bytes
	lw r5, 0(r2)
	sw r5, 0(r4)
	addi r2, r2, 4
	addi r4, r4, 4
	addi r3, r3, -4
	j .word
.bytes:
	beqz r3, .done
	lbu r5, 0(r2)
	sb r5, 0(r4)
	addi r2, r2, 1
	addi r4, r4, 1
	addi r3, r3, -1
	j .bytes
.done:
	ret

; memset(r1 = dst, r2 = byte, r3 = n) -> r1 = dst
; Only the low 8 bits of r2 are used.
memset:
	mv r4, r1                   ; r4 = next destination byte
	andi r2, r2, 0xFF
	shli r5, r2, 8
	or r2, r2, r5
	shli r5, r2, 16
	or r2, r2, r5               ; the byte in all four lanes
.head:
	andi r5, r4, 3
	beqz r5, .words
	beqz r3, .done
	sb r2, 0(r4)
	addi r4, r4, 1
	addi r3, r3, -1
	j .head
.words:
	li r6, 4
.word:
	bltu r3, r6, .bytes
	sw r2, 0(r4)
	addi r4, r4, 4
	addi r3, r3, -4
	j .word
.bytes:
	beqz r3, .done
	sb r2, 0(r4)
	addi r4, r4, 1
	addi r3, r3, -1
	j .bytes
.done:
	ret
