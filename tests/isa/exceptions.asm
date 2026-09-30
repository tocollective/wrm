; ============================================================================
;  Exceptions: every fault cause, CAUSE, EPC, BADADDR, STATUS and IRET
; ============================================================================
; trap_record (see the harness) records each trap and skips the faulting
; instruction, or returns to r25. MTCR STATUS clears EXL, so faults are
; handled; nothing raises an interrupt here (the PIC ENABLE mask is 0).

	.include "../common/harness.asm"

DATA            = 0x1000
NO_RAM          = 0x00100000        ; right after the 1MB of RAM
NO_DEVICE       = 0xFD0FF000        ; an unused page of the I/O region

test_main:
	la r1, trap_record
	mtcr ivec, r1
	li r1, STATUS_IE
	mtcr status, r1
	li r24, 0
	li r25, 0
	li r10, DATA
	li r1, 0x11223344
	sw r1, 0(r10)

	; ---- illegal instruction: unknown opcodes
	li r28, 1
.ill:
	.dw 0x123456FF
	li r1, 1
	la r2, .ill
	li r3, 0x123456FF
	call check_trap
	li r28, 2
	mfcr r4, status             ; the handler got IE = 0, PIE = 1, EXL = 1
	li r3, STATUS_IE | 2
	bne r4, r3, fail            ; IRET restored IE, PIE stays, EXL cleared
	li r3, STATUS_EXL | 2
	bne r23, r3, fail

	; every opcode that is not in the instruction set, one by one
	li r28, 100
	la r10, illegal_opcodes
	la r11, illegal_opcodes_end
.opcode:
	addi r28, r28, 1
	jalr ra, r10                ; each entry is the word and a RET
	li r1, 1
	mv r2, r10
	lw r3, 0(r10)
	call check_trap
	addi r10, r10, 8
	bltu r10, r11, .opcode
	li r10, DATA

	; ---- illegal instruction: control registers that don't exist or are
	; read-only
	li r28, 10
.cr11:
	.dw 0x002C0104              ; mfcr r1, cr11
	li r1, 1
	la r2, .cr11
	li r3, 0x002C0104
	call check_trap
	li r28, 11
.crneg:
	.dw 0xFFFC0104              ; mfcr r1, cr0x3FFF (imm14 = -1)
	li r1, 1
	la r2, .crneg
	li r3, 0xFFFC0104
	call check_trap
	li r28, 12
.cycle:
	.dw 0x001C0005              ; mtcr cycle, r0
	li r1, 1
	la r2, .cycle
	li r3, 0x001C0005
	call check_trap
	li r28, 13
.instreth:
	.dw 0x00280005              ; mtcr instreth, r0
	li r1, 1
	la r2, .instreth
	li r3, 0x00280005
	call check_trap
	li r28, 14
.mtcr11:
	.dw 0x002C0005              ; mtcr cr11, r0
	li r1, 1
	la r2, .mtcr11
	li r3, 0x002C0005
	call check_trap

	; ---- misaligned loads: rd is not written
	li r28, 20
	li r5, 0x5555
.lw1:
	lw r5, 1(r10)
	li r1, 3
	la r2, .lw1
	addi r3, r10, 1
	call check_trap
	li r3, 0x5555
	bne r5, r3, fail
	li r28, 21
.lw2:
	lw r5, 2(r10)
	li r1, 3
	la r2, .lw2
	addi r3, r10, 2
	call check_trap
	li r28, 22
.lw3:
	lw r5, 3(r10)
	li r1, 3
	la r2, .lw3
	addi r3, r10, 3
	call check_trap
	li r28, 23
.lh1:
	lh r5, 1(r10)
	li r1, 3
	la r2, .lh1
	addi r3, r10, 1
	call check_trap
	li r28, 24
.lhu3:
	lhu r5, 3(r10)
	li r1, 3
	la r2, .lhu3
	addi r3, r10, 3
	call check_trap
	li r3, 0x5555
	bne r5, r3, fail
	li r28, 25
	lbu r5, 3(r10)              ; bytes are never misaligned
	li r3, 0x11
	bne r5, r3, fail
	bnez r24, fail

	; ---- misaligned stores: memory is not written
	li r28, 30
	li r5, -1
