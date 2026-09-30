#ifndef WRM_CONFIG_H
#define WRM_CONFIG_H
#include "common.h"

typedef struct config {
	bool debug;
	const char* version;
	const char* firm_path; // firmware
	const char* hdd_path[2]; // disk image paths; NULL = not connected
	const char* floppy_path; // NULL = not connected
	uint64_t clock_rate;
	bool make_dump;
	int window_scale;
	bool step_mode;
	bool headless; // no window: runs until the machine powers off or halts
} config_t;

config_t* config_get(void);
// Applies the command line; prints the usage and exits on --help or an
// unknown option.
void config_parse(int argc, char* argv[]);

#endif // WRM_CONFIG_H
