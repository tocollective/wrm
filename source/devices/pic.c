#include "devices/pic.h"

pic_t* pic_create(void) {
	pic_t* pic = (pic_t*)calloc(1, sizeof(pic_t));
	if (!pic) error("Failed to allocate PIC!");
	pic_reset(pic);
	return pic;
}

void pic_destroy(pic_t* pic) {
	if (!pic) return;
	free(pic);
	pic = NULL;
}

// lines are left alone: they follow the devices, not the PIC
void pic_reset(pic_t* pic) {
	if (!pic) return;
	pic->enable = 0;
}

void pic_set_line(pic_t* pic, const uint8_t irq, const bool level) {
	if (!pic || irq >= PIC_LINE_COUNT) return;
	if (level) {
		pic->lines |= 1u << irq;
	} else {
		pic->lines &= ~(1u << irq);
	}
}

bool pic_irq(const pic_t* pic) {
	if (!pic) return false;
	return (pic->lines & pic->enable) != 0;
}

static uint32_t pic_claim(const pic_t* pic) {
	const uint32_t active = pic->lines & pic->enable;
	for (uint32_t irq = 0; irq < PIC_LINE_COUNT; irq++) {
		if (active & (1u << irq)) return irq;
	}
	return PIC_NO_IRQ;
}

bool pic_read(pic_t* pic, const uint32_t offset, const uint8_t size,
			  uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case PIC_REG_PENDING:
			*value = pic->lines;
			return false;
		case PIC_REG_ENABLE:
			*value = pic->enable;
			return false;
		case PIC_REG_ACTIVE:
			*value = pic->lines & pic->enable;
			return false;
		case PIC_REG_CLAIM:
			*value = pic_claim(pic);
			return false;
	}
	return true;
}

bool pic_write(pic_t* pic, const uint32_t offset, const uint8_t size,
			   const uint32_t value) {
	(void)size;
	switch (offset) {
		case PIC_REG_PENDING:
		case PIC_REG_ACTIVE:
		case PIC_REG_CLAIM:
			return false; // read-only, writes are ignored
		case PIC_REG_ENABLE:
			pic->enable = value;
			return false;
	}
	return true;
}
