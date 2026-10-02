#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L // stat under strict C99
#endif

#include "snapshot.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

// File layout: the header (magic, version, what the machine is made of),
// then the state, then a 64-bit FNV-1a checksum of everything before it.
// Numbers are little-endian. Every part starts with a 4-byte tag, so a
// layout that doesn't match is caught where it goes wrong.
static const char snapshot_magic[8] = { 'W', 'R', 'M', 'S', 'N', 'A', 'P', 0 };

#define SNAPSHOT_FNV_OFFSET 0xCBF29CE484222325ULL
#define SNAPSHOT_FNV_PRIME 0x100000001B3ULL

// One stream for both ways: saving writes the fields of the machine to
// data, loading reads them from data into the machine. The same code walks
// the fields both ways, so the two can't disagree on the layout.
typedef struct snapshot_stream {
	bool load;
	uint8_t* data;
	size_t size; // bytes written, or in the file
	size_t capacity;
	size_t position; // loading: bytes read
	bool failed; // loading: read past the end, or a tag didn't match
} snapshot_stream_t;

static uint64_t snapshot_hash(const uint8_t* data, const size_t size) {
	uint64_t hash = SNAPSHOT_FNV_OFFSET;
	for (size_t i = 0; i < size; i++) {
		hash ^= data[i];
		hash *= SNAPSHOT_FNV_PRIME;
	}
	return hash;
}

static void snap_bytes(snapshot_stream_t* s, void* bytes, const size_t size) {
	if (s->load) {
		if (s->failed || size > s->size - s->position) {
			s->failed = true;
			memset(bytes, 0, size);
			return;
		}
		memcpy(bytes, s->data + s->position, size);
		s->position += size;
		return;
	}
	if (s->size + size > s->capacity) {
		size_t capacity = s->capacity ? s->capacity : 1 << 20;
		while (s->size + size > capacity) capacity *= 2;
		uint8_t* data = realloc(s->data, capacity);
		if (!data) error("Failed to allocate the snapshot!");
		s->data = data;
		s->capacity = capacity;
	}
	memcpy(s->data + s->size, bytes, size);
	s->size += size;
}

static void snap_u64(snapshot_stream_t* s, uint64_t* value) {
	uint8_t b[8];
	for (int i = 0; i < 8 && !s->load; i++) b[i] = (uint8_t)(*value >> (8 * i));
	snap_bytes(s, b, sizeof(b));
	if (!s->load) return;
	*value = 0;
	for (int i = 0; i < 8; i++) *value |= (uint64_t)b[i] << (8 * i);
}

static void snap_u32(snapshot_stream_t* s, uint32_t* value) {
	uint64_t wide = *value;
	snap_u64(s, &wide);
	*value = (uint32_t)wide;
}

static void snap_u8(snapshot_stream_t* s, uint8_t* value) {
	snap_bytes(s, value, 1);
}

static void snap_bool(snapshot_stream_t* s, bool* value) {
	uint8_t byte = *value ? 1 : 0;
	snap_u8(s, &byte);
	*value = byte != 0;
}

static void snap_i32(snapshot_stream_t* s, int32_t* value) {
	uint32_t bits = (uint32_t)*value;
	snap_u32(s, &bits);
	*value = (int32_t)bits;
}

static void snap_u32s(snapshot_stream_t* s, uint32_t* values,
					  const size_t count) {
	for (size_t i = 0; i < count; i++) snap_u32(s, &values[i]);
}

static void snap_tag(snapshot_stream_t* s, const char* tag) {
	char bytes[4];
	memcpy(bytes, tag, 4);
	snap_bytes(s, bytes, 4);
	if (s->load && memcmp(bytes, tag, 4) != 0) s->failed = true;
}

// ---- the CPU ----------------------------------------------------------------

static void snap_latch(snapshot_stream_t* s, cpu_latch_t* latch,
					   const bool decoded) {
	snap_bool(s, &latch->valid);
	snap_u32(s, &latch->pc);
	snap_u32(s, &latch->in.raw);
	snap_u32(s, &latch->a);
	snap_u32(s, &latch->b);
	snap_u32(s, &latch->d);
	snap_u32(s, &latch->result);
	snap_u8(s, &latch->fault);
	snap_u32(s, &latch->fault_value);
	snap_u8(s, &latch->fflags);
	// decoding is a function of the word; IF/ID only has the word
	if (s->load) {
		const uint32_t raw = latch->in.raw;
		latch->in = decoded ? cpu_decode(raw) : (cpu_instruction_t){ .raw = raw };
	}
}

