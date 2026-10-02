; ============================================================================
;  The network behind the Ethernet card, over the host's loopback only. The
;  guest plays both ends of a TCP connection: its port 1000 connects to
;  10.0.2.2:47201, the host's 127.0.0.1:47201, which is forwarded back to
;  its port 80. The handshake, data both ways, closing both ways, a reset
;  for a segment of no connection, a refused connection; then a UDP
;  datagram there and back through the forwarded port 7, and DNS queries.
; ============================================================================
; @args --net-allow 127.0.0.1
; @args --net-forward 127.0.0.1:47201:80 --net-forward 127.0.0.1:47202:7
; The host's loopback is denied by default; the test allows 127.0.0.1.

	.include "../common/harness.asm"
	.include "../common/eth.asm"

CLIENT          = CONN0             ; the guest's port 1000, connecting
SERVER          = CONN1             ; its port 80, where the forward leads
REFUSED         = CONN2
CLIENT_PORT     = 1000
SERVER_PORT     = 80
FORWARD_TCP     = 47201             ; the host's port for SERVER_PORT
FORWARD_UDP     = 47202             ; ... and for UDP_PORT
CLOSED_PORT     = 47209             ; nobody listens there
CLIENT_ISN      = 0x10000000
SERVER_ISN      = 0x20000000
UDP_PORT        = 7
UDP_CLIENT      = 2000
DNS_PORT        = 3000
HELLO_SIZE      = 10                ; s_hello
PING_SIZE       = 5                 ; s_ping
PONG_SIZE       = 4                 ; s_pong
QUERY_A_SIZE    = 26                ; dns_query_a
QUERY_AAAA_SIZE = 29                ; dns_query_aaaa

test_main:
	call eth_init

	; ---- the client's SYN; the host connects through the forward, so the
	;      server gets a SYN too. Which frame comes first is up to the host.
	li r28, 1
	li r1, CLIENT
	li r2, CLIENT_PORT
	li r3, GATEWAY
	li r4, FORWARD_TCP
	li r5, CLIENT_ISN
	call conn_init
	li r1, CLIENT
	li r2, TCP_SYN
	li r3, 0
	li r4, 0
	call tcp_send
	li r28, 2
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_B
	call eth_recv
	li r28, 3
	li r1, FRAME_A + 36             ; to the client's port: the SYN-ACK
	call get16
	li r10, FRAME_A                 ; r10 = the client's frame
	li r11, FRAME_B                 ; r11 = the server's
	li r3, CLIENT_PORT
	beq r1, r3, .sorted
	li r10, FRAME_B
	li r11, FRAME_A
