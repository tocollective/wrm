; ============================================================================
;  Network card with --net, on the host's loopback only: a TCP connection
;  between two sockets of the machine (LISTEN, CONNECT, SEND, RECEIVE, the
;  other end closing, a refused connection), UDP datagrams between two
;  sockets, states and errors, the IRQ line, a DNS lookup of an address
; ============================================================================
; @args --net

	.include "../common/harness.asm"

BUF             = 0x1000            ; RECEIVE target, reached as offset(r0)
UDP_ADDR        = BUF               ; a datagram's header in BUF
UDP_PORT        = BUF + 4
UDP_LENGTH      = BUF + 6
TIMEOUT         = 240000000         ; cycles to wait for the host: 5 s
SOCKET0         = NET + NET_SOCKET0
SOCKET1         = SOCKET0 + NET_SOCKET_SIZE
SOCKET2         = SOCKET1 + NET_SOCKET_SIZE
SOCKET3         = SOCKET2 + NET_SOCKET_SIZE
HELLO_SIZE      = 10                ; s_hello
PING_SIZE       = 5                 ; s_ping

test_main:
	li r10, NET
	li r11, SOCKET0                 ; listens, then is the server's end
	li r12, SOCKET1                 ; connects

	; ---- the link is up, and this host can do everything
	li r28, 1
	lw r4, NET_STATUS(r10)
	li r3, NET_LINK | NET_CAN_LISTEN | NET_CAN_UDP
	bne r4, r3, fail

	; ---- LISTEN on any port: LOCAL_PORT shows the one picked
	li r28, 2
	sw r0, SOCK_LOCAL_PORT(r11)
	li r1, NET_LISTEN
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_STATE(r11)
	li r3, SOCK_LISTENING
	bne r4, r3, fail
	lw r13, SOCK_LOCAL_PORT(r11)    ; r13 = the server's port
	beqz r13, fail
	li r28, 3                       ; only a closed socket takes LISTEN
	li r1, NET_LISTEN
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	li r3, NET_ERR_STATE
	bne r4, r3, fail
	lw r4, SOCK_STATE(r11)          ; and a failed command changes nothing
	li r3, SOCK_LISTENING
	bne r4, r3, fail

	; ---- CONNECT to it
	li r28, 4
	li r1, LOCALHOST
	sw r1, SOCK_PEER_ADDR(r12)
	sw r13, SOCK_PEER_PORT(r12)
	li r1, NET_CONNECT
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	bnez r4, fail
	lw r4, SOCK_STATE(r12)          ; reported by the card's next poll
	li r3, SOCK_CONNECTING
	bne r4, r3, fail
	li r28, 5
	mv r1, r12
	li r2, SOCK_CONNECTED
	call wait_state
	mv r1, r11
	call wait_state
	li r28, 6                       ; both ends say so
	lw r4, SOCK_EVENTS(r12)
	li r3, SOCK_EV_CONNECTED
	bne r4, r3, fail
	lw r4, SOCK_EVENTS(r11)
	bne r4, r3, fail
	li r28, 7                       ; and know each other
	lw r4, SOCK_PEER_ADDR(r11)
	li r3, LOCALHOST
	bne r4, r3, fail
	lw r4, SOCK_PEER_PORT(r11)
	lw r3, SOCK_LOCAL_PORT(r12)
	bne r4, r3, fail
	beqz r3, fail
	li r28, 8
	li r1, SOCK_EV_CONNECTED
	sw r1, SOCK_EVENTS(r11)         ; writing 1 clears the bit
	sw r1, SOCK_EVENTS(r12)
	lw r4, SOCK_EVENTS(r11)
	bnez r4, fail

	; ---- SEND from ROM, RECEIVE at the other end
	li r28, 10
	la r1, s_hello
	sw r1, SOCK_ADDRESS(r12)
	li r1, HELLO_SIZE
	sw r1, SOCK_COUNT(r12)
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	bnez r4, fail
	li r28, 11                      ; all of it moved
	lw r4, SOCK_COUNT(r12)
	bnez r4, fail
	lw r4, SOCK_ADDRESS(r12)
	la r3, s_hello + HELLO_SIZE
	bne r4, r3, fail
	li r28, 12
	mv r1, r11
	li r2, HELLO_SIZE
	call wait_rx
	li r28, 13
	lw r4, SOCK_EVENTS(r11)
	andi r4, r4, SOCK_EV_RECEIVED
	beqz r4, fail
	li r28, 14                      ; the IRQ line follows EVENTS & IRQ_MASK
	lw r4, NET_PENDING(r10)
	bnez r4, fail
	li r1, SOCK_EV_RECEIVED
	sw r1, SOCK_IRQ_MASK(r11)
	lw r4, NET_PENDING(r10)
	li r3, 1 << 0
	bne r4, r3, fail
	li r1, PIC
	lw r4, PIC_PENDING(r1)
	li r3, 1 << IRQ_NET
	and r4, r4, r3
	beqz r4, fail
	li r1, SOCK_EV_RECEIVED
	sw r1, SOCK_EVENTS(r11)
	lw r4, NET_PENDING(r10)
	bnez r4, fail
	sw r0, SOCK_IRQ_MASK(r11)
	li r28, 15                      ; at most COUNT bytes...
	li r1, BUF
	sw r1, SOCK_ADDRESS(r11)
	li r1, 4
	sw r1, SOCK_COUNT(r11)
	li r1, NET_RECEIVE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_COUNT(r11)
	bnez r4, fail
	lw r4, SOCK_RX_SIZE(r11)
	li r3, HELLO_SIZE - 4
	bne r4, r3, fail
	li r28, 16                      ; ...or what there is
	li r1, 64
	sw r1, SOCK_COUNT(r11)
	li r1, NET_RECEIVE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_COUNT(r11)
	li r3, 64 - (HELLO_SIZE - 4)
	bne r4, r3, fail
	lw r4, SOCK_ADDRESS(r11)
	li r3, BUF + HELLO_SIZE
	bne r4, r3, fail
	lw r4, SOCK_RX_SIZE(r11)
	bnez r4, fail
	li r28, 17                      ; the bytes are the ones sent
	li r1, BUF
	la r2, s_hello
	li r3, HELLO_SIZE
	call compare

	; ---- RECEIVE into ROM stops at the first byte
	li r28, 18
	la r1, s_hello
	sw r1, SOCK_ADDRESS(r12)
	li r1, HELLO_SIZE
	sw r1, SOCK_COUNT(r12)
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r12)
	mv r1, r11
	li r2, HELLO_SIZE
	call wait_rx
	li r1, ROM_BASE
	sw r1, SOCK_ADDRESS(r11)
	li r1, HELLO_SIZE
	sw r1, SOCK_COUNT(r11)
	li r1, NET_RECEIVE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	li r3, NET_ERR_ADDRESS
	bne r4, r3, fail
	lw r4, SOCK_ADDRESS(r11)
	li r3, ROM_BASE
	bne r4, r3, fail
	lw r4, SOCK_RX_SIZE(r11)        ; nothing was taken
	li r3, HELLO_SIZE
	bne r4, r3, fail

	; ---- the other end closes: peer closed, the bytes stay readable
	li r28, 20
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_STATE(r12)
	bnez r4, fail
	lw r4, SOCK_EVENTS(r12)         ; CLOSE clears EVENTS
	bnez r4, fail
	li r28, 21
	mv r1, r11
	li r2, SOCK_PEER_CLOSED
	call wait_state
	lw r4, SOCK_EVENTS(r11)
	andi r4, r4, SOCK_EV_CLOSED
	beqz r4, fail
	li r28, 22                      ; nothing can be sent...
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	li r3, NET_ERR_STATE
	bne r4, r3, fail
	li r28, 23                      ; ...but what came is still there
	lw r4, SOCK_RX_SIZE(r11)
	li r3, HELLO_SIZE
	bne r4, r3, fail
	li r1, BUF
	sw r1, SOCK_ADDRESS(r11)
	li r1, HELLO_SIZE
	sw r1, SOCK_COUNT(r11)
	li r1, NET_RECEIVE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_COUNT(r11)
	bnez r4, fail
	li r28, 24
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_STATE(r11)
	bnez r4, fail

	; ---- nobody listens on the port now: the connection is refused (at
	;      once or a little later, depending on the host)
	li r28, 30
	li r1, NET_CONNECT
	sw r1, SOCK_COMMAND(r12)
	li r28, 31
	mv r1, r12
	li r2, SOCK_CLOSED
	call wait_state
	lw r4, SOCK_ERROR(r12)
	li r3, NET_ERR_NETWORK
	bne r4, r3, fail
	lw r4, SOCK_EVENTS(r12)
	li r3, SOCK_EV_CLOSED
	bne r4, r3, fail
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r12)

	; ---- UDP: a datagram from socket 3 to socket 2
	li r11, SOCKET2
	li r12, SOCKET3
	li r28, 40
	sw r0, SOCK_LOCAL_PORT(r11)
	li r1, NET_UDP
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_STATE(r11)
	li r3, SOCK_UDP
	bne r4, r3, fail
	lw r13, SOCK_LOCAL_PORT(r11)
	beqz r13, fail
	sw r0, SOCK_LOCAL_PORT(r12)
	li r1, NET_UDP
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	bnez r4, fail
	lw r14, SOCK_LOCAL_PORT(r12)
	beqz r14, fail
	li r28, 41                      ; a UDP socket can't CONNECT
	li r1, NET_CONNECT
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	li r3, NET_ERR_STATE
	bne r4, r3, fail
	li r28, 42                      ; nor send more than 8192 bytes at once
	li r1, LOCALHOST
	sw r1, SOCK_PEER_ADDR(r12)
	sw r13, SOCK_PEER_PORT(r12)
	la r1, s_ping
	sw r1, SOCK_ADDRESS(r12)
	li r1, NET_DATAGRAM_MAX + 1
	sw r1, SOCK_COUNT(r12)
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	li r3, NET_ERR_LENGTH
	bne r4, r3, fail
	li r28, 43
	li r1, PING_SIZE
	sw r1, SOCK_COUNT(r12)
	li r1, NET_SEND
	sw r1, SOCK_COMMAND(r12)
	lw r4, SOCK_ERROR(r12)
	bnez r4, fail
	lw r4, SOCK_COUNT(r12)
	bnez r4, fail
	li r28, 44                      ; the datagram comes with its header
	mv r1, r11
	li r2, 8 + PING_SIZE
	call wait_rx
	li r1, BUF
	sw r1, SOCK_ADDRESS(r11)
	li r1, 64
	sw r1, SOCK_COUNT(r11)
	li r1, NET_RECEIVE
	sw r1, SOCK_COMMAND(r11)
	lw r4, SOCK_ERROR(r11)
	bnez r4, fail
	lw r4, SOCK_ADDRESS(r11)
	li r3, BUF + 8 + PING_SIZE
	bne r4, r3, fail
	li r28, 45
	lw r4, UDP_ADDR(r0)             ; the sender's address
	li r3, LOCALHOST
	bne r4, r3, fail
	lhu r4, UDP_PORT(r0)            ; its port
	bne r4, r14, fail
	lhu r4, UDP_LENGTH(r0)          ; the length
	li r3, PING_SIZE
	bne r4, r3, fail
	li r28, 46
	li r1, BUF + 8
	la r2, s_ping
	li r3, PING_SIZE
	call compare
	li r1, NET_CLOSE
	sw r1, SOCK_COMMAND(r11)
	sw r1, SOCK_COMMAND(r12)

	; ---- DNS: a dotted address resolves to itself
	li r28, 50
	la r1, s_address
	sw r1, NET_DNS_NAME(r10)
	li r1, NET_DNS_LOOKUP
	sw r1, NET_DNS_COMMAND(r10)
	mfcr r16, cycle
