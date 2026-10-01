#ifndef WRM_NETWORK_H
#define WRM_NETWORK_H
#include "common.h"

// The host's network: non-blocking IPv4 sockets over BSD sockets, Winsock
// or, in a browser, Emscripten's sockets (WebSockets underneath). The
// network card polls them from the main loop, so nothing here waits.
// Addresses are host-order words, 127.0.0.1 = 0x7F000001.

// A host socket: an int, or a Winsock SOCKET, which is pointer-sized
typedef intptr_t network_socket_t;
#define NETWORK_NO_SOCKET ((network_socket_t) - 1)

// Results of send and receive besides a byte count
#define NETWORK_WOULD_BLOCK (-1) // nothing to do now, try again later
#define NETWORK_EOF (-2) // the other end closed the connection
#define NETWORK_ERROR (-3) // the connection or socket failed

// What the host can do: in a browser only outgoing TCP works
bool network_can_listen(void);
bool network_can_udp(void);

// Starts the host's sockets (Winsock); false (with a warning) if it can't.
bool network_init(void);
void network_quit(void);

// TCP connection to addr:port, under way when this returns; *pending is
// set if it hasn't finished yet (see network_connected).
network_socket_t network_connect(const uint32_t addr, const uint16_t port,
								 bool* pending);
// 1 once the connection is up, 0 while it is under way, -1 if it failed
int network_connected(const network_socket_t socket);
// TCP socket listening on local_addr:port, port 0 = any
network_socket_t network_listen(const uint32_t local_addr, const uint16_t port);
// The next connection on a listening socket, NETWORK_NO_SOCKET if none
// came in yet; *addr and *port get the other end.
network_socket_t network_accept(const network_socket_t socket, uint32_t* addr,
								uint16_t* port);
// UDP socket on local_addr:port, port 0 = any
network_socket_t network_udp(const uint32_t local_addr, const uint16_t port);
void network_close(const network_socket_t socket);
// the local port of a socket, 0 if unknown
uint16_t network_local_port(const network_socket_t socket);

// Byte counts or NETWORK_*; receive never returns 0 (that is NETWORK_EOF).
long network_send(const network_socket_t socket, const void* data,
				  const size_t size);
long network_receive(const network_socket_t socket, void* buffer,
					 const size_t size);
// UDP: a datagram may be empty, so 0 is a count here
long network_send_to(const network_socket_t socket, const void* data,
					 const size_t size, const uint32_t addr,
					 const uint16_t port);
long network_receive_from(const network_socket_t socket, void* buffer,
						  const size_t size, uint32_t* addr, uint16_t* port);

// A host name lookup, run on a thread where there are threads.
typedef struct network_lookup network_lookup_t;

network_lookup_t* network_lookup_start(const char* name);
// true once it has ended; *addr is then the first IPv4 address, 0 if none
bool network_lookup_done(network_lookup_t* lookup, uint32_t* addr);
// Frees a lookup, done or not: one still running is left to end on its own.
void network_lookup_free(network_lookup_t* lookup);

#endif // WRM_NETWORK_H
