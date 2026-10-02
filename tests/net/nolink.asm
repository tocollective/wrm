; ============================================================================
;  Ethernet card with --no-net: the link is down; frames are still sent
;  (into nothing) and nothing comes back
; ============================================================================
; @args --no-net

	.include "../common/harness.asm"

RX_RING         = 0x1000            ; reached as offset(r0)
TX_RING         = 0x1010
RX_BUF          = 0x1800
WAIT            = 2000000           ; ticks: many polls of the network

test_main:
	li r10, ETH

	li r28, 1
	lw r4, ETH_STATUS(r10)
	bnez r4, fail

	; ---- one descriptor each way
	li r1, RX_BUF
	sw r1, RX_RING(r0)
	li r1, ETH_DESC_OWN | 0x600
	sw r1, RX_RING + 4(r0)
	la r1, frame
	sw r1, TX_RING(r0)
	li r1, ETH_DESC_OWN | 60
	sw r1, TX_RING + 4(r0)
	li r1, RX_RING
	sw r1, ETH_RX_RING(r10)
	li r1, TX_RING
	sw r1, ETH_TX_RING(r10)
	li r1, 1
	sw r1, ETH_RX_SIZE(r10)
	sw r1, ETH_TX_SIZE(r10)
	li r1, ETH_ENABLE
	sw r1, ETH_CONTROL(r10)

	; ---- the frame is sent
	li r28, 2
	sw r0, ETH_TX_KICK(r10)
	lw r4, TX_RING + 4(r0)
	li r3, 60
	bne r4, r3, fail
	li r28, 3
	lw r4, ETH_PENDING(r10)
	li r3, ETH_TX
	bne r4, r3, fail
	lw r4, ETH_TX_NEXT(r10)         ; round the ring of one
	bnez r4, fail

	; ---- and nothing comes in
	li r28, 4
	li r5, TIMER
.wait:
	lw r4, TIMER_COUNT_LO(r5)
	li r3, WAIT
	bltu r4, r3, .wait
	lw r4, RX_RING + 4(r0)
	li r3, ETH_DESC_OWN | 0x600
	bne r4, r3, fail
	lw r4, ETH_PENDING(r10)
	li r3, ETH_TX
	bne r4, r3, fail

	j pass

frame:                              ; an ARP request for 10.0.2.2, padded
	.db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56
	.db 0x08, 0x06, 0x00, 0x01, 0x08, 0x00, 0x06, 0x04, 0x00, 0x01
	.db 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x0A, 0x00, 0x02, 0x0F
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x02, 0x02
	.db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
