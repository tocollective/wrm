; ============================================================================
;  The VRAM window: VRAM at 0xFC000000 for loads and stores of any size,
;  the same bytes the drawing engine sees, a source for LOAD; no fetches,
;  nothing past its end. The hardware cursor's registers.
; ============================================================================

	.include "../common/harness.asm"

RAM_BUF         = 0x1800            ; STORE's target, reached as offset(r0)

test_main:
	li r10, VRAM_WINDOW
	li r11, VIDEO
	li r1, VIDEO_320X240 | VIDEO_32BPP
	sw r1, VIDEO_MODE(r11)

	; ---- words, half-words and bytes, little-endian
	li r28, 1
	li r1, 0x11223344
	sw r1, 0x100(r10)
	lw r4, 0x100(r10)
	bne r4, r1, fail
	li r28, 2
	lbu r4, 0x101(r10)
	li r3, 0x33
	bne r4, r3, fail
	li r28, 3
	li r1, 0xBEEF
	sh r1, 0x102(r10)
	lw r4, 0x100(r10)
	li r3, 0xBEEF3344
	bne r4, r3, fail
	li r28, 4
	lh r4, 0x102(r10)
	li r3, 0xFFFFBEEF
	bne r4, r3, fail

	; ---- the engine sees the window's bytes: STORE to RAM
	li r28, 5
	li r1, 0x100
	sw r1, VIDEO_SRC_BASE(r11)
	li r1, RAM_BUF
	sw r1, VIDEO_ADDRESS(r11)
	li r1, 4
	sw r1, VIDEO_COUNT(r11)
	li r1, VIDEO_STORE
	sw r1, VIDEO_COMMAND(r11)
	call wait_done
	lw r4, RAM_BUF(r0)
	li r3, 0xBEEF3344
	bne r4, r3, fail

	; ---- ... and the window sees the engine's: FILL a pixel
	li r28, 6
	li r1, 0x200
	sw r1, VIDEO_DST_BASE(r11)
	li r1, 4
	sw r1, VIDEO_DST_PITCH(r11)
	sw r0, VIDEO_DST_XY(r11)
	li r1, 1 | 1 << 16
	sw r1, VIDEO_SIZE(r11)
	li r1, 0x00C0FFEE
	sw r1, VIDEO_FG(r11)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r11)
	call wait_done
	lw r4, 0x200(r10)
	li r3, 0x00C0FFEE
	bne r4, r3, fail

	; ---- LOAD takes its data from the window too
	li r28, 7
	li r1, VRAM_WINDOW + 0x200
	sw r1, VIDEO_ADDRESS(r11)
	li r1, 0x300
	sw r1, VIDEO_DST_BASE(r11)
	li r1, 4
	sw r1, VIDEO_COUNT(r11)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r11)
	call wait_done
	lw r4, 0x300(r10)
	li r3, 0x00C0FFEE
	bne r4, r3, fail

	; ---- the last word, and nothing after it
	li r28, 8
	li r12, VRAM_WINDOW + VRAM_SIZE - 4
	li r1, 0x5A5A5A5A
	sw r1, 0(r12)
	lw r4, 0(r12)
	bne r4, r1, fail

	la r1, trap_record
	mtcr ivec, r1
	mtcr status, r0                 ; clear reset EXL
	li r24, 0
	li r25, 0
	li r28, 9
.past:
	lw r4, 4(r12)                   ; VRAM_WINDOW + VRAM_SIZE
	li r1, 6                        ; load bus error
	la r2, .past
	call check_trap

	; ---- code doesn't run from it
	li r28, 10
	li r1, 0x00000001               ; NOP
	sw r1, 0x400(r10)
	li r1, 0x00000061 | 31 << 13    ; JALR r0, r31, 0: back
	sw r1, 0x404(r10)
	la r25, .fetched
	addi r12, r10, 0x400
	jalr ra, r12
	j fail
.fetched:
	li r1, 5                        ; fetch bus error
	mv r2, r12
	call check_trap

	; ---- the cursor's registers: zero after reset, the bits that exist
	li r28, 11
	lw r4, VIDEO_CURSOR_CONTROL(r11)
	bnez r4, fail
	lw r4, VIDEO_CURSOR_BASE(r11)
	bnez r4, fail
	lw r4, VIDEO_CURSOR_XY(r11)
	bnez r4, fail
	lw r4, VIDEO_CURSOR_HOT(r11)
	bnez r4, fail
	li r28, 12
	li r1, -1
	sw r1, VIDEO_CURSOR_CONTROL(r11)
	sw r1, VIDEO_CURSOR_BASE(r11)
	sw r1, VIDEO_CURSOR_XY(r11)
	sw r1, VIDEO_CURSOR_HOT(r11)
	lw r4, VIDEO_CURSOR_CONTROL(r11)
	li r3, VIDEO_CURSOR_SHOWN
	bne r4, r3, fail
	li r28, 13
	lw r4, VIDEO_CURSOR_BASE(r11)
	li r3, VRAM_SIZE - 4
	bne r4, r3, fail
	li r28, 14
	lw r4, VIDEO_CURSOR_XY(r11)     ; signed: -1, -1
	bne r4, r1, fail
	li r28, 15
	lw r4, VIDEO_CURSOR_HOT(r11)
	li r3, 63 | 63 << 16
	bne r4, r3, fail

	; ---- the cursor only shows: VRAM is left alone
	li r28, 16
	sw r0, VIDEO_CURSOR_BASE(r11)
	sw r0, VIDEO_CURSOR_XY(r11)
	sw r0, VIDEO_CURSOR_HOT(r11)
	li r1, VIDEO_ENABLE
	sw r1, VIDEO_CONTROL(r11)
	li r1, VIDEO_VBLANK
	sw r1, VIDEO_STATUS(r11)
.frame:
	lw r4, VIDEO_STATUS(r11)
	andi r4, r4, VIDEO_VBLANK
	beqz r4, .frame
	lw r4, 0x100(r10)
	li r3, 0xBEEF3344
	bne r4, r3, fail

	j pass

; wait_done(): waits for the engine's DONE, fails on an error
wait_done:
	lw r4, VIDEO_STATUS(r11)
	andi r3, r4, VIDEO_FAILED
	bnez r3, fail
	andi r3, r4, VIDEO_DONE
	beqz r3, wait_done
	ret

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
