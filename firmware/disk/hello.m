// Example boot image: prints what the firmware passed on and powers off.
//
// Build:  python3 tools/m.py firmware/disk/hello.m -o hdd0.img
// Run:    bin/wrm081632 --hdd hdd0.img   (or --floppy hdd0.img)
//
// tools/m.py makes a boot image: crt0 (m/runtime/crt0.asm) starts it with
// the boot image header, and the linker pads the image to whole sectors,
// so it is itself a disk image. crt0 calls main(0, null): the
// boot info block is read where the firmware leaves it, at BOOT_INFO.

import { BootInfo, DeviceEntry, BOOT_INFO } from "../defs.m"
import { puts, putc, printHex, show } from "../lib.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let info: *BootInfo = BOOT_INFO as *BootInfo
    puts("\nhello from the boot disk\n")
    show("RAM, bytes", info.ramSize)
    show("boot disk controller", info.disk)
    show("disk size, sectors", info.diskSectors)
    show("image size, bytes", info.imageSize)
    show("clock, Hz", info.clock)
    show("devices", info.devices)
    let table: *DeviceEntry = info.deviceTable as *DeviceEntry
    for i: UWord in 0..info.devices {
        puts("  0x")
        printHex(table[i].address, 8)
        puts("  type ")
        printHex(table[i].id >> 16, 4)
        puts("  IRQ ")
        printHex(table[i].id & 0xFF, 2)
        putc('\n')
    }


    let mut func(): Void {
        puts("foo")
    }
    let bar(): Void {
        puts("bar")
    }
    func()
    func = bar
    func()
    bar()

    puts("\n")
    return 0
}
