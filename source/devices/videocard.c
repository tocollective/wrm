#include "devices/videocard.h"

#include <string.h>

static const uint32_t videocard_widths[] = {320, 640, 800, 1024};
static const uint32_t videocard_heights[] = {240, 480, 600, 768};
static const uint32_t videocard_depths[VIDEO_DEPTH_COUNT] = {1, 4, 8, 16, 32};

static uint32_t videocard_width(const videocard_t* videocard) {
	return videocard_widths[videocard->mode & VIDEO_MODE_RES_MASK];
}

static uint32_t videocard_height(const videocard_t* videocard) {
	return videocard_heights[videocard->mode & VIDEO_MODE_RES_MASK];
}

static uint32_t videocard_bpp(const videocard_t* videocard) {
	const uint32_t depth = (videocard->mode & VIDEO_MODE_DEPTH_MASK)
						>> VIDEO_MODE_DEPTH_SHIFT;
	return videocard_depths[depth];
}

void videocard_mode_size(const videocard_t* videocard, uint32_t* width,
						 uint32_t* height) {
	*width = videocard_width(videocard);
	*height = videocard_height(videocard);
}

// bytes per line of the visible frame; every width is a multiple of 8
static uint32_t videocard_pitch(const videocard_t* videocard) {
	return videocard_width(videocard) * videocard_bpp(videocard) / 8;
}

static bool videocard_valid_mode(const uint32_t mode) {
	const uint32_t depth =
			(mode & VIDEO_MODE_DEPTH_MASK) >> VIDEO_MODE_DEPTH_SHIFT;
	return (mode & ~VIDEO_MODE_MASK) == 0 && depth < VIDEO_DEPTH_COUNT;
}

static void videocard_update_irq(videocard_t* videocard) {
	const uint32_t control = videocard->control;
	const bool done = videocard->done && (control & VIDEO_CONTROL_DONE_IRQ);
	const bool vblank =
			videocard->vblank && (control & VIDEO_CONTROL_VBLANK_IRQ);
	pic_set_line(videocard->pic, videocard->irq, done || vblank);
}

videocard_t* videocard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
							  const uint32_t rate) {
	videocard_t* videocard = (videocard_t*)calloc(1, sizeof(videocard_t));
	if (!videocard) error("Failed to allocate video card!");
	videocard->vram = (uint8_t*)calloc(VIDEO_VRAM_SIZE, 1);
	if (!videocard->vram) error("Failed to allocate VRAM!");
	videocard->screen = (uint32_t*)calloc(
			VIDEO_MAX_WIDTH * VIDEO_MAX_HEIGHT, sizeof(uint32_t));
	if (!videocard->screen) error("Failed to allocate the screen buffer!");

	videocard->pic = pic;
	videocard->irq = irq;
	videocard->dma = dma;
	videocard->ticks_per_frame = rate / VIDEO_REFRESH_RATE;
	if (videocard->ticks_per_frame == 0) videocard->ticks_per_frame = 1;
	videocard_reset(videocard);
	return videocard;
}

void videocard_destroy(videocard_t* videocard) {
	if (!videocard) return;
	free(videocard->screen);
	free(videocard->vram);
	free(videocard);
	videocard = NULL;
}

void videocard_reset(videocard_t* videocard) {
	if (!videocard) return;
	videocard->control = 0;
	videocard->mode = 0;
	videocard->start = 0;
	videocard->frame = 0;
	memset(videocard->palette, 0, sizeof(videocard->palette));
	videocard->palette_index = 0;
	videocard->vblank = false;
	videocard->ticks = 0;

	videocard->dst_base = 0;
	videocard->dst_pitch = 0;
	videocard->dst_xy = 0;
	videocard->src_base = 0;
	videocard->src_pitch = 0;
	videocard->src_xy = 0;
	videocard->size = 0;
	videocard->fg = 0;
	videocard->bg = 0;
	videocard->address = 0;
	videocard->count = 0;
	videocard->error = VIDEO_ERROR_NONE;
	videocard->command = 0;
	videocard->busy = false;
	videocard->done = false;
	videocard->line = 0;
	videocard->line_bpp = 0;
	videocard->line_address = 0;
	videocard->line_bytes = 0;
	videocard->line_fetched = 0;
	videocard->line_bit = 0;
	videocard->cursor_control = 0;
	videocard->cursor_base = 0;
	videocard->cursor_xy = 0;
	videocard->cursor_hot = 0;
	videocard_update_irq(videocard);
}

// ---- pixels -------------------------------------------------------------

// A pixel is addressed by its first bit in VRAM. 1 and 4 bpp pixels are
// packed from the most significant bits of a byte, 16 and 32 bpp ones are
// little-endian. The caller has checked that the pixel is in VRAM.
static uint32_t videocard_peek(const videocard_t* videocard,
							   const uint64_t bit, const uint32_t bpp) {
	const uint8_t* p = &videocard->vram[bit >> 3];
	switch (bpp) {
		case 1:
			return (*p >> (7 - (bit & 7))) & 0x1;
		case 4:
			return (*p >> (4 - (bit & 7))) & 0xF;
		case 8:
			return *p;
		case 16:
			return (uint32_t)p[0] | (uint32_t)p[1] << 8;
	}
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16
		 | (uint32_t)p[3] << 24;
}

// stores the low bpp bits of value
static void videocard_poke(videocard_t* videocard, const uint64_t bit,
						   const uint32_t bpp, const uint32_t value) {
	uint8_t* p = &videocard->vram[bit >> 3];
	switch (bpp) {
		case 1: {
			const uint8_t mask = (uint8_t)(0x80 >> (bit & 7));
			*p = (value & 1) ? *p | mask : *p & (uint8_t)~mask;
			return;
		}
		case 4: {
			const unsigned shift = 4 - (unsigned)(bit & 7);
			*p = (uint8_t)((*p & ~(0xF << shift)) | (value & 0xF) << shift);
			return;
		}
		case 8:
			p[0] = value & 0xFF;
			return;
		case 16:
			p[0] = value & 0xFF;
			p[1] = (value >> 8) & 0xFF;
			return;
	}
	p[0] = value & 0xFF;
	p[1] = (value >> 8) & 0xFF;
	p[2] = (value >> 16) & 0xFF;
	p[3] = value >> 24;
}

// the host colour, XRGB8888, of a pixel of the given depth
static uint32_t videocard_color(const videocard_t* videocard,
								const uint32_t pixel, const uint32_t bpp) {
	switch (bpp) {
		case 16: {
			const uint32_t r = (pixel >> 11) & 0x1F;
			const uint32_t g = (pixel >> 5) & 0x3F;
			const uint32_t b = pixel & 0x1F;
			return (r << 3 | r >> 2) << 16 | (g << 2 | g >> 4) << 8
				 | (b << 3 | b >> 2);
		}
		case 32:
			return pixel & 0xFFFFFF;
	}
	return videocard->palette[pixel];
}

// ---- drawing engine ----------------------------------------------------

// A rectangle of VRAM seen as an image: pitch bytes per line from base,
// with the pixel (x, y) as its top left corner.
typedef struct surface {
	uint32_t base;
	uint32_t pitch;
	uint32_t x;
	uint32_t y;
} surface_t;

static surface_t videocard_dst(const videocard_t* videocard) {
	const surface_t surface = {
		videocard->dst_base,
		videocard->dst_pitch,
		videocard->dst_xy & 0xFFFF,
		videocard->dst_xy >> 16,
	};
	return surface;
}

static surface_t videocard_src(const videocard_t* videocard) {
	const surface_t surface = {
		videocard->src_base,
		videocard->src_pitch,
		videocard->src_xy & 0xFFFF,
		videocard->src_xy >> 16,
	};
	return surface;
}

