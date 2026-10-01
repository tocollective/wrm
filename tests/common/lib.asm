; ============================================================================
;  UART output and helpers for the test ROMs (the firmware, now in M, has
;  its own in firmware/lib.m)
; ============================================================================

NAME_WIDTH      = 24            ; column where show() prints values

; putc(r1 = byte)
putc:
	li r9, UART
.wait:
	lw r8, UART_STATUS(r9)
	andi r8, r8, UART_TX_READY  ; always set here, polled for good form
	beqz r8, .wait
	sw r1, UART_DATA(r9)
	ret

; puts(r1 = zero-terminated string) -> r1 = address of the terminator
puts:
	li r9, UART
.next:
	lbu r2, 0(r1)
	beqz r2, .done
	sw r2, UART_DATA(r9)
	addi r1, r1, 1
	j .next
.done:
	ret

; pad(r1 = count): prints count spaces, nothing if count <= 0
pad:
	li r9, UART
	li r2, ' '
.next:
	blez r1, .done
	sw r2, UART_DATA(r9)
	addi r1, r1, -1
	j .next
.done:
	ret

; print_hex(r1 = value, r2 = digits)
print_hex:
	li r9, UART
	la r3, hex_digits
	addi r4, r2, -1
	shli r4, r4, 2              ; shift of the top digit
.next:
	shr r5, r1, r4
	andi r5, r5, 0xF
	add r5, r3, r5
	lbu r5, 0(r5)
	sw r5, UART_DATA(r9)
	addi r4, r4, -4
	bgez r4, .next
	ret

; print_dec(r1 = unsigned value)
print_dec:
	addi r30, r30, -16
	sw ra, 12(r30)
	addi r3, r30, 11            ; digits go backwards into 1..10(r30)
	sb r0, 0(r3)
	li r4, 10
.next:
	remu r2, r1, r4
	addi r2, r2, '0'
	addi r3, r3, -1
	sb r2, 0(r3)
	divu r1, r1, r4
	bnez r1, .next
	mv r1, r3
	call puts
	lw ra, 12(r30)
	addi r30, r30, 16
	ret

; print_int(r1 = signed value)
print_int:
	bgez r1, print_dec          ; tail call for non-negative values
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r1, 0(r30)
	li r1, '-'
	call putc
	lw r1, 0(r30)
	neg r1, r1                  ; 0x80000000 stays as is and prints unsigned
	call print_dec
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; show(r1 = name, r2 = value): "name      = value (0xVALUE)\n"
show:
	addi r30, r30, -16
	sw ra, 8(r30)
	sw r2, 4(r30)
	sw r1, 0(r30)
	call puts                   ; r1 = end of the name
	lw r2, 0(r30)
	sub r1, r1, r2              ; name length
	neg r1, r1
	addi r1, r1, NAME_WIDTH
	call pad
	la r1, s_equals
	call puts
	lw r1, 4(r30)
	call print_int
	la r1, s_hex_open
	call puts
	lw r1, 4(r30)
	li r2, 8
	call print_hex
	la r1, s_hex_close
	call puts
	lw ra, 8(r30)
	addi r30, r30, 16
	ret

; print_array(r1 = words, r2 = count): signed values on one line
print_array:
	addi r30, r30, -16
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)
	mv r10, r1
	mv r11, r2
.next:
	beqz r11, .done
	lw r1, 0(r10)
	call print_int
	li r1, ' '
	call putc
	addi r10, r10, 4
	addi r11, r11, -1
	j .next
.done:
	li r1, '\n'
	call putc
	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 16
	ret

; rdcycle() -> r1 = CYCLE, r2 = CYCLEH, both from the same moment
rdcycle:
	mfcr r2, cycleh
	mfcr r1, cycle
	mfcr r3, cycleh
	bne r2, r3, rdcycle         ; CYCLE wrapped in between: read again
	ret

; memcpy(r1 = dst, r2 = src, r3 = bytes), word-aligned, whole words
memcpy:
	add r3, r2, r3              ; end of the source
	bgeu r2, r3, .done
.next:
	lw r4, 0(r2)
	sw r4, 0(r1)
	addi r2, r2, 4
	addi r1, r1, 4
	bltu r2, r3, .next
.done:
	ret

; disk_io(r1 = controller, r2 = command, r3 = first sector, r4 = count,
;         r5 = physical RAM address) -> r1 = ERROR, 0 on success
; Runs a DISK_READ or DISK_WRITE and waits for it by polling STATUS.
disk_io:
	sw r3, DISK_SECTOR(r1)
	sw r4, DISK_COUNT(r1)
	sw r5, DISK_ADDRESS(r1)
	sw r2, DISK_COMMAND(r1)
.wait:
	lw r2, DISK_STATUS(r1)
	andi r2, r2, DISK_DONE
	beqz r2, .wait
	li r2, DISK_DONE
	sw r2, DISK_STATUS(r1)      ; acknowledge: drops the IRQ line
	lw r1, DISK_ERROR(r1)
	ret

; sort(r1 = words, r2 = count): bubble sort, signed, ascending
sort:
	addi r2, r2, -1             ; passes left
.pass:
	blez r2, .done
	mv r3, r1                   ; current pair
	mv r4, r2                   ; compares in this pass
.step:
	lw r5, 0(r3)
	lw r6, 4(r3)
	ble r5, r6, .ordered
	sw r6, 0(r3)
	sw r5, 4(r3)
.ordered:
	addi r3, r3, 4
	addi r4, r4, -1
	bnez r4, .step
	addi r2, r2, -1
	j .pass
.done:
	ret

; ---- data -----------------------------------------------------------------

hex_digits:     .ascii "0123456789ABCDEF"

s_equals:       .asciz "= "
s_hex_open:     .asciz " (0x"
s_hex_close:    .asciz ")\n"

	.align 4
