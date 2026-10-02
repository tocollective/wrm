; ============================================================================
;  crt0: only the low 8 bits of main's result reach the exit code
; ============================================================================
; @output ""
; @exit 0xA5

	.globl main
main:
	li r1, 0x123456A5
	ret
