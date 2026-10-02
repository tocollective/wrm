// Ethernet card: a driver that polls it, and the little of IPv4 the demo
// needs on top of it: ARP, ping, UDP, DHCP and DNS queries.
//
// The card moves frames by DMA through two rings of descriptors in RAM.
// Behind it is the emulator's network (unless it runs with --no-net): a
// gateway at 10.0.2.2 that hands out an address by DHCP and passes
// packets on to the host's network, and a DNS server at 10.0.2.3.
// Frames come in as the emulator services the network, between the CPU's
// instructions, so the helpers here poll the descriptors, with a timeout.
// Numbers in packets are big-endian.

import {
    eth, timer, EthDesc, ETH_LINK, ETH_ENABLE, ETH_DESC_LENGTH, ETH_DESC_ERROR, ETH_DESC_OWN,
} from "defs.m"
import { putc, printDec, printHex } from "lib.m"

let RX_COUNT: UWord = 4             // receive descriptors
let BUF_SIZE: UWord = 1536          // a buffer; the longest frame is 1514 bytes
let TIMEOUT_MS: UWord = 5000        // a DNS lookup on the host may take seconds

let ETH_HEADER: UWord = 14
let TYPE_IP: UWord = 0x0800
let TYPE_ARP: UWord = 0x0806
let ARP_SIZE: UWord = 28
let IP_HEADER: UWord = 20
let IP_PAYLOAD: UWord = 34          // ETH_HEADER + IP_HEADER: TCP, UDP, ICMP
let IP_ICMP: UWord = 1
let IP_UDP: UWord = 17
let UDP_HEADER: UWord = 8
let UDP_DATA: UWord = 42            // IP_PAYLOAD + UDP_HEADER
let ICMP_HEADER: UWord = 8
let BROADCAST: UWord = 0xFFFF_FFFF

let DHCP_SERVER_PORT: UWord = 67
let DHCP_CLIENT_PORT: UWord = 68
let DHCP_SIZE: UWord = 300          // BOOTP's smallest message
let DHCP_OPTIONS: UWord = 240       // where the options start
let DHCP_MAGIC: UWord = 0x6382_5363
let DHCP_XID: UWord = 0x5752_4D21   // "WRM!": our transaction
let DHCP_DISCOVER: UWord = 1
let DHCP_OFFER: UWord = 2
let DHCP_REQUEST: UWord = 3
let DHCP_ACK: UWord = 5

let DNS_PORT: UWord = 53
let DNS_CLIENT_PORT: UWord = 49153  // ours, for the queries
let DNS_HEADER: UWord = 12
let DNS_ID: UWord = 0x4D21

let PING_ID: UWord = 0x5752
let PING_DATA: *UByte = "WRM.081632 ping!"
let PING_SIZE: UWord = 16

let BROADCAST_MAC: UByte[6] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]

align(8) let mut rxRing: EthDesc[RX_COUNT]
align(8) let mut txRing: EthDesc[1]
let mut rxBuf: UByte[RX_COUNT * BUF_SIZE]   // descriptor n's at n * BUF_SIZE
let mut txBuf: UByte[BUF_SIZE]
let mut rxNext: UWord               // the descriptor the next frame is in
let mut ipId: UWord                 // of the next packet

/// The card's MAC address, read by ethInit.
let mut mac: UByte[6]
/// What DHCP gave (dhcpConfigure): our address, the gateway, the DNS
/// server; 0 until then.
let mut myAddr: UWord
let mut gateway: UWord
let mut dnsServer: UWord

// ---- bytes ----------------------------------------------------------------

let get16(p: *UByte): UWord {
    return (p[0] as UWord) << 8 | p[1] as UWord
}

let get32(p: *UByte): UWord {
    return get16(p) << 16 | get16(&p[2])
}

let put16(p: *mut UByte, v: UWord): Void {
    p[0] = (v >> 8) as UByte
    p[1] = v as UByte
}

let put32(p: *mut UByte, v: UWord): Void {
    put16(p, v >> 16)
    put16(&mut p[2], v)
}

let copy(dst: *mut UByte, src: *UByte, n: UWord): Void {
    for i: UWord in 0..n dst[i] = src[i]
}

let fill(dst: *mut UByte, v: UByte, n: UWord): Void {
    for i: UWord in 0..n dst[i] = v
}