static void snap_mmu(snapshot_stream_t* s, mmu_t* mmu) {
	snap_tag(s, "MMU ");
	snap_u32(s, &mmu->ptbr);
	for (int i = 0; i < MMU_TLB_SIZE; i++) {
		mmu_tlb_entry_t* entry = &mmu->tlb[i];
		snap_bool(s, &entry->valid);
		snap_u32(s, &entry->vpn);
		snap_u32(s, &entry->ppn);
		snap_u8(s, &entry->flags);
		snap_u8(s, &entry->asid);
		snap_bool(s, &entry->global);
		snap_u32(s, &entry->pte_address);
	}
	snap_u8(s, &mmu->next_victim);
	if (s->load)
		for (int i = 0; i < MMU_LOOKUP_SIZE; i++)
			mmu->lookup[i].index = MMU_LOOKUP_NONE;
}

static void snap_cpu(snapshot_stream_t* s, cpu_t* cpu) {
	snap_tag(s, "CPU ");
	snap_u32s(s, cpu->gpr, CPU_GPR_COUNT);
	snap_u32(s, &cpu->pc);
	snap_u32s(s, cpu->cr, CPU_CR_COUNT);
	snap_bool(s, &cpu->halted);
	snap_u8(s, &cpu->halt_fault);
	snap_bool(s, &cpu->waiting);
	snap_bool(s, &cpu->irq);
	snap_u64(s, &cpu->cycles);
	snap_u64(s, &cpu->retired);
	snap_bool(s, &cpu->reservation_valid);
	snap_u32(s, &cpu->reservation_address);
	snap_latch(s, &cpu->pipeline.if_id, false);
	snap_latch(s, &cpu->pipeline.id_ex, true);
	snap_latch(s, &cpu->pipeline.ex_mem, true);
	snap_latch(s, &cpu->pipeline.mem_wb, true);
	snap_mmu(s, cpu->mmu);
	if (!s->load) return;
	cpu->trigger_kinds = 0;
	for (int i = 0; i < CPU_TRIGGER_COUNT; i++)
		cpu->trigger_kinds |= cpu->cr[CPU_CR_TCTRL0 + 2 * i]
							& (CPU_TCTRL_X | CPU_TCTRL_R | CPU_TCTRL_W);
	cpu->debug.skip = false;
	cpu->debug.watch_hit = false;
}

// ---- devices ------------------------------------------------------------------

// The modification time of the file at path, 0 if unknown.
static uint64_t snapshot_mtime(const char* path) {
	struct stat info;
	if (!path || stat(path, &info) != 0) return 0;
	return (uint64_t)info.st_mtime;
}

// The image in the drive, by reference. Loading checks that it is still
// the same one; the floppy drive gets back the disk it had.
static void snap_disk_image(snapshot_stream_t* s, disk_t* disk,
							const char* name) {
	uint32_t length = disk->path ? (uint32_t)strlen(disk->path) : 0;
	snap_u32(s, &length);
	if (length > 4096) {
		s->failed = true;
		return;
	}
	char* path = malloc(length + 1);
	if (!path) error("Failed to allocate the snapshot!");
	if (!s->load && length) memcpy(path, disk->path, length);
	snap_bytes(s, path, length);
	path[length] = '\0';
	uint32_t sectors = disk->sectors;
	uint64_t mtime = snapshot_mtime(disk->path);
	snap_u32(s, &sectors);
	snap_u64(s, &mtime);
	if (!s->load || s->failed) {
		free(path);
		return;
	}

	const bool had = length > 0;
	const bool same = had == (disk->path != NULL)
				   && (!had || strcmp(path, disk->path) == 0);
	if (!same && disk->removable) {
		if (had && !disk_insert(disk, path))
			warning("Snapshot: the %s's disk %s can't be inserted", name, path);
		else if (!had)
			disk_eject(disk);
	} else if (!same) {
		warning("Snapshot: %s had %s, now it has %s",
				name,
				had ? path : "no disk",
				disk->path ? disk->path : "no disk");
	}
	if (had && disk->path && strcmp(path, disk->path) == 0
		&& (disk->sectors != sectors || snapshot_mtime(disk->path) != mtime))
		warning("Snapshot: the %s's disk %s has changed since it was saved",
				name,
				path);
	free(path);
}

