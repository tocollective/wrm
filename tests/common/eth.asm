; ============================================================================
;  The Ethernet card for the network tests: the rings, sending and
;  receiving frames, and building and checking IPv4, TCP and UDP the way a
;  guest's own stack would. Included after harness.asm.
;
;  Numbers in packets are big-endian; the CPU is little-endian, so fields
;  are written and read a byte at a time (get16, put32, ...). The guest's
;  checksums are left at 0: the gateway doesn't check them. Its own are
;  checked.
;
;  The helpers clobber r1-r9 and keep the rest. A TCP connection, as the
;  guest sees it, is a block in RAM (CONN_*): ports, the other end's
;  address, and the sequence numbers of both ways.
; ============================================================================

; ---- RAM ----------------------------------------------------------------------

VAR_RX_NEXT     = 0x0400            ; the receive descriptor of the next frame
RX_RING         = 0x0800            ; RX_COUNT descriptors
TX_RING         = 0x0880            ; one descriptor
CONN_SIZE       = 0x20
CONN0           = 0x0900            ; connection blocks, reached as offset(r0)
CONN1           = CONN0 + CONN_SIZE
CONN2           = CONN1 + CONN_SIZE
TX_FRAME        = 0x1000            ; the frame being sent
FRAME_A         = 0x1800            ; frames received, copied out of the ring
FRAME_B         = 0x2000
RX_BUF          = 0x4000            ; descriptor N's buffer at RX_BUF + N * BUF_SIZE
RX_COUNT        = 8                 ; a power of two
BUF_SIZE        = 0x600

; a connection block
CONN_LPORT      = 0x00              ; the guest's port
CONN_RADDR      = 0x04              ; the other end's address and port
CONN_RPORT      = 0x08
CONN_SND        = 0x0C              ; the guest's next sequence number
CONN_RCV        = 0x10              ; the other end's next one: what the guest acks

TIMEOUT         = 240000000         ; cycles to wait for a frame: 5 s
QUIET           = 24000000          ; cycles a quiet network stays quiet: 0.5 s

; ---- packets --------------------------------------------------------------------

GATEWAY         = 0x0A000202        ; 10.0.2.2: the host itself
DNS_SERVER      = 0x0A000203        ; 10.0.2.3
GUEST           = 0x0A00020F        ; 10.0.2.15
IP_PAYLOAD      = 34                ; Ethernet and IP headers, as the gateway sends them
UDP_DATA        = 42
TCP_DATA        = 54                ; with a 20-byte TCP header
IP_TCP          = 6
IP_UDP          = 17
TCP_FIN         = 0x01
TCP_SYN         = 0x02
TCP_RST         = 0x04
TCP_PSH         = 0x08
TCP_ACK         = 0x10
WINDOW          = 0x2000            ; what the guest's segments advertise

; ---- the card -------------------------------------------------------------------

; eth_init: RX_COUNT receive descriptors, one to send, and the card on
eth_init:
	li r1, RX_RING
	li r2, RX_BUF
	li r3, ETH_DESC_OWN | BUF_SIZE
	li r4, RX_COUNT
.descriptor:
	sw r2, 0(r1)
	sw r3, 4(r1)
	addi r1, r1, 8
	addi r2, r2, BUF_SIZE
	addi r4, r4, -1
	bnez r4, .descriptor
	li r9, ETH
	li r1, RX_RING
	sw r1, ETH_RX_RING(r9)
	li r1, RX_COUNT
	sw r1, ETH_RX_SIZE(r9)
	li r1, TX_RING
	sw r1, ETH_TX_RING(r9)
	li r1, 1
	sw r1, ETH_TX_SIZE(r9)
	sw r0, VAR_RX_NEXT(r0)
	li r1, ETH_ENABLE
	sw r1, ETH_CONTROL(r9)
	ret

