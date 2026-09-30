; ============================================================================
;  Data hazards: forwarding into every operand, load-use, priorities
; ============================================================================
; "distance N" = the consumer is the Nth instruction after the producer.
; Every result must be the same as with one instruction at a time.

	.include "../common/harness.asm"

DATA            = 0x1000

test_main:
	li r10, DATA
	li r1, 0x11111111
	sw r1, 0(r10)
	li r1, 0x22222222
	sw r1, 4(r10)
	li r1, DATA + 8             ; a pointer for the chase below
	sw r1, 8(r10)
	li r1, 0x33333333
	sw r1, 12(r10)

	; ---- ALU result into rs1 at distance 1-4
	li r28, 1
	li r1, 5
	addi r4, r1, 1
	li r3, 6
	bne r4, r3, fail
	li r28, 2
	li r1, 5
	nop
	addi r4, r1, 1
	li r3, 6
	bne r4, r3, fail
	li r28, 3
	li r1, 5
	nop
	nop
	addi r4, r1, 1
	li r3, 6
	bne r4, r3, fail
	li r28, 4
	li r1, 5
	nop
	nop
	nop
	addi r4, r1, 1
	li r3, 6
	bne r4, r3, fail

	; ---- into rs2, and into both at different distances
	li r28, 10
	li r2, 7
	sub r4, r0, r2
	li r3, -7
	bne r4, r3, fail
	li r28, 11
	li r2, 7
	nop
	sub r4, r0, r2
	li r3, -7
	bne r4, r3, fail
	li r28, 12
	li r1, 100                  ; distance 2 into rs1
	li r2, 1                    ; distance 1 into rs2
	sub r4, r1, r2
	li r3, 99
	bne r4, r3, fail
	li r28, 13
	li r1, 100
	li r2, 1
	nop
	sub r4, r2, r1              ; distance 3 and 2
	li r3, -99
	bne r4, r3, fail
	li r28, 14
	li r1, 3
	add r4, r1, r1              ; the same register twice
	li r3, 6
	bne r4, r3, fail

	; ---- a chain: every instruction needs the previous one
	li r28, 20
	li r1, 1
	add r1, r1, r1
	add r1, r1, r1
	add r1, r1, r1
	add r1, r1, r1
	addi r1, r1, 3
	mul r1, r1, r1
	sub r1, r1, r0
	li r3, 361                  ; (16 + 3)^2
	bne r1, r3, fail

	; ---- the newest producer wins
	li r28, 30
	li r1, 1
	li r1, 2
	addi r4, r1, 0              ; EX/MEM over MEM/WB
	li r3, 2
	bne r4, r3, fail
	li r28, 31
	li r1, 1
	li r1, 2
	nop
	addi r4, r1, 0              ; MEM/WB over the register file
	li r3, 2
	bne r4, r3, fail
	li r28, 32
	li r1, 1
	li r1, 2
	li r1, 3
	addi r4, r1, 0
	li r3, 3
	bne r4, r3, fail

	; ---- r0 is never forwarded
	li r28, 40
	addi r0, r0, 9
	addi r4, r0, 0
	bnez r4, fail
	li r28, 41
	addi r0, r0, 9
	nop
	add r4, r0, r0
	bnez r4, fail
	li r28, 42
	lw r0, 0(r10)               ; a load into r0 neither stalls nor forwards
	addi r4, r0, 0
	bnez r4, fail

	; ---- stores and branches read rd; they never write it
	li r28, 50
	li r5, 0xABC
	sw r5, 16(r10)              ; store data at distance 1
	lw r4, 16(r10)
	bne r4, r5, fail
	li r28, 51
	li r5, 0xDEF
	nop
	sw r5, 16(r10)              ; distance 2
	lw r4, 16(r10)
	bne r4, r5, fail
	li r28, 52
	li r11, DATA + 20
	sw r5, 0(r11)               ; store base at distance 1
	lw r4, 20(r10)
	bne r4, r5, fail
	li r28, 53
	li r5, 0x123
	sw r5, 24(r10)
	addi r4, r5, 0              ; the store did not write r5
	bne r4, r5, fail
	li r28, 54
	li r5, 3
	li r6, 3
	bne r5, r6, fail            ; branch operands at distance 2 and 1
	li r28, 55
	li r5, 4
	beq r5, r6, fail            ; rd at distance 1
	li r28, 56
	li r6, 4
	bne r5, r6, fail            ; rs1 at distance 1
	li r28, 57
	li r5, 8
	blt r5, r6, fail
	addi r4, r5, 0              ; the branch did not write r5
	li r3, 8
	bne r4, r3, fail

	; ---- load-use: the consumer stalls and gets the loaded value
	li r28, 60
	lw r1, 0(r10)
	addi r4, r1, 1              ; distance 1
	li r3, 0x11111112
	bne r4, r3, fail
	li r28, 61
	lw r1, 0(r10)
	nop
	addi r4, r1, 1              ; distance 2
	li r3, 0x11111112
	bne r4, r3, fail
	li r28, 62
	lw r1, 0(r10)
	nop
	nop
	addi r4, r1, 1              ; distance 3
	li r3, 0x11111112
	bne r4, r3, fail
	li r28, 63
	lw r2, 4(r10)
	sub r4, r0, r2              ; into rs2
	li r3, -0x22222222
	bne r4, r3, fail
	li r28, 64
	lw r1, 0(r10)
	lw r2, 4(r10)
	add r4, r1, r2              ; two loads in a row
	li r3, 0x33333333
	bne r4, r3, fail
	li r28, 65
	lw r1, 0(r10)
	sw r1, 28(r10)              ; load -> store data
	lw r4, 28(r10)
	li r3, 0x11111111
	bne r4, r3, fail
	li r28, 66
	lw r1, 8(r10)               ; pointer chase: load -> store and load base
	lw r4, 4(r1)
	li r3, 0x33333333
	bne r4, r3, fail
	li r28, 67
	lw r1, 8(r10)
	sw r1, 4(r1)                ; the loaded pointer as base and data
	lw r4, 12(r10)
	bne r4, r1, fail
	li r28, 68
	lw r1, 0(r10)
	li r3, 0x11111111
	bne r1, r3, fail            ; load -> branch (rd)
	li r28, 69
	lw r1, 0(r10)
	bne r3, r1, fail            ; load -> branch (rs1)
	li r28, 70
	la r1, .jalr_target
	sw r1, 32(r10)
	lw r1, 32(r10)
	jalr r5, r1                 ; load -> JALR
	j fail
