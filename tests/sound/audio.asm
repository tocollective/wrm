; ============================================================================
;  Audio card: registers, a voice playing once, half way, looping, at other
;  rates and turned on at its end, DMA faults, samples in ROM, the IRQ line
;  (no sound is made headless, but the card runs the same)
; ============================================================================

	.include "../common/harness.asm"

BUF             = 0x2000            ; samples in RAM, whatever they hold
FRAME_TICKS     = 666               ; ticks per output frame at 32 MHz
TIMEOUT         = 1000000           ; cycles to wait for the card
VOICE7          = AUDIO + AUDIO_VOICE0 + 7 * AUDIO_VOICE_SIZE

test_main:
	li r10, AUDIO
	li r11, AUDIO + AUDIO_VOICE0

	; ---- reset state
	li r28, 1
	lw r4, AUDIO_STATUS(r10)
	bnez r4, fail
	lw r4, AUDIO_FAULT(r10)
	bnez r4, fail
	lw r4, AUDIO_MASTER(r10)
	bnez r4, fail
	li r28, 2
	lw r4, AUDIO_VOICES(r10)
	li r3, 8
	bne r4, r3, fail
	lw r4, AUDIO_RATE(r10)
	li r3, AUDIO_SAMPLE_RATE
	bne r4, r3, fail
	li r28, 3
	lw r4, VOICE_CONTROL(r11)
	bnez r4, fail
	lw r4, VOICE_POSITION(r11)
	bnez r4, fail
	lw r4, VOICE_RATE(r11)
	bnez r4, fail

	; ---- registers keep their bits only
	li r28, 4
	li r1, -1
	sw r1, AUDIO_MASTER(r10)
	lw r4, AUDIO_MASTER(r10)
	li r3, 0xFFFF
	bne r4, r3, fail
	sw r1, VOICE_VOLUME(r11)
	lw r4, VOICE_VOLUME(r11)
	bne r4, r3, fail
	li r28, 5
	sw r1, VOICE_RATE(r11)
	lw r4, VOICE_RATE(r11)
	li r3, 0xFFFFFF
	bne r4, r3, fail
	li r28, 6
	li r1, -2                       ; everything but on
	sw r1, VOICE_CONTROL(r11)
	lw r4, VOICE_CONTROL(r11)
	li r3, 0x3E
	bne r4, r3, fail
	sw r0, VOICE_CONTROL(r11)
	li r28, 7                       ; read-only registers ignore writes
	sw r0, AUDIO_VOICES(r10)
	sw r0, AUDIO_RATE(r10)
	lw r4, AUDIO_VOICES(r10)
	li r3, 8
	bne r4, r3, fail
	lw r4, AUDIO_RATE(r10)
	li r3, AUDIO_SAMPLE_RATE
	bne r4, r3, fail

	; ---- once through 16 frames at the card's rate: a frame per frame
	li r28, 10
	li r1, BUF
	sw r1, VOICE_ADDRESS(r11)
	li r1, 16
	sw r1, VOICE_LENGTH(r11)
	li r1, AUDIO_SAMPLE_RATE
	sw r1, VOICE_RATE(r11)
	sw r0, VOICE_POSITION(r11)
	li r1, VOICE_ON | VOICE_SIGNAL_END
	mfcr r14, cycle
	sw r1, VOICE_CONTROL(r11)
	mv r1, r11
	call wait_off
	mfcr r15, cycle
	li r28, 11                      ; it stops at LENGTH...
	lw r4, VOICE_POSITION(r11)
	li r3, 16
	bne r4, r3, fail
	li r28, 12                      ; ...and signals its end
	lw r4, AUDIO_STATUS(r10)
	li r3, 1
	bne r4, r3, fail
	lw r4, AUDIO_FAULT(r10)
	bnez r4, fail
	li r28, 13                      ; 16 frames; the first may come at once
	sub r4, r15, r14
	li r3, 15 * FRAME_TICKS
	bltu r4, r3, fail
	li r3, 17 * FRAME_TICKS
	bgeu r4, r3, fail
	li r28, 14                      ; the line is up while STATUS isn't 0
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_AUDIO
	and r4, r4, r3
	beqz r4, fail
	li r28, 15                      ; writing 1 clears the bit, the line drops
	li r1, 1
	sw r1, AUDIO_STATUS(r10)
	lw r4, AUDIO_STATUS(r10)
	bnez r4, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_AUDIO
	and r4, r4, r3
	bnez r4, fail

	; ---- the half way signal
	li r28, 20
	sw r0, VOICE_POSITION(r11)
	li r1, VOICE_ON | VOICE_SIGNAL_HALF
	sw r1, VOICE_CONTROL(r11)
	li r2, 1
	call wait_status
	li r28, 21                      ; just at LENGTH / 2
	lw r4, VOICE_POSITION(r11)
	li r3, 8
	bltu r4, r3, fail
	li r3, 10
	bgeu r4, r3, fail
	li r28, 22                      ; the end doesn't signal without bit 4
	li r1, 1
	sw r1, AUDIO_STATUS(r10)
	mv r1, r11
	call wait_off
	lw r4, AUDIO_STATUS(r10)
	bnez r4, fail

	; ---- a loop: frames 4-7 over and over, signalled at every turn
	li r28, 30
	li r1, 4
	sw r1, VOICE_LOOP(r11)
	li r1, 8
	sw r1, VOICE_LENGTH(r11)
	sw r0, VOICE_POSITION(r11)
	li r1, VOICE_ON | VOICE_LOOPED | VOICE_SIGNAL_END
	sw r1, VOICE_CONTROL(r11)
	li r2, 1
	call wait_status
	li r28, 31                      ; back at LOOP...
	lw r4, VOICE_POSITION(r11)
	li r3, 4
	bltu r4, r3, fail
	li r3, 6
	bgeu r4, r3, fail
	li r28, 32                      ; ...and still on
	lw r4, VOICE_CONTROL(r11)
	andi r4, r4, VOICE_ON
	beqz r4, fail
	li r28, 33                      ; the next turn
	li r1, 1
	sw r1, AUDIO_STATUS(r10)
	li r2, 1
	call wait_status
	lw r4, VOICE_POSITION(r11)
	li r3, 4
	bltu r4, r3, fail
	li r3, 6
	bgeu r4, r3, fail
	sw r0, VOICE_CONTROL(r11)
	li r1, 1
	sw r1, AUDIO_STATUS(r10)

	; ---- twice the rate: frames 0, 2, 4, 6, and it stops at LENGTH
	li r28, 40
	li r1, 7
	sw r1, VOICE_LENGTH(r11)
	li r1, AUDIO_SAMPLE_RATE * 2
	sw r1, VOICE_RATE(r11)
	sw r0, VOICE_POSITION(r11)
	li r1, VOICE_ON
	sw r1, VOICE_CONTROL(r11)
	mv r1, r11
	call wait_off
	lw r4, VOICE_POSITION(r11)
	li r3, 7
	bne r4, r3, fail
	li r28, 41                      ; rate 0 holds the frame
	sw r0, VOICE_RATE(r11)
	li r1, 3
	sw r1, VOICE_POSITION(r11)
	li r1, VOICE_ON
	sw r1, VOICE_CONTROL(r11)
	li r1, 5 * FRAME_TICKS
	call delay
	lw r4, VOICE_POSITION(r11)
	li r3, 3
	bne r4, r3, fail
	lw r4, VOICE_CONTROL(r11)
	li r3, VOICE_ON
	bne r4, r3, fail
	sw r0, VOICE_CONTROL(r11)

	; ---- turned on at its end: the end comes before anything plays
	li r28, 50
	li r1, AUDIO_SAMPLE_RATE
	sw r1, VOICE_RATE(r11)
	li r1, 4
	sw r1, VOICE_LENGTH(r11)
	sw r1, VOICE_POSITION(r11)
	li r1, VOICE_ON | VOICE_SIGNAL_END
	sw r1, VOICE_CONTROL(r11)
	li r2, 1
	call wait_status
	li r28, 51
	lw r4, VOICE_CONTROL(r11)
	li r3, VOICE_SIGNAL_END
	bne r4, r3, fail
	lw r4, VOICE_POSITION(r11)
	li r3, 4
	bne r4, r3, fail
	li r1, 1
	sw r1, AUDIO_STATUS(r10)

	; ---- a sample outside memory stops the voice with a fault, no signal
	li r28, 60
	li r1, 0xF0000000               ; unmapped
	sw r1, VOICE_ADDRESS(r11)
	sw r0, VOICE_POSITION(r11)
	li r1, VOICE_ON | VOICE_SIGNAL_END
	sw r1, VOICE_CONTROL(r11)
	mv r1, r11
	call wait_off
	li r28, 61
	lw r4, AUDIO_FAULT(r10)
	li r3, 1
	bne r4, r3, fail
	lw r4, AUDIO_STATUS(r10)
	bnez r4, fail
	li r28, 62                      ; writing 1 clears FAULT
	li r1, 1
	sw r1, AUDIO_FAULT(r10)
	lw r4, AUDIO_FAULT(r10)
	bnez r4, fail
	li r28, 63                      ; so does a 16-bit value at an odd address
	li r1, BUF + 1
	sw r1, VOICE_ADDRESS(r11)
	li r1, VOICE_ON | VOICE_16BIT
	sw r1, VOICE_CONTROL(r11)
	mv r1, r11
	call wait_off
	lw r4, AUDIO_FAULT(r10)
	li r3, 1
	bne r4, r3, fail
	li r1, 1
	sw r1, AUDIO_FAULT(r10)
	li r28, 64                      ; and the I/O region
	li r1, AUDIO
	sw r1, VOICE_ADDRESS(r11)
	li r1, VOICE_ON
	sw r1, VOICE_CONTROL(r11)
	mv r1, r11
	call wait_off
	lw r4, AUDIO_FAULT(r10)
	li r3, 1
	bne r4, r3, fail
	li r1, 1
	sw r1, AUDIO_FAULT(r10)

	; ---- ROM is fine: 16-bit stereo frames of this very code
	li r28, 70
	li r1, ROM_BASE
	sw r1, VOICE_ADDRESS(r11)
	sw r0, VOICE_POSITION(r11)
	li r1, VOICE_ON | VOICE_16BIT | VOICE_STEREO
	sw r1, VOICE_CONTROL(r11)
	mv r1, r11
	call wait_off
	lw r4, AUDIO_FAULT(r10)
	bnez r4, fail
	lw r4, VOICE_POSITION(r11)
	li r3, 4
	bne r4, r3, fail

	; ---- the last voice has its own STATUS bit
	li r28, 80
	li r12, VOICE7
	li r1, BUF
	sw r1, VOICE_ADDRESS(r12)
	li r1, 2
	sw r1, VOICE_LENGTH(r12)
	li r1, AUDIO_SAMPLE_RATE
	sw r1, VOICE_RATE(r12)
	li r1, VOICE_ON | VOICE_SIGNAL_END
	sw r1, VOICE_CONTROL(r12)
	li r2, 1 << 7
	call wait_status
	lw r4, AUDIO_STATUS(r10)
	li r3, 1 << 7
	bne r4, r3, fail
	li r28, 81
	sw r3, AUDIO_STATUS(r10)
	lw r4, AUDIO_STATUS(r10)
	bnez r4, fail

	j pass

; wait_off(r1 = voice): returns once the voice has turned off; fails after
; TIMEOUT cycles
wait_off:
	mfcr r16, cycle
.loop:
	lw r4, VOICE_CONTROL(r1)
	andi r4, r4, VOICE_ON
	beqz r4, .done
	mfcr r17, cycle
	sub r17, r17, r16
	li r3, TIMEOUT
	bltu r17, r3, .loop
	j fail
.done:
	ret

; wait_status(r2 = bits): returns once one of the bits is set in STATUS;
; fails after TIMEOUT cycles
wait_status:
	mfcr r16, cycle
.loop:
	lw r4, AUDIO_STATUS(r10)
	and r4, r4, r2
	bnez r4, .done
	mfcr r17, cycle
	sub r17, r17, r16
	li r3, TIMEOUT
	bltu r17, r3, .loop
	j fail
.done:
	ret

; delay(r1 = cycles)
delay:
	mfcr r16, cycle
.loop:
	mfcr r17, cycle
	sub r17, r17, r16
	bltu r17, r1, .loop
	ret
