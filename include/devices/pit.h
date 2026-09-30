#ifndef WRM_PIT_H
#define WRM_PIT_H
#include "common.h"

#include "devices/pic.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define PIT_REG_COUNT_LO 0x00 // R: free-running tick counter, low half
#define PIT_REG_COUNT_HI 0x04 // R: high half
#define PIT_REG_FREQUENCY 0x08 // R: ticks per second
#define PIT_REG_RELOAD 0x0C // RW: period in ticks
#define PIT_REG_VALUE 0x10 // R: ticks left until the timer expires
#define PIT_REG_CONTROL 0x14 // RW: a write also restarts the countdown
#define PIT_REG_STATUS 0x18 // R, W: 1 clears the bit

#define PIT_CONTROL_ENABLE 0x01 // count down
#define PIT_CONTROL_PERIODIC 0x02 // reload on expiry, 0 = one-shot
#define PIT_CONTROL_MASK (PIT_CONTROL_ENABLE | PIT_CONTROL_PERIODIC)

#define PIT_STATUS_EXPIRED 0x01

// Programmable interval timer, ticked by the system clock.
// IRQ line is asserted while STATUS.EXPIRED is set.
typedef struct pit {
	pic_t* pic;
	uint8_t irq;
	uint32_t frequency;
	uint64_t count;
	uint32_t reload;
	uint32_t value;
	uint32_t control;
	bool expired;
} pit_t;

pit_t* pit_create(pic_t* pic, const uint8_t irq, const uint32_t frequency);
void pit_destroy(pit_t* pit);

void pit_reset(pit_t* pit);
// advances the timer by one clock tick
void pit_tick(pit_t* pit);

// bus side: offset is relative to the device base; return true on bus error
bool pit_read(pit_t* pit, const uint32_t offset, const uint8_t size,
			  uint32_t* value);
bool pit_write(pit_t* pit, const uint32_t offset, const uint8_t size,
			   const uint32_t value);

#endif // WRM_PIT_H
