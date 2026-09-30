#ifndef WRM_KEYBOARD_H
#define WRM_KEYBOARD_H
#include "common.h"

#include "devices/pic.h"

#define KEYBOARD_FIFO_SIZE 32

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define KEYBOARD_REG_STATUS 0x00 // R
#define KEYBOARD_REG_DATA 0x04 // R: pops the next event, 0 if empty
#define KEYBOARD_REG_CONTROL 0x08 // W

#define KEYBOARD_STATUS_READY 0x01 // FIFO is not empty
#define KEYBOARD_STATUS_OVERFLOW 0x02 // events were dropped, cleared on read

#define KEYBOARD_CONTROL_FLUSH 0x01 // drop all pending events

// Event layout: bits 0-15 = USB HID usage ID (page 0x07), bit 31 = release
#define KEYBOARD_EVENT_CODE_MASK 0xFFFF
#define KEYBOARD_EVENT_RELEASE 0x80000000

// IRQ line is asserted while the FIFO is not empty.
typedef struct keyboard {
	pic_t* pic;
	uint8_t irq;
	uint32_t fifo[KEYBOARD_FIFO_SIZE];
	uint8_t head; // next event to read
	uint8_t count;
	bool overflow;
} keyboard_t;

keyboard_t* keyboard_create(pic_t* pic, const uint8_t irq);
void keyboard_destroy(keyboard_t* kbd);

void keyboard_reset(keyboard_t* kbd);
// host side: queue a key event
void keyboard_key(keyboard_t* kbd, const uint16_t code, const bool pressed);

// bus side: offset is relative to the device base; return true on bus error
bool keyboard_read(keyboard_t* kbd, const uint32_t offset, const uint8_t size,
				   uint32_t* value);
bool keyboard_write(keyboard_t* kbd, const uint32_t offset, const uint8_t size,
					const uint32_t value);

#endif // WRM_KEYBOARD_H
