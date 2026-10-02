// 64-bit file offsets on 32-bit hosts too; fseeko, fileno, flock, fsync
// and realpath under strict C99
#define _FILE_OFFSET_BITS 64
#ifndef _WIN32
#define _DEFAULT_SOURCE
#endif

#include "devices/disk.h"

#include <string.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
typedef __int64 disk_offset_t;
#define disk_fseek _fseeki64
#define disk_ftell _ftelli64
#else
#include <fcntl.h>
#include <sys/file.h>
#include <sys/types.h>
#include <unistd.h>
typedef off_t disk_offset_t;
#define disk_fseek fseeko
#define disk_ftell ftello
#endif

#ifdef __EMSCRIPTEN__
#include "web.h"
#endif

static void disk_update_irq(disk_t* disk) {
	pic_set_line(disk->pic, disk->irq, disk->done || disk->changed);
}

// Locks the open image against other emulators: exclusively to write it,
// shared to read it. False if another one holds a lock in the way. The
// lock goes with the file when it is closed.
static bool disk_lock(FILE* file, const bool exclusive) {
#ifdef _WIN32
	// Windows locks keep everyone else from the bytes they cover, so the
	// lock is on a byte far past the end of any image
	OVERLAPPED at = { 0 };
	at.Offset = 0xFFFFFFFE;
	at.OffsetHigh = 0x7FFFFFFF;
	const DWORD flags = LOCKFILE_FAIL_IMMEDIATELY
					  | (exclusive ? LOCKFILE_EXCLUSIVE_LOCK : 0);
	return LockFileEx(
			(HANDLE)_get_osfhandle(_fileno(file)), flags, 0, 1, 0, &at);
#else
	return flock(fileno(file), (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0;
#endif
}

// Writes what stdio holds of the image and has the host put it on its
// medium; false if it fails.
static bool disk_sync(FILE* file) {
	if (fflush(file) != 0) return false;
#if defined(_WIN32)
	return _commit(_fileno(file)) == 0;
#elif defined(__APPLE__) && defined(F_FULLFSYNC)
	// fsync on macOS leaves the data in the drive's cache; not every file
	// system takes F_FULLFSYNC
	return fcntl(fileno(file), F_FULLFSYNC) != -1 || fsync(fileno(file)) == 0;
#else
	return fsync(fileno(file)) == 0;
#endif
}

// Attaches the image at path; false (with a warning) if it can't be used.
// An image that another emulator has attached is read-only here, and one
// it writes can't be attached.
static bool disk_open(disk_t* disk, const char* path) {
	disk->readonly = false;
	bool in_use = false;
	disk->file = fopen(path, "r+b");
	if (disk->file && !disk_lock(disk->file, true)) {
		fclose(disk->file);
		disk->file = NULL;
		in_use = true;
	}
	if (!disk->file) {
		disk->file = fopen(path, "rb");
		disk->readonly = true;
		if (disk->file && !disk_lock(disk->file, false)) {
			warning("Disk image %s is being written by another emulator",
					path);
			fclose(disk->file);
			disk->file = NULL;
			disk->readonly = false;
			return false;
		}
	}
	if (!disk->file) {
		disk->readonly = false;
		warning("Failed to open the disk image %s", path);
		return false;
	}
	if (in_use)
		warning("Disk image %s is in use by another emulator: attached "
				"read-only",
				path);

	disk_offset_t size = -1;
	if (disk_fseek(disk->file, 0, SEEK_END) == 0)
		size = disk_ftell(disk->file);
	if (size < 0) {
		warning("Failed to get the size of the disk image %s", path);
		fclose(disk->file);
		disk->file = NULL;
		return false;
	}
	if (size % DISK_SECTOR_SIZE)
		warning("Disk image %s: the last %d bytes are not a whole sector "
				"and can't be accessed",
				path,
				(int)(size % DISK_SECTOR_SIZE));

	const uint64_t sectors = (uint64_t)size / DISK_SECTOR_SIZE;
	disk->sectors = sectors > UINT32_MAX ? UINT32_MAX : (uint32_t)sectors;
	const size_t length = strlen(path) + 1;
	disk->path = malloc(length);
	if (!disk->path) error("Failed to allocate disk controller!");
	memcpy(disk->path, path, length);
	print("Disk %s: %u sectors%s",
		  path,
		  disk->sectors,
		  disk->readonly ? ", read-only" : "");
	return true;
}

static void disk_close(disk_t* disk) {
	if (disk->file) fclose(disk->file);
	disk->file = NULL;
	free(disk->path);
	disk->path = NULL;
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

void disk_set_serial(disk_t* disk, const char* serial, const bool from_name) {
	if (!disk) return;
	disk->serial = serial;
	disk->serial_from_name = from_name;
}

void disk_reset(disk_t* disk) {
	if (!disk) return;
	if (disk->file) fflush(disk->file);
	disk->sector = 0;
	disk->count = 0;
	disk->address = 0;
	disk->error = DISK_ERROR_NONE;
	disk->list = 0;
	disk->command = 0;
	disk->busy = false;
	disk->done = false;
	disk->changed = false;
	disk->position = 0;
	disk->wait = 0;
	disk->left = 0;
	disk_update_irq(disk);
}

static uint32_t disk_command_code(const disk_t* disk) {
	return disk->command & DISK_COMMAND_CODE;
}

static void disk_finish(disk_t* disk, const uint32_t error) {
	if (disk_command_code(disk) == DISK_COMMAND_WRITE && disk->file)
		fflush(disk->file);
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

static bool disk_command_valid(const uint32_t command) {
	if (command & ~(DISK_COMMAND_CODE | DISK_COMMAND_LIST)) return false;
	switch (command & DISK_COMMAND_CODE) {
		case DISK_COMMAND_READ:
		case DISK_COMMAND_WRITE:
		case DISK_COMMAND_IDENTIFY:
			return true;
		case DISK_COMMAND_FLUSH:
			return !(command & DISK_COMMAND_LIST); // moves no data
	}
	return false;
}

// Checks the registers and starts the transfer; a command that can't run
// finishes at once with an error, and so does FLUSH when it's done.
static void disk_start(disk_t* disk, const uint32_t command) {
	disk->command = command;
	disk->done = false;
	disk->error = DISK_ERROR_NONE;
	disk->position = 0;
	disk->left = 0;
	const uint32_t code = disk_command_code(disk);
	const bool list = command & DISK_COMMAND_LIST;

	if (!disk_command_valid(command))
		disk_finish(disk, DISK_ERROR_COMMAND);
	else if (!disk->file)
		disk_finish(disk, DISK_ERROR_NO_DISK);
	else if (code == DISK_COMMAND_FLUSH) {
		disk_finish(disk,
					disk->readonly || disk_sync(disk->file) ? DISK_ERROR_NONE
															: DISK_ERROR_MEDIA);
#ifdef __EMSCRIPTEN__
		// the browser's copy of the image is what lasts
		if (!disk->readonly) web_persist();
#endif
	}
	else if (code == DISK_COMMAND_WRITE && disk->readonly)
		disk_finish(disk, DISK_ERROR_READONLY);
	else if ((list ? disk->list : disk->address) & 3)
		disk_finish(disk, DISK_ERROR_ADDRESS);
	else if (code != DISK_COMMAND_IDENTIFY
			 && (disk->sector > disk->sectors
				 || disk->count > disk->sectors - disk->sector))
		disk_finish(disk, DISK_ERROR_RANGE);
	else if (code != DISK_COMMAND_IDENTIFY && disk->count == 0)
		disk_finish(disk, DISK_ERROR_NONE);
	else {
		disk->busy = true;
		// the first word moves word_ticks ticks from now
		disk->wait = disk->word_ticks - 1;
		disk_update_irq(disk);
	}
}

// Moves the current sector between the buffer and the image; false if the
// host fails. SECTOR is 32-bit, so the offset is below 2^41.
static bool disk_seek(disk_t* disk) {
	const disk_offset_t offset =
		(disk_offset_t)disk->sector * DISK_SECTOR_SIZE;
	return disk_fseek(disk->file, offset, SEEK_SET) == 0;
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

// 64-bit FNV-1a, continuing from hash
static uint64_t disk_hash(uint64_t hash, const char* text) {
	for (; *text; text++) {
		hash ^= (uint8_t)*text;
		hash *= 0x100000001B3ULL;
	}
	return hash;
}

// The serial number IDENTIFY reports, NUL-padded: the given one, or 16
// hex digits of a hash of where the image is.
static void disk_make_serial(const disk_t* disk, char* serial) {
	memset(serial, 0, DISK_SERIAL_SIZE);
	if (disk->serial) {
		strncpy(serial, disk->serial, DISK_SERIAL_SIZE - 1);
		return;
	}
	const char* name = disk->path;
	char* absolute = NULL;
	if (disk->serial_from_name) {
		for (const char* p = disk->path; *p; p++)
			if (*p == '/' || *p == '\\') name = p + 1;
	} else {
#ifdef _WIN32
		absolute = _fullpath(NULL, disk->path, 0);
#else
		absolute = realpath(disk->path, NULL);
#endif
		if (absolute) name = absolute;
	}
	snprintf(serial,
			 DISK_SERIAL_SIZE,
			 "%016llX",
			 (unsigned long long)disk_hash(0xCBF29CE484222325ULL, name));
	free(absolute);
}

static void disk_buffer_put32(disk_t* disk, const uint32_t offset,
							  const uint32_t value) {
	for (int i = 0; i < 4; i++)
		disk->buffer[offset + i] = (uint8_t)(value >> (8 * i));
}

// Fills the buffer with the identify block. The UUID is a hash of the
// serial number, so the same serial always gives the same UUID.
static void disk_load_identify(disk_t* disk) {
	memset(disk->buffer, 0, sizeof(disk->buffer));
	disk_buffer_put32(disk, 0x00, DISK_IDENTIFY_MAGIC);
	disk_buffer_put32(disk, 0x04, DISK_IDENTIFY_VERSION);
	disk_buffer_put32(disk, 0x08, disk->sectors);
	disk_buffer_put32(disk, 0x0C, DISK_SECTOR_SIZE);
	disk_buffer_put32(
			disk, 0x10, (disk->removable ? 1u : 0) | (disk->readonly ? 2u : 0));

	char serial[DISK_SERIAL_SIZE];
	disk_make_serial(disk, serial);
	memcpy(&disk->buffer[0x30], serial, DISK_SERIAL_SIZE);
	const char* model =
		disk->removable ? "WRM.081632 floppy disk" : "WRM.081632 hard disk";
	strncpy((char*)&disk->buffer[0x50], model, DISK_MODEL_SIZE - 1);

	// RFC 9562 version 8 (custom), big-endian like any UUID
	const uint64_t high = disk_hash(0xCBF29CE484222325ULL, serial);
	const uint64_t low = disk_hash(high, serial);
	uint8_t* uuid = &disk->buffer[0x20];
	for (int i = 0; i < 8; i++) {
		uuid[i] = (uint8_t)(high >> (56 - 8 * i));
		uuid[8 + i] = (uint8_t)(low >> (56 - 8 * i));
	}
	uuid[6] = (uuid[6] & 0x0F) | 0x80;
	uuid[8] = (uuid[8] & 0x3F) | 0x80;
}

// LIST: when the current piece of RAM is used up, takes the next one from
// the descriptor at LIST; false if the transfer has stopped on an error.
static bool disk_next_piece(disk_t* disk) {
	if (!(disk->command & DISK_COMMAND_LIST) || disk->left) return true;
	uint32_t address = 0, bytes = 0;
	if (disk->dma.read(disk->dma.ctx, disk->list, 4, &address)
		|| disk->dma.read(disk->dma.ctx, disk->list + 4, 4, &bytes)) {
		disk_finish(disk, DISK_ERROR_ADDRESS);
		return false;
	}
	if (bytes == 0 || ((address | bytes) & 3)) {
		disk_finish(disk, DISK_ERROR_DESCRIPTOR);
		return false;
	}
	disk->address = address;
	disk->left = bytes;
	disk->list += 8;
	return true;
}

// The tick on which the next word moves: wait is 0.
static void disk_move_word(disk_t* disk) {
	disk->wait = disk->word_ticks - 1;
	const uint32_t code = disk_command_code(disk);
	const bool identify = code == DISK_COMMAND_IDENTIFY;
	const bool reading = code == DISK_COMMAND_READ || identify;

	if (reading && disk->position == 0) {
		if (identify)
			disk_load_identify(disk);
		else if (!disk_load_sector(disk)) {
			disk_finish(disk, DISK_ERROR_MEDIA);
			return;
		}
	}
	if (!disk_next_piece(disk)) return;

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
	if (disk->left) disk->left -= 4;
	if (disk->position < DISK_SECTOR_SIZE) return;

	// the sector is done
	if (identify) {
		disk_finish(disk, DISK_ERROR_NONE); // SECTOR and COUNT stay
		return;
	}
	if (!reading && !disk_store_sector(disk)) {
		disk_finish(disk, DISK_ERROR_MEDIA);
		return;
	}
	disk->position = 0;
	disk->sector++;
	disk->count--;
	if (disk->count == 0) disk_finish(disk, DISK_ERROR_NONE);
}

void disk_run(disk_t* disk, uint64_t ticks) {
	while (ticks > 0 && disk->busy) {
		if (ticks <= disk->wait) {
			disk->wait -= (uint32_t)ticks;
			return;
		}
		ticks -= (uint64_t)disk->wait + 1;
		disk->wait = 0;
		disk_move_word(disk);
	}
}

uint64_t disk_next_event(const disk_t* disk) {
	return disk->busy ? (uint64_t)disk->wait + 1 : TICKS_NEVER;
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
		case DISK_REG_LIST:
			*value = disk->list;
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
		case DISK_REG_LIST:
			if (!disk->busy) disk->list = value;
			return false;
		case DISK_REG_COMMAND:
			if (!disk->busy) disk_start(disk, value);
			return false;
	}
	return true;
}
