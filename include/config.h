#ifndef WRM_CONFIG_H
#define WRM_CONFIG_H
#include "common.h"

#define CONFIG_RAM_SLOT_COUNT 4
#define CONFIG_HDD_COUNT 2

typedef struct config {
	bool debug; // dump the CPU state whenever the machine stops or quits
	const char* version;
	const char* firm_path; // firmware
	const char* hdd_path[CONFIG_HDD_COUNT]; // disk images, NULL = no disk
	const char* floppy_path; // NULL = no disk in the drive
	bool mute; // no sound output
	uint64_t clock_rate; // Hz
	size_t ram_size[CONFIG_RAM_SLOT_COUNT]; // bytes per slot, 0 = empty
	bool make_dump;
	int window_scale;
	bool step_mode;
	bool headless; // no window: runs until the machine powers off or halts
	const char* trace_path; // retired instructions, NULL = off, "-" = stderr
} config_t;

config_t* config_get(void);
// Applies the command line; prints the usage and exits on --help or an
// unknown option.
void config_parse(int argc, char* argv[]);

#endif // WRM_CONFIG_H
