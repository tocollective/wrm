; ============================================================================
;  [9] Video modes: every depth, in the four resolutions
; ============================================================================

VIDEO_SHOW_FRAMES = 120             ; 2 seconds at 60 frames a second
MODE_ENTRY_SIZE   = 16

demo_video:
	addi r30, r30, -16
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)

	la r1, s_video_title
	call puts
	li r9, KBD
	li r2, KBD_FLUSH
	sw r2, KBD_CONTROL(r9)      ; drop the releases of earlier demos

	la r10, video_modes
.next:
	lw r11, 0(r10)              ; MODE
	li r2, -1
	beq r11, r2, .done
	lw r1, 8(r10)               ; say which mode on the UART too
	call puts
	li r1, '\n'
	call putc

	mv r1, r11
	call video_screen
	lw r1, 4(r10)
	jalr ra, r1, 0              ; draw the picture
	lw r1, 8(r10)
	li r2, 8 << 16 | 8
	lw r3, 12(r10)
	li r4, 0                    ; black in every depth, see draw_font1
	li r5, 0
	call video_text

	li r1, VIDEO_SHOW_FRAMES
	call video_wait
	addi r10, r10, MODE_ENTRY_SIZE
	j .next

.done:
	call video_init             ; back to the console, with its palette
	la r1, s_video_done
	call con_puts
	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 16
	ret

; video_screen(r1 = MODE): sets the mode, makes the whole visible frame the
; destination surface and clears it to 0
video_screen:
	li r9, VIDEO
	sw r1, VIDEO_MODE(r9)
	sw r0, VIDEO_DST_BASE(r9)
	lw r2, VIDEO_PITCH(r9)
	sw r2, VIDEO_DST_PITCH(r9)
	sw r0, VIDEO_DST_XY(r9)
	lw r2, VIDEO_WIDTH(r9)
	lw r3, VIDEO_HEIGHT(r9)
	shli r3, r3, 16
	or r2, r2, r3
	sw r2, VIDEO_SIZE(r9)
	sw r0, VIDEO_FG(r9)
	li r2, VIDEO_FILL
	sw r2, VIDEO_COMMAND(r9)
	ret

; video_wait(r1 = frames): returns after that many frames, or earlier when
; a key is pressed in the window
video_wait:
	li r9, VIDEO
	lw r2, VIDEO_FRAME(r9)
	add r2, r2, r1              ; the frame to wait for
.poll:
	li r9, KBD
	lw r3, KBD_STATUS(r9)
	andi r3, r3, KBD_READY
	beqz r3, .frame
	lw r3, KBD_DATA(r9)
	bgez r3, .done              ; bit 31 clear: pressed, not released
.frame:
	li r9, VIDEO
	lw r3, VIDEO_FRAME(r9)
	sub r3, r2, r3
	bgtz r3, .poll              ; the difference survives FRAME wrapping
.done:
	ret

; ---- pictures, drawn on the visible frame -------------------------------------

; 640x480, 8 bpp: the 256 palette entries in a 16x16 grid
draw_palette8:
	li r9, VIDEO
	li r1, 30 << 16 | 40        ; 640 / 16 by 480 / 16
	sw r1, VIDEO_SIZE(r9)
	li r6, 40
	li r7, 30
	li r8, 256
	li r2, 0                    ; entry
.cell:
	andi r3, r2, 15
	mul r3, r3, r6              ; x
	shri r4, r2, 4
	mul r4, r4, r7              ; y
	shli r4, r4, 16
	or r3, r3, r4
	sw r3, VIDEO_DST_XY(r9)
	sw r2, VIDEO_FG(r9)
	li r3, VIDEO_FILL
	sw r3, VIDEO_COMMAND(r9)
	addi r2, r2, 1
	bltu r2, r8, .cell
	ret

; 320x240, 4 bpp: the 16 colours as vertical bars
draw_bars4:
	li r9, VIDEO
	li r1, 240 << 16 | 20
	sw r1, VIDEO_SIZE(r9)
	li r8, 16
	li r2, 0                    ; colour, x = colour * 20
	li r3, 0
.bar:
	sw r3, VIDEO_DST_XY(r9)
	sw r2, VIDEO_FG(r9)
	li r4, VIDEO_FILL
	sw r4, VIDEO_COMMAND(r9)
	addi r2, r2, 1
	addi r3, r3, 20
	bltu r2, r8, .bar
	ret