// the first bit of the pixel (i, j) of the rectangle
static uint64_t surface_bit(const surface_t* surface, const uint32_t i,
							const uint32_t j, const uint32_t bpp) {
	const uint64_t line =
			(uint64_t)surface->base + (uint64_t)(surface->y + j) * surface->pitch;
	return line * 8 + (uint64_t)(surface->x + i) * bpp;
}

// Whether lines of w pixels from x stay within the pitch.
static bool surface_fits_pitch(const surface_t* surface, const uint32_t w,
							   const uint32_t bpp) {
	const uint64_t line_bits = ((uint64_t)surface->x + w) * bpp;
	return line_bits <= (uint64_t)surface->pitch * 8;
}

// Whether w x h pixels fit: no line runs past the pitch, and the last one
// ends in VRAM. An empty rectangle always fits.
static bool surface_fits(const surface_t* surface, const uint32_t w,
						 const uint32_t h, const uint32_t bpp) {
	if (w == 0 || h == 0) return true;
	if (!surface_fits_pitch(surface, w, bpp)) return false;
	const uint64_t line_bits = ((uint64_t)surface->x + w) * bpp;
	const uint64_t end = (uint64_t)surface->base
					   + ((uint64_t)surface->y + h - 1) * surface->pitch
					   + (line_bits + 7) / 8;
	return end <= VIDEO_VRAM_SIZE;
}

static uint32_t videocard_fill(videocard_t* videocard) {
	const uint32_t bpp = videocard_bpp(videocard);
	const uint32_t w = videocard->size & 0xFFFF;
	const uint32_t h = videocard->size >> 16;
	const surface_t dst = videocard_dst(videocard);
	if (!surface_fits(&dst, w, h, bpp)) return VIDEO_ERROR_RANGE;

	for (uint32_t j = 0; j < h; j++)
		for (uint32_t i = 0; i < w; i++)
			videocard_poke(
					videocard, surface_bit(&dst, i, j, bpp), bpp, videocard->fg);
	return VIDEO_ERROR_NONE;
}

static void videocard_copy_pixel(videocard_t* videocard, const surface_t* src,
								 const surface_t* dst, const uint32_t i,
								 const uint32_t j, const uint32_t bpp) {
	const uint32_t pixel =
			videocard_peek(videocard, surface_bit(src, i, j, bpp), bpp);
	videocard_poke(videocard, surface_bit(dst, i, j, bpp), bpp, pixel);
}

// Like memmove, it goes backwards when the destination starts after the
// source, so overlapping rectangles of the same pitch copy correctly.
static uint32_t videocard_copy(videocard_t* videocard) {
	const uint32_t bpp = videocard_bpp(videocard);
	const uint32_t w = videocard->size & 0xFFFF;
	const uint32_t h = videocard->size >> 16;
	const surface_t src = videocard_src(videocard);
	const surface_t dst = videocard_dst(videocard);
	if (!surface_fits(&src, w, h, bpp) || !surface_fits(&dst, w, h, bpp))
		return VIDEO_ERROR_RANGE;
	if (w == 0 || h == 0) return VIDEO_ERROR_NONE;

	if (surface_bit(&dst, 0, 0, bpp) > surface_bit(&src, 0, 0, bpp)) {
		for (uint32_t j = h; j-- > 0;)
			for (uint32_t i = w; i-- > 0;)
				videocard_copy_pixel(videocard, &src, &dst, i, j, bpp);
	} else {
		for (uint32_t j = 0; j < h; j++)
			for (uint32_t i = 0; i < w; i++)
				videocard_copy_pixel(videocard, &src, &dst, i, j, bpp);
	}
	return VIDEO_ERROR_NONE;
}

// A bit of the 1 bpp source of EXPAND: 1 bits become FG, 0 bits BG, or
// are skipped with TRANSPARENT.
static void videocard_expand_pixel(videocard_t* videocard,
								   const surface_t* dst, const uint32_t i,
								   const uint32_t j, const uint32_t bpp,
								   const bool set) {
	const bool transparent = videocard->command & VIDEO_COMMAND_TRANSPARENT;
	if (!set && transparent) return;
	videocard_poke(videocard,
				   surface_bit(dst, i, j, bpp),
				   bpp,
				   set ? videocard->fg : videocard->bg);
}

// EXPAND from VRAM
static uint32_t videocard_expand(videocard_t* videocard) {
	const uint32_t bpp = videocard_bpp(videocard);
	const uint32_t w = videocard->size & 0xFFFF;
	const uint32_t h = videocard->size >> 16;
	const surface_t src = videocard_src(videocard);
	const surface_t dst = videocard_dst(videocard);
	if (!surface_fits(&src, w, h, 1) || !surface_fits(&dst, w, h, bpp))
		return VIDEO_ERROR_RANGE;

	for (uint32_t j = 0; j < h; j++) {
		for (uint32_t i = 0; i < w; i++) {
			const bool set = videocard_peek(
					videocard, surface_bit(&src, i, j, 1), 1);
			videocard_expand_pixel(videocard, &dst, i, j, bpp, set);
		}
	}
	return VIDEO_ERROR_NONE;
}

static void videocard_finish(videocard_t* videocard, const uint32_t error) {
	videocard->busy = false;
	videocard->done = true;
	videocard->error = error;
	videocard_update_irq(videocard);
}

// LOAD and STORE: checks the registers and starts the transfer; a command
// that can't run finishes at once with an error.
static void videocard_start_dma(videocard_t* videocard, const bool load) {
	const uint32_t vram = load ? videocard->dst_base : videocard->src_base;
	const uint32_t count = videocard->count;
	if ((videocard->address | vram | count) & 3)
		videocard_finish(videocard, VIDEO_ERROR_ADDRESS);
	else if (vram > VIDEO_VRAM_SIZE || count > VIDEO_VRAM_SIZE - vram)
		videocard_finish(videocard, VIDEO_ERROR_RANGE);
	else if (count == 0)
		videocard_finish(videocard, VIDEO_ERROR_NONE);
	else {
		videocard->busy = true;
		videocard_update_irq(videocard);
	}
}

// ---- EXPAND from memory ----------------------------------------------------
// SRC_BASE is a physical address. The card fetches the source a line at a
// time, one word per tick: the aligned words that hold the line's bits.
// When the last one is in, it draws the line.

// Sets up the fetch of the current line; false if it runs past the top of
// the address space.
static bool videocard_line_start(videocard_t* videocard) {
	const uint32_t w = videocard->size & 0xFFFF;
	const surface_t src = videocard_src(videocard);
	const uint64_t line = (uint64_t)src.base
						+ ((uint64_t)src.y + videocard->line) * src.pitch;
	const uint64_t first = line + src.x / 8; // bytes of the line's bits
	const uint64_t last = line + (src.x + w - 1) / 8;
	const uint64_t start = first & ~(uint64_t)3;
	const uint64_t end = (last | 3) + 1;
	if (end > (uint64_t)UINT32_MAX + 1) return false;

	videocard->line_address = start;
	videocard->line_bytes = (uint32_t)(end - start);
	videocard->line_fetched = 0;
	videocard->line_bit = (uint32_t)(first - start) * 8 + src.x % 8;
	return true;
}

static void videocard_start_memory_expand(videocard_t* videocard) {
	const uint32_t bpp = videocard_bpp(videocard);
	const uint32_t w = videocard->size & 0xFFFF;
	const uint32_t h = videocard->size >> 16;
	const surface_t src = videocard_src(videocard);
	const surface_t dst = videocard_dst(videocard);
	if (!surface_fits_pitch(&src, w, 1) || !surface_fits(&dst, w, h, bpp))
		videocard_finish(videocard, VIDEO_ERROR_RANGE);
	else if (w == 0 || h == 0)
		videocard_finish(videocard, VIDEO_ERROR_NONE);
	else {
		videocard->line = 0;
		videocard->line_bpp = bpp; // a mode change doesn't reach it
		if (!videocard_line_start(videocard)) {
			videocard_finish(videocard, VIDEO_ERROR_ADDRESS);
			return;
		}
		videocard->busy = true;
		videocard_update_irq(videocard);
	}
}

// one word per tick; draws the line once it is complete
static void videocard_line_tick(videocard_t* videocard) {
	uint32_t value = 0;
	const uint32_t address = (uint32_t)videocard->line_address;
	if (videocard->dma.read(videocard->dma.ctx, address, 4, &value)) {
		videocard_finish(videocard, VIDEO_ERROR_ADDRESS);
		return;
	}
	uint8_t* p = &videocard->line_buffer[videocard->line_fetched];
	p[0] = value & 0xFF;
	p[1] = (value >> 8) & 0xFF;
	p[2] = (value >> 16) & 0xFF;
	p[3] = value >> 24;
	videocard->line_address += 4;
	videocard->line_fetched += 4;
	if (videocard->line_fetched < videocard->line_bytes) return;

	const uint32_t w = videocard->size & 0xFFFF;
	const uint32_t h = videocard->size >> 16;
	const surface_t dst = videocard_dst(videocard);
	for (uint32_t i = 0; i < w; i++) {
		const uint32_t bit = videocard->line_bit + i;
		const uint8_t byte = videocard->line_buffer[bit >> 3];
		const bool set = (byte >> (7 - (bit & 7))) & 1;
		videocard_expand_pixel(
				videocard, &dst, i, videocard->line, videocard->line_bpp, set);
	}

	videocard->line++;
	if (videocard->line == h)
		videocard_finish(videocard, VIDEO_ERROR_NONE);
	else if (!videocard_line_start(videocard))
		videocard_finish(videocard, VIDEO_ERROR_ADDRESS);
}

// Drawing commands finish at once, except EXPAND from memory; LOAD and
// STORE run on their own.
static void videocard_start(videocard_t* videocard, const uint32_t command) {
	videocard->command = command;
	videocard->done = false;
	videocard->error = VIDEO_ERROR_NONE;

	switch (command & VIDEO_COMMAND_OP_MASK) {
		case VIDEO_COMMAND_FILL:
			videocard_finish(videocard, videocard_fill(videocard));
			break;
		case VIDEO_COMMAND_COPY:
			videocard_finish(videocard, videocard_copy(videocard));
			break;
		case VIDEO_COMMAND_EXPAND:
			if (command & VIDEO_COMMAND_MEMORY)
				videocard_start_memory_expand(videocard);
			else
				videocard_finish(videocard, videocard_expand(videocard));
			break;
		case VIDEO_COMMAND_LOAD:
			videocard_start_dma(videocard, true);
			break;
		case VIDEO_COMMAND_STORE:
			videocard_start_dma(videocard, false);
			break;
		default:
			videocard_finish(videocard, VIDEO_ERROR_COMMAND);
			break;
	}
}

static uint32_t videocard_vram_peek32(const videocard_t* videocard,
									  const uint32_t offset) {
	const uint8_t* p = &videocard->vram[offset];
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16
		 | (uint32_t)p[3] << 24;
}

static void videocard_vram_poke32(videocard_t* videocard,
								  const uint32_t offset, const uint32_t value) {
	uint8_t* p = &videocard->vram[offset];
	p[0] = value & 0xFF;
	p[1] = (value >> 8) & 0xFF;
	p[2] = (value >> 16) & 0xFF;
	p[3] = value >> 24;
}

// one word per tick; the range was checked when the command started
static void videocard_dma_tick(videocard_t* videocard) {
	const bool load =
			(videocard->command & VIDEO_COMMAND_OP_MASK) == VIDEO_COMMAND_LOAD;
	if (load) {
		uint32_t value = 0;
		if (videocard->dma.read(
					videocard->dma.ctx, videocard->address, 4, &value)) {
			videocard_finish(videocard, VIDEO_ERROR_ADDRESS);
			return;
		}
		videocard_vram_poke32(videocard, videocard->dst_base, value);
		videocard->dst_base += 4;
	} else {
		const uint32_t value =
				videocard_vram_peek32(videocard, videocard->src_base);
		if (videocard->dma.write(
					videocard->dma.ctx, videocard->address, 4, value)) {
			videocard_finish(videocard, VIDEO_ERROR_ADDRESS);
			return;
		}
		videocard->src_base += 4;
	}
	videocard->address += 4;
	videocard->count -= 4;
	if (videocard->count == 0) videocard_finish(videocard, VIDEO_ERROR_NONE);
}