static void snap_disk(snapshot_stream_t* s, disk_t* disk, const char* name) {
	snap_tag(s, "DISK");
	snap_disk_image(s, disk, name);
	snap_bool(s, &disk->changed);
	snap_u32(s, &disk->sector);
	snap_u32(s, &disk->count);
	snap_u32(s, &disk->address);
	snap_u32(s, &disk->error);
	snap_u32(s, &disk->list);
	snap_u32(s, &disk->command);
	snap_bool(s, &disk->busy);
	snap_bool(s, &disk->done);
	snap_bytes(s, disk->buffer, sizeof(disk->buffer));
	snap_u32(s, &disk->position);
	snap_u32(s, &disk->wait);
	snap_u32(s, &disk->left);
	if (!s->load) return;
	// a transfer to a disk that isn't there any more
	if (!disk->file && disk->busy) {
		disk->busy = false;
		disk->done = true;
		disk->error = DISK_ERROR_NO_DISK;
	}
	pic_set_line(disk->pic, disk->irq, disk->done || disk->changed);
}

static void snap_pic(snapshot_stream_t* s, pic_t* pic) {
	snap_tag(s, "PIC ");
	snap_u32(s, &pic->lines);
	snap_u32(s, &pic->enable);
}

static void snap_keyboard(snapshot_stream_t* s, keyboard_t* kbd) {
	snap_tag(s, "KBD ");
	snap_u32s(s, kbd->fifo, KEYBOARD_FIFO_SIZE);
	snap_u8(s, &kbd->head);
	snap_u8(s, &kbd->count);
	snap_bool(s, &kbd->overflow);
	if (kbd->head >= KEYBOARD_FIFO_SIZE || kbd->count > KEYBOARD_FIFO_SIZE)
		s->failed = true;
}

static void snap_uart(snapshot_stream_t* s, uart_t* uart) {
	snap_tag(s, "UART");
	snap_bytes(s, uart->rx_fifo, UART_RX_FIFO_SIZE);
	snap_u8(s, &uart->rx_head);
	snap_u8(s, &uart->rx_count);
	snap_bool(s, &uart->rx_overflow);
	if (uart->rx_head >= UART_RX_FIFO_SIZE || uart->rx_count > UART_RX_FIFO_SIZE)
		s->failed = true;
}

static void snap_pit(snapshot_stream_t* s, pit_t* pit) {
	snap_tag(s, "PIT ");
	snap_u64(s, &pit->count);
	snap_u32(s, &pit->reload);
	snap_u32(s, &pit->value);
	snap_u32(s, &pit->control);
	snap_bool(s, &pit->expired);
}

static void snap_power(snapshot_stream_t* s, power_t* power) {
	snap_tag(s, "PWR ");
	uint32_t request = power->request;
	uint32_t cause = power->reset_cause;
	snap_u32(s, &request);
	snap_u8(s, &power->exit_code);
	snap_u32(s, &power->status);
	snap_u32(s, &cause);
	power->request = (power_request_t)request;
	power->reset_cause = (power_reset_cause_t)cause;
}

static void snap_video(snapshot_stream_t* s, videocard_t* v) {
	snap_tag(s, "VID ");
	snap_u32(s, &v->control);
	snap_u32(s, &v->mode);
	snap_u32(s, &v->start);
	snap_u32(s, &v->frame);
	snap_u32s(s, v->palette, VIDEO_PALETTE_SIZE);
	snap_u8(s, &v->palette_index);
	snap_bool(s, &v->vblank);
	snap_u32(s, &v->ticks);
	snap_u32(s, &v->dst_base);
	snap_u32(s, &v->dst_pitch);
	snap_u32(s, &v->dst_xy);
	snap_u32(s, &v->src_base);
	snap_u32(s, &v->src_pitch);
	snap_u32(s, &v->src_xy);
	snap_u32(s, &v->size);
	snap_u32(s, &v->fg);
	snap_u32(s, &v->bg);
	snap_u32(s, &v->address);
	snap_u32(s, &v->count);
	snap_u32(s, &v->error);
	snap_u32(s, &v->command);
	snap_bool(s, &v->busy);
	snap_bool(s, &v->done);
	snap_u32(s, &v->line);
	snap_u32(s, &v->line_bpp);
	snap_u64(s, &v->line_address);
	snap_u32(s, &v->line_bytes);
	snap_u32(s, &v->line_fetched);
	snap_u32(s, &v->line_bit);
	snap_bytes(s, v->line_buffer, sizeof(v->line_buffer));
	snap_u32(s, &v->cursor_control);
	snap_u32(s, &v->cursor_base);
	snap_u32(s, &v->cursor_xy);
	snap_u32(s, &v->cursor_hot);
	snap_bytes(s, v->vram, VIDEO_VRAM_SIZE);
	if (v->ticks >= v->ticks_per_frame || v->line_bytes > sizeof(v->line_buffer)
		|| v->line_fetched > v->line_bytes)
		s->failed = true;
}

static void snap_beeper(snapshot_stream_t* s, beeper_t* beeper) {
	snap_tag(s, "BEEP");
	snap_u32(s, &beeper->control);
	snap_u32(s, &beeper->frequency);
	snap_u32(s, &beeper->duration);
	snap_u32(s, &beeper->phase);
	snap_u32(s, &beeper->step);
}

static void snap_mouse(snapshot_stream_t* s, mouse_t* mouse) {
	snap_tag(s, "MOUS");
	snap_bool(s, &mouse->enabled);
	snap_bool(s, &mouse->absolute);
	snap_u32(s, &mouse->buttons);
	snap_u32(s, &mouse->position);
	snap_u32s(s, mouse->fifo, MOUSE_FIFO_SIZE);
	snap_u32s(s, mouse->fifo_position, MOUSE_FIFO_SIZE);
	snap_u32(s, &mouse->popped_position);
	snap_u8(s, &mouse->head);
	snap_u8(s, &mouse->count);
	snap_bool(s, &mouse->overflow);
	snap_bool(s, &mouse->tail_motion);
	if (mouse->head >= MOUSE_FIFO_SIZE || mouse->count > MOUSE_FIFO_SIZE)
		s->failed = true;
}

static void snap_audio(snapshot_stream_t* s, audiocard_t* card) {
	snap_tag(s, "AUD ");
	snap_u32(s, &card->status);
	snap_u32(s, &card->fault);
	snap_u32(s, &card->master);
	for (int n = 0; n < AUDIO_VOICE_COUNT; n++) {
		audio_voice_t* voice = &card->voice[n];
		snap_u32(s, &voice->control);
		snap_u32(s, &voice->address);
		snap_u32(s, &voice->length);
		snap_u32(s, &voice->loop);
		snap_u32(s, &voice->rate);
		snap_u32(s, &voice->volume);
		snap_u64(s, &voice->position);
		snap_u64(s, &voice->step);
	}
	snap_u64(s, &card->sample_clock);
	if (card->sample_clock >= card->clock_rate) s->failed = true;
}

static void snap_rtc(snapshot_stream_t* s, rtc_t* rtc) {
	snap_tag(s, "RTC ");
	snap_u32(s, &rtc->ticks);
	snap_u64(s, &rtc->seconds);
	snap_u32(s, &rtc->nanoseconds);
	snap_i32(s, &rtc->utc_offset);
	snap_u64(s, &rtc->alarm);
	snap_u32(s, &rtc->control);
	snap_bool(s, &rtc->fired);
	if (rtc->ticks >= rtc->period) s->failed = true;
}

// The host's random bits are never given out twice: a loaded machine
// takes new ones. A seeded generator goes on with its stream.
static void snap_rng(snapshot_stream_t* s, rng_t* rng) {
	snap_tag(s, "RNG ");
	snap_u64(s, &rng->counter);
	snap_u32s(s, rng->pool, RNG_POOL_WORDS);
	snap_u32(s, &rng->used);
	if (rng->used > RNG_POOL_WORDS) s->failed = true;
	if (s->load && !rng->seeded) rng_drop_pool(rng);
}