/// Adds n bytes at p to the sum of an internet checksum (RFC 1071).
let sum16(p: *UByte, n: UWord, sum: UWord): UWord {
    let mut s: UWord = sum
    let mut i: UWord = 0
    while i + 1 < n {
        s += get16(&p[i])
        i += 2
    }
    if n & 1 != 0 s += (p[n - 1] as UWord) << 8
    return s
}

/// The checksum of a sum: folded to 16 bits and complemented.
let checksum(sum: UWord): UWord {
    let mut s: UWord = sum
    while s >> 16 != 0 s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF
}

/// The sum of the pseudo header that UDP's checksum covers too.
let pseudoSum(src: UWord, dst: UWord, protocol: UWord, length: UWord): UWord {
    return (src >> 16) + (src & 0xFFFF) + (dst >> 16) + (dst & 0xFFFF) + protocol + length
}

// ---- the card ---------------------------------------------------------------

/// Sets up the rings and turns the card on; false if its link is down
/// (the emulator runs with --no-net).
let ethInit(): Bool {
    eth.control = 0                 // the rings change only while it is off
    let lo: UWord = eth.macLo
    let hi: UWord = eth.macHi
    for i: UWord in 0..4 mac[i] = (lo >> (8 * i)) as UByte
    mac[4] = hi as UByte
    mac[5] = (hi >> 8) as UByte
    if eth.status & ETH_LINK == 0 return false

    for i: UWord in 0..RX_COUNT {
        let d: *volatile mut EthDesc = &mut rxRing[i]
        d.buffer = &mut rxBuf[i * BUF_SIZE] as UWord
        d.word = ETH_DESC_OWN | BUF_SIZE    // the card's to fill
    }
    rxNext = 0
    eth.rxRing = &mut rxRing[0] as UWord
    eth.rxSize = RX_COUNT
    eth.txRing = &mut txRing[0] as UWord
    eth.txSize = 1
    eth.control = ETH_ENABLE        // both rings start from their first descriptor
    return true
}

/// Turns the card off: frames that come in are dropped.
let ethStop(): Void {
    eth.control = 0
}

/// Sends the frame in txBuf, n bytes; false if the card didn't.
let ethSend(n: UWord): Bool {
    let d: *volatile mut EthDesc = &mut txRing[0]
    d.buffer = &mut txBuf[0] as UWord
    fence()                         // the frame is in RAM before the card reads it
    d.word = ETH_DESC_OWN | n
    eth.txKick = 0                  // sent in this store: the card is done with it
    return d.word & (ETH_DESC_OWN | ETH_DESC_ERROR) == 0
}

/// Waits for the next frame, ms milliseconds at most; its length, 0 if
/// none came. The frame is at rxFrame() until ethRelease().
let ethReceive(ms: UWord): UWord {
    let d: *volatile mut EthDesc = &mut rxRing[rxNext]
    let start: UWord = timer.countLo
    let ticks: UWord = timer.frequency / 1000 * ms
    while d.word & ETH_DESC_OWN != 0 {
        if timer.countLo - start >= ticks return 0
    }
    fence()                         // the frame's bytes after its descriptor
    return d.word & ETH_DESC_LENGTH
}

/// The frame ethReceive() waited for.
let rxFrame(): *UByte {
    return &rxBuf[rxNext * BUF_SIZE]
}

/// Gives the frame's buffer back to the card.
let ethRelease(): Void {
    let d: *volatile mut EthDesc = &mut rxRing[rxNext]
    d.word = ETH_DESC_OWN | BUF_SIZE
    rxNext = (rxNext + 1) % RX_COUNT
}

/// Starts a frame to dst (a MAC address); its payload goes at
/// txBuf[ETH_HEADER].
let ethHeader(dst: *UByte, kind: UWord): Void {
    copy(&mut txBuf[0], dst, 6)
    copy(&mut txBuf[6], &mac[0], 6)
    put16(&mut txBuf[12], kind)
}

// ---- ARP and IP ---------------------------------------------------------------

