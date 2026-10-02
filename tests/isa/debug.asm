; ============================================================================
;  Debugging: single step (STATUS.SS) and the triggers (TADDRn/TCTRLn)
; ============================================================================

	.include "../common/harness.asm"

VAR_DATA        = 0x0200            ; 16 bytes the data triggers watch

test_main:
	; ---- the triggers are off after reset; TCTRL keeps X, R, W and SIZE
	li r28, 1
	mfcr r4, tctrl0
	bnez r4, fail
	mfcr r4, tctrl1
	bnez r4, fail
	mfcr r4, taddr0
	bnez r4, fail
	li r28, 2                   ; EXL is still set: nothing can match
	li r1, -1
	mtcr tctrl0, r1
	mfcr r4, tctrl0
	li r3, 0x1F07
	mtcr tctrl0, r0
	bne r4, r3, fail
	li r28, 3
	li r1, 0x12345679
	mtcr taddr1, r1
	mfcr r4, taddr1
	bne r4, r1, fail
	mtcr taddr1, r0

	; ---- single step: a trap after each instruction, EPC the next one
	li r28, 10
	la r1, step_record
	mtcr ivec, r1
	li r24, 0
	li r5, 0
	li r1, STATUS_SS
	mtcr status, r1             ; stepping starts after the next one
.s0:
	addi r5, r5, 1              ; trap 1: EPC = .s1, BADADDR = .s0
.s1:
	addi r5, r5, 1              ; trap 2
.s2:
	mtcr status, r0             ; trap 3: SS was set as it started
.s3:
	li r3, 3
	bne r24, r3, fail
	li r28, 11                  ; each one ran once
	li r3, 2
	bne r5, r3, fail
	li r28, 12
	li r3, CAUSE_STEP
	bne r20, r3, fail
	li r28, 13
	la r3, .s3
	bne r21, r3, fail
	li r28, 14
	la r3, .s2
	bne r22, r3, fail
	li r28, 15                  ; the handler isn't stepped: SS went to PSS
	li r3, STATUS_EXL           ; (the last one stepped had cleared SS)
	bne r23, r3, fail

	; ---- the debugger's way: IRET with PSS set runs one instruction
	li r28, 20
	li r24, 0
	li r6, 0
	la r1, .t0
	mtcr epc, r1
	li r1, STATUS_EXL | STATUS_PSS
	mtcr status, r1
	iret                        ; SS = PSS: .t0 runs, then the trap
.t0:
	addi r6, r6, 7              ; trap 1, the handler sees PSS
	mv r7, r23                  ; trap 2
.t1:
	mtcr status, r0             ; trap 3
	li r3, 3
	bne r24, r3, fail
	li r28, 21
	li r3, 7
	bne r6, r3, fail
	li r28, 22
	li r3, STATUS_EXL | STATUS_PSS
	bne r7, r3, fail
	li r28, 23
	la r3, .t1
	bne r22, r3, fail

	; ---- WFI with SS takes the trap instead of waiting
	li r28, 30
	li r24, 0
	li r1, STATUS_SS
	mtcr status, r1
	nop                         ; trap 1
	wfi                         ; trap 2: no IRQ would ever wake it
	mtcr status, r0             ; trap 3
	li r3, 3
	bne r24, r3, fail

	; ---- an instruction trigger faults before the instruction runs
	li r28, 40
	la r1, trap_record
	mtcr ivec, r1
	li r24, 0
	li r25, 0
	li r5, 0
	la r1, .x0
	mtcr taddr0, r1
	li r1, TCTRL_X              ; one byte: any fetch of the word
	mtcr tctrl0, r1             ; matches from the next instruction on
	nop
.x0:
	addi r5, r5, 1              ; faults; trap_record skips it
	mtcr tctrl0, r0
	li r3, 1
	bne r24, r3, fail
	li r28, 41
	bnez r5, fail
	li r28, 42
	li r3, CAUSE_WATCH
	bne r20, r3, fail
	li r28, 43
	la r3, .x0
	bne r21, r3, fail
	bne r22, r3, fail

	; ---- a load trigger over 4 bytes: loads in it fault, stores don't
	li r28, 50
	li r24, 0
	li r1, 0x11223344
	sw r1, VAR_DATA(r0)
	li r1, VAR_DATA + 1         ; any address in the range
	mtcr taddr0, r1
	li r1, TCTRL_R | 2 << TCTRL_SIZE_SHIFT
	mtcr tctrl0, r1
	li r5, 0
	lhu r5, VAR_DATA + 2(r0)    ; faults, r5 stays 0
	li r3, 1
	bne r24, r3, fail
	li r28, 51
	bnez r5, fail
	li r28, 52
	li r3, VAR_DATA + 2
	bne r22, r3, fail
	li r28, 53
	sw r0, VAR_DATA(r0)         ; a store doesn't match R
	lw r4, VAR_DATA + 4(r0)     ; past the range
	li r3, 1
	bne r24, r3, fail
	li r28, 54                  ; nor while EXL is set
	li r1, STATUS_EXL
	mtcr status, r1
	lw r4, VAR_DATA(r0)
	mtcr status, r0
	li r3, 1
	bne r24, r3, fail
	mtcr tctrl0, r0

	; ---- a store trigger over 16 bytes, on trigger 1: the store has no
	; effect
	li r28, 60
	li r24, 0
	li r1, -1
	sw r1, VAR_DATA + 12(r0)
	li r1, VAR_DATA + 5         ; aligned down to VAR_DATA
	mtcr taddr1, r1
	li r1, TCTRL_W | 4 << TCTRL_SIZE_SHIFT
	mtcr tctrl1, r1
	sb r0, VAR_DATA + 15(r0)    ; faults
	sb r0, VAR_DATA + 16(r0)    ; past the range
	li r3, 1
	bne r24, r3, fail
	li r28, 61
	lw r4, VAR_DATA + 12(r0)    ; loads don't match W
	li r3, -1
	bne r4, r3, fail
	li r28, 62
	li r3, VAR_DATA + 15
	bne r22, r3, fail
	li r28, 63
	li r3, CAUSE_WATCH
	bne r20, r3, fail
	mtcr tctrl1, r0
	mtcr taddr1, r0
	mtcr taddr0, r0

	j pass

; Single step handler: counts the traps in r24, keeps CAUSE, EPC, BADADDR
; and STATUS of the last one in r20-r23, and goes on at EPC.
step_record:
	mfcr r20, cause
	mfcr r21, epc
	mfcr r22, badaddr
	mfcr r23, status
	addi r24, r24, 1
	iret
