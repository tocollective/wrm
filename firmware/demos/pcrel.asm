; ============================================================================
;  [4] PC-relative code
; ============================================================================

demo_pcrel:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_pcrel_title
	call puts

.here:
	auipc r2, 0                 ; r2 = address of this very instruction
	la r1, s_auipc
	call show
	la r1, s_la_here
	la r2, .here                ; the same address, known to the assembler
	call show
	la r1, s_la_dollar
	la r2, $                    ; $ = address of the current line
	call show

	; AUIPC + JALR reach any address, JAL only +-1MB
.far:
	auipc r5, %hi(far_target - .far)
	jalr ra, r5, %lo(far_target - .far)

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

far_target:
	la r1, s_far
	j puts                      ; tail call: puts returns to demo_pcrel

; ---- data -----------------------------------------------------------------

s_pcrel_title:  .asciz "\n[4] pc-relative\n"
s_auipc:        .asciz "AUIPC r2, 0"
s_la_here:      .asciz "LA r2, .here"
s_la_dollar:    .asciz "LA r2, $"
s_far:          .asciz "far_target reached through AUIPC + JALR\n"

	.align 4
