#include "config.h"

#include "version.h"

static config_t config = {
	.debug = false,
	.version = WRM_VERSION,
	.firm_path = "firmware.rom",
	.hdd_path = { "hdd0.img", NULL },
	.floppy_path = "floppy.img",
	.clock_rate = 24000000ULL, // 24 MHz
	.make_dump = false,
	.window_scale = 1,
	.step_mode = false,
};

config_t* config_get(void) {
	return &config;
}