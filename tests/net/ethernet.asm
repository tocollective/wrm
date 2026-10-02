; ============================================================================
;  Ethernet card and the network behind it, without leaving the machine:
;  the registers, the rings, ARP and ping answered by the gateway, an
;  address from DHCP, a frame of a wrong length, a ring out of reach
; ============================================================================

	.include "../common/harness.asm"

RX_RING         = 0x3000            ; 4 descriptors
TX_RING         = 0x3100            ; 4 descriptors
RX_BUF          = 0x4000            ; descriptor N's buffer at RX_BUF + N * BUF_SIZE
BUF_SIZE        = 0x600
DESCRIPTORS     = 4
TIMEOUT         = 160000000         ; ticks to wait for the network: 5 s
ARP_SIZE        = 42
PING_SIZE       = 46
DHCP_SIZE       = 286
DHCP_REPLY_SIZE = 342               ; a 300-byte BOOTP message
GATEWAY_IP_LE   = 0x0202000A        ; 10.0.2.2 as LW reads it from a packet

test_main:
	li r10, ETH

	; ---- reset state, the link and the card's address
	li r28, 1
	lw r4, ETH_STATUS(r10)
	li r3, ETH_LINK
	bne r4, r3, fail
	lw r4, ETH_CONTROL(r10)
	bnez r4, fail
	lw r4, ETH_PENDING(r10)
	bnez r4, fail
	li r28, 2
	lw r4, ETH_MAC_LO(r10)          ; 52:54:00:12:34:56
	li r3, 0x12005452
	bne r4, r3, fail
	lw r4, ETH_MAC_HI(r10)
	li r3, 0x5634
	bne r4, r3, fail

	; ---- the rings: every receive descriptor is the card's
	li r1, RX_RING
	li r2, RX_BUF
	li r3, ETH_DESC_OWN | BUF_SIZE
	li r5, DESCRIPTORS
.rx_descriptor:
	sw r2, 0(r1)
	sw r3, 4(r1)
	addi r1, r1, 8
	addi r2, r2, BUF_SIZE
	addi r5, r5, -1
	bnez r5, .rx_descriptor
	li r28, 3
	li r1, RX_RING
	sw r1, ETH_RX_RING(r10)
	li r1, DESCRIPTORS
	sw r1, ETH_RX_SIZE(r10)
	li r1, TX_RING
	sw r1, ETH_TX_RING(r10)
	li r1, DESCRIPTORS
	sw r1, ETH_TX_SIZE(r10)
	li r1, ETH_ENABLE
	sw r1, ETH_CONTROL(r10)
	lw r4, ETH_RX_RING(r10)
	li r3, RX_RING
	bne r4, r3, fail
	li r28, 4                       ; not while the card is on
	li r1, 0x8000
	sw r1, ETH_RX_RING(r10)
	sw r0, ETH_TX_SIZE(r10)
	lw r4, ETH_RX_RING(r10)
	bne r4, r3, fail
	lw r4, ETH_TX_SIZE(r10)
	li r3, DESCRIPTORS
	bne r4, r3, fail

	; ---- ARP: who has 10.0.2.2? The gateway does
	li r28, 5
	la r1, arp_request
	li r2, ARP_SIZE
	call send
	li r28, 6
	li r1, RX_RING
	call wait_rx
	li r3, ARP_SIZE
	bne r4, r3, fail
	li r28, 7
	li r12, RX_BUF
	lhu r4, 12(r12)                 ; EtherType 0x0806
	li r3, 0x0608
	bne r4, r3, fail
	lhu r4, 20(r12)                 ; a reply
	li r3, 0x0200
	bne r4, r3, fail
	lw r4, 28(r12)                  ; from 10.0.2.2
	li r3, GATEWAY_IP_LE
	bne r4, r3, fail
	li r28, 8
	lw r4, 0(r12)                   ; to the card
	li r3, 0x12005452
	bne r4, r3, fail
	lw r4, ETH_RX_NEXT(r10)
	li r3, 1
	bne r4, r3, fail
	lw r4, ETH_PENDING(r10)
	li r3, ETH_RX | ETH_TX
	bne r4, r3, fail

	; ---- PENDING clears by writing 1; with RX_IRQ it drives the line
	li r28, 9
	li r1, ETH_ENABLE | ETH_RX_IRQ
	sw r1, ETH_CONTROL(r10)
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_ETH
	and r4, r4, r3
	beqz r4, fail
	li r28, 10
	li r1, ETH_RX | ETH_TX
	sw r1, ETH_PENDING(r10)
	lw r4, ETH_PENDING(r10)
	bnez r4, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_ETH
	and r4, r4, r3
	bnez r4, fail

	; ---- ping the gateway: it answers itself
	li r28, 11
	la r1, ping_request
	li r2, PING_SIZE
	call send
	li r28, 12
	li r1, RX_RING + 8
	call wait_rx
	li r3, PING_SIZE
	bne r4, r3, fail
	li r28, 13
	li r12, RX_BUF + BUF_SIZE
	lbu r4, 23(r12)                 ; ICMP
	li r3, 1
	bne r4, r3, fail
	lbu r4, 34(r12)                 ; an echo reply
	bnez r4, fail
	lhu r4, 38(r12)                 ; identifier 0x1234
	li r3, 0x3412
	bne r4, r3, fail
	lhu r4, 40(r12)                 ; sequence 1
	li r3, 0x0100
	bne r4, r3, fail
	lhu r4, 42(r12)                 ; "ping"
	li r3, 'p' | 'i' << 8
	bne r4, r3, fail
	lhu r4, 26(r12)                 ; from 10.0.2.2
	li r3, 0x000A
	bne r4, r3, fail
	lhu r4, 28(r12)
	li r3, 0x0202
	bne r4, r3, fail

	; ---- DHCP: the offer is 10.0.2.15
	li r28, 14
	la r1, dhcp_discover
	li r2, DHCP_SIZE
	call send
	li r28, 15
	li r1, RX_RING + 16
	call wait_rx
	li r3, DHCP_REPLY_SIZE
	bne r4, r3, fail
	li r28, 16
	li r12, RX_BUF + 2 * BUF_SIZE
	lhu r4, 46(r12)                 ; xid 0xCAFEBABE
	li r3, 0xFECA
	bne r4, r3, fail
	lhu r4, 58(r12)                 ; yiaddr 10.0.2.15
	li r3, 0x000A
	bne r4, r3, fail
	lhu r4, 60(r12)
	li r3, 0x0F02
	bne r4, r3, fail
	lbu r4, 284(r12)                ; message type: OFFER
	li r3, 2
	bne r4, r3, fail

	; ---- a frame shorter than its header isn't sent
	li r28, 17
	la r1, arp_request
	li r2, 10
	call send_raw
	li r3, ETH_DESC_ERROR | 10
	bne r4, r3, fail

	; ---- off, the rings can change; a ring out of reach is a fault
	li r28, 18
	sw r0, ETH_CONTROL(r10)
	li r1, 0x0F000000               ; no RAM there
	sw r1, ETH_TX_RING(r10)
	lw r4, ETH_TX_RING(r10)
	bne r4, r1, fail
	li r28, 19
	li r1, ETH_ENABLE
	sw r1, ETH_CONTROL(r10)
	sw r0, ETH_TX_KICK(r10)
	lw r4, ETH_PENDING(r10)
	andi r4, r4, ETH_FAULT
	beqz r4, fail
	li r28, 20
	lw r4, ETH_CONTROL(r10)         ; the card turned itself off
	bnez r4, fail

	j pass