; eth_send(r1 = length): sends the frame at TX_FRAME; fails unless it went
eth_send:
	li r9, ETH
	li r2, TX_FRAME
	sw r2, TX_RING(r0)
	li r2, ETH_DESC_OWN
	or r2, r2, r1
	sw r2, TX_RING + 4(r0)
	sw r0, ETH_TX_KICK(r9)          ; sent in this store
	lw r4, TX_RING + 4(r0)
	bne r4, r1, fail                ; OWN and ERROR clear, the length kept
	ret

; eth_recv(r1 = buffer) -> r2 = length: waits for the next frame, copies it
; to the buffer (word-aligned) and gives its descriptor back to the card;
; fails after TIMEOUT cycles, with r4 = the descriptor
eth_recv:
	lw r3, VAR_RX_NEXT(r0)
	shli r4, r3, 3
	addi r4, r4, RX_RING
	mfcr r5, cycle
.wait:
	lw r2, 4(r4)
	li r6, ETH_DESC_OWN
	and r6, r6, r2
	beqz r6, .got
	mfcr r6, cycle
	sub r6, r6, r5
	li r7, TIMEOUT
	bltu r6, r7, .wait
	j fail
.got:
	li r6, 0xFFFF
	and r2, r2, r6                  ; the length
	lw r5, 0(r4)                    ; the buffer
	addi r7, r2, 3
	shri r7, r7, 2                  ; words
.copy:
	beqz r7, .copied
	lw r8, 0(r5)
	sw r8, 0(r1)
	addi r5, r5, 4
	addi r1, r1, 4
	addi r7, r7, -1
	j .copy
.copied:
	li r6, ETH_DESC_OWN | BUF_SIZE
	sw r6, 4(r4)                    ; the card's again
	addi r3, r3, 1
	andi r3, r3, RX_COUNT - 1
	sw r3, VAR_RX_NEXT(r0)
	ret

; eth_quiet: fails if a frame comes in the next QUIET cycles, with r2 =
; its descriptor's word
eth_quiet:
	lw r3, VAR_RX_NEXT(r0)
	shli r4, r3, 3
	addi r4, r4, RX_RING
	mfcr r5, cycle
.wait:
	lw r2, 4(r4)
	li r6, ETH_DESC_OWN
	and r6, r6, r2
	beqz r6, fail
	mfcr r6, cycle
	sub r6, r6, r5
	li r7, QUIET
	bltu r6, r7, .wait
	ret

; ---- bytes ----------------------------------------------------------------------

; get16(r1 = address) -> r1
get16:
	lbu r2, 0(r1)
	lbu r3, 1(r1)
	shli r2, r2, 8
	or r1, r2, r3
	ret

; get32(r1 = address) -> r1
get32:
	lbu r2, 0(r1)
	lbu r3, 1(r1)
	lbu r4, 2(r1)
	lbu r5, 3(r1)
	shli r2, r2, 24
	shli r3, r3, 16
	shli r4, r4, 8
	or r2, r2, r3
	or r4, r4, r5
	or r1, r2, r4
	ret

; put16(r1 = address, r2 = value)
put16:
	shri r3, r2, 8
	sb r3, 0(r1)
	sb r2, 1(r1)
	ret

; put32(r1 = address, r2 = value)
put32:
	shri r3, r2, 24
	sb r3, 0(r1)
	shri r3, r2, 16
	sb r3, 1(r1)
	shri r3, r2, 8
	sb r3, 2(r1)
	sb r2, 3(r1)
	ret

; copy(r1 = to, r2 = from, r3 = bytes)
copy:
	beqz r3, .done
	lbu r4, 0(r2)
	sb r4, 0(r1)
	addi r1, r1, 1
	addi r2, r2, 1
	addi r3, r3, -1
	j copy
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

; sum16(r1 = address, r2 = bytes, r3 = sum) -> r3: the bytes added to the
; sum of an internet checksum (RFC 1071), as big-endian half-words
sum16:
	add r4, r1, r2                  ; the end
