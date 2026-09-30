#ifndef WRM_PIC_H
#define WRM_PIC_H
#include "common.h"

// Programmable interrupt controller: 32 level-triggered IRQ lines.
// A line stays asserted while its device needs service; the handler clears
// the condition in the device, which drops the line.
#define PIC_LINE_COUNT 32

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define PIC_REG_PENDING 0x00 // R: current level of every line
#define PIC_REG_ENABLE 0x04 // RW: 1 = line may interrupt the CPU
#define PIC_REG_ACTIVE 0x08 // R: PENDING & ENABLE
#define PIC_REG_CLAIM 0x0C // R: lowest active line, PIC_NO_IRQ if none

#define PIC_NO_IRQ 0xFFFFFFFF

typedef struct pic {
	uint32_t lines; // driven by devices
	uint32_t enable;
} pic_t;

pic_t* pic_create(void);
void pic_destroy(pic_t* pic);

void pic_reset(pic_t* pic);
// device side: drive an IRQ line
void pic_set_line(pic_t* pic, const uint8_t irq, const bool level);
// CPU side: true while any enabled line is asserted
bool pic_irq(const pic_t* pic);

// bus side: offset is relative to the device base; return true on bus error
bool pic_read(pic_t* pic, const uint32_t offset, const uint8_t size,
			  uint32_t* value);
bool pic_write(pic_t* pic, const uint32_t offset, const uint8_t size,
			   const uint32_t value);

#endif // WRM_PIC_H
