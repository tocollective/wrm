#ifndef WRM_SHARE_H
#define WRM_SHARE_H
#include "common.h"

#include <stdio.h>

#include "bus.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define SHARE_REG_STATUS 0x00 // R
#define SHARE_REG_COMMAND 0x04 // W: runs a command at once
#define SHARE_REG_ERROR 0x08 // R: why the last command failed, 0 = it didn't
#define SHARE_REG_HANDLE 0x0C // RW: an open file or directory; OPEN sets it
#define SHARE_REG_PATH 0x10 // RW: physical address of a path
#define SHARE_REG_PATH2 0x14 // RW: ... of the new path, for RENAME
#define SHARE_REG_ADDRESS 0x18 // RW: physical address of the data
#define SHARE_REG_COUNT 0x1C // RW: bytes to move
#define SHARE_REG_POSITION_LO 0x20 // RW: byte offset in the file
#define SHARE_REG_POSITION_HI 0x24 // RW
#define SHARE_REG_FLAGS 0x28 // RW: for OPEN
#define SHARE_REG_RESULT 0x2C // R: bytes moved, or of the record written
#define SHARE_REG_HANDLES 0x30 // R: SHARE_HANDLE_COUNT

#define SHARE_STATUS_PRESENT 0x01 // a host folder is shared
#define SHARE_STATUS_READONLY 0x02 // ... read-only

#define SHARE_COMMAND_OPEN 1
#define SHARE_COMMAND_CLOSE 2
#define SHARE_COMMAND_READ 3
#define SHARE_COMMAND_WRITE 4
#define SHARE_COMMAND_STAT 5
#define SHARE_COMMAND_READDIR 6
#define SHARE_COMMAND_MKDIR 7
#define SHARE_COMMAND_REMOVE 8
#define SHARE_COMMAND_RENAME 9
#define SHARE_COMMAND_TRUNCATE 10
#define SHARE_COMMAND_SYNC 11

#define SHARE_FLAG_WRITE 0x01 // read and write, not only read
#define SHARE_FLAG_CREATE 0x02 // a file that isn't there is made, empty
#define SHARE_FLAG_TRUNCATE 0x04 // the file is cut to 0 bytes
#define SHARE_FLAG_EXCLUSIVE 0x08 // with CREATE: the file must not be there
#define SHARE_FLAG_DIRECTORY 0x10 // a directory, for READDIR
#define SHARE_FLAGS_MASK 0x1F

#define SHARE_ERROR_NONE 0
#define SHARE_ERROR_COMMAND 1 // unknown command, or FLAGS that don't go
#define SHARE_ERROR_NO_FOLDER 2 // no folder is shared
#define SHARE_ERROR_PATH 3 // a path that isn't allowed
#define SHARE_ERROR_NOT_FOUND 4
#define SHARE_ERROR_EXISTS 5
#define SHARE_ERROR_READONLY 6 // the share or the handle is read-only
#define SHARE_ERROR_HANDLE 7 // HANDLE isn't open, or is of the other kind
#define SHARE_ERROR_NO_HANDLE 8 // every handle is open
#define SHARE_ERROR_TYPE 9 // a directory for a file, or the other way round
#define SHARE_ERROR_NOT_EMPTY 10 // REMOVE of a directory with something in it
#define SHARE_ERROR_ADDRESS 11 // the DMA reached memory it can't
#define SHARE_ERROR_SIZE 12 // COUNT is too small for the record
#define SHARE_ERROR_HOST 13 // the host refused or failed
#define SHARE_ERROR_OUTSIDE 14 // a symbolic link leads out of the folder

#define SHARE_HANDLE_COUNT 16
#define SHARE_PATH_MAX 1024 // bytes of a path, its NUL included
#define SHARE_NAME_MAX 255 // bytes of a name in a directory
#define SHARE_STAT_SIZE 32 // the record STAT writes
#define SHARE_DIRENT_MAX (SHARE_STAT_SIZE + SHARE_NAME_MAX + 1)
#define SHARE_MOVE_MAX (1u << 20) // bytes READ or WRITE move at most

#define SHARE_TYPE_FILE 1 // in the TYPE of a record
#define SHARE_TYPE_DIRECTORY 2
#define SHARE_TYPE_OTHER 3

typedef struct share_handle {
	FILE* file; // an open file, NULL = none
	bool writable;
	void* directory; // an open directory (see share.c), NULL = none
} share_handle_t;

// Shared folder: a host directory the guest uses file by file, with the
// file system in the device, as the network card has TCP/IP. Commands run
// at once, in the tick of the store to COMMAND, and move data by DMA (RAM
// or ROM to read from, RAM to write to). Paths are relative to the folder
// and can't leave it. There is no IRQ.
typedef struct share {
	bus_t dma;
	char* root; // the folder's absolute path, NULL = none shared
	bool readonly;
	share_handle_t handle[SHARE_HANDLE_COUNT];

	uint32_t error;
	uint32_t current; // the HANDLE register
	uint32_t path;
	uint32_t path2;
	uint32_t address;
	uint32_t count;
	uint64_t position;
	uint32_t flags;
	uint32_t result;
} share_t;

// root = NULL shares nothing; a root that isn't a directory is a fatal
// error.
share_t* share_create(const bus_t dma, const char* root, const bool readonly);
void share_destroy(share_t* share);

// Closes every handle and clears the registers.
void share_reset(share_t* share);
// Closes every handle; the registers stay (a loaded snapshot can't have
// the host's files open).
void share_close_handles(share_t* share);
// Handles open now.
int share_open_handles(const share_t* share);

// bus side: offset is relative to the device base; return true on bus error
bool share_read(share_t* share, const uint32_t offset, const uint8_t size,
				uint32_t* value);
bool share_write(share_t* share, const uint32_t offset, const uint8_t size,
				 const uint32_t value);

#endif // WRM_SHARE_H
