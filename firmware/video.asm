; ============================================================================
;  Video card: setup, text and the screen console
;
;  The CPU can't reach VRAM: everything goes through the drawing engine.
;  The font (font.asm) is loaded by DMA from ROM into the end of VRAM once,
;  and a character is then one EXPAND command from there (a glyph cache,
;  as on the 2D accelerators of the 90s).
;
;  The screen console is 80x30 characters in 640x480, 8 bpp and scrolls
;  with a COPY. It is separate from the UART: puts and friends in lib.asm
;  still write to the UART only.
; ============================================================================

; video_init(): console mode, palette, font, cleared screen, display on
video_init:
	addi r30, r30, -8
	sw ra, 4(r30)
	li r9, VIDEO
	sw r0, VIDEO_CONTROL(r9)    ; display off while it is set up
	li r1, CON_MODE
	sw r1, VIDEO_MODE(r9)
	sw r0, VIDEO_START(r9)
	call video_palette
	la r1, font
	li r2, FONT_VRAM
	li r3, FONT_SIZE
	call video_load
	call con_clear
	li r9, VIDEO
	li r1, VIDEO_ENABLE
	sw r1, VIDEO_CONTROL(r9)
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; video_palette(): the 16 VGA colours, then the xterm 6x6x6 colour cube
; (16-231) and grey ramp (232-255)
video_palette:
	li r9, VIDEO
	sw r0, VIDEO_PALETTE_INDEX(r9)  ; each write to DATA moves to the next entry
	la r1, vga_colors
	li r2, 16
.base:
	lw r3, 0(r1)
	sw r3, VIDEO_PALETTE_DATA(r9)
	addi r1, r1, 4
	addi r2, r2, -1
	bnez r2, .base

	la r8, cube_levels
	li r7, 6
	li r1, 0                    ; red
.red:
	li r2, 0                    ; green
.green:
	li r3, 0                    ; blue
.blue:
	add r4, r8, r1
	lbu r4, 0(r4)
	shli r4, r4, 16
	add r5, r8, r2
	lbu r5, 0(r5)
	shli r5, r5, 8
	or r4, r4, r5
	add r5, r8, r3
	lbu r5, 0(r5)
	or r4, r4, r5
	sw r4, VIDEO_PALETTE_DATA(r9)
	addi r3, r3, 1
	bltu r3, r7, .blue
	addi r2, r2, 1
	bltu r2, r7, .green
	addi r1, r1, 1
	bltu r1, r7, .red

	li r1, 8                    ; grey level
	li r2, 24
.grey:
	shli r3, r1, 16
	shli r4, r1, 8
	or r3, r3, r4
	or r3, r3, r1
	sw r3, VIDEO_PALETTE_DATA(r9)
	addi r1, r1, 10
	addi r2, r2, -1
	bnez r2, .grey
	ret

; video_load(r1 = physical address, r2 = VRAM offset, r3 = bytes)
;   -> r1 = ERROR, 0 on success
; Copies RAM or ROM into VRAM by DMA and waits for it by polling STATUS.
video_load:
	li r9, VIDEO
	sw r1, VIDEO_ADDRESS(r9)
	sw r2, VIDEO_DST_BASE(r9)
	sw r3, VIDEO_COUNT(r9)
	li r1, VIDEO_LOAD
	sw r1, VIDEO_COMMAND(r9)
.wait:
	lw r1, VIDEO_STATUS(r9)
	andi r1, r1, VIDEO_DONE
	beqz r1, .wait
	lw r1, VIDEO_ERROR(r9)
	ret

; video_glyph(r1 = character, r2 = DST_XY, r3 = fg, r4 = bg,
;             r5 = VIDEO_TRANSPARENT or 0)
; Draws a character of the font on the destination surface, which
; DST_BASE and DST_PITCH already describe.
video_glyph:
	li r9, VIDEO
	andi r1, r1, 0xFF
	shli r1, r1, 4              ; 16 bytes per glyph
	li r6, FONT_VRAM
	add r1, r1, r6
	sw r1, VIDEO_SRC_BASE(r9)
	li r6, 1                    ; a byte per line of the glyph
	sw r6, VIDEO_SRC_PITCH(r9)
	sw r0, VIDEO_SRC_XY(r9)
	li r6, GLYPH_SIZE
	sw r6, VIDEO_SIZE(r9)
	sw r2, VIDEO_DST_XY(r9)
	sw r3, VIDEO_FG(r9)
	sw r4, VIDEO_BG(r9)
	ori r5, r5, VIDEO_EXPAND
	sw r5, VIDEO_COMMAND(r9)    ; done at once
	ret

