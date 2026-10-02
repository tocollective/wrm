// The host's network on a desktop; in a browser it is network_web.c.
#ifndef __EMSCRIPTEN__

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L // sockets and getaddrinfo under strict C99
#define _DARWIN_C_SOURCE // ... and SO_NOSIGPIPE on macOS
#endif

#include "network.h"

#include <string.h>

// Winsock goes before anything that may pull in windows.h (SDL)
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include <SDL3/SDL.h> // threads for lookups

#ifdef _WIN32
typedef SOCKET native_socket_t;
#define NATIVE_INVALID INVALID_SOCKET
#define network_close_native closesocket
#else
typedef int native_socket_t;
#define NATIVE_INVALID (-1)
#define network_close_native close
#endif

#define NATIVE(s) ((native_socket_t)(s))

// A send to a connection the other end has closed raises SIGPIPE on
// POSIX, which would kill the emulator: Linux takes a flag per send,
// macOS an option per socket (see network_open).
#ifdef MSG_NOSIGNAL
#define NETWORK_SEND_FLAGS MSG_NOSIGNAL
#else
#define NETWORK_SEND_FLAGS 0
#endif

bool network_can_listen(void) {
	return true;
}

bool network_can_udp(void) {
	return true;
}

bool network_init(void) {
#ifdef _WIN32
	WSADATA data;
	if (WSAStartup(MAKEWORD(2, 2), &data) != 0) {
		warning("No network: failed to start Winsock");
		return false;
	}
#endif
	return true;
}

void network_quit(void) {
#ifdef _WIN32
	WSACleanup();
#endif
}

// The last call failed only because it would have had to wait.
static bool network_would_block(void) {
#ifdef _WIN32
	return WSAGetLastError() == WSAEWOULDBLOCK;
#else
	return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
#endif
}

// The last connect has started and goes on in the background.
static bool network_in_progress(void) {
#ifdef _WIN32
	return WSAGetLastError() == WSAEWOULDBLOCK;
#else
	return errno == EINPROGRESS || errno == EINTR;
#endif
}