// ---- scanout --------------------------------------------------------------

// One channel of the cursor over the frame: alpha 255 is the cursor alone,
// 0 the frame alone
static uint32_t videocard_blend(const uint32_t cursor, const uint32_t frame,
								const uint32_t alpha) {
	return (cursor * alpha + frame * (255 - alpha) + 127) / 255;
}

// Blends the cursor over the screen. Its pixels that are off the screen,
// or past the end of VRAM, aren't drawn.
static void videocard_draw_cursor(videocard_t* videocard) {
	const uint32_t width = videocard->screen_width;
	const uint32_t height = videocard->screen_height;
	// the image's top left corner on the screen
	const int32_t left = (int32_t)(int16_t)(videocard->cursor_xy & 0xFFFF)
					   - (int32_t)(videocard->cursor_hot & 0xFFFF);
	const int32_t top = (int32_t)(int16_t)(videocard->cursor_xy >> 16)
					  - (int32_t)(videocard->cursor_hot >> 16);
	for (int32_t cy = 0; cy < VIDEO_CURSOR_SIZE; cy++) {
		const int32_t y = top + cy;
		if (y < 0 || y >= (int32_t)height) continue;
		for (int32_t cx = 0; cx < VIDEO_CURSOR_SIZE; cx++) {
			const int32_t x = left + cx;
			if (x < 0 || x >= (int32_t)width) continue;
			const uint64_t at = (uint64_t)videocard->cursor_base
							  + ((uint64_t)cy * VIDEO_CURSOR_SIZE + cx) * 4;
			if (at + 4 > VIDEO_VRAM_SIZE) return; // and so are the rest
			const uint32_t pixel = videocard_peek(videocard, at * 8, 32);
			const uint32_t alpha = pixel >> 24;
			if (alpha == 0) continue;
			uint32_t* out = &videocard->screen[(uint32_t)y * width + x];
			uint32_t color = 0;
			for (int shift = 0; shift < 24; shift += 8)
				color |= videocard_blend((pixel >> shift) & 0xFF,
										 (*out >> shift) & 0xFF,
										 alpha)
					   << shift;
			*out = color;
		}
	}
}

// Converts the visible frame to the screen. Lines that run past the end of
// VRAM are black, and so is everything while the display is off.
static void videocard_scanout(videocard_t* videocard) {
	const uint32_t width = videocard_width(videocard);
	const uint32_t height = videocard_height(videocard);
	const uint32_t bpp = videocard_bpp(videocard);
	const uint32_t pitch = videocard_pitch(videocard);
	const bool enabled = videocard->control & VIDEO_CONTROL_ENABLE;

	videocard->screen_width = width;
	videocard->screen_height = height;
	for (uint32_t y = 0; y < height; y++) {
		uint32_t* out = &videocard->screen[y * width];
		const uint64_t line = (uint64_t)videocard->start + (uint64_t)y * pitch;
		if (!enabled || line + pitch > VIDEO_VRAM_SIZE) {
			memset(out, 0, width * sizeof(uint32_t));
			continue;
		}
		for (uint32_t x = 0; x < width; x++) {
			const uint64_t bit = line * 8 + (uint64_t)x * bpp;
			const uint32_t pixel = videocard_peek(videocard, bit, bpp);
			out[x] = videocard_color(videocard, pixel, bpp);
		}
	}
	if (enabled && (videocard->cursor_control & VIDEO_CURSOR_SHOWN))
		videocard_draw_cursor(videocard);
	videocard->screen_updates++;
}

static void videocard_vblank(videocard_t* videocard) {
	if (videocard->connected) videocard_scanout(videocard);
	videocard->frame++;
	videocard->vblank = true;
	videocard_update_irq(videocard);
}

