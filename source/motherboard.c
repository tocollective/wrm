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

// The disk controller in the I/O page at page, NULL if it holds none.
static disk_t* motherboard_find_disk(motherboard_t* mb, const uint32_t page) {
	const uint32_t index = (page - MB_DISK0_BASE) / MB_IO_PAGE_SIZE;
	if (page < MB_DISK0_BASE || index >= DISK_COUNT) return NULL;
	return mb->disk[index];
}

// returns true on bus error
static bool motherboard_io_read(motherboard_t* mb, const uint32_t address,
								const uint8_t size, uint32_t* value) {
	const uint32_t page = address & ~(MB_IO_PAGE_SIZE - 1);
	const uint32_t offset = address & (MB_IO_PAGE_SIZE - 1);
	if (offset & 3) return true;

	bool fail = true;
	disk_t* disk = motherboard_find_disk(mb, page);
	if (disk) fail = disk_read(disk, offset, size, value);
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
		case MB_PIT_BASE:
			fail = pit_read(mb->pit, offset, size, value);
			break;
		case MB_POWER_BASE:
			fail = power_read(mb->power, offset, size, value);
			break;
		case MB_VIDEO_BASE:
			fail = videocard_read(mb->videocard, offset, size, value);
			break;
		case MB_FLOPPY_BASE:
			fail = disk_read(mb->floppy, offset, size, value);
			break;
		case MB_BEEPER_BASE:
			fail = beeper_read(mb->beeper, offset, size, value);
			break;
		case MB_MOUSE_BASE:
			fail = mouse_read(mb->mouse, offset, size, value);
			break;
		case MB_NET_BASE:
			fail = netcard_read(mb->netcard, offset, size, value);
			break;
		case MB_AUDIO_BASE:
			fail = audiocard_read(mb->audiocard, offset, size, value);
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

	disk_t* disk = motherboard_find_disk(mb, page);
	if (disk) return disk_write(disk, offset, size, value);
	switch (page) {
		case MB_PIC_BASE:
			return pic_write(mb->pic, offset, size, value);
		case MB_KEYBOARD_BASE:
			return keyboard_write(mb->keyboard, offset, size, value);
		case MB_UART_BASE:
			return uart_write(mb->uart, offset, size, value);
		case MB_PIT_BASE:
			return pit_write(mb->pit, offset, size, value);
		case MB_POWER_BASE:
			return power_write(mb->power, offset, size, value);
		case MB_VIDEO_BASE:
			return videocard_write(mb->videocard, offset, size, value);
		case MB_FLOPPY_BASE:
			return disk_write(mb->floppy, offset, size, value);
		case MB_BEEPER_BASE:
			return beeper_write(mb->beeper, offset, size, value);
		case MB_MOUSE_BASE:
			return mouse_write(mb->mouse, offset, size, value);
		case MB_NET_BASE:
			return netcard_write(mb->netcard, offset, size, value);
		case MB_AUDIO_BASE:
			return audiocard_write(mb->audiocard, offset, size, value);
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

// Instruction fetches and page table walks: like a read, but the I/O
// region is a bus error, so a fetch down a mispredicted path never has a
// device's side effects (e.g. popping the UART FIFO).
// returns true on bus error
static bool motherboard_bus_fetch(void* ctx, const uint32_t address,
								  const uint8_t size, uint32_t* value) {
	if (address >= MB_IO_BASE && address - MB_IO_BASE < MB_IO_SIZE)
		return true;
	return motherboard_bus_read(ctx, address, size, value);
}

// returns true on bus error
static bool motherboard_bus_write(void* ctx, const uint32_t address,
								  const uint8_t size, const uint32_t value) {
	motherboard_t* mb = ctx;

	if (address >= MB_ROM_BASE) return true; // ROM is read-only
	if (address >= MB_IO_BASE) {
		const bool failed = motherboard_io_write(mb, address, size, value);
		if (!failed) cpu_invalidate_reservation(mb->cpu, address, size);
		return failed;
	}

	size_t offset = 0;
	ram_t* ram = motherboard_find_ram(mb, address, &offset);
	if (!ram || offset + size > ram->size) return true;
	switch (size) {
		case 1:
			ram_poke8(ram, offset, value);
			cpu_invalidate_reservation(mb->cpu, address, size);
			return false;
		case 2:
			ram_poke16(ram, offset, value);
			cpu_invalidate_reservation(mb->cpu, address, size);
			return false;
		case 4:
			ram_poke32(ram, offset, value);
			cpu_invalidate_reservation(mb->cpu, address, size);
			return false;
	}
	return true;
}

// DMA from devices: RAM only, ROM and the I/O region are bus errors.
// returns true on bus error
static bool motherboard_dma_read(void* ctx, const uint32_t address,
								 const uint8_t size, uint32_t* value) {
	if (address >= MB_IO_BASE) return true;
	return motherboard_bus_read(ctx, address, size, value);
}

// returns true on bus error
static bool motherboard_dma_write(void* ctx, const uint32_t address,
								  const uint8_t size, const uint32_t value) {
	if (address >= MB_IO_BASE) return true;
	return motherboard_bus_write(ctx, address, size, value);
}

// DMA of the video, network and audio cards: reads RAM or ROM (e.g. the
// firmware's font, a request or a sample in the firmware), writes RAM
// only; the I/O region is a bus error.
// returns true on bus error
static bool motherboard_video_dma_read(void* ctx, const uint32_t address,
									   const uint8_t size, uint32_t* value) {
	if (address >= MB_IO_BASE && address < MB_ROM_BASE) return true;
	return motherboard_bus_read(ctx, address, size, value);
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
		.fetch = motherboard_bus_fetch,
		.write = motherboard_bus_write,
	};
	mb->cpu = cpu_create(bus);

	mb->pic = pic_create();
	mb->keyboard = keyboard_create(mb->pic, MB_IRQ_KEYBOARD);
	mb->uart = uart_create(mb->pic, MB_IRQ_UART);
	// the timer counts clock ticks
	mb->pit = pit_create(mb->pic, MB_IRQ_PIT, (uint32_t)mb->clock->rate);
	mb->power = power_create();

	const bus_t dma = {
		.ctx = mb,
		.read = motherboard_dma_read,
		.fetch = motherboard_dma_read,
		.write = motherboard_dma_write,
	};
	for (int i = 0; i < DISK_COUNT; i++)
		mb->disk[i] = disk_create(
				mb->pic, MB_IRQ_DISK0 + i, dma, false, 1, cfg->hdd_path[i]);
	// the floppy is slow in real time whatever the clock rate
	const uint64_t floppy_ticks =
		mb->clock->rate * 4 / DISK_FLOPPY_BYTES_PER_SECOND;
	mb->floppy = disk_create(mb->pic,
							 MB_IRQ_FLOPPY,
							 dma,
							 true,
							 floppy_ticks > UINT32_MAX ? UINT32_MAX
													   : (uint32_t)floppy_ticks,
							 cfg->floppy_path);

	const bus_t video_dma = {
		.ctx = mb,
		.read = motherboard_video_dma_read,
		.fetch = motherboard_video_dma_read,
		.write = motherboard_dma_write,
	};
	mb->videocard = videocard_create(
			mb->pic, MB_IRQ_VIDEO, video_dma, (uint32_t)mb->clock->rate);
	mb->beeper = beeper_create((uint32_t)mb->clock->rate);
	mb->mouse = mouse_create(mb->pic, MB_IRQ_MOUSE);
	mb->netcard = netcard_create(
			mb->pic, MB_IRQ_NET, video_dma, cfg->net, cfg->net_bind);
	mb->audiocard = audiocard_create(
			mb->pic, MB_IRQ_AUDIO, video_dma, (uint32_t)mb->clock->rate);

	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		mb->ram_slot[i].ram = NULL;
		mb->ram_slot[i].installed = false;
	}

	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		if (!cfg->ram_size[i]) continue;
		if (motherboard_install_ram_slot(mb, i, cfg->ram_size[i]))
			error("Failed to install RAM slot %i.", i);
	}

	if (motherboard_ram_slots_check(mb)) error("Can't run without RAM.");

	mb->rom = rom_create(ROM_MAX_SIZE);
	rom_load(mb->rom, cfg->firm_path);

	return mb;
}

