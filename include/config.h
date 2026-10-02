#ifndef WRM_CONFIG_H
#define WRM_CONFIG_H
#include "common.h"

#include "netpolicy.h"

#define CONFIG_RAM_SLOT_COUNT 4
#define CONFIG_HDD_COUNT 2
#define CONFIG_MONITOR_PORT 4040 // --monitor without a port

typedef struct config {
	bool debug; // dump the CPU state whenever the machine stops or quits
	const char* version;
	const char* firm_path; // firmware
	const char* hdd_path[CONFIG_HDD_COUNT]; // disk images, NULL = no disk
	// serial numbers IDENTIFY reports, NULL = made from the image's path
	const char* hdd_serial[CONFIG_HDD_COUNT];
	const char* floppy_path; // NULL = no disk in the drive
	const char* share_path; // the shared folder, NULL = none
	bool share_readonly;
	bool mute; // no sound output
	uint64_t clock_rate; // Hz
	size_t ram_size[CONFIG_RAM_SLOT_COUNT]; // bytes per slot, 0 = empty
	bool make_dump;
	int window_scale;
	bool step_mode;
	bool headless; // no window: runs until the machine powers off or halts
	const char* trace_path; // retired instructions, NULL = off, "-" = stderr
	bool net; // the network card is connected to the host's network
	// where the guest may connect and send to, which ports are forwarded
	net_policy_t net_policy;
	bool unthrottled; // run as fast as the host can, not at the clock rate
	// The run depends only on the ROM, the disks and the input: unthrottled,
	// a virtual RTC, a seeded RNG, the network polled at fixed ticks.
	bool deterministic;
	bool rtc_virtual; // the RTC counts ticks from rtc_epoch
	uint64_t rtc_epoch; // seconds since 1970-01-01 UTC at power-on
	bool rng_seeded; // the RNG gives the stream of rng_seed, not the host's
	uint64_t rng_seed;
	const char* input_path; // input script (see input.h), NULL = none
	uint16_t monitor_port; // the monitor's TCP port, 0 = no monitor
	bool pause; // start stopped, for the monitor
	const char* snapshot_path; // load this snapshot at start, NULL = none
} config_t;

config_t* config_get(void);
// Applies the command line; prints the usage and exits on --help or an
// unknown option.
void config_parse(int argc, char* argv[]);

#endif // WRM_CONFIG_H
