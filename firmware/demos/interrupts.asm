; ============================================================================
;  [6] Interrupts
; ============================================================================

demo_interrupts:
	addi r30, r30, -4
	sw ra, 0(r30)

	la r1, s_irq_title
	call puts

	la r1, irq_handler
	mtcr ivec, r1

	li r2, KBD_FLUSH
	li r9, KBD
	sw r2, KBD_CONTROL(r9)
	li r2, UART_FLUSH
	li r9, UART
	sw r2, UART_CONTROL(r9)

	li r9, PIC
	li r2, (1 << IRQ_KBD) | (1 << IRQ_UART)
	sw r2, PIC_ENABLE(r9)
	li r2, STATUS_IE
	mtcr status, r2
	la r1, s_status
	mfcr r2, status
	call show

.idle:
	wfi                         ; sleep; the handler runs and IRETs back here
	lw r2, VAR_QUIT(r0)
	beqz r2, .idle

	mtcr status, r0             ; no interrupts after this instruction
	li r9, PIC
	sw r0, PIC_ENABLE(r9)

	la r1, s_irq_count
	lw r2, VAR_IRQ_COUNT(r0)
	call show
	la r1, s_key_count
	lw r2, VAR_KEY_COUNT(r0)
	call show

	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; The CPU jumps here with IE = 0 and EPC = the interrupted instruction.
; Everything the handler touches is restored before IRET.
irq_handler:
	mtcr scratch, r30           ; stash the interrupted stack pointer
	li r30, IRQ_STACK_TOP       ; and switch to the interrupt stack
	addi r30, r30, -40
	sw r1, 0(r30)
	sw r2, 4(r30)
	sw r3, 8(r30)
	sw r4, 12(r30)
	sw r5, 16(r30)
	sw r6, 20(r30)
	sw r7, 24(r30)
	sw r8, 28(r30)
	sw r9, 32(r30)
	sw ra, 36(r30)

	lw r1, VAR_IRQ_COUNT(r0)
	addi r1, r1, 1
	sw r1, VAR_IRQ_COUNT(r0)

.claim:
	li r1, PIC
	lw r1, PIC_CLAIM(r1)        ; lowest active line
	bltz r1, .done              ; 0xFFFFFFFF: nothing left
	li r2, IRQ_KBD
	beq r1, r2, .kbd
	li r2, IRQ_UART
	beq r1, r2, .uart
	li r2, IRQ_TIMER
	beq r1, r2, .timer
	j .done
.kbd:
	call on_key
	j .claim
.uart:
	call on_uart
	j .claim
.timer:
	call on_timer
	j .claim

.done:
	lw ra, 36(r30)
	lw r9, 32(r30)
	lw r8, 28(r30)
	lw r7, 24(r30)
	lw r6, 20(r30)
	lw r5, 16(r30)
	lw r4, 12(r30)
	lw r3, 8(r30)
	lw r2, 4(r30)
	lw r1, 0(r30)
	mfcr r30, scratch
	iret                        ; pc = EPC, IE = PIE

; Pops one keyboard event and describes it; Esc asks the main loop to quit.
on_key:
	addi r30, r30, -12
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)

	li r9, KBD
	lw r2, KBD_STATUS(r9)       ; reading STATUS also clears the overflow bit
	andi r2, r2, KBD_OVERFLOW
	beqz r2, .no_overflow
	la r1, s_overflow
	call puts
.no_overflow:
	li r9, KBD
	lw r10, KBD_DATA(r9)        ; the line drops once the FIFO is empty
	shli r11, r10, 16
	shri r11, r11, 16           ; usage ID; ANDI can't take 0xFFFF (14 bits)

	la r1, s_key
	call puts
	mv r1, r11
	li r2, 4
	call print_hex
	bltz r10, .released         ; bit 31 = released

	lw r1, VAR_KEY_COUNT(r0)
	addi r1, r1, 1
	sw r1, VAR_KEY_COUNT(r0)
	la r1, s_pressed
	call puts

	addi r10, r11, -HID_A       ; letters a-z are usage IDs 0x04-0x1D
	sltiu r1, r10, 26
	beqz r1, .not_letter
	li r1, ' '
	call putc
	addi r1, r10, 'a'
	call putc
.not_letter:
	addi r1, r11, -HID_ESCAPE
	bnez r1, .newline
	li r1, 1
	sw r1, VAR_QUIT(r0)
	la r1, s_esc
	call puts
	j .newline
.released:
	la r1, s_released
	call puts
.newline:
	li r1, '\n'
	call putc

	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 12
	ret

; Echoes one received byte back; Esc asks the main loop to quit, so the
; demo also runs without a window (--headless).
on_uart:
	li r9, UART
	lw r1, UART_DATA(r9)        ; the line drops once the RX FIFO is empty
	li r2, HOST_ESCAPE
	bne r1, r2, putc            ; tail call: putc returns to the handler
	li r1, 1
	sw r1, VAR_QUIT(r0)
	ret

; ---- data -----------------------------------------------------------------

s_irq_title:    .asciz "\n[6] interrupts: press keys in the window (Esc quits)\n    or type in the terminal (echoed through the UART, Esc quits)\n"
s_status:       .asciz "STATUS"
s_key:          .asciz "key 0x"
s_pressed:      .asciz " pressed"
s_released:     .asciz " released"
s_esc:          .asciz " (Esc)"
s_overflow:     .asciz "keyboard FIFO overflowed, events were lost\n"
s_irq_count:    .asciz "interrupts taken"
s_key_count:    .asciz "keys pressed"

	.align 4
