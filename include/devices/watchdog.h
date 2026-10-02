#ifndef WRM_WATCHDOG_H
#define WRM_WATCHDOG_H
#include "common.h"

#include "devices/pic.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define WATCHDOG_REG_CONTROL 0x00 // RW: ignored once locked
#define WATCHDOG_REG_TIMEOUT 0x04 // RW: ticks until the IRQ, ignored once locked
#define WATCHDOG_REG_GRACE 0x08 // RW: then ticks until the reset, ditto
#define WATCHDOG_REG_KICK 0x0C // W: starts again from TIMEOUT
#define WATCHDOG_REG_VALUE 0x10 // R: ticks left in the current stage
#define WATCHDOG_REG_STATUS 0x14 // RW: W 1 to BARK clears it

#define WATCHDOG_CONTROL_ENABLE 0x01
#define WATCHDOG_CONTROL_LOCK 0x02 // CONTROL, TIMEOUT and GRACE until reset
#define WATCHDOG_CONTROL_MASK (WATCHDOG_CONTROL_ENABLE | WATCHDOG_CONTROL_LOCK)

#define WATCHDOG_STATUS_BARK 0x01 // TIMEOUT ran out: the IRQ line is up
#define WATCHDOG_STATUS_GRACE 0x02 // counting GRACE down to the reset

// Watchdog timer, ticked by the system clock. Software kicks it before
// TIMEOUT ticks run out; if it doesn't, the watchdog barks (STATUS.BARK,
// the IRQ line) and gives it GRACE more ticks, and then bites: the
// motherboard resets the machine after that tick.
typedef struct watchdog {
	pic_t* pic;
	uint8_t irq;
	uint32_t control;
	uint32_t timeout;
	uint32_t grace;
	uint32_t value; // ticks left in the stage
	bool barked; // in the second stage, GRACE
	bool bark; // STATUS.BARK
	bool bitten; // GRACE ran out: the machine is to reset
} watchdog_t;

watchdog_t* watchdog_create(pic_t* pic, const uint8_t irq);
void watchdog_destroy(watchdog_t* watchdog);

void watchdog_reset(watchdog_t* watchdog);
// Advances the watchdog by that many clock ticks, as if ticked one by one;
// it stops on the tick it bites.
void watchdog_run(watchdog_t* watchdog, const uint64_t ticks);
// Ticks until it barks or bites (1 = the next one), TICKS_NEVER if it
// won't.
uint64_t watchdog_next_event(const watchdog_t* watchdog);

// bus side: offset is relative to the device base; return true on bus error
bool watchdog_read(watchdog_t* watchdog, const uint32_t offset,
				   const uint8_t size, uint32_t* value);
bool watchdog_write(watchdog_t* watchdog, const uint32_t offset,
					const uint8_t size, const uint32_t value);

#endif // WRM_WATCHDOG_H
