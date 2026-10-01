#include "devices/mouse.h"

static void mouse_update_irq(mouse_t* mouse) {
	pic_set_line(mouse->pic, mouse->irq, mouse->count > 0);
}

mouse_t* mouse_create(pic_t* pic, const uint8_t irq) {
	mouse_t* mouse = (mouse_t*)calloc(1, sizeof(mouse_t));
	if (!mouse) error("Failed to allocate Mouse!");
	mouse->pic = pic;
	mouse->irq = irq;
	mouse_reset(mouse);
	return mouse;
}

void mouse_destroy(mouse_t* mouse) {
	if (!mouse) return;
	free(mouse);
	mouse = NULL;
}

static void mouse_flush(mouse_t* mouse) {
	mouse->head = 0;
	mouse->count = 0;
	mouse->overflow = false;
	mouse->tail_motion = false;
	mouse_update_irq(mouse);
}

void mouse_reset(mouse_t* mouse) {
	if (!mouse) return;
	mouse->enabled = false;
	mouse->buttons = 0;
	mouse_flush(mouse);
}

static uint32_t mouse_event(const mouse_t* mouse, const int32_t dx,
							const int32_t dy, const int32_t wheel) {
	return MOUSE_EVENT_VALID | mouse->buttons << MOUSE_EVENT_BUTTON_SHIFT
		   | ((uint32_t)wheel & 0xFF) << MOUSE_EVENT_WHEEL_SHIFT
		   | ((uint32_t)dy & 0xFF) << MOUSE_EVENT_DY_SHIFT
		   | ((uint32_t)dx & 0xFF);
}

static void mouse_push(mouse_t* mouse, const uint32_t event,
					   const bool motion) {
	if (mouse->count == MOUSE_FIFO_SIZE) {
		mouse->overflow = true;
		return;
	}
	const uint8_t tail = (mouse->head + mouse->count) % MOUSE_FIFO_SIZE;
	mouse->fifo[tail] = event;
	mouse->count++;
	mouse->tail_motion = motion;
	mouse_update_irq(mouse);
}

static int32_t mouse_clamp(const int32_t value) {
	if (value < -128) return -128;
	if (value > 127) return 127;
	return value;
}

static int32_t mouse_field(const uint32_t event, const unsigned shift) {
	const int32_t value = (int32_t)((event >> shift) & 0xFF);
	return value >= 0x80 ? value - 0x100 : value;
}

// Adds the motion to the newest event if it holds only motion with the
// same buttons and the sum still fits; false if it can't.
static bool mouse_merge(mouse_t* mouse, const int32_t dx, const int32_t dy) {
	if (mouse->count == 0 || !mouse->tail_motion) return false;
	const uint8_t tail = (mouse->head + mouse->count - 1) % MOUSE_FIFO_SIZE;
	const uint32_t event = mouse->fifo[tail];
	if ((event >> MOUSE_EVENT_BUTTON_SHIFT & MOUSE_BUTTON_MASK)
		!= mouse->buttons)
		return false;
	const int32_t x = mouse_field(event, 0) + dx;
	const int32_t y = mouse_field(event, MOUSE_EVENT_DY_SHIFT) + dy;
	if (x != mouse_clamp(x) || y != mouse_clamp(y)) return false;
	mouse->fifo[tail] = mouse_event(mouse, x, y, 0);
	return true;
}

void mouse_move(mouse_t* mouse, const int32_t dx, const int32_t dy) {
	if (!mouse || !mouse->enabled) return;
	int32_t x = dx;
	int32_t y = dy;
	while (x || y) {
		const int32_t step_x = mouse_clamp(x);
		const int32_t step_y = mouse_clamp(y);
		if (!mouse_merge(mouse, step_x, step_y))
			mouse_push(mouse, mouse_event(mouse, step_x, step_y, 0), true);
		x -= step_x;
		y -= step_y;
	}
}

void mouse_button(mouse_t* mouse, const uint32_t button, const bool pressed) {
	if (!mouse || !mouse->enabled) return;
	const uint32_t buttons =
		pressed ? mouse->buttons | button : mouse->buttons & ~button;
	if (buttons == mouse->buttons) return;
	mouse->buttons = buttons & MOUSE_BUTTON_MASK;
	mouse_push(mouse, mouse_event(mouse, 0, 0, 0), false);
}

void mouse_wheel(mouse_t* mouse, const int32_t steps) {
	if (!mouse || !mouse->enabled) return;
	int32_t left = steps;
	while (left) {
		const int32_t step = mouse_clamp(left);
		mouse_push(mouse, mouse_event(mouse, 0, 0, step), false);
		left -= step;
	}
}

void mouse_release_buttons(mouse_t* mouse) {
	if (!mouse) return;
	if (mouse->enabled && mouse->buttons) {
		mouse->buttons = 0;
		mouse_push(mouse, mouse_event(mouse, 0, 0, 0), false);
	}
	mouse->buttons = 0;
}

static uint32_t mouse_pop(mouse_t* mouse) {
	if (mouse->count == 0) return 0;
	const uint32_t event = mouse->fifo[mouse->head];
	mouse->head = (mouse->head + 1) % MOUSE_FIFO_SIZE;
	mouse->count--;
	if (mouse->count == 0) mouse->tail_motion = false;
	mouse_update_irq(mouse);
	return event;
}

bool mouse_read(mouse_t* mouse, const uint32_t offset, const uint8_t size,
				uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case MOUSE_REG_STATUS: {
			uint32_t status = 0;
			if (mouse->count > 0) status |= MOUSE_STATUS_READY;
			if (mouse->overflow) status |= MOUSE_STATUS_OVERFLOW;
			mouse->overflow = false;
			*value = status;
			return false;
		}
		case MOUSE_REG_DATA:
			*value = mouse_pop(mouse);
			return false;
		case MOUSE_REG_CONTROL:
			*value = mouse->enabled ? MOUSE_CONTROL_ENABLE : 0;
			return false;
	}
	return true;
}

bool mouse_write(mouse_t* mouse, const uint32_t offset, const uint8_t size,
				 const uint32_t value) {
	(void)size;
	switch (offset) {
		case MOUSE_REG_STATUS:
		case MOUSE_REG_DATA:
			return false; // read-only, writes are ignored
		case MOUSE_REG_CONTROL:
			if (value & MOUSE_CONTROL_FLUSH) mouse_flush(mouse);
			mouse->enabled = value & MOUSE_CONTROL_ENABLE;
			// the host gives its pointer back, with the buttons up
			if (!mouse->enabled) mouse->buttons = 0;
			return false;
	}
	return true;
}