.dns:
	lw r4, NET_DNS_STATUS(r10)
	andi r4, r4, NET_DNS_BUSY
	beqz r4, .dns_done
	mfcr r17, cycle
	sub r17, r17, r16
	li r3, TIMEOUT
	bltu r17, r3, .dns
	j fail
.dns_done:
	li r28, 51
	lw r4, NET_DNS_STATUS(r10)
	li r3, NET_DNS_DONE
	bne r4, r3, fail
	lw r4, NET_DNS_RESULT(r10)
	li r3, 0x0A010203
	bne r4, r3, fail

	j pass

; wait_state(r1 = socket, r2 = state): returns once the socket is in it;
; fails after TIMEOUT cycles
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

; wait_rx(r1 = socket, r2 = bytes): returns once RX_SIZE has that many;
; fails after TIMEOUT cycles
wait_rx:
	mfcr r16, cycle
.loop:
	lw r4, SOCK_RX_SIZE(r1)
	bgeu r4, r2, .done
	mfcr r17, cycle
	sub r17, r17, r16
	li r3, TIMEOUT
	bltu r17, r3, .loop
	j fail
.done:
	ret

; compare(r1 = a, r2 = b, r3 = bytes): fails unless they are the same
compare:
	beqz r3, .done
	lbu r4, 0(r1)
	lbu r5, 0(r2)
	bne r4, r5, fail
	addi r1, r1, 1
	addi r2, r2, 1
	addi r3, r3, -1
	j compare
.done:
	ret

s_hello:        .ascii "hello, net"
s_ping:         .ascii "ping!"
s_address:      .asciz "10.1.2.3"
