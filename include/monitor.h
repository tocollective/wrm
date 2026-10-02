#ifndef WRM_MONITOR_H
#define WRM_MONITOR_H
#include "common.h"

#include "machine.h"
#include "network.h"

#define MONITOR_LINE_SIZE 256

// The emulator's monitor (--monitor): a text console on a TCP port of
// 127.0.0.1 (nc 127.0.0.1 4040). It stops and steps the machine, shows
// and changes registers and memory, sets breakpoints and watchpoints (see
// cpu_debug_t) and saves and loads snapshots. One client at a time; the
// machine keeps running when it leaves. 'help' lists the commands.
typedef struct monitor {
	machine_t* machine;
	network_socket_t server; // listening
	network_socket_t client; // NETWORK_NO_SOCKET when nobody is connected
	char line[MONITOR_LINE_SIZE]; // the command being received
	size_t line_length;
	bool line_overflow; // the command is too long: it is dropped
	char* out; // to send to the client
	size_t out_size;
	size_t out_capacity;
	cpu_stop_t reported; // the stop the client has been told about
} monitor_t;

// NULL (with a warning) if the port can't be listened on.
monitor_t* monitor_create(machine_t* machine, const uint16_t port);
void monitor_destroy(monitor_t* monitor);

// Takes a client, runs the commands it has sent and tells it when the
// machine stops. Called every iteration of the main loop; never waits.
void monitor_poll(monitor_t* monitor);

#endif // WRM_MONITOR_H
