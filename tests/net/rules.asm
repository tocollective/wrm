; ============================================================================
;  Network rules: the default denials, --net-allow and --net-deny (the last
;  match wins), datagrams, and a forwarded port (--net-forward)
; ============================================================================
; @args --net-allow 127.0.0.1:47000-47999 --net-deny 127.0.0.1:47500
; @args --net-forward 127.0.0.1:47123:80
; Of the loopback only 127.0.0.1, ports 47000-47999 but 47500, may be
; reached. The guest's port 80 listens on 127.0.0.1:47123 of the host.

	.include "../common/harness.asm"

TIMEOUT         = 240000000         ; cycles to wait for the host: 5 s
SOCKET0         = NET + NET_SOCKET0
SOCKET1         = SOCKET0 + NET_SOCKET_SIZE
LOCALHOST2      = 0x7F000002        ; 127.0.0.2
PRIVATE         = 0x0A010203        ; 10.1.2.3
LAN             = 0xC0A80101        ; 192.168.1.1

test_main:
	li r11, SOCKET0
	li r12, SOCKET1

	; ---- denied: refused at once with error 8 and EVENTS.closed
	li r28, 1                   ; a port the allow rule doesn't cover
	li r1, LOCALHOST
	li r2, 22
	call connect
	li r3, NET_ERR_DENIED
	bne r4, r3, fail
	li r28, 2
	lw r4, SOCK_STATE(r12)
	bnez r4, fail
	lw r4, SOCK_EVENTS(r12)
	li r3, SOCK_EV_CLOSED
	bne r4, r3, fail
	li r28, 3                   ; a private network
	li r1, PRIVATE
	li r2, 80
	call connect
	li r3, NET_ERR_DENIED
	bne r4, r3, fail
	li r28, 4                   ; the deny after the allow wins
	li r1, LOCALHOST
	li r2, 47500
	call connect
	li r3, NET_ERR_DENIED
	bne r4, r3, fail
	li r28, 5                   ; the allow is for 127.0.0.1 only
	li r1, LAN
	li r2, 47100
	call connect
	li r3, NET_ERR_DENIED
	bne r4, r3, fail
	li r1, LOCALHOST2
	li r2, 47100
	call connect
	li r3, NET_ERR_DENIED
	bne r4, r3, fail

	; ---- a datagram to a denied address isn't sent
	li r28, 10
	sw r0, SOCK_LOCAL_PORT(r12)
	li r1, NET_UDP
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	bnez r4, fail
	li r28, 11
	li r1, LOCALHOST2
	sw r1, SOCK_PEER_ADDR(r12)
	li r1, 47000
	sw r1, SOCK_PEER_PORT(r12)
	la r1, s_ping
	sw r1, SOCK_ADDRESS(r12)
	li r1, 4
	sw r1, SOCK_COUNT(r12)
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	li r3, NET_ERR_DENIED
	bne r4, r3, fail
	li r28, 12                  ; ADDRESS and COUNT stay
	lw r4, SOCK_COUNT(r12)
	li r3, 4
	bne r4, r3, fail
	lw r4, SOCK_ADDRESS(r12)
	la r3, s_ping
	bne r4, r3, fail
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r12)

	; ---- port 80 of the guest is 47123 of the host
	li r28, 20
	li r1, 80
	sw r1, SOCK_LOCAL_PORT(r11)
	li r1, NET_LISTEN
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	li r28, 21                  ; the guest still sees its own port
	lw r4, SOCK_LOCAL_PORT(r11)
	li r3, 80
	bne r4, r3, fail
	li r28, 22                  ; allowed: connects to the forward
	li r1, LOCALHOST
	li r2, 47123
	call connect
	bnez r4, fail
	li r28, 23
	mv r1, r11
	li r2, SOCK_CONNECTED
	call wait_state
	li r28, 24
	mv r1, r12
	li r2, SOCK_CONNECTED
	call wait_state
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r11)
	sw r1, SOCK_COMMAND(r12)

	j pass

; connect(r1 = address, r2 = port): CONNECT on socket 1 (r12), closed
; first -> r4 = ERROR
connect:
	li r4, NET_CLOSE
	sw r4, SOCK_COMMAND(r12)
	sw r1, SOCK_PEER_ADDR(r12)
	sw r2, SOCK_PEER_PORT(r12)
	li r4, NET_CONNECT
	sw r4, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	ret

; wait_state(r1 = socket, r2 = STATE): returns once the socket is in that
; state; fails after TIMEOUT cycles
wait_state:
	mfcr r16, cycle
.loop:
	lw r4, SOCK_STATE(r1)
	beq r4, r2, .done
	mfcr r17, cycle
	sub r17, r17, r16
	li r3, TIMEOUT
	bltu r17, r3, .loop
	j fail
.done:
	ret

s_ping:         .ascii "ping"
