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
	.hdd_serial = { NULL, NULL },
	.floppy_path = NULL,
	.share_path = NULL,
	.share_readonly = false,
	.mute = false,
	.clock_rate = 32000000ULL, // 32 MHz
	.ram_size = { 1024 * 1024 * 4 }, // 4MB in slot 0
	.make_dump = false,
	.window_scale = 1,
	.step_mode = false,
	.headless = false,
	.trace_path = NULL,
	.net = true,
	.unthrottled = false,
	.deterministic = false,
	.rtc_virtual = false,
	.rtc_epoch = 0,
	.rng_seeded = false,
	.rng_seed = 0,
	.input_path = NULL,
	.monitor_port = 0,
	.pause = false,
	.snapshot_path = NULL,
};

config_t* config_get(void) {
	return &config;
}

static void config_usage(const char* program) {
	printf("WRM.081632 %s\n"
		   "usage: %s [options]\n"
		   "  --rom PATH        firmware image (default: %s)\n"
		   "  --ram SIZE[,...]  RAM per slot, up to %d slots: 1M, 2M, 4M, "
		   "8M, 16M or 32M\n"
		   "                    (default: 4M)\n"
		   "  --clock HZ        clock rate, with an optional k, M or G "
		   "suffix (default: 32M)\n"
		   "  --hdd PATH        disk image for disk 0; a second --hdd "
		   "attaches disk 1\n"
		   "  --hdd-serial N=SERIAL\n"
		   "                    serial number disk N reports (default: "
		   "made from the\n"
		   "                    image's path), at most 31 characters\n"
		   "  --floppy PATH     disk image in the floppy drive; a file "
		   "dropped on the\n"
		   "                    window replaces it at run time\n"
		   "  --share PATH[:ro] share a host folder with the guest, "
		   "read-only with :ro\n"
		   "  --mute            no sound\n"
		   "  --no-net          cut the network card off the host's network\n"
		   "  --net-allow ADDR[/BITS][:PORT[-PORT]]\n"
		   "                    let the guest connect and send there; by "
		   "default it can\n"
		   "                    reach public addresses only, not the host "
		   "or its networks\n"
		   "  --net-deny ADDR[/BITS][:PORT[-PORT]]\n"
		   "                    keep the guest from there; the last rule "
		   "that matches wins\n"
		   "  --net-forward [ADDR:]HOST_PORT:GUEST_PORT\n"
		   "                    the guest's LISTEN and UDP on GUEST_PORT "
		   "open on\n"
		   "                    ADDR:HOST_PORT of the host (default ADDR: "
		   "127.0.0.1)\n"
		   "  --headless        no window; exit when the machine powers off "
		   "or halts\n"
		   "  --unthrottled     run as fast as the host can, not at the "
		   "clock rate\n"
		   "  --deterministic   the same input gives the same run: implies "
		   "--unthrottled,\n"
		   "                    a virtual RTC and a seeded RNG, polls the "
		   "network at fixed\n"
		   "                    ticks\n"
		   "  --rtc=SECONDS     the RTC starts at SECONDS after 1970-01-01 "
		   "UTC and counts\n"
		   "                    clock ticks (default with --deterministic: "
		   "0)\n"
		   "  --seed=N          the random number generator gives the same "
		   "numbers on\n"
		   "                    every run, made from N (default with "
		   "--deterministic: 0)\n"
		   "  --input PATH      feed the keyboard, UART, mouse and power "
		   "button from an\n"
		   "                    input script at the clock ticks it gives\n"
		   "  --monitor[=PORT]  a debugging console on 127.0.0.1:PORT "
		   "(default: %d)\n"
		   "  --pause           start stopped, until the monitor goes on\n"
		   "  --load PATH       start from a snapshot saved by the monitor "
		   "or Ctrl+Alt+S\n"
		   "  --trace[=PATH]    log every retired instruction to PATH "
		   "(default: stderr)\n"
		   "  --debug           dump the CPU state when the machine stops or "
		   "quits\n"
		   "  -h, --help        show this help\n",
		   config.version,
		   program,
		   config.firm_path,
		   CONFIG_RAM_SLOT_COUNT,
		   CONFIG_MONITOR_PORT);
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

// "PATH" or "PATH:ro" for --share
static void config_parse_share(const char* text) {
	const size_t length = strlen(text);
	if (!length) error("--share needs a folder");
	config.share_readonly = length > 3 && strcmp(text + length - 3, ":ro") == 0;
	if (!config.share_readonly) {
		config.share_path = text;
		return;
	}
	char* path = malloc(length - 2);
	if (!path) error("Failed to allocate the configuration!");
	memcpy(path, text, length - 3);
	path[length - 3] = '\0';
	config.share_path = path; // for the whole run
}

// "N=SERIAL" for --hdd-serial
static void config_parse_hdd_serial(const char* text) {
	const char* equals = strchr(text, '=');
	if (!equals || equals - text != 1 || !isdigit((unsigned char)text[0])
		|| text[0] - '0' >= CONFIG_HDD_COUNT)
		error("--hdd-serial: expected N=SERIAL with N from 0 to %d, got '%s'",
			  CONFIG_HDD_COUNT - 1,
			  text);
	const char* serial = equals + 1;
	if (!*serial || strlen(serial) > 31)
		error("--hdd-serial: the serial number must be 1 to 31 characters");
	for (const char* p = serial; *p; p++)
		if (*p < 0x21 || *p > 0x7E)
			error("--hdd-serial: the serial number must be printable ASCII "
				  "without spaces");
	config.hdd_serial[text[0] - '0'] = serial;
}

// "a.b.c.d" at *p, as a word with a on top; moves *p past it. False if
// there is none.
static bool config_parse_ipv4(const char** p, uint32_t* addr) {
	uint32_t value = 0;
	for (int i = 0; i < 4; i++) {
		if (!isdigit((unsigned char)**p)) return false;
		errno = 0;
		char* end = NULL;
		const unsigned long part = strtoul(*p, &end, 10);
		if (errno || part > 255 || end - *p > 3) return false;
		value = value << 8 | (uint32_t)part;
		*p = end;
		if (i < 3 && *(*p)++ != '.') return false;
	}
	*addr = value;
	return true;
}

// A port, 0-65535, at *p; moves *p past it.
static bool config_parse_port_number(const char** p, uint16_t* port) {
	if (!isdigit((unsigned char)**p)) return false;
	errno = 0;
	char* end = NULL;
	const unsigned long value = strtoul(*p, &end, 10);
	if (errno || value > 65535) return false;
	*port = (uint16_t)value;
	*p = end;
	return true;
}

// "ADDR[/BITS][:PORT[-PORT]]" for --net-allow and --net-deny
static void config_parse_net_rule(const char* option, const char* text,
								  const bool allow) {
	net_rule_t rule = { .allow = allow, .port_min = 0, .port_max = 65535 };
	const char* p = text;
	int bits = 32;
	bool ok = config_parse_ipv4(&p, &rule.addr);
	if (ok && *p == '/') {
		p++;
		errno = 0;
		char* end = NULL;
		const long value = isdigit((unsigned char)*p) ? strtol(p, &end, 10) : -1;
		ok = !errno && value >= 0 && value <= 32;
		bits = (int)value;
		if (ok) p = end;
	}
	if (ok && *p == ':') {
		p++;
		ok = config_parse_port_number(&p, &rule.port_min);
		rule.port_max = rule.port_min;
		if (ok && *p == '-') {
			p++;
			ok = config_parse_port_number(&p, &rule.port_max)
			  && rule.port_max >= rule.port_min;
		}
	}
	if (!ok || *p)
		error("%s: expected ADDR[/BITS][:PORT[-PORT]], got '%s'", option, text);
	rule.mask = bits == 0 ? 0 : UINT32_MAX << (32 - bits);
	rule.addr &= rule.mask;
	if (!net_policy_add(&config.net_policy, rule))
		error("%s: at most %d rules", option, NET_RULE_MAX);
}

// "[ADDR:]HOST_PORT:GUEST_PORT" for --net-forward
static void config_parse_net_forward(const char* text) {
	net_forward_t forward = { .host_addr = NET_LOCAL_ADDR };
	const char* p = text;
	const char* after_addr = text;
	uint32_t addr = 0;
	if (config_parse_ipv4(&after_addr, &addr) && *after_addr == ':') {
		forward.host_addr = addr;
		p = after_addr + 1;
	}
	const bool ok = config_parse_port_number(&p, &forward.host_port)
				 && *p++ == ':'
				 && config_parse_port_number(&p, &forward.guest_port) && !*p
				 && forward.host_port && forward.guest_port;
	if (!ok)
		error("--net-forward: expected [ADDR:]HOST_PORT:GUEST_PORT with ports "
			  "1-65535, got '%s'",
			  text);
	net_policy_t* policy = &config.net_policy;
	if (net_policy_forward(policy, forward.guest_port))
		error("--net-forward: guest port %u is forwarded twice",
			  (unsigned)forward.guest_port);
	if (policy->forwards == NET_FORWARD_MAX)
		error("--net-forward: at most %d", NET_FORWARD_MAX);
	policy->forward[policy->forwards++] = forward;
}

static void config_parse_rtc(const char* text) {
	uint64_t seconds = 0;
	if (!config_parse_number(text, 1000, &seconds)
		|| seconds > UINT64_MAX / 1000000000ULL / 2)
		error("--rtc: invalid time '%s'", text);
	config.rtc_virtual = true;
	config.rtc_epoch = seconds;
}

static void config_parse_seed(const char* text) {
	uint64_t seed = 0;
	if (!config_parse_number(text, 1000, &seed))
		error("--seed: invalid seed '%s'", text);
	config.rng_seeded = true;
	config.rng_seed = seed;
}

static void config_parse_port(const char* text) {
	uint64_t port = 0;
	if (!config_parse_number(text, 1000, &port) || port == 0 || port > 65535)
		error("--monitor: invalid port '%s'", text);
	config.monitor_port = (uint16_t)port;
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
	net_policy_defaults(&config.net_policy); // the options' rules go after
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
		} else if (strcmp(arg, "--hdd-serial") == 0) {
			config_parse_hdd_serial(config_value(argc, argv, &i));
		} else if (strcmp(arg, "--floppy") == 0) {
			config.floppy_path = config_value(argc, argv, &i);
		} else if (strcmp(arg, "--share") == 0) {
			config_parse_share(config_value(argc, argv, &i));
		} else if (strcmp(arg, "--mute") == 0) {
			config.mute = true;
		} else if (strcmp(arg, "--trace") == 0) {
			config.trace_path = "-";
		} else if (strncmp(arg, "--trace=", 8) == 0 && arg[8]) {
			config.trace_path = arg + 8;
		} else if (strcmp(arg, "--no-net") == 0) {
			config.net = false;
		} else if (strcmp(arg, "--net-allow") == 0) {
			config_parse_net_rule(arg, config_value(argc, argv, &i), true);
		} else if (strcmp(arg, "--net-deny") == 0) {
			config_parse_net_rule(arg, config_value(argc, argv, &i), false);
		} else if (strcmp(arg, "--net-forward") == 0) {
			config_parse_net_forward(config_value(argc, argv, &i));
		} else if (strncmp(arg, "--net=", 6) == 0) {
			error("--net=ADDR is gone: --net-forward ADDR:PORT:PORT opens a "
				  "guest's port on another address");
		} else if (strcmp(arg, "--debug") == 0) {
			config.debug = true;
		} else if (strcmp(arg, "--unthrottled") == 0) {
			config.unthrottled = true;
		} else if (strcmp(arg, "--deterministic") == 0) {
			config.deterministic = true;
			config.unthrottled = true;
			config.rtc_virtual = true;
			config.rng_seeded = true;
		} else if (strncmp(arg, "--rtc=", 6) == 0) {
			config_parse_rtc(arg + 6);
		} else if (strncmp(arg, "--seed=", 7) == 0) {
			config_parse_seed(arg + 7);
		} else if (strcmp(arg, "--input") == 0) {
			config.input_path = config_value(argc, argv, &i);
		} else if (strcmp(arg, "--monitor") == 0) {
			config.monitor_port = CONFIG_MONITOR_PORT;
		} else if (strncmp(arg, "--monitor=", 10) == 0) {
			config_parse_port(arg + 10);
		} else if (strcmp(arg, "--pause") == 0) {
			config.pause = true;
		} else if (strcmp(arg, "--load") == 0) {
			config.snapshot_path = config_value(argc, argv, &i);
		} else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
			config_usage(program);
			exit(0);
		} else {
			error("Unknown option: %s (see --help)", arg);
		}
	}
}
