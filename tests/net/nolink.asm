; ============================================================================
;  Network card without --net: the link is down, so every command fails
;  with error 4 and a DNS lookup fails at once; the registers still work
; ============================================================================

	.include "../common/harness.asm"

SOCKET0         = NET + NET_SOCKET0
SOCKET7         = NET + NET_SOCKET0 + 7 * NET_SOCKET_SIZE

test_main:
	li r10, NET
	li r11, SOCKET0

	; ---- reset state
	li r28, 1
	lw r4, NET_STATUS(r10)          ; no link, so nothing works
	bnez r4, fail
	lw r4, NET_PENDING(r10)
	bnez r4, fail
	lw r4, NET_SOCKETS(r10)
	li r3, 8
	bne r4, r3, fail
	li r28, 2
	lw r4, NET_DNS_STATUS(r10)
	bnez r4, fail
	lw r4, NET_DNS_RESULT(r10)
	bnez r4, fail
	li r28, 3
	lw r4, SOCK_STATE(r11)
	li r3, SOCK_CLOSED
	bne r4, r3, fail
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_EVENTS(r11)
	bnez r4, fail
	lw r4, SOCK_RX_SIZE(r11)
	bnez r4, fail
	lw r4, SOCK_TX_FREE(r11)
	li r3, NET_BUFFER_SIZE
	bne r4, r3, fail

	; ---- registers keep their bits only
	li r28, 4
	li r1, 0x12345
	sw r1, SOCK_LOCAL_PORT(r11)
	lw r4, SOCK_LOCAL_PORT(r11)
	li r3, 0x2345                   ; ports are 16 bits
	bne r4, r3, fail
	sw r1, SOCK_PEER_PORT(r11)
	lw r4, SOCK_PEER_PORT(r11)
	bne r4, r3, fail
	li r28, 5
	li r1, -1
	sw r1, SOCK_IRQ_MASK(r11)
	lw r4, SOCK_IRQ_MASK(r11)
	li r3, SOCK_EV_CONNECTED | SOCK_EV_CLOSED | SOCK_EV_RECEIVED | SOCK_EV_SENT
	bne r4, r3, fail
	li r28, 6
	li r1, LOCALHOST
	sw r1, SOCK_PEER_ADDR(r11)
	lw r4, SOCK_PEER_ADDR(r11)
	bne r4, r1, fail
	li r28, 7                       ; read-only registers ignore writes
	li r1, -1
	sw r1, SOCK_STATE(r11)
	sw r1, SOCK_RX_SIZE(r11)
	sw r1, NET_STATUS(r10)
	sw r1, NET_SOCKETS(r10)
	lw r4, SOCK_STATE(r11)
	bnez r4, fail
	lw r4, SOCK_RX_SIZE(r11)
	bnez r4, fail
	lw r4, NET_STATUS(r10)
	bnez r4, fail
	li r28, 8                       ; the last socket's registers
	li r12, SOCKET7
	li r1, 0xC0A80001               ; 192.168.0.1
	sw r1, SOCK_PEER_ADDR(r12)
	lw r4, SOCK_PEER_ADDR(r12)
	bne r4, r1, fail
	lw r4, SOCK_PEER_ADDR(r11)      ; socket 0 keeps its own
	li r3, LOCALHOST
	bne r4, r3, fail

	; ---- commands: unknown ones fail with 1, the rest with 4
	li r28, 10
	li r1, 7
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	li r3, NET_ERR_COMMAND
	bne r4, r3, fail
	li r28, 11
	sw r0, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bne r4, r3, fail
	li r28, 12
	li r1, NET_CONNECT
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	li r3, NET_ERR_LINK
	bne r4, r3, fail
	lw r4, SOCK_STATE(r11)
	bnez r4, fail
	li r28, 13
	li r1, NET_LISTEN
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bne r4, r3, fail
	li r1, NET_UDP
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bne r4, r3, fail
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bne r4, r3, fail
	li r1, NET_RECEIVE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bne r4, r3, fail
	li r28, 14                      ; CLOSE always works, and clears ERROR
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_STATE(r11)
	bnez r4, fail
	lw r4, SOCK_COMMAND(r11)        ; write-only
	bnez r4, fail

	; ---- a DNS lookup fails at once
	li r28, 20
	la r1, s_name
	sw r1, NET_DNS_NAME(r10)
	lw r4, NET_DNS_NAME(r10)
	bne r4, r1, fail
	li r1, NET_DNS_LOOKUP
	sw r1, NET_DNS_COMMAND(r10)
	lw r4, NET_DNS_STATUS(r10)
	li r3, NET_DNS_DONE | NET_DNS_FAILED
	bne r4, r3, fail
	lw r4, NET_DNS_RESULT(r10)
	bnez r4, fail
	li r28, 21                      ; DONE alone doesn't raise the line
	lw r4, NET_PENDING(r10)
	bnez r4, fail
	li r28, 22                      ; with the IRQ on, it does
	li r1, NET_DNS_IRQ
	sw r1, NET_DNS_CONTROL(r10)
	lw r4, NET_DNS_CONTROL(r10)
	bne r4, r1, fail
	lw r4, NET_PENDING(r10)
	li r3, NET_PENDING_DNS
	bne r4, r3, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_NET
	and r4, r4, r3
	beqz r4, fail
	li r28, 23                      ; writing 1 to DONE clears it
	li r1, NET_DNS_DONE
	sw r1, NET_DNS_STATUS(r10)
	lw r4, NET_DNS_STATUS(r10)
	li r3, NET_DNS_FAILED
	bne r4, r3, fail
	lw r4, NET_PENDING(r10)
	bnez r4, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_NET
	and r4, r4, r3
	bnez r4, fail

	j pass

s_name:         .asciz "localhost"
