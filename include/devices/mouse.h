#ifndef WRM_MOUSE_H
#define WRM_MOUSE_H
#include "common.h"

#include "devices/pic.h"

#define MOUSE_FIFO_SIZE 64

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define MOUSE_REG_STATUS 0x00 // R
#define MOUSE_REG_DATA 0x04 // R: pops the next event, 0 if empty
#define MOUSE_REG_CONTROL 0x08 // RW
#define MOUSE_REG_POSITION 0x0C // R: of the event popped last, x | y << 16

#define MOUSE_STATUS_READY 0x01 // FIFO is not empty
#define MOUSE_STATUS_OVERFLOW 0x02 // events were dropped, cleared on read

#define MOUSE_CONTROL_FLUSH 0x01 // W: drop all pending events, reads as 0
#define MOUSE_CONTROL_ENABLE 0x02 // events are queued only while set
#define MOUSE_CONTROL_ABSOLUTE 0x04 // the host's pointer, without capture

// Event layout: bits 0-7 = dx, 8-15 = dy (down), 16-23 = wheel (away from
// the user), all signed; bits 24-26 = buttons down after the event;
// bit 27 = absolute: no motion, the event has a position (POSITION);
// bit 31 = always set, so an event is never 0
#define MOUSE_EVENT_DY_SHIFT 8
#define MOUSE_EVENT_WHEEL_SHIFT 16
#define MOUSE_EVENT_BUTTON_SHIFT 24
#define MOUSE_EVENT_ABSOLUTE 0x08000000
#define MOUSE_EVENT_VALID 0x80000000

#define MOUSE_BUTTON_LEFT 0x01
#define MOUSE_BUTTON_RIGHT 0x02
#define MOUSE_BUTTON_MIDDLE 0x04
#define MOUSE_BUTTON_MASK 0x07

// Mouse: relative, the host feeds it motion, buttons and wheel steps while
// it has the pointer; or absolute, like a tablet, where the host feeds it
// where its pointer is in the frame, and every event has the position it
// happened at. IRQ line is asserted while the FIFO is not empty.
typedef struct mouse {
	pic_t* pic;
	uint8_t irq;
	bool enabled;
	bool absolute;
	uint32_t buttons; // down now
	uint32_t position; // absolute: where the pointer is now, x | y << 16
	uint32_t fifo[MOUSE_FIFO_SIZE];
	uint32_t fifo_position[MOUSE_FIFO_SIZE]; // of each event, absolute
	uint8_t head; // next event to read
	uint8_t count;
	bool overflow;
	bool tail_motion; // the newest event holds motion only: more can merge
	uint32_t popped_position; // POSITION: of the event read last
} mouse_t;

mouse_t* mouse_create(pic_t* pic, const uint8_t irq);
void mouse_destroy(mouse_t* mouse);

void mouse_reset(mouse_t* mouse);

// host side, ignored while the mouse is disabled: queue motion (any size,
// split into events as needed; relative mode only), the pointer's position
// in the frame's pixels (absolute mode only), a button (MOUSE_BUTTON_*) or
// wheel steps
void mouse_move(mouse_t* mouse, const int32_t dx, const int32_t dy);
void mouse_point(mouse_t* mouse, const uint32_t x, const uint32_t y);
void mouse_button(mouse_t* mouse, const uint32_t button, const bool pressed);
void mouse_wheel(mouse_t* mouse, const int32_t steps);
// the host takes its pointer back: every button counts as released
void mouse_release_buttons(mouse_t* mouse);

// bus side: offset is relative to the device base; return true on bus error
bool mouse_read(mouse_t* mouse, const uint32_t offset, const uint8_t size,
				uint32_t* value);
bool mouse_write(mouse_t* mouse, const uint32_t offset, const uint8_t size,
				 const uint32_t value);

#endif // WRM_MOUSE_H
