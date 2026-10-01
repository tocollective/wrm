#ifndef WRM_MOTHERBOARD_H
#define WRM_MOTHERBOARD_H
#include "common.h"

#include "clock.h"
#include "config.h"
#include "cpu.h"
#include "devices/audiocard.h"
#include "devices/beeper.h"
#include "devices/disk.h"
#include "devices/keyboard.h"
#include "devices/mouse.h"
#include "devices/netcard.h"
#include "devices/pic.h"
#include "devices/pit.h"
#include "devices/power.h"
#include "devices/rtc.h"
#include "devices/uart.h"
#include "devices/videocard.h"
#include "ram.h"
#include "rom.h"

#define RAM_SLOT_COUNT CONFIG_RAM_SLOT_COUNT
#define DISK_COUNT CONFIG_HDD_COUNT

// Memory map (see docs/SPECIFICATION.md)
#define MB_RAM_BASE 0x00000000 // installed slots are mapped back to back
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
#define MB_NET_BASE 0xFD00B000
#define MB_AUDIO_BASE 0xFD00C000
#define MB_RTC_BASE 0xFD00D000
#define MB_ROM_BASE 0xFE000000 // ROM_MAX_SIZE bytes up to 0xFFFFFFFF

// IRQ lines (see docs/SPECIFICATION.md)
#define MB_IRQ_KEYBOARD 0
#define MB_IRQ_UART 1
#define MB_IRQ_PIT 2
#define MB_IRQ_DISK0 3 // disk N on line MB_IRQ_DISK0 + N
#define MB_IRQ_VIDEO 5 // after the disks
#define MB_IRQ_FLOPPY 6
#define MB_IRQ_MOUSE 7
#define MB_IRQ_NET 8
#define MB_IRQ_AUDIO 9
#define MB_IRQ_RTC 10
#define MB_IRQ_POWER 11

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
	MB_DEVICE_NET = 11,
	MB_DEVICE_AUDIO = 12,
	MB_DEVICE_RTC = 13,
} mb_device_type_t;

typedef struct ram_slot {
	ram_t* ram;
	bool installed;
} ram_slot_t;

typedef struct motherboard {
	sys_clock_t* clock;
	cpu_t* cpu;
	ram_slot_t ram_slot[RAM_SLOT_COUNT];
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
	netcard_t* netcard;
	audiocard_t* audiocard;
	rtc_t* rtc;
} motherboard_t;

motherboard_t* motherboard_create(void);
void motherboard_destroy(motherboard_t* mb);

// Resets the CPU and every device; RAM keeps its contents. cause is what
// the power controller's RESET_CAUSE then reads.
void motherboard_reset(motherboard_t* mb, const power_reset_cause_t cause);
// Advances the machine by one clock tick.
void motherboard_tick(motherboard_t* mb);

#endif // WRM_MOTHERBOARD_H
