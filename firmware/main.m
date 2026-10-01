// WRM.081632 demo firmware, in M.
//
// Boots from the floppy or disk 0 if one holds a boot image (--floppy,
// --hdd, see docs/SPECIFICATION.md#boot-protocol); otherwise runs the
// demos.
//
// A tour of the machine: every instruction group, the UART, the keyboard,
// the PIC, polling, WFI, interrupts, the MMU and user mode, the timer and
// the cycle counters, the video modes, the mouse, the network, the audio
// card, the real-time clock, power off. The demos' output goes to the
// UART, i.e. to the host's stdout; the screen shows a short banner, the
// video modes and the mouse's pointer.
//
// Build (m/docs/COMPILER.md, "Цель: ROM"):
//   python3 tools/m.py --rom firmware/main.m -o firmware.s
//   python3 tools/asm.py firmware.s -o firmware.rom
//
// Files:
//   main.m           the order of the demos
//   defs.m           device registers, the CPU, the boot protocol
//   boot.m, .asm     booting from the floppy or disk 0
//   lib.m            UART output and helpers (puts, show, sort, ...)
//   video.m          video card setup, text, the screen console
//   mouse.m          enabling the mouse, decoding its events
//   net.m            the network card's commands, waiting for them
//   audio.m          playing samples on the audio card's voices
//   font.m           the 8x16 font, loaded into VRAM by videoInit
//   trap.m, .asm     the trap entry and the dispatch of interrupts
//   demos/*.m        one demo each; pcrel and the user program of mmu are
//                    assembly (.asm next to them)
//
// The reset code is m/runtime/rom0.asm: it sets the stack, copies .data to
// RAM, zeroes .bss and calls main; its result powers the machine off.

import { beeper, timer, power, ROM_BASE, BEEPER_ON } from "defs.m"
import { puts, show } from "lib.m"
import { videoInit, conPuts } from "video.m"
import { boot } from "boot.m"
import { demoAlu } from "demos/alu.m"
import { demoMemory } from "demos/memory.m"
import { demoCalls } from "demos/calls.m"
import { demoPcrel } from "demos/pcrel.m"
import { demoPolling } from "demos/polling.m"
import { demoInterrupts } from "demos/interrupts.m"
import { demoMmu } from "demos/mmu.m"
import { demoTimer } from "demos/timer.m"
import { demoVideo } from "demos/video.m"
import { demoMouse } from "demos/mouse.m"
import { demoNet } from "demos/net.m"
import { demoAudio } from "demos/audio.m"
import { demoRtc } from "demos/rtc.m"

/// The end of the ROM image (m/runtime/rom0.asm).
extern let __image_end: UByte

let main(argc: UWord, argv: *UByte[]): Word {
    postBeep()
    videoInit()                     // a boot image gets the screen console too
    conPuts("WRM.081632 firmware\n\n")
    boot()                          // returns if there is nothing to boot
    conPuts("No boot image: running the demos.\nTheir output goes to the UART console.\n")

    puts("\nWRM.081632 demo firmware\n========================\n")
    show("firmware size, bytes", &__image_end as UWord - ROM_BASE)
    show("reset cause", power.resetCause)   // 0 power-on, 1 RESET, 2 host

    demoAlu()
    demoMemory()
    demoCalls()
    demoPcrel()
    demoPolling()
    demoInterrupts()
    demoMmu()
    demoTimer()
    demoVideo()
    demoMouse()
    demoNet()
    demoAudio()
    demoRtc()

    puts("\nbye\n")
    // while true {}
    return 0                        // exit code 0: the emulator quits
}

/// A short beep at power-on, like a PC after its self-test. The beeper
/// times it by itself, so nothing waits for it to end.
let postBeep(): Void {
    beeper.frequency = 1000         // Hz
    beeper.duration = timer.frequency / 10     // 1/10 s of ticks
    beeper.control = BEEPER_ON
}
