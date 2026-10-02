#include "devices/pit.h"

static void pit_update_irq(pit_t* pit) {
	pic_set_line(pit->pic, pit->irq, pit->expired);
}

pit_t* pit_create(pic_t* pic, const uint8_t irq, const uint32_t frequency) {
	pit_t* pit = (pit_t*)calloc(1, sizeof(pit_t));
	if (!pit) error("Failed to allocate PIT!");
	pit->pic = pic;
	pit->irq = irq;
	pit->frequency = frequency;
	pit_reset(pit);
	return pit;
}

void pit_destroy(pit_t* pit) {
	if (!pit) return;
	free(pit);
	pit = NULL;
}

void pit_reset(pit_t* pit) {
	if (!pit) return;
	pit->count = 0;
	pit->reload = 0;
	pit->value = 0;
	pit->control = 0;
	pit->expired = false;
	pit_update_irq(pit);
}

// Every tick COUNT goes up and, while enabled, VALUE goes down; the timer
// expires on the tick VALUE reaches 0 (RELOAD = 0 behaves like 1: it
// expires on every tick), and then reloads or stops.
void pit_run(pit_t* pit, const uint64_t ticks) {
	pit->count += ticks;
	if (!(pit->control & PIT_CONTROL_ENABLE) || ticks == 0) return;

	const uint64_t first = pit->value > 0 ? pit->value : 1;
	if (ticks < first) {
		pit->value -= (uint32_t)ticks;
		return;
	}

	pit->expired = true;
	if (pit->control & PIT_CONTROL_PERIODIC) {
		// after each expiry VALUE starts again from RELOAD
		const uint64_t period = pit->reload > 0 ? pit->reload : 1;
		pit->value = pit->reload - (uint32_t)((ticks - first) % period);
	} else {
		pit->value = 0;
		pit->control &= ~PIT_CONTROL_ENABLE;
	}
	pit_update_irq(pit);
}

uint64_t pit_next_event(const pit_t* pit) {
	// expiring again while EXPIRED is set changes nothing but VALUE and
	// CONTROL, which a read brings up to date
	if (!(pit->control & PIT_CONTROL_ENABLE) || pit->expired)
		return TICKS_NEVER;
	return pit->value > 0 ? pit->value : 1;
}

bool pit_read(pit_t* pit, const uint32_t offset, const uint8_t size,
			  uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case PIT_REG_COUNT_LO:
			*value = (uint32_t)pit->count;
			return false;
		case PIT_REG_COUNT_HI:
			*value = (uint32_t)(pit->count >> 32);
			return false;
		case PIT_REG_FREQUENCY:
			*value = pit->frequency;
			return false;
		case PIT_REG_RELOAD:
			*value = pit->reload;
			return false;
		case PIT_REG_VALUE:
			*value = pit->value;
			return false;
		case PIT_REG_CONTROL:
			*value = pit->control;
			return false;
		case PIT_REG_STATUS:
			*value = pit->expired ? PIT_STATUS_EXPIRED : 0;
			return false;
	}
	return true;
}

bool pit_write(pit_t* pit, const uint32_t offset, const uint8_t size,
			   const uint32_t value) {
	(void)size;
	switch (offset) {
		case PIT_REG_COUNT_LO:
		case PIT_REG_COUNT_HI:
		case PIT_REG_FREQUENCY:
		case PIT_REG_VALUE:
			return false; // read-only, writes are ignored
		case PIT_REG_RELOAD:
			pit->reload = value;
			return false;
		case PIT_REG_CONTROL:
			pit->control = value & PIT_CONTROL_MASK;
			pit->value = pit->reload;
			return false;
		case PIT_REG_STATUS:
			if (value & PIT_STATUS_EXPIRED) {
				pit->expired = false;
				pit_update_irq(pit);
			}
			return false;
	}
	return true;
}
