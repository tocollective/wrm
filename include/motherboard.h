#ifndef WRM_MOTHERBOARD_H
#define WRM_MOTHERBOARD_H
#include "common.h"

#include "clock.h"
#include "config.h"
#include "cpu.h"
#include "devices/audiocard.h"
#include "devices/beeper.h"
#include "devices/disk.h"
#include "devices/ethcard.h"
#include "devices/keyboard.h"
#include "devices/mouse.h"
#include "devices/pic.h"
#include "devices/pit.h"
#include "devices/power.h"
#include "devices/rng.h"
#include "devices/rtc.h"
#include "devices/share.h"
#include "devices/uart.h"
#include "devices/videocard.h"
#include "devices/watchdog.h"
#include "ram.h"
#include "rom.h"

#define RAM_SLOT_COUNT CONFIG_RAM_SLOT_COUNT
#define DISK_COUNT CONFIG_HDD_COUNT

// Memory map (see docs/SPECIFICATION.md)
#define MB_RAM_BASE 0x00000000 // installed slots are mapped back to back
#define MB_VRAM_BASE 0xFC000000 // the video card's VRAM, VIDEO_VRAM_SIZE bytes
#define MB_IO_BASE 0xFD000000 // memory-mapped devices, one page each
#define MB_IO_SIZE 0x01000000
#define MB_IO_PAGE_SIZE 0x1000
#define MB_PIC_BASE 0xFD000000
#define MB_KEYBOARD_BASE 0xFD001000
#define MB_UART_BASE 0xFD002000
#define MB_PIT_BASE 0xFD003000
#define MB_POWER_BASE 0xFD004000
#define MB_DISK0_BASE 0xFD005000 // disk N at MB_DISK0_BASE + N pages
#define MB_VIDEO_BASE 0xFD007000 // after the disks
#define MB_FLOPPY_BASE 0xFD008000
#define MB_BEEPER_BASE 0xFD009000
#define MB_MOUSE_BASE 0xFD00A000
#define MB_ETH_BASE 0xFD00B000
#define MB_AUDIO_BASE 0xFD00C000
#define MB_RTC_BASE 0xFD00D000
#define MB_RNG_BASE 0xFD00E000
#define MB_SHARE_BASE 0xFD00F000
#define MB_WATCHDOG_BASE 0xFD010000
#define MB_ROM_BASE 0xFE000000 // ROM_MAX_SIZE bytes up to 0xFFFFFFFF

// IRQ lines (see docs/SPECIFICATION.md)
#define MB_IRQ_KEYBOARD 0
#define MB_IRQ_UART 1
#define MB_IRQ_PIT 2
#define MB_IRQ_DISK0 3 // disk N on line MB_IRQ_DISK0 + N
#define MB_IRQ_VIDEO 5 // after the disks
#define MB_IRQ_FLOPPY 6
#define MB_IRQ_MOUSE 7
#define MB_IRQ_ETH 8
#define MB_IRQ_AUDIO 9
#define MB_IRQ_RTC 10
#define MB_IRQ_POWER 11
#define MB_IRQ_WATCHDOG 12

// Every device's page has an ID register at MB_IO_ID: the type in bits
// 31:16, the version in 15:8 and the IRQ line in 7:0 (MB_NO_IRQ for none)
#define MB_IO_ID 0xFFC
#define MB_DEVICE_VERSION 1
#define MB_NO_IRQ 0xFF

// Device types in the ID register (see docs/SPECIFICATION.md)
typedef enum mb_device_type {
	MB_DEVICE_PIC = 1,
	MB_DEVICE_KEYBOARD = 2,
	MB_DEVICE_UART = 3,
	MB_DEVICE_TIMER = 4,
	MB_DEVICE_POWER = 5,
	MB_DEVICE_DISK = 6, // a hard disk
	MB_DEVICE_VIDEO = 7,
	MB_DEVICE_FLOPPY = 8,
	MB_DEVICE_BEEPER = 9,
	MB_DEVICE_MOUSE = 10,
	MB_DEVICE_ETH = 11, // Ethernet card
	MB_DEVICE_AUDIO = 12,
	MB_DEVICE_RTC = 13,
	MB_DEVICE_RNG = 14, // random number generator
	MB_DEVICE_SHARE = 15, // shared folder
	MB_DEVICE_WATCHDOG = 16,
} mb_device_type_t;

typedef struct ram_slot {
	ram_t* ram;
	bool installed;
} ram_slot_t;

// The RAM region seen in 1MB chunks, the smallest slot: every slot starts
// and ends on a chunk, so an access within a chunk is within one slot.
#define MB_RAM_CHUNK_SHIFT 20
#define MB_RAM_CHUNK_SIZE (1u << MB_RAM_CHUNK_SHIFT)
#define MB_RAM_CHUNKS (RAM_SLOT_COUNT * 32) // slots of up to 32MB

// Devices that run on the clock, in the order they tick. Each one runs
// only when it has to: on the tick of its next event (a DMA word, the end
// of a frame, a timer expiring; see the devices' *_next_event) and before
// the CPU accesses its registers. In between it falls behind and catches
// up in one go, exactly as if it had ticked every time.
typedef enum mb_timed {
	MB_TIMED_PIT,
	MB_TIMED_DISK0, // disk N is MB_TIMED_DISK0 + N
	MB_TIMED_VIDEO = MB_TIMED_DISK0 + DISK_COUNT,
	MB_TIMED_FLOPPY,
	MB_TIMED_BEEPER,
	MB_TIMED_AUDIO,
	MB_TIMED_RTC,
	MB_TIMED_WATCHDOG,
	MB_TIMED_COUNT,
} mb_timed_t;

typedef struct motherboard {
	sys_clock_t* clock;
	cpu_t* cpu;
	ram_slot_t ram_slot[RAM_SLOT_COUNT];
	uint8_t* ram_map[MB_RAM_CHUNKS]; // host memory of each chunk, NULL = none
	rom_t* rom;
	pic_t* pic;
	keyboard_t* keyboard;
	uart_t* uart;
	pit_t* pit;
	power_t* power;
	disk_t* disk[DISK_COUNT]; // hard disks
	videocard_t* videocard;
	disk_t* floppy; // the same controller with a removable disk
	beeper_t* beeper;
	mouse_t* mouse;
	ethcard_t* ethcard;
	audiocard_t* audiocard;
	rtc_t* rtc;
	rng_t* rng;
	share_t* share;
	watchdog_t* watchdog;

	uint64_t tick; // clock ticks since power-on, the one running included
	uint64_t synced[MB_TIMED_COUNT]; // the tick each device has run up to
	uint64_t due[MB_TIMED_COUNT]; // the tick it runs next, or TICKS_NEVER
	uint64_t next_due; // the earliest of them
} motherboard_t;

motherboard_t* motherboard_create(void);
void motherboard_destroy(motherboard_t* mb);

// Resets the CPU and every device; RAM keeps its contents. cause is what
// the power controller's RESET_CAUSE then reads.
void motherboard_reset(motherboard_t* mb, const power_reset_cause_t cause);
// Runs the machine for that many clock ticks, or until it stops (powered
// off, halted, or by the debugger); returns the ticks run. On return every device is up to
// date, so the host can look at them and feed them input.
uint64_t motherboard_run(motherboard_t* mb, const uint64_t ticks);
// Nothing will run any more: powered off, or the CPU is halted.
bool motherboard_stopped(const motherboard_t* mb);

#endif // WRM_MOTHERBOARD_H
