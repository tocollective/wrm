; ============================================================================
;  Boot protocol: the firmware (firmware/main.m) skips a floppy without a
;  boot image (it shows the error on the screen) and boots disk 0,
;  where tests/common/boot_image.asm checks the state and reports
; ============================================================================
; @rom ../../firmware/main.m
; @floppy 4
; @hdd ../common/boot_image.asm
; @args --ram 4M,2M
; Sector 0 of a pattern disk starts with 0, not BOOT_MAGIC.
