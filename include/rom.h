#ifndef WRM_ROM_H
#define WRM_ROM_H
#include "common.h"

#define ROM_MAX_SIZE 0x2000000 // 32MB

typedef struct rom {
	uint8_t* data;
	size_t size;
} rom_t;

rom_t* rom_create(const size_t size);
void rom_destroy(rom_t* rom);

void rom_load(rom_t* rom, const char* path);

uint8_t rom_peek8(rom_t* rom, const size_t address);
uint16_t rom_peek16(rom_t* rom, const size_t address);
uint32_t rom_peek32(rom_t* rom, const size_t address);

#endif // WRM_ROM_H
