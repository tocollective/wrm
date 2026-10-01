// [11] Network: a DNS lookup and an HTTP request, through the network
// card's TCP/IP in hardware. Needs a link: with the emulator's --no-net the
// demo says so and goes on.

import { puts, putc, show, strlen } from "../lib.m"
import { netLinked, netResolve, netConnect, netSend, netReceive, netClose, printAddr } from "../net.m"

let HOST: *UByte = "example.com"
let PORT: UWord = 80
let REQUEST: *UByte = "GET / HTTP/1.0\r\nHost: example.com\r\nConnection: close\r\n\r\n"
let SOCKET: UWord = 0

let mut reply: UByte[512]

let demoNet(): Void {
    puts("\n[11] network\n")
    if !netLinked() {
        puts("no link: run the emulator without --no-net to try it\n")
        return
    }

    puts(HOST)
    puts(" is ")
    let addr: UWord = netResolve(HOST)
    if addr == 0 {
        puts("not found\n")
        return
    }
    printAddr(addr)
    putc('\n')

    let failure: UWord = netConnect(SOCKET, addr, PORT)
    if failure != 0 {
        show("can't connect, error", failure)
        return
    }
    puts("connected, sending the request\n")
    if netSend(SOCKET, REQUEST, strlen(REQUEST)) != 0 {
        puts("can't send\n")
        netClose(SOCKET)
        return
    }

    // the reply until the server closes; its first line is the status
    let mut total: UWord = 0
    let mut firstLine: Bool = true
    while true {
        let n: UWord = netReceive(SOCKET, &mut reply[0], 512)
        if n == 0 break
        for i: UWord in 0..n {
            if !firstLine break
            if reply[i] == '\n' {
                firstLine = false
                putc('\n')
            } else if reply[i] != '\r' {
                putc(reply[i])
            }
        }
        total += n
    }
    netClose(SOCKET)
    show("reply, bytes", total)
}

export { demoNet }
