; ============================================================================
;  Video card: registers, modes, palette, the drawing engine in every depth,
;  DMA from ROM and to RAM, EXPAND from memory, errors, VBLANK, the IRQ line
; ============================================================================
; VRAM is zero at power-on. The engine's results are read back with STORE.

	.include "../common/harness.asm"

BUF             = 0x1000            ; STORE target, reached as offset(r0)
IRQ_VIDEO_BIT   = 1 << IRQ_VIDEO

test_main:
	li r10, VIDEO

	; ---- reset state
	li r28, 1
	lw r4, VIDEO_STATUS(r10)
	bnez r4, fail
	lw r4, VIDEO_CONTROL(r10)
	bnez r4, fail
	lw r4, VIDEO_MODE(r10)
	bnez r4, fail
	lw r4, VIDEO_ERROR(r10)
	bnez r4, fail
	li r28, 2                   ; MODE 0 = 320x240, 1 bpp
	lw r4, VIDEO_WIDTH(r10)
	li r3, 320
	bne r4, r3, fail
	lw r4, VIDEO_HEIGHT(r10)
	li r3, 240
	bne r4, r3, fail
	lw r4, VIDEO_BPP(r10)
	li r3, 1
	bne r4, r3, fail
	lw r4, VIDEO_PITCH(r10)
	li r3, 40
	bne r4, r3, fail
	li r28, 3
	lw r4, VIDEO_VRAM_SIZE(r10)
	li r3, VRAM_SIZE
	bne r4, r3, fail

	; ---- modes
	li r28, 4
	li r1, VIDEO_1024X768 | VIDEO_32BPP
	sw r1, VIDEO_MODE(r10)
	lw r4, VIDEO_MODE(r10)
	bne r4, r1, fail
	lw r4, VIDEO_PITCH(r10)
	li r3, 4096
	bne r4, r3, fail
	li r28, 5                   ; a bad depth is ignored
	li r2, VIDEO_640X480 | 5 << 4
	sw r2, VIDEO_MODE(r10)
	lw r4, VIDEO_MODE(r10)
	bne r4, r1, fail
	li r28, 6                   ; so are reserved bits
	li r2, VIDEO_640X480 | VIDEO_8BPP | 1 << 8
	sw r2, VIDEO_MODE(r10)
	lw r4, VIDEO_MODE(r10)
	bne r4, r1, fail
	li r28, 7
	li r1, VIDEO_800X600 | VIDEO_16BPP
	sw r1, VIDEO_MODE(r10)
	lw r4, VIDEO_WIDTH(r10)
	li r3, 800
	bne r4, r3, fail
	lw r4, VIDEO_HEIGHT(r10)
	li r3, 600
	bne r4, r3, fail
	lw r4, VIDEO_BPP(r10)
	li r3, 16
	bne r4, r3, fail
	lw r4, VIDEO_PITCH(r10)
	li r3, 1600
	bne r4, r3, fail
	li r28, 8                   ; read-only registers ignore writes
	sw r0, VIDEO_WIDTH(r10)
	lw r4, VIDEO_WIDTH(r10)
	li r3, 800
	bne r4, r3, fail

	; ---- palette
	li r28, 10
	li r1, 5
	sw r1, VIDEO_PALETTE_INDEX(r10)
	li r1, 0x12345678           ; the top byte is dropped
	sw r1, VIDEO_PALETTE_DATA(r10)
	lw r4, VIDEO_PALETTE_INDEX(r10)
	li r3, 6                    ; a write moves to the next entry
	bne r4, r3, fail
	li r28, 11
	li r1, 5
	sw r1, VIDEO_PALETTE_INDEX(r10)
	lw r4, VIDEO_PALETTE_DATA(r10)
	li r3, 0x345678
	bne r4, r3, fail
	lw r4, VIDEO_PALETTE_INDEX(r10)
	li r3, 5                    ; a read doesn't
	bne r4, r3, fail
	li r28, 12                  ; the index wraps
	li r1, 255
	sw r1, VIDEO_PALETTE_INDEX(r10)
	sw r0, VIDEO_PALETTE_DATA(r10)
	lw r4, VIDEO_PALETTE_INDEX(r10)
	bnez r4, fail

	; ---- FILL, 8 bpp: 2x2 at (1, 1) of a 16-byte pitch surface
	li r1, VIDEO_640X480 | VIDEO_8BPP
	sw r1, VIDEO_MODE(r10)
	li r28, 20
	li r1, 0x1000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 16
	sw r1, VIDEO_DST_PITCH(r10)
	li r1, 1 << 16 | 1
	sw r1, VIDEO_DST_XY(r10)
	li r1, 2 << 16 | 2
	sw r1, VIDEO_SIZE(r10)
	li r1, 0xAB
	sw r1, VIDEO_FG(r10)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_STATUS(r10)    ; done at once
	li r3, VIDEO_DONE
	bne r4, r3, fail
	lw r4, VIDEO_ERROR(r10)
	bnez r4, fail

	; ---- STORE it to RAM: 64 words, 64 ticks
	li r28, 21
	li r1, 0x1000
	li r2, 256
	call store_start
	lw r4, VIDEO_STATUS(r10)
	li r3, VIDEO_BUSY
	bne r4, r3, fail
	li r28, 22                  ; the engine ignores writes while busy
	li r1, 0x55
	sw r1, VIDEO_SIZE(r10)
	sw r1, VIDEO_ADDRESS(r10)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_SIZE(r10)
	li r3, 2 << 16 | 2
	bne r4, r3, fail
	li r28, 23
	call wait_done
	bnez r1, fail
	li r28, 24                  ; the registers point just past it
	lw r4, VIDEO_SRC_BASE(r10)
	li r3, 0x1100
	bne r4, r3, fail
	lw r4, VIDEO_ADDRESS(r10)
	li r3, BUF + 256
	bne r4, r3, fail
	lw r4, VIDEO_COUNT(r10)
	bnez r4, fail
	li r28, 25
	lw r4, BUF + 0(r0)
	bnez r4, fail
	lw r4, BUF + 16(r0)
	li r3, 0x00ABAB00
	bne r4, r3, fail
	lw r4, BUF + 32(r0)
	bne r4, r3, fail
	lw r4, BUF + 20(r0)
	bnez r4, fail

	; ---- LOAD a 1 bpp bitmap from ROM
	li r28, 30
	la r1, bitmap
	sw r1, VIDEO_ADDRESS(r10)
	li r1, 0x2000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 4
	sw r1, VIDEO_COUNT(r10)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r10)
	call wait_done
	bnez r1, fail
	li r28, 31
	lw r4, VIDEO_DST_BASE(r10)
	li r3, 0x2004
	bne r4, r3, fail

	; ---- EXPAND it: 8x2 pixels to (0, 0) of an 8-byte pitch surface
	li r28, 32
	li r1, 0x2000
	sw r1, VIDEO_SRC_BASE(r10)
	li r1, 1
	sw r1, VIDEO_SRC_PITCH(r10)
	sw r0, VIDEO_SRC_XY(r10)
	li r1, 0x3000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 8
	sw r1, VIDEO_DST_PITCH(r10)
	sw r0, VIDEO_DST_XY(r10)
	li r1, 2 << 16 | 8
	sw r1, VIDEO_SIZE(r10)
	li r1, 0x11
	sw r1, VIDEO_FG(r10)
	li r1, 0x22
	sw r1, VIDEO_BG(r10)
	li r1, VIDEO_EXPAND
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	bnez r4, fail
	li r1, 0x3000
	li r2, 16
	call store
	bnez r1, fail
	li r28, 33                  ; 0xA5 = 10100101, the first bit on the left
	lw r4, BUF + 0(r0)
	li r3, 0x22112211
	bne r4, r3, fail
	lw r4, BUF + 4(r0)
	li r3, 0x11221122
	bne r4, r3, fail
	li r28, 34                  ; 0x3C = 00111100
	lw r4, BUF + 8(r0)
	li r3, 0x11112222
	bne r4, r3, fail
	lw r4, BUF + 12(r0)
	li r3, 0x22221111
	bne r4, r3, fail

	; ---- EXPAND with TRANSPARENT: 0 bits leave the pixels alone
	li r28, 35
	li r1, 0x2000               ; STORE has moved SRC_BASE on
	sw r1, VIDEO_SRC_BASE(r10)
	li r1, 1 << 16 | 8
	sw r1, VIDEO_SIZE(r10)
	li r1, 0x33
	sw r1, VIDEO_FG(r10)
	li r1, VIDEO_EXPAND | VIDEO_TRANSPARENT
	sw r1, VIDEO_COMMAND(r10)
	li r1, 0x3000
	li r2, 8
	call store
	bnez r1, fail
	li r28, 36
	lw r4, BUF + 0(r0)
	li r3, 0x22332233
	bne r4, r3, fail
	lw r4, BUF + 4(r0)
	li r3, 0x33223322
	bne r4, r3, fail

	; ---- COPY, overlapping: 4 pixels one to the right
	li r28, 40
	li r1, 0x3000
	sw r1, VIDEO_SRC_BASE(r10)
	li r1, 8
	sw r1, VIDEO_SRC_PITCH(r10)
	sw r0, VIDEO_SRC_XY(r10)
	li r1, 1
	sw r1, VIDEO_DST_XY(r10)
	li r1, 1 << 16 | 4
	sw r1, VIDEO_SIZE(r10)
	li r1, VIDEO_COPY
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	bnez r4, fail
	li r1, 0x3000
	li r2, 8
	call store
	bnez r1, fail
	li r28, 41                  ; 33 22 33 22 22 33 22 33 -> 33 33 22 33 22 ...
	lw r4, BUF + 0(r0)
	li r3, 0x33223333
	bne r4, r3, fail
	lw r4, BUF + 4(r0)
	li r3, 0x33223322
	bne r4, r3, fail

	; ---- EXPAND from memory: the bitmap in ROM, 8x2 pixels as in 32-34
	li r28, 42
	li r1, VIDEO_640X480 | VIDEO_8BPP
	sw r1, VIDEO_MODE(r10)
	la r1, bitmap
	sw r1, VIDEO_SRC_BASE(r10)
	li r1, 1
	sw r1, VIDEO_SRC_PITCH(r10)
	sw r0, VIDEO_SRC_XY(r10)
	li r1, 0x6000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 8
	sw r1, VIDEO_DST_PITCH(r10)
	sw r0, VIDEO_DST_XY(r10)
	li r1, 2 << 16 | 8
	sw r1, VIDEO_SIZE(r10)
	li r1, 0x11
	sw r1, VIDEO_FG(r10)
	li r1, 0x22
	sw r1, VIDEO_BG(r10)
	li r1, VIDEO_EXPAND | VIDEO_MEMORY
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_STATUS(r10)    ; runs by DMA, a word per tick
	li r3, VIDEO_BUSY
	bne r4, r3, fail
	li r28, 43
	call wait_done
	bnez r1, fail
	li r1, 0x6000
	li r2, 16
	call store
	bnez r1, fail
	li r28, 44
	lw r4, BUF + 0(r0)
	li r3, 0x22112211
	bne r4, r3, fail
	lw r4, BUF + 4(r0)
	li r3, 0x11221122
	bne r4, r3, fail
	lw r4, BUF + 8(r0)
	li r3, 0x11112222
	bne r4, r3, fail
	lw r4, BUF + 12(r0)
	li r3, 0x22221111
	bne r4, r3, fail

	li r28, 45                  ; any byte and bit, across a word boundary
	la r1, bitmap + 3
	sw r1, VIDEO_SRC_BASE(r10)
	li r1, 4                    ; 0x05 0xA0 from bit 4: 0101 1010
	sw r1, VIDEO_SRC_XY(r10)
	li r1, 0x6010
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 1 << 16 | 8
	sw r1, VIDEO_SIZE(r10)
	li r1, VIDEO_EXPAND | VIDEO_MEMORY
	sw r1, VIDEO_COMMAND(r10)
	call wait_done
	bnez r1, fail
	li r1, 0x6010
	li r2, 8
	call store
	bnez r1, fail
	li r28, 46
	lw r4, BUF + 0(r0)
	li r3, 0x11221122
	bne r4, r3, fail
	lw r4, BUF + 4(r0)
	li r3, 0x22112211
	bne r4, r3, fail

	li r28, 47                  ; the source lines must fit the pitch
	la r1, bitmap
	sw r1, VIDEO_SRC_BASE(r10)
	li r1, 1
	sw r1, VIDEO_SRC_XY(r10)    ; 1 + 8 bits in a byte
	li r1, VIDEO_EXPAND | VIDEO_MEMORY
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	li r3, VIDEO_ERR_RANGE
	bne r4, r3, fail
	li r28, 48                  ; the I/O region is out of reach
	li r1, UART
	sw r1, VIDEO_SRC_BASE(r10)
	sw r0, VIDEO_SRC_XY(r10)
	li r1, VIDEO_EXPAND | VIDEO_MEMORY
	sw r1, VIDEO_COMMAND(r10)
	call wait_done
	li r3, VIDEO_ERR_ADDRESS
	bne r1, r3, fail

	; ---- pixel packing in the other depths
	li r28, 50                  ; 4 bpp: pixels 1-2 of 0x4000
	li r1, VIDEO_640X480 | VIDEO_4BPP
	sw r1, VIDEO_MODE(r10)
	li r1, 0x4000
	li r2, 1
	li r3, 2
	li r4, 0xC
	call fill_line
	bnez r1, fail
	li r28, 51                  ; 1 bpp: pixels 3-5 of 0x4004
	li r1, VIDEO_640X480 | VIDEO_1BPP
	sw r1, VIDEO_MODE(r10)
	li r1, 0x4004
	li r2, 3
	li r3, 3
	li r4, 1
	call fill_line
	bnez r1, fail
	li r28, 52                  ; 16 bpp: pixel 1 of 0x4008
	li r1, VIDEO_640X480 | VIDEO_16BPP
	sw r1, VIDEO_MODE(r10)
	li r1, 0x4008
	li r2, 1
	li r3, 1
	li r4, 0x1234
	call fill_line
	bnez r1, fail
	li r28, 53                  ; 32 bpp: pixel 0 of 0x4010
	li r1, VIDEO_640X480 | VIDEO_32BPP
	sw r1, VIDEO_MODE(r10)
	li r1, 0x4010
	li r2, 0
	li r3, 1
	li r4, 0xDEADBEEF
	call fill_line
	bnez r1, fail
	li r28, 54
	li r1, 0x4000
	li r2, 20
	call store
	bnez r1, fail
	li r28, 55
	lw r4, BUF + 0(r0)
	li r3, 0x0000C00C
	bne r4, r3, fail
	li r28, 56
	lw r4, BUF + 4(r0)
	li r3, 0x0000001C
	bne r4, r3, fail
	li r28, 57
	lw r4, BUF + 8(r0)
	li r3, 0x12340000
	bne r4, r3, fail
	li r28, 58
	lw r4, BUF + 16(r0)
	li r3, 0xDEADBEEF
	bne r4, r3, fail

	; ---- errors
	li r28, 60                  ; unknown command
	li r1, 0x77
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_STATUS(r10)
	li r3, VIDEO_DONE | VIDEO_FAILED
	bne r4, r3, fail
	lw r4, VIDEO_ERROR(r10)
	li r3, VIDEO_ERR_COMMAND
	bne r4, r3, fail
	li r28, 61                  ; a line longer than the pitch (32 bpp)
	li r1, 0x5000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 16
	sw r1, VIDEO_DST_PITCH(r10)
	sw r0, VIDEO_DST_XY(r10)
	li r1, 1 << 16 | 5
	sw r1, VIDEO_SIZE(r10)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	li r3, VIDEO_ERR_RANGE
	bne r4, r3, fail
	li r28, 62                  ; the next command clears the error
	li r1, 1 << 16 | 4
	sw r1, VIDEO_SIZE(r10)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_STATUS(r10)
	li r3, VIDEO_DONE
	bne r4, r3, fail
	li r28, 63                  ; past the end of VRAM
	li r1, VRAM_SIZE - 16
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 2 << 16 | 4
	sw r1, VIDEO_SIZE(r10)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	li r3, VIDEO_ERR_RANGE
	bne r4, r3, fail
	li r28, 64                  ; an empty rectangle is fine anywhere
	li r1, 0 << 16 | 4
	sw r1, VIDEO_SIZE(r10)
	li r1, 0x10000
	sw r1, VIDEO_DST_XY(r10)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	bnez r4, fail

	li r28, 65                  ; unaligned DMA
	li r1, BUF + 2
	sw r1, VIDEO_ADDRESS(r10)
	li r1, 0x2000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 4
	sw r1, VIDEO_COUNT(r10)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	li r3, VIDEO_ERR_ADDRESS
	bne r4, r3, fail
	li r28, 66                  ; past the end of VRAM
	li r1, BUF
	sw r1, VIDEO_ADDRESS(r10)
	li r1, VRAM_SIZE - 4
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 8
	sw r1, VIDEO_COUNT(r10)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_ERROR(r10)
	li r3, VIDEO_ERR_RANGE
	bne r4, r3, fail
	li r28, 67                  ; COUNT = 0 finishes at once without an error
	sw r0, VIDEO_COUNT(r10)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r10)
	lw r4, VIDEO_STATUS(r10)
	li r3, VIDEO_DONE
	bne r4, r3, fail
	li r28, 68                  ; LOAD from the I/O region stops at that word
	li r1, UART
	sw r1, VIDEO_ADDRESS(r10)
	li r1, 0x2000
	sw r1, VIDEO_DST_BASE(r10)
	li r1, 8
	sw r1, VIDEO_COUNT(r10)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r10)
	call wait_done
	li r3, VIDEO_ERR_ADDRESS
	bne r1, r3, fail
	lw r4, VIDEO_ADDRESS(r10)
	li r3, UART
	bne r4, r3, fail
	li r28, 69                  ; STORE reaches RAM only
	li r1, ROM_BASE
	sw r1, VIDEO_ADDRESS(r10)
	li r1, 4
	sw r1, VIDEO_COUNT(r10)
	li r1, VIDEO_STORE
	sw r1, VIDEO_COMMAND(r10)
	call wait_done
	li r3, VIDEO_ERR_ADDRESS
	bne r1, r3, fail

	; ---- DONE and the IRQ line
	li r11, PIC
	li r28, 70                  ; DONE only drives the line when enabled
	lw r4, PIC_PENDING(r11)
	andi r4, r4, IRQ_VIDEO_BIT
	bnez r4, fail
	li r28, 71
	li r1, VIDEO_DONE_IRQ
	sw r1, VIDEO_CONTROL(r10)
	lw r4, PIC_PENDING(r11)
	andi r4, r4, IRQ_VIDEO_BIT
	beqz r4, fail
	li r28, 72                  ; writing 1 to DONE clears it
	li r1, VIDEO_DONE
	sw r1, VIDEO_STATUS(r10)
	lw r4, VIDEO_STATUS(r10)
	andi r4, r4, VIDEO_DONE
	bnez r4, fail
	lw r4, PIC_PENDING(r11)
	andi r4, r4, IRQ_VIDEO_BIT
	bnez r4, fail

	; ---- VBLANK
	li r28, 80
	li r1, VIDEO_VBLANK_IRQ
	sw r1, VIDEO_CONTROL(r10)
	li r1, VIDEO_VBLANK
	sw r1, VIDEO_STATUS(r10)    ; forget earlier frames
	lw r12, VIDEO_FRAME(r10)
