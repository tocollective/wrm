#include "motherboard.h"

#include "config.h"

// https://en.wikipedia.org/wiki/SIMM
static bool is_valid_ram_size(size_t size) {
	if (size == 1024 * 1024) return true; // 1MB
	if (size == 1024 * 1024 * 2) return true; // 2MB
	if (size == 1024 * 1024 * 4) return true; // 4MB
	if (size == 1024 * 1024 * 8) return true; // 8MB
	if (size == 1024 * 1024 * 16) return true; // 16MB
	if (size == 1024 * 1024 * 32) return true; // 32MB
	return false;
}

static bool motherboard_ram_slots_check(motherboard_t* mb) {
	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		if (mb->ram_slot[i].installed) return false;
	}
	return true;
}

static bool motherboard_install_ram_slot(motherboard_t* mb, const int slot,
										 const size_t size) {
	if (slot >= RAM_SLOT_COUNT) return true;
	if (mb->ram_slot[slot].installed) return true;
	if (!is_valid_ram_size(size)) {
		warning("Invalid RAM size! Must be %s, but "
				"got %zu.\n",
				"1MB, 2MB, 4MB, 8MB, 16MB or 32MB",
				size);
		return true;
	}

	mb->ram_slot[slot].ram = ram_create(size);
	mb->ram_slot[slot].installed = true;

	print("Installed %zuMB RAM to %i slot.", size / (1024 * 1024), slot);
	return false;
}

motherboard_t* motherboard_create(void) {
	config_t* cfg = config_get();

	motherboard_t* mb = (motherboard_t*)calloc(1, sizeof(motherboard_t));
	if (!mb) error("Failed to allocate Motherboard!");

	mb->cpu = cpu_create();

	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		mb->ram_slot[i].ram = NULL;
		mb->ram_slot[i].installed = false;
	}

	if (motherboard_install_ram_slot(mb, 0, 1024 * 1024 * 1))
		error("Failed to install RAM slot %i.", 0);

	if (motherboard_ram_slots_check(mb)) error("Can't run without RAM.");

	mb->rom = rom_create(ROM_MAX_SIZE);
	rom_load(mb->rom, cfg->firm_path);

	return mb;
}

void motherboard_destroy(motherboard_t* mb) {
	if (!mb) return;
	if (mb->rom) {
		rom_destroy(mb->rom);
		mb->rom = NULL;
	}

	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		if (mb->ram_slot[i].ram) {
			ram_destroy(mb->ram_slot[i].ram);
			mb->ram_slot[i].ram = NULL;
			mb->ram_slot[i].installed = false;
		}
	}

	if (mb->cpu) {
		cpu_destroy(mb->cpu);
		mb->cpu = NULL;
	}

	free(mb);
	mb = NULL;
}