.next:
	addi r5, r1, 1
	bgeu r5, r4, .tail              ; fewer than 2 bytes left
	lbu r6, 0(r1)
	lbu r7, 1(r1)
	shli r6, r6, 8
	or r6, r6, r7
	add r3, r3, r6
	addi r1, r1, 2
	j .next
.tail:
	bgeu r1, r4, .done
	lbu r6, 0(r1)
	shli r6, r6, 8
	add r3, r3, r6
.done:
	ret

; fold(r3 = sum) -> r1: the checksum of the sum, 0 if the bytes summed
; held a right one
fold:
	li r6, 0xFFFF
.again:
	shri r5, r3, 16
	beqz r5, .done
	and r3, r3, r6
	add r3, r3, r5
	j .again
.done:
	xor r1, r3, r6
	ret

; ---- IP -------------------------------------------------------------------------

; ip_header(r1 = destination, r2 = protocol, r3 = payload bytes): the
; Ethernet and IP headers of a packet from the guest at TX_FRAME
ip_header:
	addi r30, r30, -16
	sw ra, 0(r30)
	sw r1, 4(r30)
	sw r2, 8(r30)
	sw r3, 12(r30)
	li r1, TX_FRAME
	la r2, ip_template
	li r3, IP_PAYLOAD
	call copy
	li r1, TX_FRAME + 16            ; the total length
	lw r2, 12(r30)
	addi r2, r2, 20
	call put16
	lw r2, 8(r30)
	li r1, TX_FRAME
	sb r2, 23(r1)
	li r1, TX_FRAME + 30
	lw r2, 4(r30)
	call put32
	lw ra, 0(r30)
	addi r30, r30, 16
	ret

; ip_check(r1 = frame, r2 = protocol, r3 = source): fails unless the frame
; is an IP packet of the protocol from the source to the guest, with a
; 20-byte header and its checksum right
ip_check:
	addi r30, r30, -16
	sw ra, 0(r30)
	sw r1, 4(r30)
	sw r3, 8(r30)
	lhu r4, 12(r1)                  ; EtherType 0x0800
	li r3, 0x0008
	bne r4, r3, fail
	lbu r4, 14(r1)
	li r3, 0x45
	bne r4, r3, fail
	lbu r4, 23(r1)
	bne r4, r2, fail
	addi r1, r1, 26
	call get32
	mv r4, r1
	lw r3, 8(r30)
	bne r4, r3, fail
	lw r1, 4(r30)
	addi r1, r1, 30
	call get32
	mv r4, r1
	li r3, GUEST
	bne r4, r3, fail
	lw r1, 4(r30)
	addi r1, r1, 14
	li r2, 20
	li r3, 0
	call sum16
	call fold
	mv r4, r1
	bnez r4, fail
	lw ra, 0(r30)
	addi r30, r30, 16
	ret

; l4_checksum(r1 = frame): fails unless the checksum of the TCP segment
; or UDP datagram in the IP packet is right, with r4 = what it sums to
l4_checksum:
	addi r30, r30, -8
	sw ra, 0(r30)
	sw r1, 4(r30)
	addi r1, r1, 16
	call get16
	addi r8, r1, -20                ; the segment's length
	lw r1, 4(r30)
	lbu r3, 23(r1)                  ; the pseudo header: protocol, length,
	add r3, r3, r8                  ; and the two addresses
	addi r1, r1, 26
	li r2, 8
	call sum16
	lw r1, 4(r30)
	addi r1, r1, IP_PAYLOAD
	mv r2, r8
	call sum16
	call fold
	mv r4, r1
	bnez r4, fail
	lw ra, 0(r30)
	addi r30, r30, 8
	ret

; ---- TCP ------------------------------------------------------------------------