// The host's files can't be saved: a loaded machine has every handle
// closed, as if the host had closed them.
static void snap_share(snapshot_stream_t* s, share_t* share) {
	snap_tag(s, "SHR ");
	if (s->load) share_close_handles(share);
	snap_u32(s, &share->error);
	snap_u32(s, &share->current);
	snap_u32(s, &share->path);
	snap_u32(s, &share->path2);
	snap_u32(s, &share->address);
	snap_u32(s, &share->count);
	snap_u64(s, &share->position);
	snap_u32(s, &share->flags);
	snap_u32(s, &share->result);
}

// The connections of the network behind the card can't be saved: a loaded
// machine finds them gone, as after the network went down a while.
static void snap_ethcard(snapshot_stream_t* s, ethcard_t* eth) {
	snap_tag(s, "ETH ");
	snap_u32(s, &eth->control);
	snap_u32(s, &eth->pending);
	snap_u32(s, &eth->rx_ring);
	snap_u32(s, &eth->rx_size);
	snap_u32(s, &eth->rx_next);
	snap_u32(s, &eth->tx_ring);
	snap_u32(s, &eth->tx_size);
	snap_u32(s, &eth->tx_next);
	if (eth->rx_size > ETH_RING_MAX || eth->tx_size > ETH_RING_MAX)
		s->failed = true;
	if (s->load && !s->failed) ethcard_disconnect(eth);
}

static void snap_watchdog(snapshot_stream_t* s, watchdog_t* watchdog) {
	snap_tag(s, "WDOG");
	snap_u32(s, &watchdog->control);
	snap_u32(s, &watchdog->timeout);
	snap_u32(s, &watchdog->grace);
	snap_u32(s, &watchdog->value);
	snap_bool(s, &watchdog->barked);
	snap_bool(s, &watchdog->bark);
	snap_bool(s, &watchdog->bitten);
}

// ---- the machine --------------------------------------------------------------

// What the machine is made of: a snapshot only loads into the same.
static void snap_header(snapshot_stream_t* s, const motherboard_t* mb) {
	char magic[sizeof(snapshot_magic)];
	memcpy(magic, snapshot_magic, sizeof(magic));
	snap_bytes(s, magic, sizeof(magic));
	if (memcmp(magic, snapshot_magic, sizeof(magic)) != 0) {
		warning("Snapshot: not a snapshot");
		s->failed = true;
		return;
	}
	uint32_t version = SNAPSHOT_VERSION;
	snap_u32(s, &version);
	if (version != SNAPSHOT_VERSION) {
		warning("Snapshot: version %u, this emulator reads %u",
				(unsigned)version,
				SNAPSHOT_VERSION);
		s->failed = true;
		return;
	}

	uint64_t rate = mb->clock->rate;
	snap_u64(s, &rate);
	if (rate != mb->clock->rate) {
		warning("Snapshot: saved at %llu Hz, this machine runs at %llu Hz",
				(unsigned long long)rate,
				(unsigned long long)mb->clock->rate);
		s->failed = true;
	}
	for (int i = 0; i < RAM_SLOT_COUNT; i++) {
		const ram_slot_t* slot = &mb->ram_slot[i];
		uint64_t size = slot->installed ? slot->ram->size : 0;
		snap_u64(s, &size);
		if (size != (slot->installed ? slot->ram->size : 0)) {
			warning("Snapshot: RAM slot %d had %llu bytes, now %llu",
					i,
					(unsigned long long)size,
					(unsigned long long)(slot->installed ? slot->ram->size
														 : 0));
			s->failed = true;
		}
	}
	const uint64_t rom = snapshot_hash(mb->rom->data, mb->rom->size);
	uint64_t saved = rom;
	snap_u64(s, &saved);
	if (saved != rom) {
		warning("Snapshot: it was saved with another ROM");
		s->failed = true;
	}
}

static void snap_machine(snapshot_stream_t* s, machine_t* machine) {
	motherboard_t* mb = machine->motherboard;
	snap_header(s, mb);
	if (s->failed) return;

	snap_tag(s, "TIME");
	snap_u64(s, &machine->ticks);
	snap_u64(s, &mb->tick);
	snap_cpu(s, mb->cpu);
	snap_tag(s, "RAM ");
	for (int i = 0; i < RAM_SLOT_COUNT; i++)
		if (mb->ram_slot[i].installed)
			snap_bytes(s, mb->ram_slot[i].ram->data, mb->ram_slot[i].ram->size);
	snap_pic(s, mb->pic);
	snap_keyboard(s, mb->keyboard);
	snap_uart(s, mb->uart);
	snap_pit(s, mb->pit);
	snap_power(s, mb->power);
	char name[8];
	for (int i = 0; i < DISK_COUNT; i++) {
		snprintf(name, sizeof(name), "disk %d", i);
		snap_disk(s, mb->disk[i], name);
	}
	snap_video(s, mb->videocard);
	snap_disk(s, mb->floppy, "floppy");
	snap_beeper(s, mb->beeper);
	snap_mouse(s, mb->mouse);
	snap_ethcard(s, mb->ethcard);
	snap_audio(s, mb->audiocard);
	snap_rtc(s, mb->rtc);
	snap_rng(s, mb->rng);
	snap_share(s, mb->share);
	snap_watchdog(s, mb->watchdog);
	snap_tag(s, "END ");
}

bool snapshot_save(const machine_t* machine, const char* path) {
	// saving only reads the machine
	snapshot_stream_t s = { .load = false };
	snap_machine(&s, (machine_t*)machine);
	uint64_t checksum = snapshot_hash(s.data, s.size);
	snap_u64(&s, &checksum);

	FILE* file = fopen(path, "wb");
	bool saved = file && fwrite(s.data, 1, s.size, file) == s.size;
	if (file && fclose(file) != 0) saved = false;
	if (!saved) warning("Failed to save the snapshot %s", path);
	free(s.data);
	return saved;
}

// Reads the whole file; NULL (with a warning) if it can't.
static uint8_t* snapshot_read_file(const char* path, size_t* size) {
	FILE* file = fopen(path, "rb");
	if (!file) {
		warning("Failed to open the snapshot %s", path);
		return NULL;
	}
	uint8_t* data = NULL;
	size_t length = 0;
	size_t capacity = 0;
	while (true) {
		if (length == capacity) {
			capacity = capacity ? capacity * 2 : 1 << 20;
			uint8_t* grown = realloc(data, capacity);
			if (!grown) error("Failed to allocate the snapshot!");
			data = grown;
		}
		const size_t got = fread(data + length, 1, capacity - length, file);
		length += got;
		if (got == 0) break;
	}
	const bool failed = ferror(file) != 0;
	fclose(file);
	if (failed) {
		warning("Failed to read the snapshot %s", path);
		free(data);
		return NULL;
	}
	*size = length;
	return data;
}

bool snapshot_load(machine_t* machine, const char* path) {
	size_t size = 0;
	uint8_t* data = snapshot_read_file(path, &size);
	if (!data) return false;

	// the checksum first: a file that is cut short or damaged is never
	// half loaded
	bool ok = size >= sizeof(snapshot_magic) + 8;
	if (ok) {
		uint64_t checksum = 0;
		for (int i = 0; i < 8; i++)
			checksum |= (uint64_t)data[size - 8 + i] << (8 * i);
		ok = checksum == snapshot_hash(data, size - 8);
	}
	snapshot_stream_t s = { .load = true, .data = data, .size = size - 8 };
	if (!ok) {
		warning("Snapshot %s: not a snapshot, or damaged", path);
		free(data);
		return false;
	}

	// what the machine is made of has to match before anything changes
	snap_header(&s, machine->motherboard);
	if (s.failed) {
		warning("Snapshot %s can't be loaded into this machine", path);
		free(data);
		return false;
	}
	s.position = 0;
	snap_machine(&s, machine);
	free(data);
	motherboard_t* mb = machine->motherboard;
	for (int i = 0; i < MB_TIMED_COUNT; i++) mb->synced[i] = mb->tick;
	if (s.failed || s.position != s.size) {
		// the same version, yet another layout: half of it is loaded
		warning("Snapshot %s doesn't match this build of the emulator: the "
				"machine is reset",
				path);
		motherboard_reset(mb, POWER_RESET_CAUSE_POWER_ON);
		return false;
	}

	// the emulator's side of it
	clock_reset(mb->clock);
	input_seek(machine->input, machine->ticks);
	machine->next_poll =
		(machine->ticks / machine->net_period + 1) * machine->net_period;
	print("Loaded the snapshot %s", path);
	return true;
}
