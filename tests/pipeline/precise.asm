; ============================================================================
;  Precise faults and squashed instructions
; ============================================================================
; A fault is raised when the faulting instruction reaches WB: the older
; instructions have completed, the younger ones have no effect, and a
; faulting instruction in the shadow of a taken branch never traps.
; trap_record (see the harness) records the traps; IE is set so that
; supervisor faults are handled.

	.include "../common/harness.asm"

DATA            = 0x1000
NO_RAM          = 0x00100000

test_main:
	la r1, trap_record
	mtcr ivec, r1
	li r1, STATUS_IE
	mtcr status, r1
	li r24, 0
	li r25, 0
	li r10, DATA
	sw r0, 0(r10)
	sw r0, 4(r10)

	; ---- the shadow of a taken branch or jump: fetched, never executed
	li r28, 1
	beq r0, r0, .t1
	.dw 0x000000FF              ; illegal
	lw r1, 1(r10)               ; misaligned
.t1:
	bnez r24, fail
	li r28, 2
	j .t2
	syscall
	sw r0, 1(r10)
.t2:
	bnez r24, fail
	li r28, 3
	la r1, .t3
	jr r1
	hlt
	sw r0, 0(r1)                ; a store to ROM
.t3:
	bnez r24, fail
	li r28, 4
	li r5, 0x55
	beq r0, r0, .t4
	li r5, 0x66                 ; no register writes...
	sw r5, 0(r10)               ; ...and no stores
.t4:
	li r3, 0x55
	bne r5, r3, fail
	lw r4, 0(r10)
	bnez r4, fail
	li r28, 5
	li r5, 1
	lw r1, 0(r10)
	beq r1, r0, .t5             ; taken after a load-use stall
	li r5, 2
	li r5, 3
.t5:
	li r3, 1
	bne r5, r3, fail

	; ---- older instructions complete, younger ones have no effect
	li r28, 10
	li r5, 0
	li r7, 0x77
	la r25, .resume10
	addi r5, r5, 1              ; older: done
	sw r7, 4(r10)               ; older store: done
.f10:
	lw r6, 1(r10)               ; misaligned load
	addi r5, r5, 16             ; younger: squashed
	sw r5, 0(r10)               ; younger store: squashed
	j fail
.resume10:
	li r1, 3
	la r2, .f10
	call check_trap
	li r3, 1
	bne r5, r3, fail
	li r28, 11
	lw r4, 0(r10)
	bnez r4, fail
	li r28, 12
	lw r4, 4(r10)
	li r3, 0x77
	bne r4, r3, fail

	; ---- a faulting load writes nothing, even to a stalled consumer
	li r28, 20
	li r6, 0x66
	li r7, 0x77
	la r25, .resume20
.f20:
	lw r6, 1(r10)
	addi r7, r6, 1              ; load-use on the faulting load
	j fail
.resume20:
	li r1, 3
	la r2, .f20
	call check_trap
	li r3, 0x66
	bne r6, r3, fail
	li r3, 0x77
	bne r7, r3, fail

	; ---- the oldest fault wins, even when a younger one is found first
	; (the illegal opcode is seen in ID while the load is still in EX)
	li r28, 30
	la r25, .resume30
.f30:
	lw r6, 1(r10)
	.dw 0x000000FF
	syscall
	j fail
.resume30:
	li r1, 3
	la r2, .f30
	call check_trap
	li r28, 31
	la r25, .resume31
.f31:
	sh r0, 1(r10)               ; misaligned store
	syscall
	j fail
.resume31:
	li r1, 4
	la r2, .f31
	call check_trap
	li r28, 32
	la r25, .resume32
	li r11, NO_RAM
	sw r0, -4(r11)              ; the last RAM word is fine
.f32:
	lw r6, 0(r11)               ; load bus error
	jr r11                      ; its target is a fetch bus error
	j fail
.resume32:
	li r1, 6
	la r2, .f32
	call check_trap
	li r28, 33
	la r25, .resume33
	li r11, NO_RAM
	jr r11                      ; the target faults, not the shadow
	.dw 0x000000FF
	syscall
.resume33:
	li r1, 5
	li r2, NO_RAM
	call check_trap

	; ---- IRET retries the faulting instruction when EPC is left alone
	li r28, 40
	la r1, retry_trap
	mtcr ivec, r1
	li r5, 0
	li r6, 0
.f40:
	.dw 0x000000FF              ; retried twice, skipped the third time
	li r3, 3
	bne r5, r3, fail
	bne r6, r3, fail
	j pass

; retry_trap: returns to EPC twice, skips the instruction the third time;
; r5 = times entered, r6 = times EPC pointed at the same instruction
retry_trap:
	addi r5, r5, 1
	mfcr r26, epc
	la r27, test_main.f40
	bne r26, r27, .skip
	addi r6, r6, 1
.skip:
	li r27, 3
	bltu r5, r27, .retry
	addi r26, r26, 4
	mtcr epc, r26
.retry:
	iret

; check_trap(r1 = CAUSE, r2 = EPC): exactly one trap was recorded since the
; last check and it matches; r4 = the mismatching value
check_trap:
	li r4, 1
	bne r24, r4, .count
	mv r4, r20
	bne r4, r1, fail
	mv r4, r21
	bne r4, r2, fail
	li r24, 0
	ret
.count:
	mv r4, r24
	j fail
