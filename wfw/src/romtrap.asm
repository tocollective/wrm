; Used by the ROM runtime before wfw/src/main.m has initialized the screen.
; If early startup faults, stop without touching the UART.

__EARLY_POWER_OFF = 0xFD004000

	.text
	.globl __trap
__trap:
	li r1, 254
	li r9, __EARLY_POWER_OFF
	sw r1, 0(r9)
	hlt
