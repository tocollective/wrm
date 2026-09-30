#ifndef WRM_VIDEOCARD_H
#define WRM_VIDEOCARD_H
#include "common.h"

#include "bus.h"
#include "devices/pic.h"

#define VIDEO_VRAM_SIZE 0x400000 // 4MB
#define VIDEO_MAX_WIDTH 1024
#define VIDEO_MAX_HEIGHT 768
#define VIDEO_REFRESH_RATE 60 // frames per second
#define VIDEO_PALETTE_SIZE 256

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define VIDEO_REG_STATUS 0x00 // RW: W 1 to DONE or VBLANK clears it
#define VIDEO_REG_CONTROL 0x04 // RW: display and IRQ enables
#define VIDEO_REG_MODE 0x08 // RW: resolution and depth
#define VIDEO_REG_WIDTH 0x0C // R: of the current mode, in pixels
#define VIDEO_REG_HEIGHT 0x10 // R
#define VIDEO_REG_BPP 0x14 // R: bits per pixel
#define VIDEO_REG_PITCH 0x18 // R: bytes per line of the visible frame
#define VIDEO_REG_VRAM_SIZE 0x1C // R
#define VIDEO_REG_START 0x20 // RW: VRAM offset of the visible frame
#define VIDEO_REG_FRAME 0x24 // R: frames since reset
#define VIDEO_REG_PALETTE_INDEX 0x28 // RW: palette entry of PALETTE_DATA
#define VIDEO_REG_PALETTE_DATA 0x2C // RW: 0x00RRGGBB, W advances the index
#define VIDEO_REG_COMMAND 0x40 // W: starts a drawing engine command
#define VIDEO_REG_ERROR 0x44 // R: why the last command failed, 0 = it didn't
#define VIDEO_REG_DST_BASE 0x48 // RW: destination surface, VRAM offset
#define VIDEO_REG_DST_PITCH 0x4C // RW: ... its bytes per line
#define VIDEO_REG_DST_XY 0x50 // RW: x in bits 0-15, y in bits 16-31
#define VIDEO_REG_SRC_BASE 0x54 // RW: source surface, VRAM offset
#define VIDEO_REG_SRC_PITCH 0x58 // RW
#define VIDEO_REG_SRC_XY 0x5C // RW
#define VIDEO_REG_SIZE 0x60 // RW: width in bits 0-15, height in bits 16-31
#define VIDEO_REG_FG 0x64 // RW: pixel value of FILL and EXPAND
#define VIDEO_REG_BG 0x68 // RW: pixel value of EXPAND for 0 bits
#define VIDEO_REG_ADDRESS 0x6C // RW: physical address of the next DMA word
#define VIDEO_REG_COUNT 0x70 // RW: bytes left to move by DMA

#define VIDEO_STATUS_BUSY 0x01 // a DMA command is running
#define VIDEO_STATUS_DONE 0x02 // the last command has finished
#define VIDEO_STATUS_ERROR 0x04 // ... and failed: ERROR is not 0
#define VIDEO_STATUS_VBLANK 0x08 // a frame has ended

#define VIDEO_CONTROL_ENABLE 0x01 // show the frame, black when clear
#define VIDEO_CONTROL_DONE_IRQ 0x02 // assert the IRQ line while DONE
#define VIDEO_CONTROL_VBLANK_IRQ 0x04 // assert the IRQ line while VBLANK

#define VIDEO_MODE_RES_MASK 0x03 // bits 0-1: resolution
#define VIDEO_MODE_DEPTH_SHIFT 4 // bits 4-6: depth
#define VIDEO_MODE_DEPTH_MASK 0x70
#define VIDEO_MODE_MASK (VIDEO_MODE_RES_MASK | VIDEO_MODE_DEPTH_MASK)

#define VIDEO_RES_320X240 0
#define VIDEO_RES_640X480 1
#define VIDEO_RES_800X600 2
#define VIDEO_RES_1024X768 3

#define VIDEO_DEPTH_1 0 // palette
#define VIDEO_DEPTH_4 1 // palette
#define VIDEO_DEPTH_8 2 // palette
#define VIDEO_DEPTH_16 3 // RGB565
#define VIDEO_DEPTH_32 4 // XRGB8888
#define VIDEO_DEPTH_COUNT 5

#define VIDEO_COMMAND_OP_MASK 0xFF
#define VIDEO_COMMAND_TRANSPARENT 0x100 // EXPAND leaves 0 bits alone

#define VIDEO_COMMAND_FILL 1 // rectangle of FG
#define VIDEO_COMMAND_COPY 2 // VRAM rectangle to VRAM rectangle
#define VIDEO_COMMAND_EXPAND 3 // 1bpp VRAM bitmap to FG/BG pixels
#define VIDEO_COMMAND_LOAD 4 // DMA: memory to VRAM
#define VIDEO_COMMAND_STORE 5 // DMA: VRAM to RAM

#define VIDEO_ERROR_NONE 0
#define VIDEO_ERROR_COMMAND 1 // unknown command
#define VIDEO_ERROR_RANGE 2 // runs past the pitch or the end of VRAM
#define VIDEO_ERROR_ADDRESS 3 // unaligned DMA, or DMA outside RAM (and ROM)

// Video card with its own VRAM, which the CPU can't reach: it draws through
// the drawing engine and moves data by DMA. The frame is scanned out of
// VRAM once per frame at VBLANK. IRQ line is asserted while DONE or VBLANK
// is set and enabled in CONTROL.
typedef struct videocard {
	pic_t* pic;
	uint8_t irq;
	bus_t dma; // LOAD reads RAM or ROM, STORE writes RAM
	uint8_t* vram;

	uint32_t control;
	uint32_t mode;
	uint32_t start;
	uint32_t frame;
	uint32_t palette[VIDEO_PALETTE_SIZE]; // 0x00RRGGBB
	uint8_t palette_index;
	bool vblank;

	uint32_t ticks_per_frame;
	uint32_t ticks; // into the current frame

	// drawing engine
	uint32_t dst_base;
	uint32_t dst_pitch;
	uint32_t dst_xy;
	uint32_t src_base;
	uint32_t src_pitch;
	uint32_t src_xy;
	uint32_t size;
	uint32_t fg;
	uint32_t bg;
	uint32_t address;
	uint32_t count;
	uint32_t error;
	uint32_t command; // the running one
	bool busy;
	bool done;

	// Monitor side: the last frame scanned out, XRGB8888. Only kept up to
	// date while a display is connected.
	bool connected;
	uint32_t* screen; // VIDEO_MAX_WIDTH * VIDEO_MAX_HEIGHT pixels
	uint32_t screen_width;
	uint32_t screen_height;
	uint64_t screen_updates; // goes up with every frame scanned out
} videocard_t;

// rate: clock ticks per second, the frame rate is derived from it
videocard_t* videocard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
							  const uint32_t rate);
void videocard_destroy(videocard_t* videocard);

// Stops a running DMA command; VRAM keeps its contents.
void videocard_reset(videocard_t* videocard);
// advances the frame and a running DMA command by one clock tick
void videocard_tick(videocard_t* videocard);

// bus side: offset is relative to the device base; return true on bus error
bool videocard_read(videocard_t* videocard, const uint32_t offset,
					const uint8_t size, uint32_t* value);
bool videocard_write(videocard_t* videocard, const uint32_t offset,
					 const uint8_t size, const uint32_t value);

#endif // WRM_VIDEOCARD_H
