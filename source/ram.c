#include "ram.h"

#include <string.h>

ram_t* ram_create(const size_t size) {
	ram_t* ram = (ram_t*)calloc(1, sizeof(ram_t));
	if (!ram) error("Failed to allocate RAM!");
	ram->data = calloc(1, size);
	if (!ram->data) error("Failed to allocate RAM data!");
	ram->size = size;
	return ram;
}

void ram_destroy(ram_t* ram) {
	if (!ram) return;
	free(ram->data);
	ram->data = NULL;
	ram->size = 0;
	free(ram);
	ram = NULL;
}

void ram_clear(ram_t* ram) {
	if (!ram) return;
	memset(ram->data, 0, ram->size);
}

uint8_t ram_peek8(ram_t* ram, const size_t address) {
	if (!ram) return 0;
	return ram->data[address];
}

uint16_t ram_peek16(ram_t* ram, const size_t address) {
	const uint16_t a = ram_peek8(ram, address);
	const uint16_t b = ram_peek8(ram, address + 1);
	return (b << 8) | a;
}

uint32_t ram_peek32(ram_t* ram, const size_t address) {
	const uint32_t a = ram_peek16(ram, address);
	const uint32_t b = ram_peek16(ram, address + 2);
	return (b << 16) | a;
}

void ram_poke8(ram_t* ram, const size_t address, const uint8_t value) {
	ram->data[address] = value;
}

void ram_poke16(ram_t* ram, const size_t address, const uint16_t value) {
	ram_poke8(ram, address, value & 0xFF);
	ram_poke8(ram, address + 1, value >> 8);
}

void ram_poke32(ram_t* ram, const size_t address, const uint32_t value) {
	ram_poke16(ram, address, value & 0xFFFF);
	ram_poke16(ram, address + 2, value >> 16);
}