; send(r1 = frame, r2 = length): sends a frame through the next TX
; descriptor and checks that it went. Clobbers r1-r5, r13.
send:
	addi r30, r30, -4
	sw ra, 0(r30)
	call send_raw
	li r3, 0x0000FFFF
	and r3, r3, r2
	bne r4, r3, fail                ; OWN and ERROR clear, the length kept
	lw ra, 0(r30)
	addi r30, r30, 4
	ret

; send_raw(r1 = frame, r2 = length) -> r4 = the descriptor's word after
send_raw:
	lw r13, ETH_TX_NEXT(r10)
	shli r13, r13, 3
	li r3, TX_RING
	add r13, r13, r3
	sw r1, 0(r13)
	li r3, ETH_DESC_OWN
	or r3, r3, r2
	sw r3, 4(r13)
	sw r0, ETH_TX_KICK(r10)         ; sent in this store
	lw r4, 4(r13)
	ret

; wait_rx(r1 = descriptor) -> r4 = its word once the card has given it
; back; fails after TIMEOUT ticks. Clobbers r3, r5.
wait_rx:
	li r5, TIMER
.loop:
	lw r4, 4(r1)
	li r3, ETH_DESC_OWN
	and r3, r3, r4
	beqz r3, .done
	lw r3, TIMER_COUNT_LO(r5)
	li r4, TIMEOUT
	bltu r3, r4, .loop
	j fail
.done:
	ret

; frames, as the card sends them: no FCS, checksums left at 0
arp_request:				; 42 bytes
	.db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x08, 0x06, 0x00, 0x01
	.db 0x08, 0x00, 0x06, 0x04, 0x00, 0x01, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x0A, 0x00, 0x02, 0x0F
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x02, 0x02
arp_request_end:
ping_request:				; 46 bytes
	.db 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x08, 0x00, 0x45, 0x00
	.db 0x00, 0x20, 0x00, 0x00, 0x00, 0x00, 0x40, 0x01, 0x00, 0x00, 0x0A, 0x00, 0x02, 0x0F, 0x0A, 0x00
	.db 0x02, 0x02, 0x08, 0x00, 0x00, 0x00, 0x12, 0x34, 0x00, 0x01, 0x70, 0x69, 0x6E, 0x67
ping_request_end:
dhcp_discover:				; 286 bytes
	.db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x08, 0x00, 0x45, 0x00
	.db 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x40, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF
	.db 0xFF, 0xFF, 0x00, 0x44, 0x00, 0x43, 0x00, 0xFC, 0x00, 0x00, 0x01, 0x01, 0x06, 0x00, 0xCA, 0xFE
	.db 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x63, 0x82, 0x53, 0x63, 0x35, 0x01, 0x01, 0xFF
dhcp_discover_end:
