#ifndef WRM_MOTHERBOARD_H
#define WRM_MOTHERBOARD_H
#include "common.h"

#include "clock.h"
#include "config.h"
#include "cpu.h"
#include "devices/disk.h"
#include "devices/keyboard.h"
#include "devices/pic.h"
#include "devices/pit.h"
#include "devices/power.h"
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
#define MB_ROM_BASE 0xFE000000 // ROM_MAX_SIZE bytes up to 0xFFFFFFFF

// IRQ lines (see docs/SPECIFICATION.md)
#define MB_IRQ_KEYBOARD 0
#define MB_IRQ_UART 1
#define MB_IRQ_PIT 2
#define MB_IRQ_DISK0 3 // disk N on line MB_IRQ_DISK0 + N
#define MB_IRQ_VIDEO 5 // after the disks

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
	disk_t* disk[DISK_COUNT];
	videocard_t* videocard;
} motherboard_t;

motherboard_t* motherboard_create(void);
void motherboard_destroy(motherboard_t* mb);

// Resets the CPU and every device; RAM keeps its contents.
void motherboard_reset(motherboard_t* mb);
// Advances the machine by one clock tick.
void motherboard_tick(motherboard_t* mb);

#endif // WRM_MOTHERBOARD_H