.sw2:
	sw r5, 2(r10)
	li r1, 4
	la r2, .sw2
	addi r3, r10, 2
	call check_trap
	li r28, 31
.sh1:
	sh r5, 1(r10)
	li r1, 4
	la r2, .sh1
	addi r3, r10, 1
	call check_trap
	li r28, 32
.sw1:
	sw r5, 1(r10)
	li r1, 4
	la r2, .sw1
	addi r3, r10, 1
	call check_trap
	li r28, 33
	lw r4, 0(r10)
	li r3, 0x11223344
	bne r4, r3, fail
	lw r4, 4(r10)
	bnez r4, fail

	; ---- load bus errors: unmapped physical addresses
	li r28, 40
	li r11, NO_RAM
	li r5, 0x5555
.ld_noram:
	lw r5, 0(r11)
	li r1, 6
	la r2, .ld_noram
	li r3, NO_RAM
	call check_trap
	li r3, 0x5555
	bne r5, r3, fail
	li r28, 41
	lw r4, -4(r11)              ; the last word of RAM is fine
	bnez r24, fail
	li r28, 42
	li r11, 0x80000000
.ld_hole:
	lb r5, 5(r11)
	li r1, 6
	la r2, .ld_hole
	li r3, 0x80000005
	call check_trap
	li r28, 43
	li r11, NO_DEVICE
.ld_nodev:
	lw r5, 8(r11)
	li r1, 6
	la r2, .ld_nodev
	li r3, NO_DEVICE + 8
	call check_trap
	li r28, 44
	li r11, PIC
.ld_ioalign:
	lhu r5, 2(r11)              ; device registers need a multiple of 4
	li r1, 6
	la r2, .ld_ioalign
	li r3, PIC + 2
	call check_trap
	li r28, 45
	li r11, 0xFFFFFFFC
	lw r5, 0(r11)               ; the last word of ROM exists
	bnez r24, fail

	; ---- store bus errors: ROM and unmapped addresses
	li r28, 50
	la r11, rom_word
.st_rom:
	sw r0, 0(r11)
	li r1, 7
	la r2, .st_rom
	la r3, rom_word
	call check_trap
	li r28, 51
.sb_rom:
	sb r0, 1(r11)
	li r1, 7
	la r2, .sb_rom
	la r3, rom_word + 1
	call check_trap
	li r28, 52
	lw r4, 0(r11)
	li r3, 0xCAFEF00D
	bne r4, r3, fail
	li r28, 53
	li r11, NO_RAM
.st_noram:
	sh r0, 2(r11)
	li r1, 7
	la r2, .st_noram
	li r3, NO_RAM + 2
	call check_trap
	li r28, 54
	li r11, NO_DEVICE
.st_nodev:
	sw r0, 0(r11)
	li r1, 7
	la r2, .st_nodev
	li r3, NO_DEVICE
	call check_trap

	; ---- fetch bus error: EPC = BADADDR = the target
	li r28, 60
	la r25, .fetch_back
	li r11, NO_RAM
	jalr ra, r11
	j fail
.fetch_back:
	li r1, 5
	li r2, NO_RAM
	li r3, NO_RAM
	call check_trap
	li r28, 61
	la r25, .fetch_back2
	li r11, 0x80000000
	jr r11
	j fail
.fetch_back2:
	li r1, 5
	li r2, 0x80000000
	li r3, 0x80000000
	call check_trap
	li r28, 62                  ; code never runs from the I/O region, even
	la r25, .fetch_back3        ; from a device's page
	li r11, PIC
	jr r11
	j fail
.fetch_back3:
	li r1, 5
	li r2, PIC
	li r3, PIC
	call check_trap

	; ---- misaligned fetch: IRET to an address that is not a multiple of 4
	li r28, 70
	la r25, .misfetch_back
	li r1, STATUS_IE | 2        ; IE and PIE: IRET keeps IE set
	mtcr status, r1
	la r11, .misfetch + 2
	mtcr epc, r11
	iret
	j fail
