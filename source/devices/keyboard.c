#include "devices/keyboard.h"

static void keyboard_update_irq(keyboard_t* kbd) {
	pic_set_line(kbd->pic, kbd->irq, kbd->count > 0);
}

keyboard_t* keyboard_create(pic_t* pic, const uint8_t irq) {
	keyboard_t* kbd = (keyboard_t*)calloc(1, sizeof(keyboard_t));
	if (!kbd) error("Failed to allocate Keyboard!");
	kbd->pic = pic;
	kbd->irq = irq;
	keyboard_reset(kbd);
	return kbd;
}

void keyboard_destroy(keyboard_t* kbd) {
	if (!kbd) return;
	free(kbd);
	kbd = NULL;
}

void keyboard_reset(keyboard_t* kbd) {
	if (!kbd) return;
	kbd->head = 0;
	kbd->count = 0;
	kbd->overflow = false;
	keyboard_update_irq(kbd);
}

void keyboard_key(keyboard_t* kbd, const uint16_t code, const bool pressed) {
	if (!kbd || code == 0) return;
	if (kbd->count == KEYBOARD_FIFO_SIZE) {
		kbd->overflow = true;
		return;
	}

	uint32_t event = code & KEYBOARD_EVENT_CODE_MASK;
	if (!pressed) event |= KEYBOARD_EVENT_RELEASE;

	const uint8_t tail = (kbd->head + kbd->count) % KEYBOARD_FIFO_SIZE;
	kbd->fifo[tail] = event;
	kbd->count++;
	keyboard_update_irq(kbd);
}

static uint32_t keyboard_pop(keyboard_t* kbd) {
	if (kbd->count == 0) return 0;
	const uint32_t event = kbd->fifo[kbd->head];
	kbd->head = (kbd->head + 1) % KEYBOARD_FIFO_SIZE;
	kbd->count--;
	keyboard_update_irq(kbd);
	return event;
}

bool keyboard_read(keyboard_t* kbd, const uint32_t offset, const uint8_t size,
				   uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case KEYBOARD_REG_STATUS: {
			uint32_t status = 0;
			if (kbd->count > 0) status |= KEYBOARD_STATUS_READY;
			if (kbd->overflow) status |= KEYBOARD_STATUS_OVERFLOW;
			kbd->overflow = false;
			*value = status;
			return false;
		}
		case KEYBOARD_REG_DATA:
			*value = keyboard_pop(kbd);
			return false;
		case KEYBOARD_REG_CONTROL:
			*value = 0;
			return false;
	}
	return true;
}

bool keyboard_write(keyboard_t* kbd, const uint32_t offset, const uint8_t size,
					const uint32_t value) {
	(void)size;
	switch (offset) {
		case KEYBOARD_REG_STATUS:
		case KEYBOARD_REG_DATA:
			return false; // read-only, writes are ignored
		case KEYBOARD_REG_CONTROL:
			if (value & KEYBOARD_CONTROL_FLUSH) keyboard_reset(kbd);
			return false;
	}
	return true;
}