; video_text(r1 = string, r2 = DST_XY, r3 = fg, r4 = bg, r5 = flags)
; Draws a zero-terminated string on one line, like video_glyph.
video_text:
	addi r30, r30, -24
	sw ra, 20(r30)
	sw r10, 16(r30)
	sw r11, 12(r30)
	sw r12, 8(r30)
	sw r13, 4(r30)
	sw r14, 0(r30)
	mv r10, r1
	mv r11, r2
	mv r12, r3
	mv r13, r4
	mv r14, r5
.next:
	lbu r1, 0(r10)
	beqz r1, .done
	mv r2, r11
	mv r3, r12
	mv r4, r13
	mv r5, r14
	call video_glyph
	addi r10, r10, 1
	addi r11, r11, 8            ; x is the low half of DST_XY
	j .next
.done:
	lw r14, 0(r30)
	lw r13, 4(r30)
	lw r12, 8(r30)
	lw r11, 12(r30)
	lw r10, 16(r30)
	lw ra, 20(r30)
	addi r30, r30, 24
	ret

; ---- screen console ---------------------------------------------------------

; con_clear(): clears the console and puts the cursor at the top left
con_clear:
	li r9, VIDEO
	sw r0, VIDEO_DST_BASE(r9)
	li r1, CON_PITCH
	sw r1, VIDEO_DST_PITCH(r9)
	sw r0, VIDEO_DST_XY(r9)
	li r1, CON_ROWS * 16 << 16 | CON_COLS * 8
	sw r1, VIDEO_SIZE(r9)
	li r1, CON_BG
	sw r1, VIDEO_FG(r9)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r9)
	sw r0, VAR_CON_X(r0)
	sw r0, VAR_CON_Y(r0)
	ret

; con_putc(r1 = byte): '\n' starts a new line, anything else is a glyph
con_putc:
	addi r30, r30, -8
	sw ra, 4(r30)
	li r2, '\n'
	beq r1, r2, .newline
	li r9, VIDEO
	sw r0, VIDEO_DST_BASE(r9)
	li r2, CON_PITCH
	sw r2, VIDEO_DST_PITCH(r9)
	lw r2, VAR_CON_X(r0)
	lw r3, VAR_CON_Y(r0)
	shli r2, r2, 3              ; x = column * 8
	shli r3, r3, 20             ; y = row * 16, in the high half
	or r2, r2, r3
	li r3, CON_FG
	li r4, CON_BG
	li r5, 0
	call video_glyph
	lw r2, VAR_CON_X(r0)
	addi r2, r2, 1
	sw r2, VAR_CON_X(r0)
	li r3, CON_COLS
	bltu r2, r3, .done
.newline:
	call con_newline
.done:
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; con_newline(): moves the cursor to the next line, scrolling up by a
; line at the bottom of the screen
con_newline:
	sw r0, VAR_CON_X(r0)
	lw r1, VAR_CON_Y(r0)
	addi r1, r1, 1
	li r2, CON_ROWS
	bgeu r1, r2, .scroll
	sw r1, VAR_CON_Y(r0)
	ret
.scroll:                        ; the cursor stays on the last line
	li r9, VIDEO
	sw r0, VIDEO_SRC_BASE(r9)
	sw r0, VIDEO_DST_BASE(r9)
	li r1, CON_PITCH
	sw r1, VIDEO_SRC_PITCH(r9)
	sw r1, VIDEO_DST_PITCH(r9)
	li r1, 16 << 16             ; from the second line...
	sw r1, VIDEO_SRC_XY(r9)
	sw r0, VIDEO_DST_XY(r9)     ; ...to the first
	li r1, (CON_ROWS - 1) * 16 << 16 | CON_COLS * 8
	sw r1, VIDEO_SIZE(r9)
	li r1, VIDEO_COPY
	sw r1, VIDEO_COMMAND(r9)
	li r1, (CON_ROWS - 1) * 16 << 16
	sw r1, VIDEO_DST_XY(r9)     ; then clear the last line
	li r1, 16 << 16 | CON_COLS * 8
	sw r1, VIDEO_SIZE(r9)
	li r1, CON_BG
	sw r1, VIDEO_FG(r9)
	li r1, VIDEO_FILL
	sw r1, VIDEO_COMMAND(r9)
	ret

; con_puts(r1 = zero-terminated string)
con_puts:
	addi r30, r30, -8
	sw ra, 4(r30)
	sw r10, 0(r30)
	mv r10, r1
.next:
	lbu r1, 0(r10)
	beqz r1, .done
	call con_putc
	addi r10, r10, 1
	j .next
.done:
	lw r10, 0(r30)
	lw ra, 4(r30)
	addi r30, r30, 8
	ret

; ---- data -----------------------------------------------------------------

	.align 4
vga_colors:
	.dw 0x000000, 0x0000AA, 0x00AA00, 0x00AAAA
	.dw 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA
	.dw 0x555555, 0x5555FF, 0x55FF55, 0x55FFFF
	.dw 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF
cube_levels:
	.db 0, 95, 135, 175, 215, 255

	.align 4
