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

void pit_tick(pit_t* pit) {
	pit->count++;
	if (!(pit->control & PIT_CONTROL_ENABLE)) return;

	// RELOAD = 0 behaves like 1: the timer expires on every tick
	if (pit->value > 0) pit->value--;
	if (pit->value > 0) return;

	pit->expired = true;
	if (pit->control & PIT_CONTROL_PERIODIC) {
		pit->value = pit->reload;
	} else {
		pit->control &= ~PIT_CONTROL_ENABLE;
	}
	pit_update_irq(pit);
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
