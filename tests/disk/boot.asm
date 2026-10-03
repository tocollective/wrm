; ============================================================================
;  Boot protocol: the firmware (wfw/src/main.m) loads
;  tests/common/boot_image.asm from disk 0, which checks the state it is
;  entered with and reports PASS or FAIL
; ============================================================================
; @rom ../../wfw/src/main.m
; @hdd ../common/boot_image.asm
; @args --ram 4M,2M
