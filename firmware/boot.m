// Booting from the floppy or disk 0 (docs/SPECIFICATION.md#boot-protocol).

import {
    pic, timer, floppy, disk0, DiskRegs, BootHeader, BootInfo,
    DISK_PRESENT, DISK_DONE, DISK_READ, SECTOR_SIZE,
    BOOT_MAGIC, BOOT_INFO_MAGIC, BOOT_INFO, BOOT_STACK_TOP, BOOT_LOAD,
    CR_PTBR, CR_IVEC, CR_STATUS, STATUS_EXL,
} from "defs.m"
import { puts, putc, printDec } from "lib.m"

extern let ramSize(): UWord
extern let onStack(fn: (): Void, top: UWord): Void
extern let bootJump(entry: UWord): Void

/// Runs a DISK_READ or DISK_WRITE and waits for it by polling STATUS.
/// Returns ERROR, 0 on success.
let diskIo(d: *volatile mut DiskRegs, command: UWord, sector: UWord, count: UWord,
           address: UWord): UWord {
    d.sector = sector
    d.count = count
    d.address = address
    d.command = command
    while d.status & DISK_DONE == 0 {}
    d.status = DISK_DONE            // acknowledge: drops the IRQ line
    return d.error
}

/// Loads the boot image from the first drive that holds one, the floppy
/// and then disk 0, and jumps to it. Returns only if there is nothing to
/// boot: no disks (silently), no boot image or an error (after printing
/// why, for each drive). Runs on its own stack below BOOT_LOAD, so the
/// image can't overwrite it wherever the caller's stack is.
let boot(): Void {
    onStack(bootDrives, BOOT_STACK_TOP)
}

let bootDrives(): Void {
    bootDisk(floppy, "floppy")
    bootDisk(disk0, "disk 0")
}

/// "boot: <drive><why>"
let fail(drive: *UByte, why: *UByte): Void {
    puts("boot: ")
    puts(drive)
    puts(why)
}

let diskError(drive: *UByte, error: UWord): Void {
    fail(drive, ": disk error ")
    printDec(error)
    putc('\n')
}

let bootDisk(d: *volatile mut DiskRegs, drive: *UByte): Void {
    if d.status & DISK_PRESENT == 0 return

    // sector 0 starts with the header
    let mut error: UWord = diskIo(d, DISK_READ, 0, 1, BOOT_LOAD)
    if error != 0 {
        diskError(drive, error)
        return
    }
    let header: *BootHeader = BOOT_LOAD as *BootHeader
    if header.magic != BOOT_MAGIC {
        fail(drive, ": no boot image\n")
        return
    }
    let sectors: UWord = header.sectors
    if header.flags != 0 || sectors == 0 || sectors > d.sectors {
        fail(drive, ": bad boot image header\n")
        return
    }
    let ram: UWord = ramSize()
    if sectors > (ram - BOOT_LOAD) >> 9 {
        fail(drive, ": the boot image doesn't fit in RAM\n")
        return
    }
    let entry: UWord = header.entry
    if entry & 3 != 0 || entry >= sectors * SECTOR_SIZE {
        fail(drive, ": bad boot image header\n")
        return
    }

    // the rest of the image right after sector 0
    error = diskIo(d, DISK_READ, 1, sectors - 1, BOOT_LOAD + SECTOR_SIZE)
    if error != 0 {
        diskError(drive, error)
        return
    }

    let info: *mut BootInfo = BOOT_INFO as *mut BootInfo
    info.magic = BOOT_INFO_MAGIC
    info.size = sizeof(BootInfo)
    info.ramSize = ram
    info.disk = d as UWord
    info.diskSectors = d.sectors
    info.image = BOOT_LOAD
    info.imageSize = sectors * SECTOR_SIZE
    info.clock = timer.frequency

    // the state after reset, except for what the protocol passes on
    pic.enable = 0
    mtcr(CR_PTBR, 0)
    mtcr(CR_IVEC, 0)
    mtcr(CR_STATUS, STATUS_EXL)
    bootJump(BOOT_LOAD + entry)
}

export { boot, diskIo }
