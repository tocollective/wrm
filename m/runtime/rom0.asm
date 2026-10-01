; ============================================================================
;  crt0 of an M ROM image, such as the firmware (m/docs/COMPILER.md,
;  "Цель: ROM")
;
;  tools/m.py --rom puts this file first in its output, then trap.asm and
;  mem.asm; the image is assembled at ROM_BASE, where the CPU starts after
;  reset. Code and constants stay in ROM. .data is copied from
;  __data_load in ROM to __data_start in RAM, .bss after it is zeroed.
;  The compiler defines __data_load, __data_start, __data_end,
;  __bss_start, __bss_end (all word aligned) and main.
;
;  RAM: .data and .bss from __RAM_DATA up (the compiler keeps them below
;  BOOT_LOAD, where a boot image can't overwrite them), the stack from
;  __STACK_TOP down. Both fit in the smallest RAM, 1MB.
; ============================================================================

__ROM_BASE      = 0xFE000000
__RAM_DATA      = 0x00002000        ; above the boot info block
__STACK_TOP     = 0x00100000        ; the end of 1MB of RAM
__POWER_OFF     = 0xFD004000        ; power controller, OFF register

__data_start    = __RAM_DATA

	.org __ROM_BASE
__image_start:
__start:                            ; pc = ROM_BASE after reset, STATUS = EXL
	li sp, __STACK_TOP
	la r1, __data_start
	la r2, __data_load
	la r3, __data_end
	j .copy_test
.copy:
	lw r4, 0(r2)
	sw r4, 0(r1)
	addi r1, r1, 4
	addi r2, r2, 4
.copy_test:
	bltu r1, r3, .copy

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