; 800x600, 16 bpp: red, green and blue ramps of RGB565, 32 steps each
draw_ramps16:
	li r9, VIDEO
	li r1, 200 << 16 | 25
	sw r1, VIDEO_SIZE(r9)
	li r6, 200 << 16            ; y of the green band
	li r7, 400 << 16            ; y of the blue band
	li r8, 32
	li r2, 0                    ; step, x = step * 25
	li r3, 0
.step:
	li r5, VIDEO_FILL
	shli r4, r2, 11             ; red
	sw r3, VIDEO_DST_XY(r9)
	sw r4, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	shli r4, r2, 6              ; green: 6 bits, every other level
	or r1, r3, r6
	sw r1, VIDEO_DST_XY(r9)
	sw r4, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	or r1, r3, r7               ; blue
	sw r1, VIDEO_DST_XY(r9)
	sw r2, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	addi r2, r2, 1
	addi r3, r3, 25
	bltu r2, r8, .step
	ret

; 1024x768, 32 bpp: red, green, blue and grey ramps, 256 steps each
draw_ramps32:
	li r9, VIDEO
	li r1, 192 << 16 | 4
	sw r1, VIDEO_SIZE(r9)
	li r5, VIDEO_FILL
	li r8, 256
	li r2, 0                    ; step, x = step * 4
	li r3, 0
.step:
	shli r4, r2, 16             ; red
	sw r3, VIDEO_DST_XY(r9)
	sw r4, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	li r6, 192 << 16
	or r1, r3, r6
	shli r4, r2, 8              ; green
	sw r1, VIDEO_DST_XY(r9)
	sw r4, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	li r6, 384 << 16
	or r1, r3, r6               ; blue
	sw r1, VIDEO_DST_XY(r9)
	sw r2, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	li r6, 576 << 16
	or r1, r3, r6
	shli r4, r2, 16             ; grey
	shli r6, r2, 8
	or r4, r4, r6
	or r4, r4, r2
	sw r1, VIDEO_DST_XY(r9)
	sw r4, VIDEO_FG(r9)
	sw r5, VIDEO_COMMAND(r9)
	addi r2, r2, 1
	addi r3, r3, 4
	bltu r2, r8, .step
	ret

; 640x480, 1 bpp: the whole font on green phosphor
draw_font1:
	addi r30, r30, -16
	sw ra, 8(r30)
	sw r10, 4(r30)
	sw r11, 0(r30)
	li r9, VIDEO
	li r1, 0
	sw r1, VIDEO_PALETTE_INDEX(r9)
	sw r0, VIDEO_PALETTE_DATA(r9)   ; 0: black
	li r1, 0x33FF66
	sw r1, VIDEO_PALETTE_DATA(r9)   ; 1: green

	li r10, 0                   ; character
	li r11, 256
.glyph:
	andi r2, r10, 15            ; 16x16 cells of 24 pixels from (128, 48)
	li r3, 24
	mul r2, r2, r3
	addi r2, r2, 128
	shri r4, r10, 4
	mul r4, r4, r3
	addi r4, r4, 48
	shli r4, r4, 16
	or r2, r2, r4
	mv r1, r10
	li r3, 1
	li r4, 0
	li r5, 0
	call video_glyph
	addi r10, r10, 1
	bltu r10, r11, .glyph

	lw r11, 0(r30)
	lw r10, 4(r30)
	lw ra, 8(r30)
	addi r30, r30, 16
	ret

; ---- data -----------------------------------------------------------------

	.align 4
; MODE, picture, label, label colour; MODE = -1 ends the list
video_modes:
	.dw VIDEO_640X480 | VIDEO_8BPP, draw_palette8, s_mode8, 15
	.dw VIDEO_320X240 | VIDEO_4BPP, draw_bars4, s_mode4, 15
	.dw VIDEO_800X600 | VIDEO_16BPP, draw_ramps16, s_mode16, 0xFFFF
	.dw VIDEO_1024X768 | VIDEO_32BPP, draw_ramps32, s_mode32, 0xFFFFFF
	.dw VIDEO_640X480 | VIDEO_1BPP, draw_font1, s_mode1, 1
	.dw -1

s_video_title:  .asciz "\n[9] video: a mode every 2 seconds, a key in the WRM window skips\n"
s_mode8:        .asciz "640x480, 8 bpp: the 256-colour palette"
s_mode4:        .asciz "320x240, 4 bpp: 16 colours"
s_mode16:       .asciz "800x600, 16 bpp: RGB565"
s_mode32:       .asciz "1024x768, 32 bpp: XRGB8888"
s_mode1:        .asciz "640x480, 1 bpp: the font"
s_video_done:   .asciz "[9] video: done\n"

	.align 4