.sorted:
	li r28, 4                       ; the SYN-ACK, with the gateway's MSS
	mv r1, r10
	li r2, CLIENT
	li r3, TCP_SYN | TCP_ACK
	call tcp_check
	bnez r1, fail
	li r28, 5
	lbu r4, 46(r10)                 ; a 24-byte header
	li r3, 0x60
	bne r4, r3, fail
	lhu r4, 54(r10)                 ; MSS 1460
	li r3, 0x0402
	bne r4, r3, fail
	lhu r4, 56(r10)
	li r3, 0xB405
	bne r4, r3, fail
	li r28, 6                       ; the server's SYN, from a port of the gateway
	addi r1, r11, 34
	call get16
	mv r4, r1
	beqz r4, fail
	mv r4, r1
	li r1, SERVER
	li r2, SERVER_PORT
	li r3, GATEWAY
	li r5, SERVER_ISN
	call conn_init
	li r28, 7
	mv r1, r11
	li r2, SERVER
	li r3, TCP_SYN
	call tcp_check
	bnez r1, fail

	; ---- both handshakes end: the client acks, the server answers
	li r28, 10
	li r1, CLIENT
	li r2, TCP_ACK
	li r3, 0
	li r4, 0
	call tcp_send
	li r1, SERVER
	li r2, TCP_SYN | TCP_ACK
	li r3, 0
	li r4, 0
	call tcp_send
	li r28, 11                      ; the gateway acks the server's SYN-ACK
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, SERVER
	li r3, TCP_ACK
	call tcp_check
	bnez r1, fail

	; ---- the client sends, the server receives
	li r28, 20
	li r1, CLIENT
	li r2, TCP_ACK | TCP_PSH
	la r3, s_hello
	li r4, HELLO_SIZE
	call tcp_send
	li r28, 21                      ; acked at once
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, CLIENT
	li r3, TCP_ACK
	call tcp_check
	bnez r1, fail
	li r28, 22                      ; through the host to the server
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, SERVER
	li r3, TCP_ACK | TCP_PSH
	call tcp_check
	li r3, HELLO_SIZE
	mv r4, r1
	bne r4, r3, fail
	li r28, 23
	mv r1, r2
	la r2, s_hello
	li r3, HELLO_SIZE
	call compare

	; ---- the server acks and answers, the client receives
	li r28, 30
	li r1, SERVER
	li r2, TCP_ACK | TCP_PSH
	la r3, s_ping
	li r4, PING_SIZE
	call tcp_send
	li r28, 31
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, SERVER
	li r3, TCP_ACK
	call tcp_check
	bnez r1, fail
	li r28, 32
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, CLIENT
	li r3, TCP_ACK | TCP_PSH
	call tcp_check
	li r3, PING_SIZE
	mv r4, r1
	bne r4, r3, fail
	li r28, 33
	mv r1, r2
	la r2, s_ping
	li r3, PING_SIZE
	call compare

	; ---- the client closes: its FIN is acked, and the host closing its
	;      end of the connection brings the server a FIN
	li r28, 40
	li r1, CLIENT
	li r2, TCP_FIN | TCP_ACK
	li r3, 0
	li r4, 0
	call tcp_send
	li r28, 41
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, CLIENT
	li r3, TCP_ACK
	call tcp_check
	li r28, 42
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, SERVER
	li r3, TCP_FIN | TCP_ACK
	call tcp_check
	bnez r1, fail

	; ---- the server closes too: the client gets its FIN
	li r28, 43
	li r1, SERVER
	li r2, TCP_FIN | TCP_ACK
	li r3, 0
	li r4, 0
	call tcp_send
	li r28, 44
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, SERVER
	li r3, TCP_ACK
	call tcp_check
	li r28, 45
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, CLIENT
	li r3, TCP_FIN | TCP_ACK
	call tcp_check
	bnez r1, fail
	li r28, 46                      ; the last ACK: the connection is gone
	li r1, CLIENT
	li r2, TCP_ACK
	li r3, 0
	li r4, 0
	call tcp_send

	; ---- a segment of no connection is answered with a reset
	li r28, 50
	li r1, CLIENT
	li r2, TCP_ACK | TCP_PSH
	la r3, s_hello
	li r4, HELLO_SIZE
	call tcp_send
	li r28, 51
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A                  ; numbered with what the segment acked
	li r2, CLIENT
	li r3, TCP_RST
	call tcp_check
	bnez r1, fail

	; ---- nobody listens on the port: the connection is refused (at once
	;      or a little later, depending on the host)
	li r28, 55
	li r1, REFUSED
	li r2, CLIENT_PORT + 1
	li r3, GATEWAY
	li r4, CLOSED_PORT
	li r5, CLIENT_ISN
	call conn_init
	li r1, REFUSED
	li r2, TCP_SYN
	li r3, 0
	li r4, 0
	call tcp_send
	li r28, 56
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, REFUSED
	li r3, TCP_RST | TCP_ACK
	call tcp_check
	bnez r1, fail

	; ---- UDP: from the guest's port 2000 to the host's 47202, which is
	;      the guest's port 7, from a port of the host...
	li r28, 60
	li r1, UDP_CLIENT
	li r2, GATEWAY
	li r3, FORWARD_UDP
	la r4, s_ping
	li r5, PING_SIZE
	call udp_send
	li r28, 61
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, GATEWAY
	li r3, 0
	li r4, UDP_PORT
	call udp_check
	mv r12, r3                      ; r12 = the host's port of the sender
	li r3, PING_SIZE
	mv r4, r1
	bne r4, r3, fail
	li r28, 62
	mv r4, r12
	li r3, FORWARD_UDP
	beq r4, r3, fail
	beqz r4, fail
	mv r1, r2
	la r2, s_ping
	li r3, PING_SIZE
	call compare
	li r28, 63                      ; ... and back, from the forwarded port
	li r1, UDP_PORT
	li r2, GATEWAY
	mv r3, r12
	la r4, s_pong
	li r5, PONG_SIZE
	call udp_send
	li r28, 64
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, GATEWAY
	li r3, FORWARD_UDP
	li r4, UDP_CLIENT
	call udp_check
	li r3, PONG_SIZE
	mv r4, r1
	bne r4, r3, fail
	li r28, 65
	mv r1, r2
	la r2, s_pong
	li r3, PONG_SIZE
	call compare

	; ---- DNS: a dotted address is its own A record...
	li r28, 70
	li r1, DNS_PORT
	li r2, DNS_SERVER
	li r3, 53
	la r4, dns_query_a
	li r5, QUERY_A_SIZE
	call udp_send
	li r28, 71
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, DNS_SERVER
	li r3, 53
	li r4, DNS_PORT
	call udp_check
	mv r10, r2                      ; r10 = the reply
	li r3, QUERY_A_SIZE + 16        ; the question again, and one answer
	mv r4, r1
	bne r4, r3, fail
	li r28, 72
	lhu r4, 0(r10)                  ; ID 0x1234
	li r3, 0x3412
	bne r4, r3, fail
	lhu r4, 2(r10)                  ; a response, recursion desired and available
	li r3, 0x8081
	bne r4, r3, fail
	lhu r4, 6(r10)                  ; one answer
	li r3, 0x0100
	bne r4, r3, fail
	li r28, 73
	addi r1, r10, QUERY_A_SIZE + 12 ; its address
	call get32
	mv r4, r1
	li r3, 0x0A010203
	bne r4, r3, fail
	; ---- ... and an AAAA query has no answer, at once
	li r28, 74
	li r1, DNS_PORT
	li r2, DNS_SERVER
	li r3, 53
	la r4, dns_query_aaaa
	li r5, QUERY_AAAA_SIZE
	call udp_send
	li r28, 75
	li r1, FRAME_A
	call eth_recv
	li r1, FRAME_A
	li r2, DNS_SERVER
	li r3, 53
	li r4, DNS_PORT
	call udp_check
	mv r10, r2
	li r3, QUERY_AAAA_SIZE
	mv r4, r1
	bne r4, r3, fail
	li r28, 76
	lhu r4, 2(r10)                  ; no error...
	li r3, 0x8081
	bne r4, r3, fail
	lhu r4, 6(r10)                  ; ... and no answer
	bnez r4, fail

	j pass

s_hello:        .ascii "hello, net"
s_ping:         .ascii "ping!"
s_pong:         .ascii "pong"

; a query for the A record of "10.1.2.3", ID 0x1234, recursion desired
dns_query_a:
	.db 0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 2, "10", 1, "1", 1, "2", 1, "3", 0, 0x00, 0x01, 0x00, 0x01
; ... and for the AAAA record of "example.com"
dns_query_aaaa:
	.db 0x12, 0x35, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	.db 7, "example", 3, "com", 0, 0x00, 0x1C, 0x00, 0x01
	.align 4
