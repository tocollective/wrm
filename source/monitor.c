#include "monitor.h"

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "disasm.h"
#include "snapshot.h"
#include "version.h"

#define MONITOR_ADDRESS 0x7F000001 // 127.0.0.1: only this host
#define MONITOR_MAX_WORDS 1024 // most words x and dis show at once
#define MONITOR_PROMPT "> "

static const char* const monitor_help =
	"c, cont               go on\n"
	"p, pause              stop before the next instruction\n"
	"s, step [N]           run N instructions (1) and stop\n"
	"r, regs               registers\n"
	"x ADDR [N]            N words (16) at a virtual address\n"
	"xp ADDR [N]           ... at a physical address\n"
	"w ADDR VALUE          write a word at a virtual address\n"
	"wp ADDR VALUE         ... at a physical address\n"
	"d, dis [ADDR] [N]     disassemble N instructions (8) at ADDR (pc)\n"
	"b, break ADDR         stop before the instruction at ADDR\n"
	"watch ADDR [LEN] [r|w|rw]\n"
	"                      stop after an access to LEN bytes (4) at ADDR,\n"
	"                      by default a write\n"
	"del ADDR|all          remove the breakpoints and watchpoints at ADDR\n"
	"list                  list them\n"
	"info                  the devices\n"
	"reset                 reset the machine\n"
	"save PATH             save a snapshot of the machine\n"
	"load PATH             load one\n"
	"quit                  disconnect, the machine runs on\n"
	"Addresses are virtual (as the CPU sees them now) unless said, numbers\n"
	"are decimal or 0x hex; 'pc' is the address of the next instruction.\n"
	"Breakpoints and watchpoints are the emulator's: software doesn't see\n"
	"them, and they work in ROM.\n";

// ---- output -------------------------------------------------------------------

static void monitor_printf(monitor_t* monitor, const char* format, ...) {
	if (monitor->client == NETWORK_NO_SOCKET) return;
	char text[512];
	va_list args;
	va_start(args, format);
	const int length = vsnprintf(text, sizeof(text), format, args);
	va_end(args);
	if (length <= 0) return;
	const size_t size = (size_t)length < sizeof(text) ? (size_t)length
													   : sizeof(text) - 1;
	if (monitor->out_size + size > monitor->out_capacity) {
		size_t capacity = monitor->out_capacity ? monitor->out_capacity : 4096;
		while (monitor->out_size + size > capacity) capacity *= 2;
		char* out = realloc(monitor->out, capacity);
		if (!out) error("Failed to allocate the monitor's output!");
		monitor->out = out;
		monitor->out_capacity = capacity;
	}
	memcpy(monitor->out + monitor->out_size, text, size);
	monitor->out_size += size;
}

static void monitor_disconnect(monitor_t* monitor) {
	if (monitor->client == NETWORK_NO_SOCKET) return;
	network_close(monitor->client);
	monitor->client = NETWORK_NO_SOCKET;
	monitor->out_size = 0;
	monitor->line_length = 0;
	monitor->line_overflow = false;
	print("Monitor: the client left");
}

// Sends what the client's socket takes now; the rest waits.
static void monitor_flush(monitor_t* monitor) {
	if (monitor->client == NETWORK_NO_SOCKET || monitor->out_size == 0) return;
	const long sent =
		network_send(monitor->client, monitor->out, monitor->out_size);
	if (sent == NETWORK_WOULD_BLOCK) return;
	if (sent < 0) {
		monitor_disconnect(monitor);
		return;
	}
	monitor->out_size -= (size_t)sent;
	memmove(monitor->out, monitor->out + sent, monitor->out_size);
}

// ---- the machine ----------------------------------------------------------------

static cpu_t* monitor_cpu(const monitor_t* monitor) {
	return monitor->machine->motherboard->cpu;
}

static const char* monitor_stop_name(const cpu_stop_t stop) {
	switch (stop) {
		case CPU_STOP_NONE:
			return "running";
		case CPU_STOP_PAUSE:
			return "paused";
		case CPU_STOP_STEP:
			return "stepped";
		case CPU_STOP_BREAKPOINT:
			return "breakpoint";
		case CPU_STOP_WATCHPOINT:
			return "watchpoint";
	}
	return "stopped";
}

