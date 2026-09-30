#include "rom.h"

#include <stdio.h>

rom_t* rom_create(const size_t size) {
	if (size > ROM_MAX_SIZE)
		error("Failed to create ROM: %s", "size is more than max!");

	rom_t* ram = (rom_t*)calloc(1, sizeof(rom_t));
	if (!ram) error("Failed to allocate ROM!");
	ram->data = calloc(1, size);
	if (!ram->data) error("Failed to allocate ROM data!");
	ram->size = size;
	return ram;
}

void rom_destroy(rom_t* rom) {
	if (!rom) return;
	free(rom->data);
	rom->data = NULL;
	rom->size = 0;
	free(rom);
	rom = NULL;
}

void rom_load(rom_t* rom, const char* path) {
	FILE* file = fopen(path, "rb");
	if (!file) error("Failed to load ROM file: %s", path);

	fseek(file, 0L, SEEK_END);
	size_t size = ftell(file);
	if (size > rom->size) {
		print("Limiting ROM to %zu bytes", rom->size);
		size = rom->size;
	}
	fseek(file, 0L, SEEK_SET);

	fread(rom->data, 1, size, file);
	fclose(file);

	print("ROM loaded %zu bytes (0x%08zX)", size, size);
}

uint8_t rom_peek8(rom_t* rom, const size_t address) {
}

uint16_t rom_peek16(rom_t* rom, const size_t address) {
}

uint32_t rom_peek32(rom_t* rom, const size_t address) {
}
