#include "devices/disk.h"

static void disk_update_irq(disk_t* disk) {
	pic_set_line(disk->pic, disk->irq, disk->done || disk->changed);
}

// Attaches the image at path; false (with a warning) if it can't be used.
static bool disk_open(disk_t* disk, const char* path) {
	disk->readonly = false;
	disk->file = fopen(path, "r+b");
	if (!disk->file) {
		disk->file = fopen(path, "rb");
		disk->readonly = true;
	}
	if (!disk->file) {
		disk->readonly = false;
		warning("Failed to open the disk image %s", path);
		return false;
	}

	long size = -1;
	if (fseek(disk->file, 0L, SEEK_END) == 0) size = ftell(disk->file);
	if (size < 0) {
		warning("Failed to get the size of the disk image %s", path);
		fclose(disk->file);
		disk->file = NULL;
		return false;
	}
	if (size % DISK_SECTOR_SIZE)
		warning("Disk image %s: the last %ld bytes are not a whole sector "
				"and can't be accessed",
				path,
				size % DISK_SECTOR_SIZE);

	const unsigned long sectors = (unsigned long)size / DISK_SECTOR_SIZE;
	disk->sectors = sectors > UINT32_MAX ? UINT32_MAX : (uint32_t)sectors;
	print("Disk %s: %u sectors%s",
		  path,
		  disk->sectors,
		  disk->readonly ? ", read-only" : "");
	return true;
}

static void disk_close(disk_t* disk) {
	if (disk->file) fclose(disk->file);
	disk->file = NULL;
	disk->readonly = false;
	disk->sectors = 0;
}

disk_t* disk_create(pic_t* pic, const uint8_t irq, const bus_t dma,
					const bool removable, const uint32_t word_ticks,
					const char* path) {
	disk_t* disk = (disk_t*)calloc(1, sizeof(disk_t));
	if (!disk) error("Failed to allocate disk controller!");
	disk->pic = pic;
	disk->irq = irq;
	disk->dma = dma;
	disk->removable = removable;
	disk->word_ticks = word_ticks ? word_ticks : 1;
	if (path && !disk_open(disk, path))
		error("Failed to attach the disk image %s", path);
	disk_reset(disk);
	return disk;
}

void disk_destroy(disk_t* disk) {
	if (!disk) return;
	disk_close(disk);
	free(disk);
	disk = NULL;
}

void disk_reset(disk_t* disk) {
	if (!disk) return;
	if (disk->file) fflush(disk->file);
	disk->sector = 0;
	disk->count = 0;
	disk->address = 0;
	disk->error = DISK_ERROR_NONE;
	disk->command = 0;
	disk->busy = false;
	disk->done = false;
	disk->changed = false;
	disk->position = 0;
	disk->wait = 0;
	disk_update_irq(disk);
}

static void disk_finish(disk_t* disk, const uint32_t error) {
	if (disk->command == DISK_COMMAND_WRITE && disk->file) fflush(disk->file);
	disk->busy = false;
	disk->done = true;
	disk->error = error;
	disk_update_irq(disk);
}

void disk_eject(disk_t* disk) {
	if (!disk || !disk->removable || !disk->file) return;
	if (disk->busy) disk_finish(disk, DISK_ERROR_NO_DISK);
	disk_close(disk);
	disk->changed = true;
	disk_update_irq(disk);
	print("Disk ejected");
}

bool disk_insert(disk_t* disk, const char* path) {
	if (!disk || !disk->removable) return false;
	disk_eject(disk);
	const bool inserted = disk_open(disk, path);
	if (inserted) {
		disk->changed = true;
		disk_update_irq(disk);
	}
	return inserted;
}

// Checks the registers and starts the transfer; a command that can't run
// finishes at once with an error.
static void disk_start(disk_t* disk, const uint32_t command) {
	disk->command = command;
	disk->done = false;
	disk->error = DISK_ERROR_NONE;
	disk->position = 0;

	if (command != DISK_COMMAND_READ && command != DISK_COMMAND_WRITE)
		disk_finish(disk, DISK_ERROR_COMMAND);
	else if (!disk->file)
		disk_finish(disk, DISK_ERROR_NO_DISK);
	else if (command == DISK_COMMAND_WRITE && disk->readonly)
		disk_finish(disk, DISK_ERROR_READONLY);
	else if (disk->address & 3)
		disk_finish(disk, DISK_ERROR_ADDRESS);
	else if (disk->sector > disk->sectors
			 || disk->count > disk->sectors - disk->sector)
		disk_finish(disk, DISK_ERROR_RANGE);
	else if (disk->count == 0)
		disk_finish(disk, DISK_ERROR_NONE);
	else {
		disk->busy = true;
		// the first word moves word_ticks ticks from now
		disk->wait = disk->word_ticks - 1;
		disk_update_irq(disk);
	}
}

