; ============================================================================
;  Network rules: the default denials, --net-allow and --net-deny (the last
;  match wins), for connections and datagrams, and forwarded ports
;  (--net-forward), which are listened on whatever the rules say
; ============================================================================
; @args --net-allow 127.0.0.1:47000-47999 --net-deny 127.0.0.1:47500
; @args --net-forward 127.0.0.1:47123:80 --net-forward 127.0.0.1:47124:7
; @args --net-forward 127.0.0.1:47500:9
; Of the loopback only 127.0.0.1, ports 47000-47999 but 47500, may be
; reached. The guest's TCP port 80 is the host's 47123; its UDP port 7 is
; 47124, and 9 is 47500.

	.include "../common/harness.asm"
	.include "../common/eth.asm"

CLIENT          = CONN0
SERVER          = CONN1
CLIENT_PORT     = 1000
ISN             = 0x10000000
LOCALHOST2      = 0x7F000002        ; 127.0.0.2
PRIVATE         = 0x0A010203        ; 10.1.2.3
LAN             = 0xC0A80101        ; 192.168.1.1
NEIGHBOUR       = 0x0A000209        ; 10.0.2.9: nobody on the virtual network
UDP_CLIENT      = 2000
PING_SIZE       = 4                 ; s_ping

test_main:
	call eth_init

	; ---- denied: the SYN is answered with a reset
	li r28, 1                       ; a port of the host the allow doesn't cover
	li r1, GATEWAY
	li r2, 22
	call refused
	li r28, 2                       ; a private network
	li r1, PRIVATE
	li r2, 80
	call refused
	li r28, 3                       ; the deny after the allow wins
	li r1, GATEWAY
	li r2, 47500
	call refused
	li r28, 4                       ; the allow is for 127.0.0.1 only
	li r1, LAN
	li r2, 47100
	call refused
	li r1, LOCALHOST2
	li r2, 47100
	call refused
	li r28, 5                       ; nothing else is on the virtual network
	li r1, NEIGHBOUR
	li r2, 80
	call refused

	; ---- a datagram to a denied port isn't sent: the guest's port 9,
	;      which the host's 47500 leads to, gets nothing. One to an allowed
	;      port comes to port 7.
	li r28, 10
	li r1, UDP_CLIENT
	li r2, GATEWAY
	li r3, 47500
	la r4, s_ping
	li r5, PING_SIZE
	call udp_send
	li r1, UDP_CLIENT
	li r2, GATEWAY
	li r3, 47124
	la r4, s_ping
	li r5, PING_SIZE
	call udp_send
	li r28, 11
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, GATEWAY
	li r3, 0
	li r4, 7
	call udp_check
	li r3, PING_SIZE
	mv r4, r1
	bne r4, r3, fail
	li r28, 12
	call eth_quiet

	; ---- allowed: a connection to the host's 47123 comes to port 80 of
	;      the guest. Which frame comes first is up to the host.
	li r28, 20
	li r1, CLIENT
	li r2, CLIENT_PORT
	li r3, GATEWAY
	li r4, 47123
	li r5, ISN
	call conn_init
	li r1, CLIENT
	li r2, TCP_SYN
	li r3, 0
	li r4, 0
	call tcp_send
	li r28, 21
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_B
	call eth_recv
	li r1, FRAME_A + 36
	call get16
	li r10, FRAME_A                 ; r10 = the client's frame
	li r11, FRAME_B                 ; r11 = the server's
	li r3, CLIENT_PORT
	beq r1, r3, .sorted
	li r10, FRAME_B
	li r11, FRAME_A
.sorted:
	li r28, 22
	mv r1, r10
	li r2, CLIENT
	li r3, TCP_SYN | TCP_ACK
	call tcp_check
	li r28, 23
	addi r1, r11, 34                ; the server's SYN, from a port of the gateway
	call get16
	mv r4, r1
	li r1, SERVER
	li r2, 80
	li r3, GATEWAY
	li r5, ISN
	call conn_init
	mv r1, r11
	li r2, SERVER
	li r3, TCP_SYN
	call tcp_check

	j pass

; refused(r1 = address, r2 = port): a SYN from the guest's CLIENT_PORT
; there is answered with a reset
refused:
	addi r30, r30, -8
	sw ra, 0(r30)
	mv r3, r1
	mv r4, r2
	li r1, CLIENT
	li r2, CLIENT_PORT
	li r5, ISN
	call conn_init
	li r1, CLIENT
	li r2, TCP_SYN
	li r3, 0
	li r4, 0
	call tcp_send
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, CLIENT
	li r3, TCP_RST | TCP_ACK
	call tcp_check
	lw ra, 0(r30)
	addi r30, r30, 8
	ret

s_ping:         .ascii "ping"
	.align 4
