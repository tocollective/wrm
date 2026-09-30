; ============================================================================
;  Control registers: reset values, MFCR/MTCR, masks, the counters
; ============================================================================

	.include "../common/harness.asm"

test_main:
	; ---- reset values (the harness only wrote IVEC)
	li r28, 1
	mfcr r4, status
	bnez r4, fail
	li r28, 2
	mfcr r4, epc
	bnez r4, fail
	li r28, 3
	mfcr r4, scratch
	bnez r4, fail
	li r28, 4
	mfcr r4, cause
	bnez r4, fail
	li r28, 5
	mfcr r4, badaddr
	bnez r4, fail
	li r28, 6
	mfcr r4, ptbr
	bnez r4, fail
	li r28, 7                   ; the counters started from zero at reset
	mfcr r4, instret
	li r3, 64
	bgeu r4, r3, fail
	mfcr r4, instreth
	bnez r4, fail
	li r28, 8
	mfcr r4, cycleh
	bnez r4, fail
	mfcr r1, instret
	mfcr r4, cycle
	bltu r4, r1, fail           ; at most one instruction per cycle

	; ---- plain registers keep what is written
	li r28, 10
	li r1, 0xDEADBEEF
	mtcr epc, r1
	mfcr r4, epc
	bne r4, r1, fail
	li r28, 11
	mtcr scratch, r1
	mfcr r4, scratch
	bne r4, r1, fail
	li r28, 12
	mtcr cause, r1
	mfcr r4, cause
	bne r4, r1, fail
	li r28, 13
	mtcr badaddr, r1
	mfcr r4, badaddr
	bne r4, r1, fail
	li r28, 14
	mfcr r5, ivec
	mtcr ivec, r1
	mfcr r4, ivec
	mtcr ivec, r5
	bne r4, r1, fail
	li r28, 15
	li r1, -1
	mtcr scratch, r1
	mfcr r4, scratch
	bne r4, r1, fail
	li r28, 16
	mtcr scratch, r0
	mfcr r4, scratch
	bnez r4, fail
	li r28, 17
	li r1, 7                    ; numbers work as well as names
	mtcr cr3, r1
	mfcr r4, 3
	bne r4, r1, fail

	; ---- STATUS: only IE, PIE, UM, PUM exist
	li r28, 20
	li r1, 0xFFFFFFFA           ; PIE, PUM and every undefined bit
	mtcr status, r1
	mfcr r4, status
	li r3, 0xA
	bne r4, r3, fail
	li r28, 21
	li r1, 0xFFFFFFF0
	mtcr status, r1
	mfcr r4, status
	bnez r4, fail

	; ---- PTBR: reserved bits read as zero
	li r28, 30
	li r1, 0x12345FFE           ; EN clear: translation stays off
	mtcr ptbr, r1
	mfcr r4, ptbr
	li r3, 0x12345000
	bne r4, r3, fail
	mtcr ptbr, r0

	; ---- INSTRET counts retired instructions
	li r28, 40
	mfcr r1, instret
	nop
	nop
	nop
	mfcr r2, instret
	sub r4, r2, r1
	li r3, 4                    ; the first MFCR and three NOPs
	bne r4, r3, fail
	li r28, 41
	mfcr r1, instret
	beq r0, r0, .taken          ; the two instructions after it are squashed
	nop
	nop
.taken:
	mfcr r2, instret
	sub r4, r2, r1
	li r3, 2
	bne r4, r3, fail
	li r28, 42
	mfcr r1, instret
	li r5, 10
.loop:
	addi r5, r5, -1
	bnez r5, .loop
	mfcr r2, instret
	sub r4, r2, r1
	li r3, 2 + 2 * 10
	bne r4, r3, fail

	; ---- CYCLE counts clock cycles
	li r28, 50
	mfcr r1, cycle
	mfcr r2, cycle
	bgeu r1, r2, fail
	li r28, 51
	mfcr r1, cycle              ; stalls, bubbles and squashes count too
	lw r5, 0(r0)
	addi r5, r5, 1
	beq r0, r0, .taken2
	nop
.taken2:
	mfcr r2, cycle
	sub r4, r2, r1
	li r3, 4 + 1 + 2            ; instructions + load-use + branch
	bltu r4, r3, fail

	; ---- 64-bit reads
	li r28, 60
	call rdcycle                ; lib.asm: r1 = CYCLE, r2 = CYCLEH
	bnez r2, fail
	beqz r1, fail

	; ---- NOP changes nothing
	li r28, 70
	li r1, 0x13579BDF
	mv r2, r1
	nop
	nop
	bne r1, r2, fail
	mfcr r4, status
	bnez r4, fail
	j pass
