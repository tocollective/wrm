// Example boot image: prints what the firmware passed on and powers off.
//
// Build:  python3 tools/m.py firmware/disk/hello.m -o hello.s
//         python3 tools/asm.py hello.s --base 0x10000 -o hdd0.img
// Run:    bin/wrm081632 --hdd hdd0.img   (or --floppy hdd0.img)
//
// tools/m.py makes a boot image: crt0 (m/runtime/crt0.asm) starts it with
// the boot image header, and the image is padded to whole sectors, so the
// assembler output is itself a disk image. crt0 calls main(0, null): the
// boot info block is read where the firmware leaves it, at BOOT_INFO.

import { BootInfo, BOOT_INFO } from "../defs.m"
import { puts, show } from "../lib.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let info: *BootInfo = BOOT_INFO as *BootInfo
    puts("\nhello from the boot disk\n")
    show("RAM, bytes", info.ramSize)
    show("boot disk controller", info.disk)
    show("disk size, sectors", info.diskSectors)
    show("image size, bytes", info.imageSize)
    show("clock, Hz", info.clock)
    return 0
}