// What the machine is doing, in a few words.
static const char* monitor_state(const monitor_t* monitor) {
	const cpu_t* cpu = monitor_cpu(monitor);
	if (machine_powered_off(monitor->machine)) return "powered off";
	if (cpu->halted) return cpu->halt_fault ? "halted by a fault" : "halted";
	if (cpu->debug.stopped) return monitor_stop_name(cpu->debug.stopped);
	if (cpu->waiting) return "running, in WFI";
	return "running";
}

// Reads a word of RAM or ROM; false if there is none (the I/O region,
// which a read could change, is left alone).
static bool monitor_read_physical(const monitor_t* monitor,
								  const uint32_t address, uint32_t* value) {
	const cpu_t* cpu = monitor_cpu(monitor);
	return !cpu->bus.fetch(cpu->bus.ctx, address, 4, value);
}

static bool monitor_translate(const monitor_t* monitor, const uint32_t address,
							  const bool physical, uint32_t* out) {
	if (physical) {
		*out = address;
		return true;
	}
	return !mmu_peek(monitor_cpu(monitor)->mmu, address, out);
}

static void monitor_print_instruction(monitor_t* monitor, const uint32_t pc) {
	cpu_t* cpu = monitor_cpu(monitor);
	uint32_t physical = 0;
	uint32_t raw = 0;
	const bool current = pc == cpu->pc;
	bool breakpoint = false;
	for (int i = 0; i < cpu->debug.breakpoint_count; i++)
		if (cpu->debug.breakpoint[i] == pc) breakpoint = true;
	const char* mark = current ? (breakpoint ? "*>" : "=>")
							   : (breakpoint ? "* " : "  ");
	if (!monitor_translate(monitor, pc, false, &physical)
		|| !monitor_read_physical(monitor, physical, &raw)) {
		monitor_printf(monitor, "%s %08X  --------\n", mark, (unsigned)pc);
		return;
	}
	char text[DISASM_MAX_LENGTH];
	disasm_instruction(raw, pc, text, sizeof(text));
	monitor_printf(monitor,
				   "%s %08X  %08X  %s\n",
				   mark,
				   (unsigned)pc,
				   (unsigned)raw,
				   text);
}

// The client hears when the machine stops: at a breakpoint, after a step...
static void monitor_report_stop(monitor_t* monitor) {
	const cpu_t* cpu = monitor_cpu(monitor);
	const cpu_stop_t stop = cpu->debug.stopped;
	if (stop == monitor->reported) return;
	monitor->reported = stop;
	if (stop == CPU_STOP_NONE) return;

	if (stop == CPU_STOP_WATCHPOINT) {
		print("Monitor: watchpoint at 0x%08X, %s by 0x%08X",
			  (unsigned)cpu->debug.hit_address,
			  cpu->debug.hit_access == MMU_ACCESS_WRITE ? "written" : "read",
			  (unsigned)cpu->debug.hit_pc);
		monitor_printf(monitor,
					   "\nwatchpoint: 0x%08X %s by the instruction at 0x%08X\n",
					   (unsigned)cpu->debug.hit_address,
					   cpu->debug.hit_access == MMU_ACCESS_WRITE ? "written"
																 : "read",
					   (unsigned)cpu->debug.hit_pc);
	} else {
		if (stop == CPU_STOP_BREAKPOINT)
			print("Monitor: breakpoint at 0x%08X", (unsigned)cpu->pc);
		monitor_printf(monitor, "\n%s\n", monitor_stop_name(stop));
	}
	monitor_print_instruction(monitor, cpu->pc);
	monitor_printf(monitor, MONITOR_PROMPT);
}

// ---- parsing ------------------------------------------------------------------

// The next word of the command, NULL at its end.
static char* monitor_word(char** cursor) {
	char* p = *cursor;
	while (*p && isspace((unsigned char)*p)) p++;
	if (!*p) {
		*cursor = p;
		return NULL;
	}
	char* word = p;
	while (*p && !isspace((unsigned char)*p)) p++;
	if (*p) *p++ = '\0';
	*cursor = p;
	return word;
}

