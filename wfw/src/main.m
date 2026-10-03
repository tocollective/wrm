// WRM.081632 ROM firmware. Build with:
//   python3 mc/mc.py --rom wfw/src/main.m -o firmware.rom
//
// Reset is in mc/runtime/rom0.asm. The firmware installs its own screen
// trap handler as soon as main starts.
// The boot hand-off and safe hardware probes are in boot/boot.asm.

import {
    pic, kbd, timer, power, beeper,
    KBD_READY, POWER_OFF_REQUEST, IRQ_POWER, BEEPER_ON,
    BOOT_INFO, BOOT_INFO_END, DeviceEntry,
} from "arch/wrm081632/defs.m"
import { consoleInit, write, writeChar, writeHex } from "console/console.m"
import { boot, machineRamSize, machineDevices } from "boot/boot.m"
import { installTrap } from "trap/trap.m"

let VERSION: *UByte = "WRM.081632 ROM 1.0.0\n"

enum MenuCommand: UByte {
    Invalid,
    Retry = 'r',
    Devices = 'd',
    Help = 'h',
    Power = 'p',
}

// USB HID usage IDs, keyboard page 0x07.
enum KeyUsage: UWord {
    D = 0x07,
    H = 0x0B,
    P = 0x13,
    R = 0x15,
}

let main(argc: UWord, argv: *UByte[]): Word {
    installTrap()
    pic.enable = 0
    beeper.frequency = 1000
    beeper.duration = timer.frequency / 10
    beeper.control = BEEPER_ON

    if !consoleInit() {
        return 254
    }

    write(VERSION)
    write("reset cause: ")
    writeHex(power.resetCause)
    write("\nRAM bytes: ")
    writeHex(machineRamSize())
    write("\n")

    boot()
    write("No boot image found. Diagnostic menu ready.\n")
    menu()
    return 0
}

let menu(): Void {
    // The CPU keeps interrupts off. Enabling the PIC line lets the host
    // deliver a power-button request, which this loop polls.
    pic.enable = 1 << IRQ_POWER
    showHelp()
    while true {
        write("wrm> ")
        switch readCommand() {
            case MenuCommand.Retry:
                write("Retrying floppy, then disk 0...\n")
                boot()
                write("No boot image found.\n")
                break
            case MenuCommand.Devices:
                showDevices()
                break
            case MenuCommand.Help:
                showHelp()
                break
            case MenuCommand.Power:
                write("Powering off.\n")
                power.off = 0
                return
            default:
                showHelp()
        }
    }
}

let showHelp(): Void {
    write("r retry boot | d devices | h help | p power off\n")
}

let showDevices(): Void {
    let table: UWord = BOOT_INFO
    let count: UWord = machineDevices(table, (BOOT_INFO_END - table) / sizeof(DeviceEntry))
    let entries: *DeviceEntry = table as *DeviceEntry
    write("Devices (address, ID):\n")
    for i: UWord in 0..count {
        write("  ")
        writeHex(entries[i].address)
        write("  ")
        writeHex(entries[i].id)
        write("\n")
    }
}

let readCommand(): MenuCommand {
    while true {
        if power.status & POWER_OFF_REQUEST != 0 {
            power.status = POWER_OFF_REQUEST
            write("\nPower button pressed.\n")
            power.off = 0
        }
        if kbd.status & KBD_READY != 0 {
            let event: UWord = kbd.data
            if event & 0x8000_0000 != 0 continue // key release
            let command: MenuCommand = keyCommand((event & 0xFFFF) as KeyUsage)
            if command != MenuCommand.Invalid {
                writeChar(command as UByte)
                write("\n")
                return command
            }
        }
    }
}

let keyCommand(usage: KeyUsage): MenuCommand {
    switch usage {
        case KeyUsage.R:
            return MenuCommand.Retry
        case KeyUsage.D:
            return MenuCommand.Devices
        case KeyUsage.H:
            return MenuCommand.Help
        case KeyUsage.P:
            return MenuCommand.Power
    }
    return MenuCommand.Invalid
}