.misfetch:
	j fail
.misfetch_back:
	li r1, 2
	la r2, .misfetch + 2
	la r3, .misfetch + 2
	call check_trap

	; ---- SYSCALL: BADADDR = 0, EPC = the SYSCALL
	li r28, 80
	li r1, -1
	mtcr badaddr, r1
.syscall:
	syscall
	li r1, CAUSE_SYSCALL
	la r2, .syscall
	li r3, 0
	call check_trap
	li r28, 81
	li r3, STATUS_EXL | 2       ; STATUS in the handler: PIE and EXL
	bne r23, r3, fail

	; ---- the handler can return anywhere by writing EPC
	li r28, 90
	la r25, .elsewhere
.ill2:
	.dw 0x000000FF
	j fail
.elsewhere:
	li r1, 1
	la r2, .ill2
	li r3, 0xFF
	call check_trap

	; ---- IE only masks interrupts: a supervisor fault with IE clear is
	; handled too
	li r28, 95
	mtcr status, r0
.ill3:
	.dw 0x000000FF
	li r1, 1
	la r2, .ill3
	li r3, 0xFF
	call check_trap
	li r28, 96
	li r3, STATUS_EXL           ; STATUS in the handler: EXL only
	bne r23, r3, fail
	li r28, 97
	mfcr r4, status             ; IRET cleared EXL, IE stays clear
	bnez r4, fail
	j pass

; check_trap(r1 = CAUSE, r2 = EPC, r3 = BADADDR): exactly one trap was
; recorded since the last check and it matches; r4 = the mismatching value
check_trap:
	li r4, 1
	bne r24, r4, .count
	mv r4, r20
	bne r4, r1, fail
	mv r4, r21
	bne r4, r2, fail
	mv r4, r22
	bne r4, r3, fail
	li r24, 0
	ret
.count:
	mv r4, r24
	j fail

rom_word:
	.dw 0xCAFEF00D

