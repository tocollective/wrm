#ifndef WRM_RAM_H
#define WRM_RAM_H
#include "common.h"

typedef struct ram {
	uint8_t* data;
	size_t size;
} ram_t;

ram_t* ram_create(const size_t size);
void ram_destroy(ram_t* ram);

void ram_clear(ram_t* ram);

uint8_t ram_peek8(ram_t* ram, const size_t address);
uint16_t ram_peek16(ram_t* ram, const size_t address);
uint32_t ram_peek32(ram_t* ram, const size_t address);

void ram_poke8(ram_t* ram, const size_t address, const uint8_t value);
void ram_poke16(ram_t* ram, const size_t address, const uint16_t value);
void ram_poke32(ram_t* ram, const size_t address, const uint32_t value);

#endif // WRM_RAM_H
