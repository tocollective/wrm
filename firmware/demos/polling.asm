; ============================================================================
;  [5] Polling: PIC line enabled, IE = 0
; ============================================================================

demo_polling:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_poll_title
	call puts

	li r9, KBD
	li r2, KBD_FLUSH
	sw r2, KBD_CONTROL(r9)
	li r9, PIC
	li r2, 1 << IRQ_KBD
	sw r2, PIC_ENABLE(r9)       ; the line drives the CPU IRQ input...
.wait:
	wfi                         ; ...but with IE = 0 WFI just wakes up and continues
	li r9, KBD
	lw r2, KBD_STATUS(r9)
	andi r2, r2, KBD_READY
	beqz r2, .wait

	li r9, PIC
	la r1, s_pic_pending
	lw r2, PIC_PENDING(r9)
	call show
	li r9, PIC
	la r1, s_pic_claim
	lw r2, PIC_CLAIM(r9)
	call show
	li r9, KBD
	la r1, s_kbd_event
	lw r2, KBD_DATA(r9)         ; pops the event
	call show

	li r9, PIC
	sw r0, PIC_ENABLE(r9)

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; ---- data -----------------------------------------------------------------

s_poll_title:   .asciz "\n[5] polling: press any key in the WRM window\n"
s_pic_pending:  .asciz "PIC PENDING"
s_pic_claim:    .asciz "PIC CLAIM"
s_kbd_event:    .asciz "keyboard event"

	.align 4