/// Asks who has addr; its MAC address goes to out. False if nobody says.
let arpResolve(addr: UWord, out: *mut UByte): Bool {
    ethHeader(&BROADCAST_MAC[0], TYPE_ARP)
    let a: *mut UByte = &mut txBuf[ETH_HEADER]
    put16(a, 1)                     // Ethernet
    put16(&mut a[2], TYPE_IP)
    a[4] = 6
    a[5] = 4
    put16(&mut a[6], 1)             // a request
    copy(&mut a[8], &mac[0], 6)
    put32(&mut a[14], myAddr)
    fill(&mut a[18], 0, 6)
    put32(&mut a[24], addr)
    if !ethSend(ETH_HEADER + ARP_SIZE) return false
    while true {
        let n: UWord = ethReceive(TIMEOUT_MS)
        if n == 0 return false
        let f: *UByte = rxFrame()
        let found: Bool = n >= ETH_HEADER + ARP_SIZE && get16(&f[12]) == TYPE_ARP
            && get16(&f[20]) == 2 && get32(&f[28]) == addr
        if found copy(out, &f[22], 6)
        ethRelease()
        if found return true
    }
}

/// Sends an IPv4 packet to dst through the MAC address via, n bytes of
/// payload already at txBuf[IP_PAYLOAD].
let ipSend(via: *UByte, dst: UWord, protocol: UWord, n: UWord): Bool {
    ethHeader(via, TYPE_IP)
    let ip: *mut UByte = &mut txBuf[ETH_HEADER]
    ip[0] = 0x45                    // version 4, a 20-byte header
    ip[1] = 0
    put16(&mut ip[2], IP_HEADER + n)
    put16(&mut ip[4], ipId)
    ipId++
    put16(&mut ip[6], 0)            // not a fragment
    ip[8] = 64                      // TTL
    ip[9] = protocol as UByte
    put16(&mut ip[10], 0)
    put32(&mut ip[12], myAddr)
    put32(&mut ip[16], dst)
    put16(&mut ip[10], checksum(sum16(ip, IP_HEADER, 0)))
    return ethSend(IP_PAYLOAD + n)
}

/// Whether frame f, n bytes, is an IPv4 packet of the protocol from src
/// (any if 0) with a 20-byte header, as the gateway sends them.
let ipReceived(f: *UByte, n: UWord, protocol: UWord, src: UWord): Bool {
    return n >= IP_PAYLOAD && get16(&f[12]) == TYPE_IP && f[14] == 0x45
        && f[23] as UWord == protocol && (src == 0 || get32(&f[26]) == src)
        && ETH_HEADER + get16(&f[16]) <= n
}

/// Pings addr through the MAC address via; true once the reply comes.
let ping(via: *UByte, addr: UWord, seq: UWord): Bool {
    let icmp: *mut UByte = &mut txBuf[IP_PAYLOAD]
    icmp[0] = 8                     // an echo request
    icmp[1] = 0
    put16(&mut icmp[2], 0)
    put16(&mut icmp[4], PING_ID)
    put16(&mut icmp[6], seq)
    copy(&mut icmp[ICMP_HEADER], PING_DATA, PING_SIZE)
    put16(&mut icmp[2], checksum(sum16(icmp, ICMP_HEADER + PING_SIZE, 0)))
    if !ipSend(via, addr, IP_ICMP, ICMP_HEADER + PING_SIZE) return false
    while true {
        let n: UWord = ethReceive(TIMEOUT_MS)
        if n == 0 return false
        let f: *UByte = rxFrame()
        let reply: Bool = ipReceived(f, n, IP_ICMP, addr) && f[IP_PAYLOAD] == 0
            && get16(&f[IP_PAYLOAD + 4]) == PING_ID && get16(&f[IP_PAYLOAD + 6]) == seq
        ethRelease()
        if reply return true
    }
}

// ---- UDP: DHCP and DNS ----------------------------------------------------------

/// Sends n bytes at txBuf[UDP_DATA] from our port sport to dst:dport,
/// through the MAC address via.
let udpSend(via: *UByte, dst: UWord, sport: UWord, dport: UWord, n: UWord): Bool {
    let udp: *mut UByte = &mut txBuf[IP_PAYLOAD]
    let size: UWord = UDP_HEADER + n
    put16(udp, sport)
    put16(&mut udp[2], dport)
    put16(&mut udp[4], size)
    put16(&mut udp[6], 0)
    let mut sum: UWord = checksum(sum16(udp, size, pseudoSum(myAddr, dst, IP_UDP, size)))
    if sum == 0 sum = 0xFFFF        // 0 would mean none
    put16(&mut udp[6], sum)
    return ipSend(via, dst, IP_UDP, size)
}

