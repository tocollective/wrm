#include "config.h"

#include <stdio.h>
#include <string.h>

#include "version.h"

static config_t config = {
	.debug = false,
	.version = WRM_VERSION,
	.firm_path = "firmware.rom",
	.hdd_path = { "hdd0.img", NULL },
	.floppy_path = "floppy.img",
	.clock_rate = 48000000ULL, // 48 MHz
	.make_dump = false,
	.window_scale = 1,
	.step_mode = false,
	.headless = false,
};

config_t* config_get(void) {
	return &config;
}

static void config_usage(const char* program) {
	printf(
			"WRM.081632 %s\n"
			"usage: %s [options]\n"
			"  --rom PATH    firmware image (default: %s)\n"
			"  --headless    no window; exit when the machine powers off or "
			"halts\n"
			"  -h, --help    show this help\n",
			config.version,
			program,
			config.firm_path);
}

void config_parse(int argc, char* argv[]) {
	const char* program = argc > 0 && argv[0] ? argv[0] : "wrm081632";
	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];
		if (strcmp(arg, "--headless") == 0) {
			config.headless = true;
		} else if (strcmp(arg, "--rom") == 0) {
			if (i + 1 >= argc) error("--rom needs a path");
			config.firm_path = argv[++i];
		} else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			config_usage(program);
			exit(0);
		} else {
			error("Unknown option: %s (see --help)", arg);
		}
	}
}