static void videocard_tick(videocard_t* videocard) {
	const uint32_t op = videocard->command & VIDEO_COMMAND_OP_MASK;
	if (videocard->busy && op == VIDEO_COMMAND_EXPAND)
		videocard_line_tick(videocard);
	else if (videocard->busy)
		videocard_dma_tick(videocard);
	if (++videocard->ticks < videocard->ticks_per_frame) return;
	videocard->ticks = 0;
	videocard_vblank(videocard);
}

void videocard_run(videocard_t* videocard, uint64_t ticks) {
	// a DMA command moves a word every tick
	for (; ticks > 0 && videocard->busy; ticks--) videocard_tick(videocard);
	while (ticks >= videocard->ticks_per_frame - videocard->ticks) {
		ticks -= videocard->ticks_per_frame - videocard->ticks;
		videocard->ticks = 0;
		videocard_vblank(videocard);
	}
	videocard->ticks += (uint32_t)ticks;
}

uint64_t videocard_next_event(const videocard_t* videocard) {
	if (videocard->busy) return 1;
	return videocard->ticks_per_frame - videocard->ticks;
}

// ---- bus ----------------------------------------------------------------

bool videocard_read(videocard_t* videocard, const uint32_t offset,
					const uint8_t size, uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case VIDEO_REG_STATUS:
			*value = (videocard->busy ? VIDEO_STATUS_BUSY : 0)
				   | (videocard->done ? VIDEO_STATUS_DONE : 0)
				   | (videocard->error ? VIDEO_STATUS_ERROR : 0)
				   | (videocard->vblank ? VIDEO_STATUS_VBLANK : 0);
			return false;
		case VIDEO_REG_CONTROL:
			*value = videocard->control;
			return false;
		case VIDEO_REG_MODE:
			*value = videocard->mode;
			return false;
		case VIDEO_REG_WIDTH:
			*value = videocard_width(videocard);
			return false;
		case VIDEO_REG_HEIGHT:
			*value = videocard_height(videocard);
			return false;
		case VIDEO_REG_BPP:
			*value = videocard_bpp(videocard);
			return false;
		case VIDEO_REG_PITCH:
			*value = videocard_pitch(videocard);
			return false;
		case VIDEO_REG_VRAM_SIZE:
			*value = VIDEO_VRAM_SIZE;
			return false;
		case VIDEO_REG_START:
			*value = videocard->start;
			return false;
		case VIDEO_REG_FRAME:
			*value = videocard->frame;
			return false;
		case VIDEO_REG_PALETTE_INDEX:
			*value = videocard->palette_index;
			return false;
		case VIDEO_REG_PALETTE_DATA:
			*value = videocard->palette[videocard->palette_index];
			return false;
		case VIDEO_REG_COMMAND:
			*value = 0; // write-only
			return false;
		case VIDEO_REG_ERROR:
			*value = videocard->error;
			return false;
		case VIDEO_REG_DST_BASE:
			*value = videocard->dst_base;
			return false;
		case VIDEO_REG_DST_PITCH:
			*value = videocard->dst_pitch;
			return false;
		case VIDEO_REG_DST_XY:
			*value = videocard->dst_xy;
			return false;
		case VIDEO_REG_SRC_BASE:
			*value = videocard->src_base;
			return false;
		case VIDEO_REG_SRC_PITCH:
			*value = videocard->src_pitch;
			return false;
		case VIDEO_REG_SRC_XY:
			*value = videocard->src_xy;
			return false;
		case VIDEO_REG_SIZE:
			*value = videocard->size;
			return false;
		case VIDEO_REG_FG:
			*value = videocard->fg;
			return false;
		case VIDEO_REG_BG:
			*value = videocard->bg;
			return false;
		case VIDEO_REG_ADDRESS:
			*value = videocard->address;
			return false;
		case VIDEO_REG_COUNT:
			*value = videocard->count;
			return false;
		case VIDEO_REG_CURSOR_CONTROL:
			*value = videocard->cursor_control;
			return false;
		case VIDEO_REG_CURSOR_BASE:
			*value = videocard->cursor_base;
			return false;
		case VIDEO_REG_CURSOR_XY:
			*value = videocard->cursor_xy;
			return false;
		case VIDEO_REG_CURSOR_HOT:
			*value = videocard->cursor_hot;
			return false;
	}
	return true;
}