/// The length of the data of a UDP datagram in frame f, n bytes, from
/// src:sport (src any if 0) to our port dport; BROADCAST if f is something
/// else.
let udpReceived(f: *UByte, n: UWord, src: UWord, sport: UWord, dport: UWord): UWord {
    if !ipReceived(f, n, IP_UDP, src) || n < UDP_DATA return BROADCAST
    if get16(&f[IP_PAYLOAD]) != sport || get16(&f[IP_PAYLOAD + 2]) != dport return BROADCAST
    let size: UWord = get16(&f[IP_PAYLOAD + 4])
    if size < UDP_HEADER || IP_PAYLOAD + size > n return BROADCAST
    return size - UDP_HEADER
}

/// Broadcasts a DHCP message of the kind; requested and server go in its
/// options unless they are 0.
let dhcpSend(kind: UWord, requested: UWord, server: UWord): Bool {
    let m: *mut UByte = &mut txBuf[UDP_DATA]
    fill(m, 0, DHCP_SIZE)
    m[0] = 1                        // a request
    m[1] = 1                        // Ethernet
    m[2] = 6
    put32(&mut m[4], DHCP_XID)
    copy(&mut m[28], &mac[0], 6)    // chaddr
    put32(&mut m[236], DHCP_MAGIC)
    let mut o: UWord = DHCP_OPTIONS
    m[o] = 53                       // the message type
    m[o + 1] = 1
    m[o + 2] = kind as UByte
    o += 3
    if requested != 0 {
        m[o] = 50                   // the address asked for
        m[o + 1] = 4
        put32(&mut m[o + 2], requested)
        o += 6
    }
    if server != 0 {
        m[o] = 54                   // the server it is asked of
        m[o + 1] = 4
        put32(&mut m[o + 2], server)
        o += 6
    }
    m[o] = 255                      // the end
    return udpSend(&BROADCAST_MAC[0], BROADCAST, DHCP_CLIENT_PORT, DHCP_SERVER_PORT, DHCP_SIZE)
}

/// Whether frame f, n bytes, is the DHCP server's reply of the kind to
/// us. If it is, the address it gives goes to offer[0] and the server's
/// to server[0]; gateway and dnsServer get the router and the DNS server
/// it names.
let dhcpReply(f: *UByte, n: UWord, kind: UWord, offer: *mut UWord, server: *mut UWord): Bool {
    let size: UWord = udpReceived(f, n, 0, DHCP_SERVER_PORT, DHCP_CLIENT_PORT)
    if size == BROADCAST || size < DHCP_OPTIONS return false
    let m: *UByte = &f[UDP_DATA]
    if m[0] != 2 || get32(&m[4]) != DHCP_XID || get32(&m[236]) != DHCP_MAGIC return false
    let mut got: UWord = 0
    let mut router: UWord = 0
    let mut dns: UWord = 0
    let mut id: UWord = 0
    let mut i: UWord = DHCP_OPTIONS
    while i + 1 < size && m[i] != 255 {
        let code: UByte = m[i]
        if code == 0 {              // padding
            i++
            continue
        }
        let length: UWord = m[i + 1] as UWord
        if i + 2 + length > size break
        let v: *UByte = &m[i + 2]
        if code == 53 && length == 1 got = v[0] as UWord
        if code == 54 && length == 4 id = get32(v)
        if code == 3 && length >= 4 router = get32(v)
        if code == 6 && length >= 4 dns = get32(v)
        i += 2 + length
    }
    if got != kind return false
    offer[0] = get32(&m[16])        // yiaddr
    server[0] = id
    gateway = router
    dnsServer = dns
    return true
}

/// Waits for the DHCP server's reply of the kind; false if none came.
let dhcpWait(kind: UWord, offer: *mut UWord, server: *mut UWord): Bool {
    while true {
        let n: UWord = ethReceive(TIMEOUT_MS)
        if n == 0 return false
        let ours: Bool = dhcpReply(rxFrame(), n, kind, offer, server)
        ethRelease()
        if ours return true
    }
}

