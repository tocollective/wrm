; A firmware exception is fatal. Interrupts remain disabled, so this entry
; only handles faults. No register state needs to be restored.

firmwareTrapEntry:
	li sp, 0x00080000
	call firmwarePanic
	hlt
