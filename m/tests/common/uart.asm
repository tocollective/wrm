; ============================================================================
;  UART output for the runtime tests, independent of the runtime itself
; ============================================================================

; t_puts(r1 = NUL-terminated string)
t_puts:
	li r2, 0xFD002000           ; UART DATA; TX never blocks
.next:
	lbu r3, 0(r1)
	beqz r3, .done
	sw r3, 0(r2)
	addi r1, r1, 1
	j .next
.done:
	ret