// A number, or 'pc'; false if word isn't one.
static bool monitor_number(const monitor_t* monitor, const char* word,
						   uint32_t* value) {
	if (!word) return false;
	if (strcmp(word, "pc") == 0) {
		*value = monitor_cpu(monitor)->pc;
		return true;
	}
	if (!isdigit((unsigned char)word[0])) return false;
	errno = 0;
	char* end = NULL;
	const unsigned long number = strtoul(word, &end, 0);
	if (errno || *end || number > UINT32_MAX) return false;
	*value = (uint32_t)number;
	return true;
}

// ---- commands -------------------------------------------------------------

static void monitor_resume(monitor_t* monitor, const uint64_t steps) {
	cpu_t* cpu = monitor_cpu(monitor);
	if (!cpu->debug.stopped) {
		monitor_printf(monitor, "the machine is running\n" MONITOR_PROMPT);
		return;
	}
	if (cpu->halted || machine_powered_off(monitor->machine)) {
		monitor_printf(monitor,
					   "the machine is %s: reset it first\n" MONITOR_PROMPT,
					   monitor_state(monitor));
		return;
	}
	cpu_debug_resume(cpu, steps);
	monitor->reported = CPU_STOP_NONE;
}

static void monitor_regs(monitor_t* monitor) {
	const cpu_t* cpu = monitor_cpu(monitor);
	monitor_printf(monitor, "%s", monitor_state(monitor));
	if (!cpu->debug.stopped && !cpu->halted)
		monitor_printf(monitor, " (registers as of now, with instructions in "
								"flight; pause first)");
	monitor_printf(monitor,
				   "\npc %08X  cycles %llu  retired %llu\n",
				   (unsigned)cpu->pc,
				   (unsigned long long)cpu->cycles,
				   (unsigned long long)cpu->retired);
	for (int i = 0; i < CPU_GPR_COUNT; i++)
		monitor_printf(monitor,
					   "r%-2d %08X%s",
					   i,
					   (unsigned)cpu->gpr[i],
					   i % 4 == 3 ? "\n" : "  ");
	static const char* const flags[] = { "IE", "PIE", "UM", "PUM",
										 "EXL", "SS", "PSS" };
	for (uint32_t cr = 0; cr < CPU_CR_COUNT; cr++) {
		if (cr >= CPU_CR_CYCLE && cr <= CPU_CR_INSTRETH) continue; // above
		uint32_t value = cpu->cr[cr];
		if (cr == CPU_CR_PTBR) value = cpu->mmu->ptbr;
		if (cr == CPU_CR_CPUID) value = CPU_CPUID;
		monitor_printf(
			monitor, "%-8s %08X", disasm_cr_name(cr), (unsigned)value);
		if (cr == CPU_CR_STATUS) {
			for (int bit = 0; bit < 7; bit++)
				if (value & (1u << bit)) monitor_printf(monitor, " %s", flags[bit]);
		} else if (cr == CPU_CR_CAUSE) {
			monitor_printf(monitor, " %s", cpu_cause_name((uint8_t)value));
		}
		monitor_printf(monitor, "\n");
	}
}

static void monitor_examine(monitor_t* monitor, char** cursor,
							const bool physical) {
	uint32_t address = 0;
	uint32_t count = 16;
	if (!monitor_number(monitor, monitor_word(cursor), &address)) {
		monitor_printf(monitor, "usage: x%s ADDR [N]\n", physical ? "p" : "");
		return;
	}
	const char* word = monitor_word(cursor);
	if (word && !monitor_number(monitor, word, &count)) {
		monitor_printf(monitor, "invalid count\n");
		return;
	}
	if (count > MONITOR_MAX_WORDS) count = MONITOR_MAX_WORDS;
	address &= ~3u;
	for (uint32_t i = 0; i < count; i++) {
		const uint32_t at = address + i * 4;
		if (i % 4 == 0) monitor_printf(monitor, "%08X ", (unsigned)at);
		uint32_t target = 0;
		uint32_t value = 0;
		if (monitor_translate(monitor, at, physical, &target)
			&& monitor_read_physical(monitor, target, &value))
			monitor_printf(monitor, " %08X", (unsigned)value);
		else
			monitor_printf(monitor, " --------");
		if (i % 4 == 3 || i + 1 == count) monitor_printf(monitor, "\n");
	}
}

