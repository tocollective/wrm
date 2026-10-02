// [11] Network: the Ethernet card and a little IPv4 on top of it
// (net.m). An address from DHCP, the gateway's MAC address by ARP, a
// ping, and a DNS lookup that the host makes for the DNS server. Needs a
// link: with the emulator's --no-net the demo says so and goes on.

import { puts, putc } from "../lib.m"
import {
    mac, myAddr, gateway, dnsServer,
    ethInit, ethStop, arpResolve, ping, dhcpConfigure, dnsResolve, printAddr, printMac,
} from "../net.m"

let HOST: *UByte = "example.com"

let mut gatewayMac: UByte[6]
let mut dnsMac: UByte[6]

let demoNet(): Void {
    puts("\n[11] network\n")
    if !ethInit() {
        puts("no link: run the emulator without --no-net to try it\n")
        return
    }
    puts("MAC address ")
    printMac(&mac[0])
    putc('\n')

    if !dhcpConfigure() {
        puts("no answer from DHCP\n")
        ethStop()
        return
    }
    puts("DHCP: address ")
    printAddr(myAddr)
    puts(", gateway ")
    printAddr(gateway)
    puts(", DNS server ")
    printAddr(dnsServer)
    putc('\n')

    if !arpResolve(gateway, &mut gatewayMac[0]) {
        puts("the gateway doesn't answer ARP\n")
        ethStop()
        return
    }
    puts("gateway's MAC address ")
    printMac(&gatewayMac[0])
    putc('\n')

    printAddr(gateway)
    if ping(&gatewayMac[0], gateway, 1) puts(" answers ping\n") else puts(" doesn't answer ping\n")

    // the DNS server is on our network too: ask for its MAC address
    if arpResolve(dnsServer, &mut dnsMac[0]) {
        puts(HOST)
        puts(" is ")
        let addr: UWord = dnsResolve(&dnsMac[0], HOST)
        if addr == 0 puts("not found") else printAddr(addr)
        putc('\n')
    }
    ethStop()
}

export { demoNet }