; conn_init(r1 = connection, r2 = the guest's port, r3 = address, r4 =
; port, r5 = the guest's first sequence number)
conn_init:
	sw r2, CONN_LPORT(r1)
	sw r3, CONN_RADDR(r1)
	sw r4, CONN_RPORT(r1)
	sw r5, CONN_SND(r1)
	sw r0, CONN_RCV(r1)
	ret

; tcp_send(r1 = connection, r2 = flags, r3 = data, r4 = bytes): a segment
; from the guest's end, acking CONN_RCV; CONN_SND moves past it
tcp_send:
	addi r30, r30, -24
	sw ra, 0(r30)
	sw r1, 4(r30)
	sw r2, 8(r30)
	sw r3, 12(r30)
	sw r4, 16(r30)
	lw r1, CONN_RADDR(r1)
	li r2, IP_TCP
	addi r3, r4, 20
	call ip_header
	lw r5, 4(r30)
	li r1, TX_FRAME + 34
	lw r2, CONN_LPORT(r5)
	call put16
	lw r5, 4(r30)
	li r1, TX_FRAME + 36
	lw r2, CONN_RPORT(r5)
	call put16
	lw r5, 4(r30)
	li r1, TX_FRAME + 38
	lw r2, CONN_SND(r5)
	call put32
	lw r5, 4(r30)
	li r1, TX_FRAME + 42
	lw r2, CONN_RCV(r5)
	call put32
	li r1, TX_FRAME
	li r2, 0x50                     ; a 20-byte header
	sb r2, 46(r1)
	lw r2, 8(r30)
	sb r2, 47(r1)
	li r1, TX_FRAME + 48
	li r2, WINDOW
	call put16
	li r1, TX_FRAME + 50            ; the checksum and the urgent pointer
	li r2, 0
	call put32
	li r1, TX_FRAME + TCP_DATA
	lw r2, 12(r30)
	lw r3, 16(r30)
	call copy
	lw r1, 16(r30)
	addi r1, r1, TCP_DATA
	call eth_send
	lw r5, 4(r30)                   ; past the data, and SYN and FIN
	lw r2, CONN_SND(r5)
	lw r3, 16(r30)
	add r2, r2, r3
	lw r3, 8(r30)
	andi r3, r3, TCP_SYN | TCP_FIN
	snez r3, r3
	add r2, r2, r3
	sw r2, CONN_SND(r5)
	lw ra, 0(r30)
	addi r30, r30, 24
	ret

; tcp_check(r1 = frame, r2 = connection, r3 = flags) -> r1 = bytes of
; data, r2 = where they start. Fails unless the frame is a segment to the
; guest's end of the connection with exactly these flags and its checksums
; right: in order (or a SYN, which sets CONN_RCV), and with ACK acking all
; the guest sent. CONN_RCV moves past it.
tcp_check:
	addi r30, r30, -16
	sw ra, 0(r30)
	sw r1, 4(r30)
	sw r2, 8(r30)
	sw r3, 12(r30)
	lw r3, CONN_RADDR(r2)
	li r2, IP_TCP
	call ip_check
	lw r1, 4(r30)
	call l4_checksum
	lw r1, 4(r30)                   ; the ports
	addi r1, r1, 34
	call get16
	mv r4, r1
	lw r5, 8(r30)
	lw r3, CONN_RPORT(r5)
	bne r4, r3, fail
	lw r1, 4(r30)
	addi r1, r1, 36
	call get16
	mv r4, r1
	lw r5, 8(r30)
	lw r3, CONN_LPORT(r5)
	bne r4, r3, fail
	lw r1, 4(r30)                   ; the flags
	lbu r4, 47(r1)
	lw r3, 12(r30)
	bne r4, r3, fail
	andi r3, r3, TCP_ACK
	beqz r3, .sequence
	addi r1, r1, 42                 ; all that was sent is acked
	call get32
	mv r4, r1
	lw r5, 8(r30)
	lw r3, CONN_SND(r5)
	bne r4, r3, fail
.sequence:
	lw r1, 4(r30)
	addi r1, r1, 38
	call get32
	mv r4, r1
	lw r5, 8(r30)
	lw r3, 12(r30)
	andi r3, r3, TCP_SYN
	beqz r3, .in_order
	sw r4, CONN_RCV(r5)             ; the other end's first number
	j .payload
.in_order:
	lw r3, CONN_RCV(r5)
	bne r4, r3, fail
.payload:
	lw r1, 4(r30)                   ; what the packet holds past both headers
	addi r1, r1, 16
	call get16
	lw r2, 4(r30)
	lbu r3, 46(r2)
	shri r3, r3, 4
	shli r3, r3, 2                  ; the TCP header's length
	sub r1, r1, r3
	addi r1, r1, -20
	addi r2, r2, IP_PAYLOAD
	add r2, r2, r3
	lw r5, 8(r30)                   ; past the data, and SYN and FIN
	lw r4, CONN_RCV(r5)
	add r4, r4, r1
	lw r3, 12(r30)
	andi r3, r3, TCP_SYN | TCP_FIN
	snez r3, r3
	add r4, r4, r3
	sw r4, CONN_RCV(r5)
	lw ra, 0(r30)
	addi r30, r30, 16
	ret

; ---- UDP ------------------------------------------------------------------------

; udp_send(r1 = the guest's port, r2 = address, r3 = port, r4 = data,
; r5 = bytes): a datagram from the guest
udp_send:
	addi r30, r30, -24
	sw ra, 0(r30)
	sw r1, 4(r30)
	sw r2, 8(r30)
	sw r3, 12(r30)
	sw r4, 16(r30)
	sw r5, 20(r30)
	mv r1, r2
	li r2, IP_UDP
	addi r3, r5, 8
	call ip_header
	li r1, TX_FRAME + 34
	lw r2, 4(r30)
	call put16
	li r1, TX_FRAME + 36
	lw r2, 12(r30)
	call put16
	li r1, TX_FRAME + 38
	lw r2, 20(r30)
	addi r2, r2, 8
	call put16
	li r1, TX_FRAME + 40            ; no checksum
	li r2, 0
	call put16
	li r1, TX_FRAME + UDP_DATA
	lw r2, 16(r30)
	lw r3, 20(r30)
	call copy
	lw r1, 20(r30)
	addi r1, r1, UDP_DATA
	call eth_send
	lw ra, 0(r30)
	addi r30, r30, 24
	ret

; udp_check(r1 = frame, r2 = source address, r3 = source port, 0 for any,
; r4 = the guest's port) -> r1 = bytes of data, r2 = where they start,
; r3 = the source port. Fails unless the frame is such a datagram, with
; its checksums right.
udp_check:
	addi r30, r30, -24
	sw ra, 0(r30)
	sw r1, 4(r30)
	sw r3, 8(r30)
	sw r4, 12(r30)
	mv r3, r2
	li r2, IP_UDP
	call ip_check
	lw r1, 4(r30)
	call l4_checksum
	lw r1, 4(r30)
	addi r1, r1, 36
	call get16
	mv r4, r1
	lw r3, 12(r30)
	bne r4, r3, fail
	lw r1, 4(r30)
	addi r1, r1, 34
	call get16
	sw r1, 16(r30)
	mv r4, r1
	lw r3, 8(r30)
	beqz r3, .any
	bne r4, r3, fail
.any:
	lw r1, 4(r30)
	addi r1, r1, 38
	call get16
	addi r1, r1, -8
	lw r2, 4(r30)
	addi r2, r2, UDP_DATA
	lw r3, 16(r30)
	lw ra, 0(r30)
	addi r30, r30, 24
	ret

; the headers of the guest's packets: to the gateway's MAC address, from
; 10.0.2.15; the length, the protocol and the destination are filled in
ip_template:
	.db 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02, 0x52, 0x54, 0x00, 0x12, 0x34, 0x56, 0x08, 0x00
	.db 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x40, 0x00, 0x00, 0x00
	.db 0x0A, 0x00, 0x02, 0x0F, 0x00, 0x00, 0x00, 0x00
	.align 4