// The drawing engine's registers ignore writes while a command runs.
static bool videocard_write_engine(videocard_t* videocard,
								   const uint32_t offset, const uint32_t value) {
	uint32_t* reg = NULL;
	switch (offset) {
		case VIDEO_REG_COMMAND:
			if (!videocard->busy) videocard_start(videocard, value);
			return false;
		case VIDEO_REG_DST_BASE:
			reg = &videocard->dst_base;
			break;
		case VIDEO_REG_DST_PITCH:
			reg = &videocard->dst_pitch;
			break;
		case VIDEO_REG_DST_XY:
			reg = &videocard->dst_xy;
			break;
		case VIDEO_REG_SRC_BASE:
			reg = &videocard->src_base;
			break;
		case VIDEO_REG_SRC_PITCH:
			reg = &videocard->src_pitch;
			break;
		case VIDEO_REG_SRC_XY:
			reg = &videocard->src_xy;
			break;
		case VIDEO_REG_SIZE:
			reg = &videocard->size;
			break;
		case VIDEO_REG_FG:
			reg = &videocard->fg;
			break;
		case VIDEO_REG_BG:
			reg = &videocard->bg;
			break;
		case VIDEO_REG_ADDRESS:
			reg = &videocard->address;
			break;
		case VIDEO_REG_COUNT:
			reg = &videocard->count;
			break;
		default:
			return true;
	}
	if (!videocard->busy) *reg = value;
	return false;
}

bool videocard_write(videocard_t* videocard, const uint32_t offset,
					 const uint8_t size, const uint32_t value) {
	(void)size;
	switch (offset) {
		case VIDEO_REG_STATUS:
			if (value & VIDEO_STATUS_DONE) videocard->done = false;
			if (value & VIDEO_STATUS_VBLANK) videocard->vblank = false;
			videocard_update_irq(videocard);
			return false;
		case VIDEO_REG_CONTROL:
			videocard->control = value
							   & (VIDEO_CONTROL_ENABLE | VIDEO_CONTROL_DONE_IRQ
								  | VIDEO_CONTROL_VBLANK_IRQ);
			videocard_update_irq(videocard);
			return false;
		case VIDEO_REG_MODE:
			if (videocard_valid_mode(value)) videocard->mode = value;
			return false;
		case VIDEO_REG_WIDTH:
		case VIDEO_REG_HEIGHT:
		case VIDEO_REG_BPP:
		case VIDEO_REG_PITCH:
		case VIDEO_REG_VRAM_SIZE:
		case VIDEO_REG_FRAME:
		case VIDEO_REG_ERROR:
			return false; // read-only, writes are ignored
		case VIDEO_REG_START:
			videocard->start = value;
			return false;
		case VIDEO_REG_PALETTE_INDEX:
			videocard->palette_index = value & 0xFF;
			return false;
		case VIDEO_REG_PALETTE_DATA:
			videocard->palette[videocard->palette_index++] = value & 0xFFFFFF;
			return false;
		case VIDEO_REG_CURSOR_CONTROL:
			videocard->cursor_control = value & VIDEO_CURSOR_SHOWN;
			return false;
		case VIDEO_REG_CURSOR_BASE:
			videocard->cursor_base = value & (VIDEO_VRAM_SIZE - 4);
			return false;
		case VIDEO_REG_CURSOR_XY:
			videocard->cursor_xy = value;
			return false;
		case VIDEO_REG_CURSOR_HOT:
			videocard->cursor_hot = value & VIDEO_CURSOR_HOT_MASK;
			return false;
	}
	return videocard_write_engine(videocard, offset, value);
}