static bool network_set_nonblocking(const native_socket_t s) {
#ifdef _WIN32
	u_long on = 1;
	return ioctlsocket(s, FIONBIO, &on) == 0;
#else
	const int flags = fcntl(s, F_GETFL, 0);
	return flags != -1 && fcntl(s, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
}

// Makes a host socket fit for the card: non-blocking, and no SIGPIPE.
static network_socket_t network_adopt(const native_socket_t s) {
	if (s == NATIVE_INVALID) return NETWORK_NO_SOCKET;
	if (!network_set_nonblocking(s)) {
		network_close_native(s);
		return NETWORK_NO_SOCKET;
	}
#ifdef SO_NOSIGPIPE
	const int on = 1;
	setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif
	return (network_socket_t)s;
}

static network_socket_t network_open(const int type) {
	return network_adopt(socket(AF_INET, type, 0));
}

static struct sockaddr_in network_address(const uint32_t addr,
										  const uint16_t port) {
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = htons(port);
	address.sin_addr.s_addr = htonl(addr);
	return address;
}

network_socket_t network_connect(const uint32_t addr, const uint16_t port,
								 bool* pending) {
	*pending = false;
	const network_socket_t s = network_open(SOCK_STREAM);
	if (s == NETWORK_NO_SOCKET) return NETWORK_NO_SOCKET;
	const struct sockaddr_in address = network_address(addr, port);
	if (connect(NATIVE(s), (const struct sockaddr*)&address, sizeof(address))
		== 0)
		return s;
	if (network_in_progress()) {
		*pending = true;
		return s;
	}
	network_close(s);
	return NETWORK_NO_SOCKET;
}

int network_connected(const network_socket_t s) {
#ifndef _WIN32
	if (NATIVE(s) >= FD_SETSIZE) return -1; // select can't watch it
#endif
	// a socket is writable once connected; Winsock reports a failure as an
	// exception instead
	fd_set writable;
	fd_set failed;
	FD_ZERO(&writable);
	FD_ZERO(&failed);
	FD_SET(NATIVE(s), &writable);
	FD_SET(NATIVE(s), &failed);
	struct timeval now = { 0, 0 };
	const int ready =
		select((int)NATIVE(s) + 1, NULL, &writable, &failed, &now);
	if (ready < 0) return -1;
	if (ready == 0) return 0;

	int failure = 0;
	socklen_t length = sizeof(failure);
	if (getsockopt(NATIVE(s), SOL_SOCKET, SO_ERROR, (char*)&failure, &length)
		!= 0)
		return -1;
	return failure == 0 ? 1 : -1;
}

// Binds a new socket of the type to local_addr:port.
static network_socket_t network_bound(const int type, const uint32_t local_addr,
									  const uint16_t port) {
	const network_socket_t s = network_open(type);
	if (s == NETWORK_NO_SOCKET) return NETWORK_NO_SOCKET;
#ifndef _WIN32
	// a port closed a moment ago can be listened on again at once (on
	// Windows the option would let another program take the port)
	if (type == SOCK_STREAM) {
		const int on = 1;
		setsockopt(NATIVE(s), SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
	}
#endif
	const struct sockaddr_in address = network_address(local_addr, port);
	if (bind(NATIVE(s), (const struct sockaddr*)&address, sizeof(address))
		!= 0) {
		network_close(s);
		return NETWORK_NO_SOCKET;
	}
	return s;
}

network_socket_t network_listen(const uint32_t local_addr,
								const uint16_t port) {
	const network_socket_t s = network_bound(SOCK_STREAM, local_addr, port);
	if (s == NETWORK_NO_SOCKET) return NETWORK_NO_SOCKET;
	if (listen(NATIVE(s), 1) != 0) {
		network_close(s);
		return NETWORK_NO_SOCKET;
	}
	return s;
}

network_socket_t network_accept(const network_socket_t s, uint32_t* addr,
								uint16_t* port) {
	struct sockaddr_in address;
	socklen_t length = sizeof(address);
	memset(&address, 0, sizeof(address));
	const network_socket_t client =
		network_adopt(accept(NATIVE(s), (struct sockaddr*)&address, &length));
	if (client == NETWORK_NO_SOCKET) return NETWORK_NO_SOCKET;
	*addr = ntohl(address.sin_addr.s_addr);
	*port = ntohs(address.sin_port);
	return client;
}

network_socket_t network_udp(const uint32_t local_addr, const uint16_t port) {
	return network_bound(SOCK_DGRAM, local_addr, port);
}

network_socket_t network_icmp(void) {
#ifdef _WIN32
	return NETWORK_NO_SOCKET; // only IcmpSendEcho, which blocks
#else
	return network_adopt(socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP));
#endif
}

void network_shutdown(const network_socket_t s) {
	if (s == NETWORK_NO_SOCKET) return;
#ifdef _WIN32
	shutdown(NATIVE(s), SD_SEND);
#else
	shutdown(NATIVE(s), SHUT_WR);
#endif
}

void network_close(const network_socket_t s) {
	if (s == NETWORK_NO_SOCKET) return;
	network_close_native(NATIVE(s));
}

uint16_t network_local_port(const network_socket_t s) {
	struct sockaddr_in address;
	socklen_t length = sizeof(address);
	memset(&address, 0, sizeof(address));
	if (getsockname(NATIVE(s), (struct sockaddr*)&address, &length) != 0)
		return 0;
	return ntohs(address.sin_port);
}

// A send or receive result as a count or NETWORK_*.
static long network_result(const long result) {
	if (result >= 0) return result;
	return network_would_block() ? NETWORK_WOULD_BLOCK : NETWORK_ERROR;
}

long network_send(const network_socket_t s, const void* data,
				  const size_t size) {
	return network_result((long)send(
		NATIVE(s), (const char*)data, (int)size, NETWORK_SEND_FLAGS));
}

long network_receive(const network_socket_t s, void* buffer,
					 const size_t size) {
	const long result =
		network_result((long)recv(NATIVE(s), (char*)buffer, (int)size, 0));
	return result == 0 ? NETWORK_EOF : result;
}

long network_send_to(const network_socket_t s, const void* data,
					 const size_t size, const uint32_t addr,
					 const uint16_t port) {
	const struct sockaddr_in address = network_address(addr, port);
	return network_result((long)sendto(NATIVE(s),
									   (const char*)data,
									   (int)size,
									   NETWORK_SEND_FLAGS,
									   (const struct sockaddr*)&address,
									   sizeof(address)));
}

long network_receive_from(const network_socket_t s, void* buffer,
						  const size_t size, uint32_t* addr, uint16_t* port) {
	struct sockaddr_in address;
	socklen_t length = sizeof(address);
	memset(&address, 0, sizeof(address));
	const long result =
		network_result((long)recvfrom(NATIVE(s),
									  (char*)buffer,
									  (int)size,
									  0,
									  (struct sockaddr*)&address,
									  &length));
	*addr = ntohl(address.sin_addr.s_addr);
	*port = ntohs(address.sin_port);
	return result;
}

// ---- lookups --------------------------------------------------------------

enum {
	LOOKUP_RUNNING,
	LOOKUP_DONE,
	LOOKUP_ABANDONED, // freed by the emulator: the thread frees it
};

struct network_lookup {
	char name[256];
	uint32_t addr; // written before state becomes LOOKUP_DONE
	SDL_AtomicInt state;
	SDL_Thread* thread; // NULL if the lookup ran at once
};

// The first IPv4 address of name, 0 if there is none. May take seconds.
static uint32_t network_resolve(const char* name) {
	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	struct addrinfo* found = NULL;
	if (getaddrinfo(name, NULL, &hints, &found) != 0) return 0;
	uint32_t addr = 0;
	for (const struct addrinfo* it = found; it; it = it->ai_next) {
		if (it->ai_family != AF_INET) continue;
		const struct sockaddr_in* address =
			(const struct sockaddr_in*)it->ai_addr;
		addr = ntohl(address->sin_addr.s_addr);
		break;
	}
	freeaddrinfo(found);
	return addr;
}

static int SDLCALL network_lookup_thread(void* data) {
	network_lookup_t* lookup = data;
	lookup->addr = network_resolve(lookup->name);
	// the emulator may have given up on it meanwhile: then it is ours
	if (!SDL_CompareAndSwapAtomicInt(
			&lookup->state, LOOKUP_RUNNING, LOOKUP_DONE))
		free(lookup);
	return 0;
}

network_lookup_t* network_lookup_start(const char* name) {
	network_lookup_t* lookup = calloc(1, sizeof(network_lookup_t));
	if (!lookup) error("Failed to allocate a host name lookup!");
	strncpy(lookup->name, name, sizeof(lookup->name) - 1);
	SDL_SetAtomicInt(&lookup->state, LOOKUP_RUNNING);
	lookup->thread = SDL_CreateThread(network_lookup_thread, "lookup", lookup);
	if (!lookup->thread) {
		lookup->addr = network_resolve(lookup->name);
		SDL_SetAtomicInt(&lookup->state, LOOKUP_DONE);
	}
	return lookup;
}

bool network_lookup_done(network_lookup_t* lookup, uint32_t* addr) {
	if (SDL_GetAtomicInt(&lookup->state) != LOOKUP_DONE) return false;
	*addr = lookup->addr;
	return true;
}

void network_lookup_free(network_lookup_t* lookup) {
	if (!lookup) return;
	if (lookup->thread) {
		SDL_DetachThread(lookup->thread);
		// still running: the thread frees it when it ends
		if (SDL_CompareAndSwapAtomicInt(
				&lookup->state, LOOKUP_RUNNING, LOOKUP_ABANDONED))
			return;
	}
	free(lookup);
}

#endif // __EMSCRIPTEN__
