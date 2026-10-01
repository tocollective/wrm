; ============================================================================
;  Example boot image: prints what the firmware passed on and powers off
;
;  Build:  python3 tools/asm.py firmware/disk/hello.asm --base 0x10000 \
;              -o hdd0.img
;  Run:    bin/wrm081632 --hdd hdd0.img   (or --floppy hdd0.img)
;
;  The image is assembled at BOOT_LOAD, where the firmware loads it, and
;  starts with the boot image header (docs/SPECIFICATION.md#boot-protocol).
;  The disk image is the assembler output itself: the final .align makes
;  it a whole number of sectors.
; ============================================================================

	.include "../defs.asm"

	.org BOOT_LOAD
header:
	.dw BOOT_MAGIC
	.dw (image_end - header) / SECTOR_SIZE
	.dw entry - header
	.dw 0                       ; flags

; r1 = boot info, r30 = BOOT_STACK_TOP, supervisor mode, MMU off
entry:
	mv r10, r1
	la r1, s_hello
	call puts
	la r1, s_ram
	lw r2, BI_RAM_SIZE(r10)
	call show
	la r1, s_disk
	lw r2, BI_DISK(r10)
	call show
	la r1, s_sectors
	lw r2, BI_DISK_SECTORS(r10)
	call show
	la r1, s_image
	lw r2, BI_IMAGE_SIZE(r10)
	call show
	la r1, s_clock
	lw r2, BI_CLOCK(r10)
	call show

	li r1, POWER
	sw r0, POWER_OFF(r1)
	hlt                         ; not reached

	.include "../lib.asm"

s_hello:        .asciz "\nhello from the boot disk\n"
s_ram:          .asciz "RAM, bytes"
s_disk:         .asciz "boot disk controller"
s_sectors:      .asciz "disk size, sectors"
s_image:        .asciz "image size, bytes"
s_clock:        .asciz "clock, Hz"

	.align SECTOR_SIZE
image_end:
