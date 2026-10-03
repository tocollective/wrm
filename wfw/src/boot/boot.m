// Booting from the floppy or disk 0 (docs/SPECIFICATION.md#boot-protocol).

import {
    pic, timer, floppy, disk0, Disk, BootHeader, BootInfo, DeviceEntry,
    DISK_PRESENT, DISK_DONE, DISK_READ, SECTOR_SIZE,
    BOOT_MAGIC, BOOT_INFO_MAGIC, BOOT_INFO, BOOT_INFO_END, BOOT_STACK_TOP, BOOT_LOAD,
    CR_PTBR, CR_IVEC, CR_STATUS, STATUS_EXL,
} from "../arch/wrm081632/defs.m"
import { write, writeHex } from "../console/console.m"
import { videoPalette } from "../video/video.m"

extern let ramSize(): UWord
extern let probeDevices(table: UWord, max: UWord): UWord
extern let onStack(fn: (): Void, top: UWord): Void
extern let bootJump(entry: UWord): Void

enum DiskError: UWord {
    UnknownCommand = 1,
    NoDisk,
    PastEnd,
    BadAddress,
    ReadOnly,
    HostIO,
    BadDescriptor,
}

/// Runs a disk command and waits for it by polling STATUS.
/// Returns ERROR, 0 on success.
let diskIo(d: Disk, command: UWord, sector: UWord, count: UWord,
           address: UWord): UWord {
    d.sector = sector
    d.count = count
    d.address = address
    d.command = command
    while d.status & DISK_DONE == 0 {}
    fence()                        // DMA writes to RAM precede reads below
    d.status = DISK_DONE            // acknowledge: drops the IRQ line
    return d.error
}

/// Loads the boot image from the first drive that holds one, the floppy
/// and then disk 0, and jumps to it. Returns only if there is nothing to
/// boot: no disks (silently), no boot image or an error (after showing
/// why, for each drive). Runs on its own stack below BOOT_LOAD, so the
/// image can't overwrite it wherever the caller's stack is.
let boot(): Void {
    onStack((): Void {
        bootDisk(floppy, "floppy")
        bootDisk(disk0, "disk 0")
    }, BOOT_STACK_TOP)
}

let machineRamSize(): UWord { return ramSize() }

let machineDevices(table: UWord, max: UWord): UWord {
    return probeDevices(table, max)
}

/// "boot: <drive><why>"
let fail(drive: *UByte, why: *UByte): Void {
    write("boot: ")
    write(drive)
    write(why)
}

let diskError(drive: *UByte, error: UWord): Void {
    fail(drive, ": disk error: ")
    switch error as DiskError {
        case DiskError.UnknownCommand:
            write("unknown command")
            break
        case DiskError.NoDisk:
            write("no disk")
            break
        case DiskError.PastEnd:
            write("past end of disk")
            break
        case DiskError.BadAddress:
            write("bad RAM address")
            break
        case DiskError.ReadOnly:
            write("read-only disk")
            break
        case DiskError.HostIO:
            write("host I/O failure")
            break
        case DiskError.BadDescriptor:
            write("bad DMA descriptor")
            break
        default:
            write("unknown error")
    }
    write(" (")
    writeHex(error)
    write(")\n")
}

let bootDisk(d: Disk, drive: *UByte): Void {
    if d.status & DISK_PRESENT == 0 return

    write("Loading from ")
    write(drive)
    write("...\n")

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
    // the device table right after the block, up to BOOT_INFO_END
    let table: UWord = BOOT_INFO + sizeof(BootInfo)
    info.devices = probeDevices(table, (BOOT_INFO_END - table) / sizeof(DeviceEntry))
    info.deviceTable = table

    write("Booting from ")
    write(drive)
    write(".\n")

    // the state after reset, except for what the protocol passes on
    videoPalette()
    pic.enable = 0
    mtcr(CR_PTBR, 0)
    mtcr(CR_IVEC, 0)
    mtcr(CR_STATUS, STATUS_EXL)
    bootJump(BOOT_LOAD + entry)
}

export { boot, machineRamSize, machineDevices }