/// Gets an address by DHCP: DISCOVER, OFFER, REQUEST, ACK. Sets myAddr,
/// gateway and dnsServer; false if the server didn't answer.
let dhcpConfigure(): Bool {
    let mut offer: UWord = 0
    let mut server: UWord = 0
    if !dhcpSend(DHCP_DISCOVER, 0, 0) || !dhcpWait(DHCP_OFFER, &mut offer, &mut server)
        return false
    let mut acked: UWord = 0
    if !dhcpSend(DHCP_REQUEST, offer, server) || !dhcpWait(DHCP_ACK, &mut acked, &mut server)
        return false
    myAddr = acked
    return true
}

/// The offset past the name at offset at of DNS message m: its labels up
/// to the empty one, or up to a pointer to another name.
let dnsSkipName(m: *UByte, size: UWord, at: UWord): UWord {
    let mut i: UWord = at
    while i < size {
        let length: UWord = m[i] as UWord
        if length == 0 return i + 1
        if length & 0xC0 == 0xC0 return i + 2
        i += 1 + length
    }
    return size
}

/// The first IPv4 address among the answers of DNS message m, 0 if
/// there is none.
let dnsAddress(m: *UByte, size: UWord): UWord {
    if size < DNS_HEADER || get16(&m[2]) & 0x000F != 0 return 0    // RCODE: an error
    let mut answers: UWord = get16(&m[6])
    let mut i: UWord = dnsSkipName(m, size, DNS_HEADER) + 4         // past the question
    while answers > 0 {
        i = dnsSkipName(m, size, i)
        if i + 10 > size return 0
        let kind: UWord = get16(&m[i])
        let length: UWord = get16(&m[i + 8])
        if kind == 1 && length == 4 && i + 14 <= size return get32(&m[i + 10])
        i += 10 + length
        answers--
    }
    return 0
}

/// Looks up the IPv4 address of name at the DNS server, through the MAC
/// address via; 0 if it has none or didn't answer.
let dnsResolve(via: *UByte, name: *UByte): UWord {
    let q: *mut UByte = &mut txBuf[UDP_DATA]
    put16(q, DNS_ID)
    put16(&mut q[2], 0x0100)        // a query, recursion desired
    put16(&mut q[4], 1)             // one question
    put16(&mut q[6], 0)
    put16(&mut q[8], 0)
    put16(&mut q[10], 0)
    // the name as labels: "example.com" is 7 "example" 3 "com" 0
    let mut o: UWord = DNS_HEADER
    let mut start: UWord = 0        // the label being copied
    let mut i: UWord = 0
    while true {
        if name[i] == '.' || name[i] == 0 {
            let length: UWord = i - start
            q[o] = length as UByte
            copy(&mut q[o + 1], &name[start], length)
            o += 1 + length
            if name[i] == 0 break
            start = i + 1
        }
        i++
    }
    q[o] = 0
    put16(&mut q[o + 1], 1)         // type A
    put16(&mut q[o + 3], 1)         // class IN
    o += 5
    if !udpSend(via, dnsServer, DNS_CLIENT_PORT, DNS_PORT, o) return 0
    while true {
        let n: UWord = ethReceive(TIMEOUT_MS)
        if n == 0 return 0
        let f: *UByte = rxFrame()
        let size: UWord = udpReceived(f, n, dnsServer, DNS_PORT, DNS_CLIENT_PORT)
        if size != BROADCAST && size >= DNS_HEADER && get16(&f[UDP_DATA]) == DNS_ID {
            let addr: UWord = dnsAddress(&f[UDP_DATA], size)
            ethRelease()
            return addr
        }
        ethRelease()
    }
}

// ---- output ---------------------------------------------------------------------

/// Writes an IPv4 address in the dotted form.
let printAddr(addr: UWord): Void {
    for i: UWord in 4..0 by -1 {
        printDec(addr >> (8 * (i - 1)) & 0xFF)
        if i > 1 putc('.')
    }
}

/// Writes a MAC address as 52:54:00:12:34:56.
let printMac(p: *UByte): Void {
    for i: UWord in 0..6 {
        printHex(p[i] as UWord, 2)
        if i < 5 putc(':')
    }
}

export { mac, myAddr, gateway, dnsServer }
export { ethInit, ethStop, arpResolve, ping, dhcpConfigure, dnsResolve, printAddr, printMac }