.vblank:
	lw r4, VIDEO_STATUS(r10)
	andi r4, r4, VIDEO_VBLANK
	beqz r4, .vblank
	li r28, 81
	lw r4, PIC_PENDING(r11)
	andi r4, r4, IRQ_VIDEO_BIT
	beqz r4, fail
	li r28, 82                  ; a frame has gone by
	lw r4, VIDEO_FRAME(r10)
	beq r4, r12, fail
	li r28, 83
	li r1, VIDEO_VBLANK
	sw r1, VIDEO_STATUS(r10)
	lw r4, VIDEO_STATUS(r10)
	andi r4, r4, VIDEO_VBLANK
	bnez r4, fail
	lw r4, PIC_PENDING(r11)
	andi r4, r4, IRQ_VIDEO_BIT
	bnez r4, fail
	sw r0, VIDEO_CONTROL(r10)

	j pass

; ---- helpers ------------------------------------------------------------------

; store_start(r1 = VRAM offset, r2 = bytes): starts a STORE to BUF
store_start:
	li r9, VIDEO
	sw r1, VIDEO_SRC_BASE(r9)
	sw r2, VIDEO_COUNT(r9)
	li r1, BUF
	sw r1, VIDEO_ADDRESS(r9)
	li r1, VIDEO_STORE
	sw r1, VIDEO_COMMAND(r9)
	ret

