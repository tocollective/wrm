; ============================================================================
;  WRM.081632 demo firmware
;
;  Boots from the floppy or disk 0 if one holds a boot image (--floppy,
;  --hdd, see docs/SPECIFICATION.md#boot-protocol); otherwise runs the
;  demos.
;
;  A tour of the machine: every instruction group, the UART, the keyboard,
;  the PIC, polling, WFI, interrupts, the MMU and user mode, the timer and
;  the cycle counters, the video modes, power off, plus most assembler
;  features (constants, local labels, expressions, pseudo-instructions,
;  directives). The demos' output goes to the UART, i.e. to the host's
;  stdout; the screen shows a short banner and the video modes.
;
;  Build:  python3 tools/asm.py firmware/main.asm -o firmware.rom
;
;  Files:
;    main.asm         reset, the order of the demos, image trailer
;    defs.asm         hardware constants and the RAM layout
;    boot.asm         boot from the floppy or disk 0
;    demos/*.asm      one demo each, with its own strings and data
;    lib.asm          UART output and helpers (puts, show, memcpy, ...)
;    video.asm        video card setup, text, the screen console
;    font.asm         the 8x16 font, loaded into VRAM by video_init
;
;  Register conventions: the ABI (docs/ABI.md), in short
;    r1-r8     arguments, r1 = return value
;    r1-r9     scratch, clobbered by every call
;    r10-r27   preserved across calls
;    r28 (tp)  thread pointer, unused by the firmware
;    r29 (fp)  preserved across calls
;    r30       stack pointer, grows down (the demos keep it only word
;              aligned, the ABI wants 8 bytes)
;    r31 (ra)  return address, written by JAL/CALL, used by RET
; ============================================================================

	.include "defs.asm"

; ============================================================================
;  Reset
; ============================================================================

	.org ROM_BASE               ; pc = 0xFE000000 after reset
reset:
	nop
	li r30, STACK_TOP           ; low 13 bits are zero: a single LUI
	sw r0, VAR_IRQ_COUNT(r0)
	sw r0, VAR_KEY_COUNT(r0)
	sw r0, VAR_QUIT(r0)
	li r1, UART
	li r2, UART_FLUSH
	sw r2, UART_CONTROL(r1)     ; drop anything received before reset
	call post_beep
	call video_init             ; a boot image gets the screen console too
	la r1, s_con_banner
	call con_puts
	call boot                   ; returns if there is nothing to boot
	la r1, s_con_demos
	call con_puts

	la r1, s_banner
	call puts
	la r1, rom_size
	lw r2, 0(r1)
	la r1, s_rom_size
	call show

	call demo_alu
	call demo_memory
	call demo_calls
	call demo_pcrel
	call demo_polling
	call demo_interrupts
	call demo_mmu
	call demo_timer
	call demo_video

	la r1, s_bye
	call puts
	li r1, POWER
	sw r0, POWER_OFF(r1)        ; exit code 0: the emulator quits
	hlt                         ; not reached

	.include "demos/alu.asm"
	.include "demos/memory.asm"
	.include "demos/calls.asm"
	.include "demos/pcrel.asm"
	.include "demos/polling.asm"
	.include "demos/interrupts.asm"
	.include "demos/mmu.asm"
	.include "demos/timer.asm"
	.include "demos/video.asm"
	.include "boot.asm"

; post_beep(): a short beep at power-on, like a PC after its self-test.
; The beeper times it by itself, so nothing waits for it to end.
post_beep:
	li r1, TIMER
	lw r2, TIMER_FREQUENCY(r1)
	li r3, 10
	divu r2, r2, r3             ; 1/10 s of ticks
	li r1, BEEPER
	li r3, 1000                 ; Hz
	sw r3, BEEPER_FREQUENCY(r1)
	sw r2, BEEPER_DURATION(r1)
	li r3, BEEPER_ON
	sw r3, BEEPER_CONTROL(r1)
	ret
	.include "lib.asm"
	.include "video.asm"
	.include "font.asm"

; ---- data -----------------------------------------------------------------

s_banner:
	.ascii "\n"
	.ascii "WRM.081632 demo firmware\n"
	.asciz "========================\n"
s_rom_size:     .asciz "firmware size, bytes"
s_bye:          .asciz "\nbye\n"
s_con_banner:   .asciz "WRM.081632 firmware\n\n"
s_con_demos:    .asciz "No boot image: running the demos.\nTheir output goes to the UART console.\n"

; image trailer: a small header-like block built from data directives
	.align 16
rom_info:
	.string "WRM"               ; magic, NUL-terminated
	.dh 1, 0                    ; version 1.0
	.db 'D', 'E', 'M', 'O'
	.space 4, 0xFF              ; reserved
rom_size:
	.dw rom_end - ROM_BASE      ; image size, including this word
rom_end:
