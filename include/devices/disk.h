#ifndef WRM_DISK_H
#define WRM_DISK_H
#include "common.h"

#include <stdio.h>

#include "bus.h"
#include "devices/pic.h"

#define DISK_SECTOR_SIZE 512

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define DISK_REG_STATUS 0x00 // R, W: 1 to DONE clears it
#define DISK_REG_SECTORS 0x04 // R: disk size in sectors, 0 without a disk
#define DISK_REG_SECTOR 0x08 // RW: next sector to transfer
#define DISK_REG_COUNT 0x0C // RW: sectors left to transfer
#define DISK_REG_ADDRESS 0x10 // RW: physical RAM address of the next word
#define DISK_REG_COMMAND 0x14 // W: starts a transfer
#define DISK_REG_ERROR 0x18 // R: why the last command failed, 0 = it didn't

#define DISK_STATUS_PRESENT 0x01 // a disk image is attached
#define DISK_STATUS_READONLY 0x02 // the image can't be written
#define DISK_STATUS_BUSY 0x04 // a transfer is running
#define DISK_STATUS_DONE 0x08 // the last command has finished
#define DISK_STATUS_ERROR 0x10 // ... and failed: ERROR is not 0

#define DISK_COMMAND_READ 1 // disk to RAM
#define DISK_COMMAND_WRITE 2 // RAM to disk

#define DISK_ERROR_NONE 0
#define DISK_ERROR_COMMAND 1 // unknown command
#define DISK_ERROR_NO_DISK 2
#define DISK_ERROR_RANGE 3 // the sectors run past the end of the disk
#define DISK_ERROR_ADDRESS 4 // unaligned ADDRESS, or DMA outside RAM
#define DISK_ERROR_READONLY 5 // write to a read-only image
#define DISK_ERROR_MEDIA 6 // the host couldn't read or write the image

// Disk controller for a host image file of 512-byte sectors. Transfers go
// straight to RAM (DMA), one word per clock tick; SECTOR, COUNT and
// ADDRESS advance as they go. IRQ line is asserted while STATUS.DONE is set.
typedef struct disk {
	pic_t* pic;
	uint8_t irq;
	bus_t dma; // RAM only
	FILE* file; // NULL = no disk
	bool readonly;
	uint32_t sectors;

	uint32_t sector;
	uint32_t count;
	uint32_t address;
	uint32_t error;
	uint32_t command; // the running one
	bool busy;
	bool done;

	uint8_t buffer[DISK_SECTOR_SIZE]; // the sector being transferred
	uint32_t position; // bytes of it already moved
} disk_t;

// path = NULL makes an empty drive
disk_t* disk_create(pic_t* pic, const uint8_t irq, const bus_t dma,
					const char* path);
void disk_destroy(disk_t* disk);

// Stops a running transfer; the sectors it has written stay written.
void disk_reset(disk_t* disk);
// advances a running transfer by one clock tick
void disk_tick(disk_t* disk);

// bus side: offset is relative to the device base; return true on bus error
bool disk_read(disk_t* disk, const uint32_t offset, const uint8_t size,
			   uint32_t* value);
bool disk_write(disk_t* disk, const uint32_t offset, const uint8_t size,
				const uint32_t value);

#endif // WRM_DISK_H