.jalr_target:
	li r28, 71
	lw r1, 0(r10)
	lbu r2, 0(r10)
	lw r4, 4(r10)
	add r4, r4, r1              ; load-use behind a load-use
	add r4, r4, r2
	li r3, 0x33333344
	bne r4, r3, fail
	li r28, 72
	li r1, 0x11
	lw r1, 0(r10)
	addi r4, r1, 0              ; the load, not the older LI
	li r3, 0x11111111
	bne r4, r3, fail

	; ---- other producers: LUI, AUIPC, JAL/JALR links, MFCR
	li r28, 80
	lui r1, 0x1
	addi r4, r1, 1
	li r3, 0x2001
	bne r4, r3, fail
	li r28, 81
.auipc:
	auipc r1, 0
	addi r4, r1, 8
	la r3, .auipc + 8
	bne r4, r3, fail
	li r28, 82
	jal r5, .jal_next
.jal_next:
	addi r4, r5, 0              ; the link, right behind the squashed slots
	la r3, .jal_next
	bne r4, r3, fail
	li r28, 83
	la r1, .jalr_next
	jalr r5, r1
.jalr_next:
	sub r4, r5, r1
	bnez r4, fail
	li r28, 84
	li r1, 0x5A5A
	mtcr scratch, r1            ; MTCR, then MFCR of the same register
	mfcr r2, scratch
	addi r4, r2, 1              ; MFCR result at distance 1
	li r3, 0x5A5B
	bne r4, r3, fail
	li r28, 85
	li r1, 0x6B6B
	mtcr scratch, r1            ; its source at distance 1
	mfcr r4, scratch
	bne r4, r1, fail
	j pass