; store(r1 = VRAM offset, r2 = bytes) -> r1 = ERROR: STOREs to BUF and waits
store:
	addi r30, r30, -8
	sw ra, 4(r30)
	call store_start
	call wait_done
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; wait_done() -> r1 = ERROR: polls STATUS until DONE
wait_done:
	li r9, VIDEO
.wait:
	lw r1, VIDEO_STATUS(r9)
	andi r1, r1, VIDEO_DONE
	beqz r1, .wait
	lw r1, VIDEO_ERROR(r9)
	ret

; fill_line(r1 = DST_BASE, r2 = x, r3 = width, r4 = FG) -> r1 = ERROR:
; FILLs one line of a 16-byte pitch surface in the current depth
fill_line:
	li r9, VIDEO
	sw r1, VIDEO_DST_BASE(r9)
	li r1, 16
	sw r1, VIDEO_DST_PITCH(r9)
	sw r2, VIDEO_DST_XY(r9)
	li r1, 1 << 16
	or r3, r3, r1
	sw r3, VIDEO_SIZE(r9)
	sw r4, VIDEO_FG(r9)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r9)
	lw r1, VIDEO_ERROR(r9)
	ret

; ---- data -----------------------------------------------------------------

	.align 4
bitmap:
	.db 0xA5, 0x3C, 0x00, 0x05, 0xA0, 0x00, 0x00, 0x00
