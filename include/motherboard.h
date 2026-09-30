#ifndef WRM_MOTHERBOARD_H
#define WRM_MOTHERBOARD_H
#include "common.h"

#include "clock.h"
#include "cpu.h"
#include "devices/keyboard.h"
#include "devices/pic.h"
#include "devices/uart.h"
#include "ram.h"
#include "rom.h"

#define RAM_SLOT_COUNT 4

// Memory map (see docs/SPECIFICATION.md)
#define MB_RAM_BASE 0x00000000 // installed slots are mapped back to back
#define MB_IO_BASE 0xFD000000 // memory-mapped devices, one page each
#define MB_IO_SIZE 0x01000000
#define MB_IO_PAGE_SIZE 0x1000
#define MB_PIC_BASE 0xFD000000
#define MB_KEYBOARD_BASE 0xFD001000
#define MB_UART_BASE 0xFD002000
#define MB_ROM_BASE 0xFE000000 // ROM_MAX_SIZE bytes up to 0xFFFFFFFF

// IRQ lines (see docs/SPECIFICATION.md)
#define MB_IRQ_KEYBOARD 0
#define MB_IRQ_UART 1

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
} motherboard_t;

motherboard_t* motherboard_create(void);
void motherboard_destroy(motherboard_t* mb);

#endif // WRM_MOTHERBOARD_H