static void monitor_write(monitor_t* monitor, char** cursor,
						  const bool physical) {
	uint32_t address = 0;
	uint32_t value = 0;
	if (!monitor_number(monitor, monitor_word(cursor), &address)
		|| !monitor_number(monitor, monitor_word(cursor), &value)
		|| (address & 3)) {
		monitor_printf(monitor,
					   "usage: w%s ADDR VALUE, ADDR a multiple of 4\n",
					   physical ? "p" : "");
		return;
	}
	uint32_t target = 0;
	if (!monitor_translate(monitor, address, physical, &target)) {
		monitor_printf(monitor, "0x%08X isn't mapped\n", (unsigned)address);
		return;
	}
	// RAM only: a device register would act on the write
	const cpu_t* cpu = monitor_cpu(monitor);
	uint32_t old = 0;
	if (target >= MB_IO_BASE
		|| !monitor_read_physical(monitor, target, &old)
		|| cpu->bus.write(cpu->bus.ctx, target, 4, value)) {
		monitor_printf(monitor, "no RAM at 0x%08X\n", (unsigned)target);
		return;
	}
	monitor_printf(monitor,
				   "%08X: %08X -> %08X\n",
				   (unsigned)address,
				   (unsigned)old,
				   (unsigned)value);
}

static void monitor_disassemble(monitor_t* monitor, char** cursor) {
	uint32_t address = monitor_cpu(monitor)->pc;
	uint32_t count = 8;
	const char* word = monitor_word(cursor);
	if (word && !monitor_number(monitor, word, &address)) {
		monitor_printf(monitor, "usage: dis [ADDR] [N]\n");
		return;
	}
	word = monitor_word(cursor);
	if (word && !monitor_number(monitor, word, &count)) {
		monitor_printf(monitor, "invalid count\n");
		return;
	}
	if (count > MONITOR_MAX_WORDS) count = MONITOR_MAX_WORDS;
	address &= ~3u;
	for (uint32_t i = 0; i < count; i++)
		monitor_print_instruction(monitor, address + i * 4);
}

static void monitor_break(monitor_t* monitor, char** cursor) {
	uint32_t address = 0;
	if (!monitor_number(monitor, monitor_word(cursor), &address)
		|| (address & 3)) {
		monitor_printf(monitor, "usage: break ADDR, a multiple of 4\n");
		return;
	}
	if (!cpu_debug_add_breakpoint(monitor_cpu(monitor), address))
		monitor_printf(monitor,
					   "at most %d breakpoints\n",
					   CPU_BREAKPOINT_COUNT);
	else
		monitor_printf(monitor, "breakpoint at %08X\n", (unsigned)address);
}

static void monitor_watch(monitor_t* monitor, char** cursor) {
	uint32_t address = 0;
	uint32_t length = 4;
	uint8_t access = MMU_ACCESS_WRITE;
	if (!monitor_number(monitor, monitor_word(cursor), &address)) {
		monitor_printf(monitor, "usage: watch ADDR [LEN] [r|w|rw]\n");
		return;
	}
	for (const char* word = monitor_word(cursor); word;
		 word = monitor_word(cursor)) {
		if (strcmp(word, "r") == 0)
			access = MMU_ACCESS_READ;
		else if (strcmp(word, "w") == 0)
			access = MMU_ACCESS_WRITE;
		else if (strcmp(word, "rw") == 0)
			access = MMU_ACCESS_READ | MMU_ACCESS_WRITE;
		else if (!monitor_number(monitor, word, &length) || length == 0) {
			monitor_printf(monitor, "usage: watch ADDR [LEN] [r|w|rw]\n");
			return;
		}
	}
	if (!cpu_debug_add_watchpoint(monitor_cpu(monitor), address, length, access))
		monitor_printf(monitor,
					   "at most %d watchpoints\n",
					   CPU_WATCHPOINT_COUNT);
	else
		monitor_printf(monitor,
					   "watchpoint at %08X, %u bytes\n",
					   (unsigned)address,
					   (unsigned)length);
}

static void monitor_delete(monitor_t* monitor, char** cursor) {
	const char* word = monitor_word(cursor);
	uint32_t address = 0;
	if (word && strcmp(word, "all") == 0) {
		cpu_debug_remove_all(monitor_cpu(monitor));
		monitor_printf(monitor, "all removed\n");
	} else if (monitor_number(monitor, word, &address)) {
		const int removed = cpu_debug_remove(monitor_cpu(monitor), address);
		monitor_printf(monitor, "%d removed\n", removed);
	} else {
		monitor_printf(monitor, "usage: del ADDR|all\n");
	}
}

static void monitor_list(monitor_t* monitor) {
	const cpu_debug_t* debug = &monitor_cpu(monitor)->debug;
	if (!debug->breakpoint_count && !debug->watchpoint_count)
		monitor_printf(monitor, "none\n");
	for (int i = 0; i < debug->breakpoint_count; i++)
		monitor_printf(monitor,
					   "break %08X\n",
					   (unsigned)debug->breakpoint[i]);
	for (int i = 0; i < debug->watchpoint_count; i++) {
		const cpu_watchpoint_t* watch = &debug->watchpoint[i];
		monitor_printf(monitor,
					   "watch %08X %u %s%s\n",
					   (unsigned)watch->address,
					   (unsigned)watch->length,
					   watch->access & MMU_ACCESS_READ ? "r" : "",
					   watch->access & MMU_ACCESS_WRITE ? "w" : "");
	}
}

static void monitor_print_disk(monitor_t* monitor, const char* name,
							   const disk_t* disk) {
	if (!disk->file) {
		monitor_printf(monitor, "%-7s empty\n", name);
		return;
	}
	monitor_printf(monitor,
				   "%-7s %u sectors%s%s, command %X sector %u count %u "
				   "address %08X list %08X error %u\n",
				   name,
				   (unsigned)disk->sectors,
				   disk->readonly ? " read-only" : "",
				   disk->busy ? " busy" : "",
				   (unsigned)disk->command,
				   (unsigned)disk->sector,
				   (unsigned)disk->count,
				   (unsigned)disk->address,
				   (unsigned)disk->list,
				   (unsigned)disk->error);
}

static void monitor_info(monitor_t* monitor) {
	const motherboard_t* mb = monitor->machine->motherboard;
	monitor_printf(monitor,
				   "machine tick %llu, %s\n",
				   (unsigned long long)mb->tick,
				   monitor_state(monitor));
	monitor_printf(monitor,
				   "pic     lines %08X enable %08X\n",
				   (unsigned)mb->pic->lines,
				   (unsigned)mb->pic->enable);
	monitor_printf(monitor,
				   "timer   count %llu reload %u value %u control %X%s\n",
				   (unsigned long long)mb->pit->count,
				   (unsigned)mb->pit->reload,
				   (unsigned)mb->pit->value,
				   (unsigned)mb->pit->control,
				   mb->pit->expired ? " expired" : "");
	monitor_printf(monitor,
				   "power   status %X reset cause %u\n",
				   (unsigned)mb->power->status,
				   (unsigned)mb->power->reset_cause);
	char name[8];
	for (int i = 0; i < DISK_COUNT; i++) {
		snprintf(name, sizeof(name), "disk%d", i);
		monitor_print_disk(monitor, name, mb->disk[i]);
	}
	monitor_print_disk(monitor, "floppy", mb->floppy);
	const videocard_t* video = mb->videocard;
	monitor_printf(monitor,
				   "video   mode %X control %X start %08X frame %u%s%s%s\n",
				   (unsigned)video->mode,
				   (unsigned)video->control,
				   (unsigned)video->start,
				   (unsigned)video->frame,
				   video->busy ? " busy" : "",
				   video->vblank ? " vblank" : "",
				   video->cursor_control ? " cursor" : "");
	monitor_printf(monitor,
				   "uart    rx %u bytes\n",
				   (unsigned)mb->uart->rx_count);
	monitor_printf(monitor,
				   "keys    %u events, mouse %s%s, %u events\n",
				   (unsigned)mb->keyboard->count,
				   mb->mouse->enabled ? "on" : "off",
				   mb->mouse->absolute ? " (absolute)" : "",
				   (unsigned)mb->mouse->count);
	const ethcard_t* eth = mb->ethcard;
	monitor_printf(monitor,
				   "eth     %s, control %X pending %X rx %u/%u tx %u/%u\n",
				   eth->link ? "link" : "no link",
				   (unsigned)eth->control,
				   (unsigned)eth->pending,
				   (unsigned)eth->rx_next,
				   (unsigned)eth->rx_size,
				   (unsigned)eth->tx_next,
				   (unsigned)eth->tx_size);
	monitor_printf(monitor,
				   "wdog    control %X value %u%s%s\n",
				   (unsigned)mb->watchdog->control,
				   (unsigned)mb->watchdog->value,
				   mb->watchdog->barked ? " grace" : "",
				   mb->watchdog->bark ? " bark" : "");
	monitor_printf(monitor,
				   "rtc     control %X alarm %llu%s\n",
				   (unsigned)mb->rtc->control,
				   (unsigned long long)mb->rtc->alarm,
				   mb->rtc->fired ? " fired" : "");
	if (mb->share->root)
		monitor_printf(monitor,
					   "share   %s%s, %d handles open, error %u\n",
					   mb->share->root,
					   mb->share->readonly ? " read-only" : "",
					   share_open_handles(mb->share),
					   (unsigned)mb->share->error);
	else
		monitor_printf(monitor, "share   none\n");
	if (mb->rng->seeded)
		monitor_printf(monitor,
					   "rng     seeded, block %llu\n",
					   (unsigned long long)mb->rng->counter);
	else
		monitor_printf(monitor, "rng     from the host\n");
}

static void monitor_snapshot(monitor_t* monitor, char** cursor,
							 const bool save) {
	// the rest of the line, so a path may have spaces
	char* path = *cursor;
	while (*path && isspace((unsigned char)*path)) path++;
	if (!*path) {
		monitor_printf(monitor, "usage: %s PATH\n", save ? "save" : "load");
		return;
	}
	if (save ? snapshot_save(monitor->machine, path)
			 : snapshot_load(monitor->machine, path))
		monitor_printf(monitor, "%s %s\n", save ? "saved" : "loaded", path);
	else
		monitor_printf(monitor, "failed, see the emulator's output\n");
	monitor->reported = monitor_cpu(monitor)->debug.stopped; // as loaded
}

static void monitor_command(monitor_t* monitor, char* line) {
	char* cursor = line;
	const char* command = monitor_word(&cursor);
	if (!command) {
		monitor_printf(monitor, MONITOR_PROMPT);
		return;
	}
	cpu_t* cpu = monitor_cpu(monitor);
	if (strcmp(command, "help") == 0 || strcmp(command, "h") == 0
		|| strcmp(command, "?") == 0) {
		monitor_printf(monitor, "%s", monitor_help);
	} else if (strcmp(command, "c") == 0 || strcmp(command, "cont") == 0) {
		monitor_resume(monitor, 0);
		return; // the prompt comes when it stops
	} else if (strcmp(command, "p") == 0 || strcmp(command, "pause") == 0
			   || strcmp(command, "stop") == 0) {
		if (cpu->debug.stopped) {
			monitor_printf(monitor, "%s\n", monitor_state(monitor));
		} else {
			cpu_debug_pause(cpu);
			return;
		}
	} else if (strcmp(command, "s") == 0 || strcmp(command, "step") == 0) {
		uint32_t steps = 1;
		const char* word = monitor_word(&cursor);
		if (word && (!monitor_number(monitor, word, &steps) || steps == 0)) {
			monitor_printf(monitor, "usage: step [N]\n");
		} else if (cpu->debug.stopped) {
			monitor_resume(monitor, steps);
			return;
		} else {
			monitor_printf(monitor, "the machine is running: pause first\n");
		}
	} else if (strcmp(command, "r") == 0 || strcmp(command, "regs") == 0) {
		monitor_regs(monitor);
	} else if (strcmp(command, "x") == 0) {
		monitor_examine(monitor, &cursor, false);
	} else if (strcmp(command, "xp") == 0) {
		monitor_examine(monitor, &cursor, true);
	} else if (strcmp(command, "w") == 0) {
		monitor_write(monitor, &cursor, false);
	} else if (strcmp(command, "wp") == 0) {
		monitor_write(monitor, &cursor, true);
	} else if (strcmp(command, "d") == 0 || strcmp(command, "dis") == 0) {
		monitor_disassemble(monitor, &cursor);
	} else if (strcmp(command, "b") == 0 || strcmp(command, "break") == 0) {
		monitor_break(monitor, &cursor);
	} else if (strcmp(command, "watch") == 0) {
		monitor_watch(monitor, &cursor);
	} else if (strcmp(command, "del") == 0 || strcmp(command, "delete") == 0) {
		monitor_delete(monitor, &cursor);
	} else if (strcmp(command, "list") == 0) {
		monitor_list(monitor);
	} else if (strcmp(command, "info") == 0) {
		monitor_info(monitor);
	} else if (strcmp(command, "reset") == 0) {
		machine_reset(monitor->machine);
		monitor_printf(monitor, "reset, %s\n", monitor_state(monitor));
	} else if (strcmp(command, "save") == 0) {
		monitor_snapshot(monitor, &cursor, true);
	} else if (strcmp(command, "load") == 0) {
		monitor_snapshot(monitor, &cursor, false);
	} else if (strcmp(command, "quit") == 0 || strcmp(command, "q") == 0) {
		monitor_printf(monitor, "bye\n");
		monitor_flush(monitor);
		monitor_disconnect(monitor);
		return;
	} else {
		monitor_printf(monitor, "unknown command '%s', see help\n", command);
	}
	monitor_printf(monitor, MONITOR_PROMPT);
}

// ---- the connection ---------------------------------------------------------

monitor_t* monitor_create(machine_t* machine, const uint16_t port) {
	if (!network_can_listen()) {
		warning("No monitor: the host can't listen for connections");
		return NULL;
	}
	if (!network_init()) return NULL;
	const network_socket_t server = network_listen(MONITOR_ADDRESS, port);
	if (server == NETWORK_NO_SOCKET) {
		warning("No monitor: can't listen on 127.0.0.1:%u", (unsigned)port);
		network_quit();
		return NULL;
	}
	monitor_t* monitor = calloc(1, sizeof(monitor_t));
	if (!monitor) error("Failed to allocate the monitor!");
	monitor->machine = machine;
	monitor->server = server;
	monitor->client = NETWORK_NO_SOCKET;
	print("Monitor on 127.0.0.1:%u", (unsigned)network_local_port(server));
	return monitor;
}

void monitor_destroy(monitor_t* monitor) {
	if (!monitor) return;
	monitor_flush(monitor);
	monitor_disconnect(monitor);
	network_close(monitor->server);
	network_quit();
	free(monitor->out);
	free(monitor);
}

static void monitor_accept(monitor_t* monitor) {
	uint32_t addr = 0;
	uint16_t port = 0;
	const network_socket_t client =
		network_accept(monitor->server, &addr, &port);
	if (client == NETWORK_NO_SOCKET) return;
	if (monitor->client != NETWORK_NO_SOCKET) { // one at a time
		static const char busy[] = "the monitor is busy\n";
		network_send(client, busy, sizeof(busy) - 1);
		network_close(client);
		return;
	}
	monitor->client = client;
	monitor->reported = monitor_cpu(monitor)->debug.stopped;
	print("Monitor: a client connected");
	monitor_printf(monitor,
				   "WRM.081632 %s monitor, 'help' lists the commands\n%s\n",
				   WRM_VERSION,
				   monitor_state(monitor));
	if (monitor_cpu(monitor)->debug.stopped)
		monitor_print_instruction(monitor, monitor_cpu(monitor)->pc);
	monitor_printf(monitor, MONITOR_PROMPT);
}

// Runs every whole line that has come in.
static void monitor_receive(monitor_t* monitor) {
	char buffer[512];
	while (monitor->client != NETWORK_NO_SOCKET) {
		const long got = network_receive(monitor->client, buffer, sizeof(buffer));
		if (got == NETWORK_WOULD_BLOCK) return;
		if (got < 0) {
			monitor_disconnect(monitor);
			return;
		}
		for (long i = 0; i < got && monitor->client != NETWORK_NO_SOCKET; i++) {
			const char c = buffer[i];
			if (c == '\r') continue;
			if (c != '\n') {
				if (monitor->line_length + 1 < MONITOR_LINE_SIZE)
					monitor->line[monitor->line_length++] = c;
				else
					monitor->line_overflow = true;
				continue;
			}
			monitor->line[monitor->line_length] = '\0';
			if (monitor->line_overflow)
				monitor_printf(monitor, "command too long\n" MONITOR_PROMPT);
			else
				monitor_command(monitor, monitor->line);
			monitor->line_length = 0;
			monitor->line_overflow = false;
		}
	}
}

void monitor_poll(monitor_t* monitor) {
	if (!monitor) return;
	monitor_accept(monitor);
	monitor_receive(monitor);
	monitor_report_stop(monitor);
	monitor_flush(monitor);
}