// Moves the current sector between the buffer and the image; false if the
// host fails. The image is at most LONG_MAX bytes, so the offset fits.
static bool disk_seek(disk_t* disk) {
	const long offset = (long)disk->sector * DISK_SECTOR_SIZE;
	return fseek(disk->file, offset, SEEK_SET) == 0;
}

static bool disk_load_sector(disk_t* disk) {
	return disk_seek(disk)
		&& fread(disk->buffer, 1, DISK_SECTOR_SIZE, disk->file)
				   == DISK_SECTOR_SIZE;
}

static bool disk_store_sector(disk_t* disk) {
	return disk_seek(disk)
		&& fwrite(disk->buffer, 1, DISK_SECTOR_SIZE, disk->file)
				   == DISK_SECTOR_SIZE;
}

static uint32_t disk_buffer_peek32(const disk_t* disk) {
	const uint8_t* p = &disk->buffer[disk->position];
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16
		 | (uint32_t)p[3] << 24;
}

static void disk_buffer_poke32(disk_t* disk, const uint32_t value) {
	uint8_t* p = &disk->buffer[disk->position];
	p[0] = value & 0xFF;
	p[1] = (value >> 8) & 0xFF;
	p[2] = (value >> 16) & 0xFF;
	p[3] = value >> 24;
}

void disk_tick(disk_t* disk) {
	if (!disk->busy) return;
	if (disk->wait) {
		disk->wait--;
		return;
	}
	disk->wait = disk->word_ticks - 1;
	const bool reading = disk->command == DISK_COMMAND_READ;

	if (reading && disk->position == 0 && !disk_load_sector(disk)) {
		disk_finish(disk, DISK_ERROR_MEDIA);
		return;
	}

	// one word
	if (reading) {
		const uint32_t value = disk_buffer_peek32(disk);
		if (disk->dma.write(disk->dma.ctx, disk->address, 4, value)) {
			disk_finish(disk, DISK_ERROR_ADDRESS);
			return;
		}
	} else {
		uint32_t value = 0;
		if (disk->dma.read(disk->dma.ctx, disk->address, 4, &value)) {
			disk_finish(disk, DISK_ERROR_ADDRESS);
			return;
		}
		disk_buffer_poke32(disk, value);
	}
	disk->address += 4;
	disk->position += 4;
	if (disk->position < DISK_SECTOR_SIZE) return;

	// the sector is done
	if (!reading && !disk_store_sector(disk)) {
		disk_finish(disk, DISK_ERROR_MEDIA);
		return;
	}
	disk->position = 0;
	disk->sector++;
	disk->count--;
	if (disk->count == 0) disk_finish(disk, DISK_ERROR_NONE);
}

bool disk_read(disk_t* disk, const uint32_t offset, const uint8_t size,
			   uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case DISK_REG_STATUS:
			*value = (disk->file ? DISK_STATUS_PRESENT : 0)
				   | (disk->readonly ? DISK_STATUS_READONLY : 0)
				   | (disk->busy ? DISK_STATUS_BUSY : 0)
				   | (disk->done ? DISK_STATUS_DONE : 0)
				   | (disk->error ? DISK_STATUS_ERROR : 0)
				   | (disk->changed ? DISK_STATUS_CHANGED : 0);
			return false;
		case DISK_REG_SECTORS:
			*value = disk->sectors;
			return false;
		case DISK_REG_SECTOR:
			*value = disk->sector;
			return false;
		case DISK_REG_COUNT:
			*value = disk->count;
			return false;
		case DISK_REG_ADDRESS:
			*value = disk->address;
			return false;
		case DISK_REG_COMMAND:
			*value = 0; // write-only
			return false;
		case DISK_REG_ERROR:
			*value = disk->error;
			return false;
	}
	return true;
}

bool disk_write(disk_t* disk, const uint32_t offset, const uint8_t size,
				const uint32_t value) {
	(void)size;
	switch (offset) {
		case DISK_REG_STATUS:
			if (value & DISK_STATUS_DONE) disk->done = false;
			if (value & DISK_STATUS_CHANGED) disk->changed = false;
			disk_update_irq(disk);
			return false;
		case DISK_REG_SECTORS:
		case DISK_REG_ERROR:
			return false; // read-only, writes are ignored
		case DISK_REG_SECTOR:
			if (!disk->busy) disk->sector = value;
			return false;
		case DISK_REG_COUNT:
			if (!disk->busy) disk->count = value;
			return false;
		case DISK_REG_ADDRESS:
			if (!disk->busy) disk->address = value;
			return false;
		case DISK_REG_COMMAND:
			if (!disk->busy) disk_start(disk, value);
			return false;
	}
	return true;
}