; every opcode that is not in the instruction set, with reserved bits set;
; each is followed by a RET
illegal_opcodes:
	.dw 0x5A5A5A08
	ret
	.dw 0x5A5A5A09
	ret
	.dw 0x5A5A5A0A
	ret
	.dw 0x5A5A5A0B
	ret
	.dw 0x5A5A5A0C
	ret
	.dw 0x5A5A5A0D
	ret
	.dw 0x5A5A5A0E
	ret
	.dw 0x5A5A5A0F
	ret
	.dw 0x5A5A5A1F
	ret
	.dw 0x5A5A5A21
	ret
	.dw 0x5A5A5A2A
	ret
	.dw 0x5A5A5A2B
	ret
	.dw 0x5A5A5A2C
	ret
	.dw 0x5A5A5A2D
	ret
	.dw 0x5A5A5A2E
	ret
	.dw 0x5A5A5A2F
	ret
	.dw 0x5A5A5A32
	ret
	.dw 0x5A5A5A33
	ret
	.dw 0x5A5A5A34
	ret
	.dw 0x5A5A5A35
	ret
	.dw 0x5A5A5A36
	ret
	.dw 0x5A5A5A37
	ret
	.dw 0x5A5A5A38
	ret
	.dw 0x5A5A5A39
	ret
	.dw 0x5A5A5A3A
	ret
	.dw 0x5A5A5A3B
	ret
	.dw 0x5A5A5A3C
	ret
	.dw 0x5A5A5A3D
	ret
	.dw 0x5A5A5A3E
	ret
	.dw 0x5A5A5A3F
	ret
	.dw 0x5A5A5A45
	ret
	.dw 0x5A5A5A46
	ret
	.dw 0x5A5A5A47
	ret
	.dw 0x5A5A5A4B
	ret
	.dw 0x5A5A5A4C
	ret
	.dw 0x5A5A5A4D
	ret
	.dw 0x5A5A5A4E
	ret
	.dw 0x5A5A5A4F
	ret
	.dw 0x5A5A5A56
	ret
	.dw 0x5A5A5A57
	ret
	.dw 0x5A5A5A58
	ret
	.dw 0x5A5A5A59
	ret
	.dw 0x5A5A5A5A
	ret
	.dw 0x5A5A5A5B
	ret
	.dw 0x5A5A5A5C
	ret
	.dw 0x5A5A5A5D
	ret
	.dw 0x5A5A5A5E
	ret
	.dw 0x5A5A5A5F
	ret
	.dw 0x5A5A5A62
	ret
	.dw 0x5A5A5A63
	ret
	.dw 0x5A5A5A64
	ret
	.dw 0x5A5A5A65
	ret
	.dw 0x5A5A5A66
	ret
	.dw 0x5A5A5A67
	ret
	.dw 0x5A5A5A68
	ret
	.dw 0x5A5A5A69
	ret
	.dw 0x5A5A5A6A
	ret
	.dw 0x5A5A5A6B
	ret
	.dw 0x5A5A5A6C
	ret
	.dw 0x5A5A5A6D
	ret
	.dw 0x5A5A5A6E
	ret
	.dw 0x5A5A5A6F
	ret
	.dw 0x5A5A5A70
	ret
	.dw 0x5A5A5A71
	ret
	.dw 0x5A5A5A72
	ret
	.dw 0x5A5A5A73
	ret
	.dw 0x5A5A5A74
	ret
	.dw 0x5A5A5A75
	ret
	.dw 0x5A5A5A76
	ret
	.dw 0x5A5A5A77
	ret
	.dw 0x5A5A5A78
	ret
	.dw 0x5A5A5A79
	ret
	.dw 0x5A5A5A7A
	ret
	.dw 0x5A5A5A7B
	ret
	.dw 0x5A5A5A7C
	ret
	.dw 0x5A5A5A7D
	ret
	.dw 0x5A5A5A7E
	ret
	.dw 0x5A5A5A7F
	ret
	.dw 0x5A5A5A80
	ret
	.dw 0x5A5A5A81
	ret
	.dw 0x5A5A5A82
	ret
	.dw 0x5A5A5A83
	ret
	.dw 0x5A5A5A84
	ret
	.dw 0x5A5A5A85
	ret
	.dw 0x5A5A5A86
	ret
	.dw 0x5A5A5A87
	ret
	.dw 0x5A5A5A88
	ret
	.dw 0x5A5A5A89
	ret
	.dw 0x5A5A5A8A
	ret
	.dw 0x5A5A5A8B
	ret
	.dw 0x5A5A5A8C
	ret
	.dw 0x5A5A5A8D
	ret
	.dw 0x5A5A5A8E
	ret
	.dw 0x5A5A5A8F
	ret
	.dw 0x5A5A5A90
	ret
	.dw 0x5A5A5A91
	ret
	.dw 0x5A5A5A92
	ret
	.dw 0x5A5A5A93
	ret
	.dw 0x5A5A5A94
	ret
	.dw 0x5A5A5A95
	ret
	.dw 0x5A5A5A96
	ret
	.dw 0x5A5A5A97
	ret
	.dw 0x5A5A5A98
	ret
	.dw 0x5A5A5A99
	ret
	.dw 0x5A5A5A9A
	ret
	.dw 0x5A5A5A9B
	ret
	.dw 0x5A5A5A9C
	ret
	.dw 0x5A5A5A9D
	ret
	.dw 0x5A5A5A9E
	ret
	.dw 0x5A5A5A9F
	ret
	.dw 0x5A5A5AA0
	ret
	.dw 0x5A5A5AA1
	ret
	.dw 0x5A5A5AA2
	ret
	.dw 0x5A5A5AA3
	ret
	.dw 0x5A5A5AA4
	ret
	.dw 0x5A5A5AA5
	ret
	.dw 0x5A5A5AA6
	ret
	.dw 0x5A5A5AA7
	ret
	.dw 0x5A5A5AA8
	ret
	.dw 0x5A5A5AA9
	ret
	.dw 0x5A5A5AAA
	ret
	.dw 0x5A5A5AAB
	ret
	.dw 0x5A5A5AAC
	ret
	.dw 0x5A5A5AAD
	ret
	.dw 0x5A5A5AAE
	ret
	.dw 0x5A5A5AAF
	ret
	.dw 0x5A5A5AB0
	ret
	.dw 0x5A5A5AB1
	ret
	.dw 0x5A5A5AB2
	ret
	.dw 0x5A5A5AB3
	ret
	.dw 0x5A5A5AB4
	ret
	.dw 0x5A5A5AB5
	ret
	.dw 0x5A5A5AB6
	ret
	.dw 0x5A5A5AB7
	ret
	.dw 0x5A5A5AB8
	ret
	.dw 0x5A5A5AB9
	ret
	.dw 0x5A5A5ABA
	ret
	.dw 0x5A5A5ABB
	ret
	.dw 0x5A5A5ABC
	ret
	.dw 0x5A5A5ABD
	ret
	.dw 0x5A5A5ABE
	ret
	.dw 0x5A5A5ABF
	ret
	.dw 0x5A5A5AC0
	ret
	.dw 0x5A5A5AC1
	ret
	.dw 0x5A5A5AC2
	ret
	.dw 0x5A5A5AC3
	ret
	.dw 0x5A5A5AC4
	ret
	.dw 0x5A5A5AC5
	ret
	.dw 0x5A5A5AC6
	ret
	.dw 0x5A5A5AC7
	ret
	.dw 0x5A5A5AC8
	ret
	.dw 0x5A5A5AC9
	ret
	.dw 0x5A5A5ACA
	ret
	.dw 0x5A5A5ACB
	ret
	.dw 0x5A5A5ACC
	ret
	.dw 0x5A5A5ACD
	ret
	.dw 0x5A5A5ACE
	ret
	.dw 0x5A5A5ACF
	ret
	.dw 0x5A5A5AD0
	ret
	.dw 0x5A5A5AD1
	ret
	.dw 0x5A5A5AD2
	ret
	.dw 0x5A5A5AD3
	ret
	.dw 0x5A5A5AD4
	ret
	.dw 0x5A5A5AD5
	ret
	.dw 0x5A5A5AD6
	ret
	.dw 0x5A5A5AD7
	ret
	.dw 0x5A5A5AD8
	ret
	.dw 0x5A5A5AD9
	ret
	.dw 0x5A5A5ADA
	ret
	.dw 0x5A5A5ADB
	ret
	.dw 0x5A5A5ADC
	ret
	.dw 0x5A5A5ADD
	ret
	.dw 0x5A5A5ADE
	ret
	.dw 0x5A5A5ADF
	ret
	.dw 0x5A5A5AE0
	ret
	.dw 0x5A5A5AE1
	ret
	.dw 0x5A5A5AE2
	ret
	.dw 0x5A5A5AE3
	ret
	.dw 0x5A5A5AE4
	ret
	.dw 0x5A5A5AE5
	ret
	.dw 0x5A5A5AE6
	ret
	.dw 0x5A5A5AE7
	ret
	.dw 0x5A5A5AE8
	ret
	.dw 0x5A5A5AE9
	ret
	.dw 0x5A5A5AEA
	ret
	.dw 0x5A5A5AEB
	ret
	.dw 0x5A5A5AEC
	ret
	.dw 0x5A5A5AED
	ret
	.dw 0x5A5A5AEE
	ret
	.dw 0x5A5A5AEF
	ret
	.dw 0x5A5A5AF0
	ret
	.dw 0x5A5A5AF1
	ret
	.dw 0x5A5A5AF2
	ret
	.dw 0x5A5A5AF3
	ret
	.dw 0x5A5A5AF4
	ret
	.dw 0x5A5A5AF5
	ret
	.dw 0x5A5A5AF6
	ret
	.dw 0x5A5A5AF7
	ret
	.dw 0x5A5A5AF8
	ret
	.dw 0x5A5A5AF9
	ret
	.dw 0x5A5A5AFA
	ret
	.dw 0x5A5A5AFB
	ret
	.dw 0x5A5A5AFC
	ret
	.dw 0x5A5A5AFD
	ret
	.dw 0x5A5A5AFE
	ret
	.dw 0x5A5A5AFF
	ret
illegal_opcodes_end:
