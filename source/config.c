#include "config.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "version.h"

static config_t config = {
	.debug = false,
	.version = WRM_VERSION,
	.firm_path = "firmware.rom",
	.hdd_path = { NULL, NULL },
	.floppy_path = "floppy.img",
	.clock_rate = 48000000ULL, // 48 MHz
	.ram_size = { 1024 * 1024 }, // 1MB in slot 0
	.make_dump = false,
	.window_scale = 1,
	.step_mode = false,
	.headless = false,
	.trace_path = NULL,
};

config_t* config_get(void) {
	return &config;
}

static void config_usage(const char* program) {
	printf(
			"WRM.081632 %s\n"
			"usage: %s [options]\n"
			"  --rom PATH        firmware image (default: %s)\n"
			"  --ram SIZE[,...]  RAM per slot, up to %d slots: 1M, 2M, 4M, "
			"8M, 16M or 32M\n"
			"                    (default: 1M)\n"
			"  --clock HZ        clock rate, with an optional k, M or G "
			"suffix (default: 48M)\n"
			"  --hdd PATH        disk image for disk 0; a second --hdd "
			"attaches disk 1\n"
			"  --headless        no window; exit when the machine powers off "
			"or halts\n"
			"  --trace[=PATH]    log every retired instruction to PATH "
			"(default: stderr)\n"
			"  --debug           dump the CPU state when the machine stops or "
			"quits\n"
			"  -h, --help        show this help\n",
			config.version,
			program,
			config.firm_path,
			CONFIG_RAM_SLOT_COUNT);
}

// Parses a whole number with an optional k/K, m/M or g/G suffix, which
// multiplies it by unit, unit^2 or unit^3. Returns false if text isn't one.
static bool config_parse_number(const char* text, const uint64_t unit,
								uint64_t* value) {
	if (!isdigit((unsigned char)text[0])) return false;
	errno = 0;
	char* end = NULL;
	const unsigned long long number = strtoull(text, &end, 0);
	if (errno) return false;

	uint64_t scale = 1;
	switch (*end) {
		case 'k':
		case 'K':
			scale = unit;
			end++;
			break;
		case 'm':
		case 'M':
			scale = unit * unit;
			end++;
			break;
		case 'g':
		case 'G':
			scale = unit * unit * unit;
			end++;
			break;
	}
	if (*end || number > UINT64_MAX / scale) return false;
	*value = number * scale;
	return true;
}

// "4M" or "4M,1M,...": sizes of the slots from 0 up, the rest are empty.
// Whether a size is one a slot takes is up to the motherboard.
static void config_parse_ram(const char* text) {
	size_t sizes[CONFIG_RAM_SLOT_COUNT] = { 0 };
	const char* item = text;
	for (int slot = 0;; slot++) {
		if (slot == CONFIG_RAM_SLOT_COUNT)
			error("--ram: at most %d slots", CONFIG_RAM_SLOT_COUNT);

		const char* comma = strchr(item, ',');
		const size_t length = comma ? (size_t)(comma - item) : strlen(item);
		char buffer[32];
		uint64_t size = 0;
		if (length >= sizeof(buffer)) error("--ram: invalid size in %s", text);
		memcpy(buffer, item, length);
		buffer[length] = '\0';
		if (!config_parse_number(buffer, 1024, &size) || size > SIZE_MAX)
			error("--ram: invalid size '%s'", buffer);
		sizes[slot] = (size_t)size;

		if (!comma) break;
		item = comma + 1;
	}
	memcpy(config.ram_size, sizes, sizeof(sizes));
}

// Each --hdd attaches the next free disk.
static void config_parse_hdd(const char* path) {
	for (int i = 0; i < CONFIG_HDD_COUNT; i++) {
		if (config.hdd_path[i]) continue;
		config.hdd_path[i] = path;
		return;
	}
	error("--hdd: at most %d disks", CONFIG_HDD_COUNT);
}

static void config_parse_clock(const char* text) {
	uint64_t rate = 0;
	if (!config_parse_number(text, 1000, &rate) || rate == 0
		|| rate > UINT32_MAX)
		error("--clock: invalid rate '%s'", text);
	config.clock_rate = rate;
}

// value of an option that takes one: the next argument
static const char* config_value(int argc, char* argv[], int* i) {
	if (*i + 1 >= argc) error("%s needs a value (see --help)", argv[*i]);
	return argv[++*i];
}

void config_parse(int argc, char* argv[]) {
	const char* program = argc > 0 && argv[0] ? argv[0] : "wrm081632";
	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];
		if (strcmp(arg, "--headless") == 0) {
			config.headless = true;
		} else if (strcmp(arg, "--rom") == 0) {
			config.firm_path = config_value(argc, argv, &i);
		} else if (strcmp(arg, "--ram") == 0) {
			config_parse_ram(config_value(argc, argv, &i));
		} else if (strcmp(arg, "--clock") == 0) {
			config_parse_clock(config_value(argc, argv, &i));
		} else if (strcmp(arg, "--hdd") == 0) {
			config_parse_hdd(config_value(argc, argv, &i));
		} else if (strcmp(arg, "--trace") == 0) {
			config.trace_path = "-";
		} else if (strncmp(arg, "--trace=", 8) == 0 && arg[8]) {
			config.trace_path = arg + 8;
		} else if (strcmp(arg, "--debug") == 0) {
			config.debug = true;
		} else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			config_usage(program);
			exit(0);
		} else {
			error("Unknown option: %s (see --help)", arg);
		}
	}
}
