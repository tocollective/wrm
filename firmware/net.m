// Network card: waiting versions of its commands, by polling.
//
// The card has TCP/IP in hardware: a socket connects, sends and receives
// bytes, and the host's network does the rest (the emulator needs --net).
// Its state changes as the emulator services the network, between the
// CPU's instructions, so the helpers here poll the socket's registers.

import {
    net, netSocket, NET_LINK, NET_DNS_LOOKUP, NET_DNS_BUSY, NET_DNS_DONE,
    NET_CLOSED, NET_CONNECTING, NET_CONNECTED, NET_CONNECT, NET_SEND, NET_RECEIVE,
    NET_CLOSE, NET_EV_CONNECTED, NET_ERR_STATE,
} from "defs.m"
import { putc, printDec } from "lib.m"

/// The link is up: the emulator runs with --net.
let netLinked(): Bool {
    return net.status & NET_LINK != 0
}

/// The IPv4 address of a host name (or of a dotted address), 0 if it has
/// none. Waits for the lookup, which may take seconds.
let netResolve(name: *UByte): UWord {
    while net.dnsStatus & NET_DNS_BUSY != 0 {}     // one lookup at a time
    net.dnsName = name as UWord
    net.dnsCommand = NET_DNS_LOOKUP
    while net.dnsStatus & NET_DNS_BUSY != 0 {}
    net.dnsStatus = NET_DNS_DONE
    return net.dnsResult
}

/// Connects socket s to addr:port and waits until it is connected.
/// Returns the socket's ERROR: 0 once connected; otherwise the socket is
/// closed again.
let netConnect(s: UWord, addr: UWord, port: UWord): UWord {
    netSocket[s].peerAddr = addr
    netSocket[s].peerPort = port
    netSocket[s].command = NET_CONNECT
    while netSocket[s].state == NET_CONNECTING {}
    if netSocket[s].state == NET_CLOSED return netSocket[s].error
    netSocket[s].events = NET_EV_CONNECTED
    return 0
}

/// Sends n bytes at data (RAM or ROM) on socket s, waiting for room in
/// the send buffer as needed. Returns the socket's ERROR, 0 if all of it
/// went into the buffer.
let netSend(s: UWord, data: *UByte, n: UWord): UWord {
    netSocket[s].address = data as UWord
    netSocket[s].count = n
    while true {
        netSocket[s].command = NET_SEND     // moves what fits
        let failure: UWord = netSocket[s].error
        if failure != 0 return failure
        if netSocket[s].count == 0 return 0
        // the buffer is full: it empties as the host sends
        while netSocket[s].txFree == 0 {
            if netSocket[s].state != NET_CONNECTED return NET_ERR_STATE
        }
    }
}

/// Moves up to n received bytes of socket s to buf, waiting for at least
/// one. Returns how many; 0 once the connection has ended and every byte
/// has been read.
let netReceive(s: UWord, buf: *mut UByte, n: UWord): UWord {
    while netSocket[s].rxSize == 0 {
        // bytes may arrive just before the end: look at RX_SIZE again
        if netSocket[s].state != NET_CONNECTED && netSocket[s].rxSize == 0 return 0
    }
    netSocket[s].address = buf as UWord
    netSocket[s].count = n
    netSocket[s].command = NET_RECEIVE
    return n - netSocket[s].count
}

/// Closes socket s; bytes not sent yet are dropped.
let netClose(s: UWord): Void {
    netSocket[s].command = NET_CLOSE
}

/// Writes an IPv4 address in the dotted form.
let printAddr(addr: UWord): Void {
    for i: UWord in 4..0 by -1 {
        printDec(addr >> (8 * (i - 1)) & 0xFF)
        if i > 1 putc('.')
    }
}

export { netLinked, netResolve, netConnect, netSend, netReceive, netClose, printAddr }
