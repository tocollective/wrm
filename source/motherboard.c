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
				"got %zu\n",
				"1MB, 2MB, 4MB, 8MB, 16MB or 32MB",
				size);
		return true;
	}

	mb->ram_slot[slot].ram = ram_create(size);
	mb->ram_slot[slot].installed = true;

	print("Installed %zuMB RAM to %i slot", size / (1024 * 1024), slot);
	return false;
}

static ram_t* motherboard_find_ram(motherboard_t* mb, const uint32_t address,
								   size_t* offset) {
	size_t base = MB_RAM_BASE;
	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		ram_slot_t* slot = &mb->ram_slot[i];
		if (!slot->installed) continue;
		if (address >= base && address - base < slot->ram->size) {
			*offset = address - base;
			return slot->ram;
		}
		base += slot->ram->size;
	}
	return NULL;
}

// Device registers are 32-bit and must be accessed at a multiple of 4;
// narrower accesses see the low bits.
static uint32_t motherboard_io_mask(const uint8_t size) {
	return size == 4 ? UINT32_MAX : (1u << (size * 8)) - 1;
}

// returns true on bus error
static bool motherboard_io_read(motherboard_t* mb, const uint32_t address,
								const uint8_t size, uint32_t* value) {
	const uint32_t page = address & ~(MB_IO_PAGE_SIZE - 1);
	const uint32_t offset = address & (MB_IO_PAGE_SIZE - 1);
	if (offset & 3) return true;

	bool fail = true;
	switch (page) {
		case MB_PIC_BASE:
			fail = pic_read(mb->pic, offset, size, value);
			break;
		case MB_KEYBOARD_BASE:
			fail = keyboard_read(mb->keyboard, offset, size, value);
			break;
		case MB_UART_BASE:
			fail = uart_read(mb->uart, offset, size, value);
			break;
	}
	if (!fail) *value &= motherboard_io_mask(size);
	return fail;
}

// returns true on bus error
static bool motherboard_io_write(motherboard_t* mb, const uint32_t address,
								 const uint8_t size, const uint32_t value) {
	const uint32_t page = address & ~(MB_IO_PAGE_SIZE - 1);
	const uint32_t offset = address & (MB_IO_PAGE_SIZE - 1);
	if (offset & 3) return true;

	switch (page) {
		case MB_PIC_BASE:
			return pic_write(mb->pic, offset, size, value);
		case MB_KEYBOARD_BASE:
			return keyboard_write(mb->keyboard, offset, size, value);
		case MB_UART_BASE:
			return uart_write(mb->uart, offset, size, value);
	}
	return true;
}

// returns true on bus error
static bool motherboard_bus_read(void* ctx, const uint32_t address,
								 const uint8_t size, uint32_t* value) {
	motherboard_t* mb = ctx;

	if (address >= MB_ROM_BASE) {
		const size_t offset = address - MB_ROM_BASE;
		if (offset + size > mb->rom->size) return true;
		switch (size) {
			case 1:
				*value = rom_peek8(mb->rom, offset);
				return false;
			case 2:
				*value = rom_peek16(mb->rom, offset);
				return false;
			case 4:
				*value = rom_peek32(mb->rom, offset);
				return false;
		}
		return true;
	}

	if (address >= MB_IO_BASE)
		return motherboard_io_read(mb, address, size, value);

	size_t offset = 0;
	ram_t* ram = motherboard_find_ram(mb, address, &offset);
	if (!ram || offset + size > ram->size) return true;
	switch (size) {
		case 1:
			*value = ram_peek8(ram, offset);
			return false;
		case 2:
			*value = ram_peek16(ram, offset);
			return false;
		case 4:
			*value = ram_peek32(ram, offset);
			return false;
	}
	return true;
}

// returns true on bus error
static bool motherboard_bus_write(void* ctx, const uint32_t address,
								  const uint8_t size, const uint32_t value) {
	motherboard_t* mb = ctx;

	if (address >= MB_ROM_BASE) return true; // ROM is read-only
	if (address >= MB_IO_BASE)
		return motherboard_io_write(mb, address, size, value);

	size_t offset = 0;
	ram_t* ram = motherboard_find_ram(mb, address, &offset);
	if (!ram || offset + size > ram->size) return true;
	switch (size) {
		case 1:
			ram_poke8(ram, offset, value);
			return false;
		case 2:
			ram_poke16(ram, offset, value);
			return false;
		case 4:
			ram_poke32(ram, offset, value);
			return false;
	}
	return true;
}

motherboard_t* motherboard_create(void) {
	config_t* cfg = config_get();

	motherboard_t* mb = (motherboard_t*)calloc(1, sizeof(motherboard_t));
	if (!mb) error("Failed to allocate Motherboard!");

	mb->clock = clock_create(cfg->clock_rate);
	print("CPU speed: %zu Hz", mb->clock->rate);

	const bus_t bus = {
		.ctx = mb,
		.read = motherboard_bus_read,
		.write = motherboard_bus_write,
	};
	mb->cpu = cpu_create(bus);

	mb->pic = pic_create();
	mb->keyboard = keyboard_create(mb->pic, MB_IRQ_KEYBOARD);
	mb->uart = uart_create(mb->pic, MB_IRQ_UART);

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
	if (mb->uart) {
		uart_destroy(mb->uart);
		mb->uart = NULL;
	}

	if (mb->keyboard) {
		keyboard_destroy(mb->keyboard);
		mb->keyboard = NULL;
	}

	if (mb->pic) {
		pic_destroy(mb->pic);
		mb->pic = NULL;
	}

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

	if (mb->clock) {
		clock_destroy(mb->clock);
		mb->clock = NULL;
	}

	free(mb);
	mb = NULL;
}
