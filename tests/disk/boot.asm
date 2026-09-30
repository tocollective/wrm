; ============================================================================
;  Boot protocol: the firmware's boot code loads tests/common/boot_image.asm,
;  which checks the state it is entered with and reports PASS or FAIL
; ============================================================================
; @hdd ../common/boot_image.asm
; @args --ram 4M,2M

	.include "../common/harness.asm"
	.include "../../firmware/boot.asm"

test_main:
	li r28, 1                   ; RAM size as the firmware sees it
	call ram_size
	mv r4, r1
	li r3, 6 << 20
	bne r4, r3, fail
	li r28, 2                   ; ram_size puts IVEC and STATUS back
	mfcr r4, ivec
	la r3, unexpected_trap
	bne r4, r3, fail
	li r28, 3
	mfcr r4, status
	li r3, STATUS_EXL
	bne r4, r3, fail

	li r28, 4
	call boot                   ; the image reports the result
	j fail