void motherboard_destroy(motherboard_t* mb) {
	if (!mb) return;
	if (mb->audiocard) {
		audiocard_destroy(mb->audiocard);
		mb->audiocard = NULL;
	}

	if (mb->netcard) {
		netcard_destroy(mb->netcard);
		mb->netcard = NULL;
	}

	if (mb->mouse) {
		mouse_destroy(mb->mouse);
		mb->mouse = NULL;
	}

	if (mb->beeper) {
		beeper_destroy(mb->beeper);
		mb->beeper = NULL;
	}

	if (mb->floppy) {
		disk_destroy(mb->floppy);
		mb->floppy = NULL;
	}

	if (mb->videocard) {
		videocard_destroy(mb->videocard);
		mb->videocard = NULL;
	}

	for (int i = 0; i < DISK_COUNT; i++) {
		if (mb->disk[i]) {
			disk_destroy(mb->disk[i]);
			mb->disk[i] = NULL;
		}
	}

	if (mb->power) {
		power_destroy(mb->power);
		mb->power = NULL;
	}

	if (mb->pit) {
		pit_destroy(mb->pit);
		mb->pit = NULL;
	}

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

void motherboard_reset(motherboard_t* mb) {
	if (!mb) return;
	cpu_reset(mb->cpu);
	keyboard_reset(mb->keyboard);
	uart_reset(mb->uart);
	pit_reset(mb->pit);
	power_reset(mb->power);
	for (int i = 0; i < DISK_COUNT; i++) disk_reset(mb->disk[i]);
	videocard_reset(mb->videocard);
	disk_reset(mb->floppy);
	beeper_reset(mb->beeper);
	mouse_reset(mb->mouse);
	netcard_reset(mb->netcard);
	audiocard_reset(mb->audiocard);
	pic_reset(mb->pic);
}

void motherboard_tick(motherboard_t* mb) {
	if (!mb) return;
	pit_tick(mb->pit);
	for (int i = 0; i < DISK_COUNT; i++) disk_tick(mb->disk[i]);
	videocard_tick(mb->videocard);
	disk_tick(mb->floppy);
	beeper_tick(mb->beeper);
	audiocard_tick(mb->audiocard);
	cpu_set_irq(mb->cpu, pic_irq(mb->pic));
	cpu_update(mb->cpu);

	// requested by a store the CPU has just made
	if (mb->power->request == POWER_REQUEST_RESET) motherboard_reset(mb);
}
