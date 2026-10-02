; ============================================================================
;  crt0 of an M boot image (m/docs/COMPILER.md, "Цель: boot-образ")
;
;  tools/m.py links this object first, at BOOT_LOAD (tools/ld.py --layout
;  boot), so the header starts the image. The linker defines
;  __image_sectors, __bss_start and __bss_end (word aligned); the program
;  defines main.
;
;  On entry (docs/SPECIFICATION.md#state-at-the-entry-point): r1 = boot
;  info block, sp = 0x00010000 (8-aligned, empty), supervisor mode,
;  .bss not zeroed.
;
;  There is no kernel, so traps go to __trap (trap.asm). A program can
;  install its own handler in IVEC.
; ============================================================================

__BOOT_MAGIC    = 0x424D5257        ; "WRMB"
__POWER_OFF     = 0xFD004000        ; power controller, OFF register

	.text
__header:
	.dw __BOOT_MAGIC
	.dw __image_sectors
	.dw __start - __header      ; the entry point, from the load address
	.dw 0                       ; flags

__start:
	la r1, __bss_start
	la r2, __bss_end
	j .zero_test
.zero:
	sw r0, 0(r1)
	addi r1, r1, 4
.zero_test:
	bltu r1, r2, .zero

	la r1, __trap
	mtcr ivec, r1
	mtcr status, r0             ; clear EXL: traps go to __trap

	li r1, 0                    ; main(0, null)
	li r2, 0
	call main
	li r9, __POWER_OFF
	sw r1, 0(r9)                ; the low 8 bits are the exit code
	hlt                         ; not reached
