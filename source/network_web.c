// The host's network in a browser. A page can't open TCP connections or
// look up host names, so it asks the network proxy (tools/netproxy.py) on
// the host: a connection is a WebSocket to ws://PROXY/tcp/ADDR/PORT that
// carries the bytes of a TCP connection the proxy opens, and a lookup is
// GET http://PROXY/resolve/NAME. PROXY is HOST:PORT/TOKEN, from the page's
// URL: ?netproxy=... as the proxy prints it at start (127.0.0.1:8080 if
// the URL has none, for a proxy run with --no-token). The proxy only
// reaches public addresses unless told otherwise. Listening and UDP are
// not available.

#ifdef __EMSCRIPTEN__

#include "network.h"

#include <emscripten.h>
#include <string.h>

// The JavaScript side keeps sockets and lookups in tables of the page,
// numbered from 1; their events land there between frames, and the
// Ethernet card's network polls them.

EM_JS(void, web_net_init, (void), {
	if (globalThis.wrmNet) return; // started once per page
	var proxy = new URLSearchParams(location.search).get("netproxy");
	globalThis.wrmNet = {
		proxy: proxy || "127.0.0.1:8080",
		next: 1,
		sockets: {},
		lookups: {},
		// says once what is missing when the proxy doesn't answer
		warned: false,
		missing: function() {
			if (this.warned) return;
			this.warned = true;
			console.warn("No network proxy at " + this.proxy
						 + ": run tools/netproxy.py on the host and open"
						 + " the page with the ?netproxy= it prints");
		},
	};
});

// The socket's number, 0 if it can't be made. state: 0 connecting,
// 1 connected, 2 closed by the other end, -1 failed.
EM_JS(int, web_net_connect, (uint32_t addr, int port), {
	var net = globalThis.wrmNet;
	addr >>>= 0;
	var ip = [ addr >>> 24, (addr >>> 16) & 255, (addr >>> 8) & 255, addr & 255 ];
	var s = { state: 0, chunks: [], offset: 0, ws: null };
	try {
		s.ws = new WebSocket("ws://" + net.proxy + "/tcp/" + ip.join(".") + "/"
							 + port);
	} catch (e) {
		return 0;
	}
	s.ws.binaryType = "arraybuffer";
	s.ws.onopen = function() { s.state = 1; };
	s.ws.onmessage = function(e) {
		if (e.data instanceof ArrayBuffer) s.chunks.push(new Uint8Array(e.data));
	};
	s.ws.onerror = function() {
		// the page can't tell a missing proxy from a refused connection
		if (s.state == 0)
			console.warn("Can't connect to " + ip.join(".") + ":" + port
						 + " through the network proxy at " + net.proxy);
		s.state = -1;
	};
	s.ws.onclose = function(e) {
		if (s.state < 0) return;
		// 1000: the proxy's close after the other end's
		s.state = s.state == 1 && (e.wasClean || e.code == 1000) ? 2 : -1;
	};
	var id = net.next++;
	net.sockets[id] = s;
	return id;
});

EM_JS(int, web_net_state, (int id), {
	var s = globalThis.wrmNet.sockets[id];
	return s ? s.state : -1;
});

// Bytes taken, 0 if it can't take them now, -1 if the connection is gone.
EM_JS(int, web_net_send, (int id, const void* data, int size), {
	var s = globalThis.wrmNet.sockets[id];
	if (!s || s.state != 1) return -1;
	// what the browser hasn't sent yet: like a full send buffer
	if (s.ws.bufferedAmount > 65536) return 0;
	s.ws.send(HEAPU8.slice(data, data + size));
	return size;
});

// Bytes received, 0 if none came yet, -1 at the end, -2 if it failed.
// What came before the end or the failure is received first.
EM_JS(int, web_net_receive, (int id, void* buffer, int size), {
	var s = globalThis.wrmNet.sockets[id];
	if (!s) return -2;
	var n = 0;
	while (n < size && s.chunks.length) {
		var chunk = s.chunks[0];
		var take = Math.min(size - n, chunk.length - s.offset);
		HEAPU8.set(chunk.subarray(s.offset, s.offset + take), buffer + n);
		n += take;
		s.offset += take;
		if (s.offset == chunk.length) {
			s.chunks.shift();
			s.offset = 0;
		}
	}
	if (n > 0) return n;
	if (s.state == 2) return -1;
	if (s.state < 0) return -2;
	return 0;
});

EM_JS(void, web_net_close, (int id), {
	var net = globalThis.wrmNet;
	var s = net.sockets[id];
	if (!s) return;
	delete net.sockets[id];
	s.ws.onopen = s.ws.onmessage = s.ws.onerror = s.ws.onclose = null;
	s.ws.close();
});

EM_JS(int, web_net_lookup_start, (const char* name, int length), {
	var net = globalThis.wrmNet;
	var text = new TextDecoder().decode(HEAPU8.slice(name, name + length));
	var lookup = { done: false, addr: 0 };
	var id = net.next++;
	net.lookups[id] = lookup;
	fetch("http://" + net.proxy + "/resolve/" + encodeURIComponent(text))
		.then(function(r) { return r.ok ? r.text() : ""; },
			  function() { net.missing(); return ""; })
		.then(function(t) {
			var p = t.trim().split(".");
			var ok = p.length == 4 && p.every(function(x) {
				var n = Number(x);
				return x.length > 0 && Number.isInteger(n) && n >= 0 && n <= 255;
			});
			if (ok) lookup.addr = ((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]) >>> 0;
			lookup.done = true;
		});
	return id;
});

// 1 once the lookup has ended, 0 while it runs
EM_JS(int, web_net_lookup_done, (int id), {
	var lookup = globalThis.wrmNet.lookups[id];
	return lookup && lookup.done ? 1 : 0;
});

// the address it found, 0 if none
EM_JS(uint32_t, web_net_lookup_addr, (int id), {
	var lookup = globalThis.wrmNet.lookups[id];
	return lookup ? lookup.addr | 0 : 0;
});

EM_JS(void, web_net_lookup_free, (int id), {
	delete globalThis.wrmNet.lookups[id];
});

bool network_can_listen(void) { return false; }

bool network_can_udp(void) { return false; }

bool network_init(void) {
	web_net_init();
	return true;
}

void network_quit(void) {}

network_socket_t network_connect(const uint32_t addr, const uint16_t port,
								 bool* pending) {
	const int id = web_net_connect(addr, port);
	*pending = id != 0;
	return id ? (network_socket_t)id : NETWORK_NO_SOCKET;
}

int network_connected(const network_socket_t socket) {
	const int state = web_net_state((int)socket);
	if (state < 0) return -1;
	return state == 0 ? 0 : 1; // closed already: what came is read first
}

network_socket_t network_listen(const uint32_t local_addr,
								const uint16_t port) {
	(void)local_addr;
	(void)port;
	return NETWORK_NO_SOCKET;
}

network_socket_t network_accept(const network_socket_t socket, uint32_t* addr,
								uint16_t* port) {
	(void)socket;
	(void)addr;
	(void)port;
	return NETWORK_NO_SOCKET;
}

network_socket_t network_udp(const uint32_t local_addr, const uint16_t port) {
	(void)local_addr;
	(void)port;
	return NETWORK_NO_SOCKET;
}

network_socket_t network_icmp(void) {
	return NETWORK_NO_SOCKET;
}

void network_shutdown(const network_socket_t socket) {
	(void)socket; // a WebSocket can't be half closed
}

void network_close(const network_socket_t socket) {
	if (socket == NETWORK_NO_SOCKET) return;
	web_net_close((int)socket);
}

uint16_t network_local_port(const network_socket_t socket) {
	(void)socket;
	return 0; // the proxy's, which the page doesn't know
}

long network_send(const network_socket_t socket, const void* data,
				  const size_t size) {
	const int sent = web_net_send((int)socket, data, (int)size);
	if (sent < 0) return NETWORK_ERROR;
	return sent == 0 ? NETWORK_WOULD_BLOCK : sent;
}

long network_receive(const network_socket_t socket, void* buffer,
					 const size_t size) {
	const int got = web_net_receive((int)socket, buffer, (int)size);
	if (got == 0) return NETWORK_WOULD_BLOCK;
	if (got == -1) return NETWORK_EOF;
	if (got < 0) return NETWORK_ERROR;
	return got;
}

long network_send_to(const network_socket_t socket, const void* data,
					 const size_t size, const uint32_t addr,
					 const uint16_t port) {
	(void)socket;
	(void)data;
	(void)size;
	(void)addr;
	(void)port;
	return NETWORK_ERROR;
}

long network_receive_from(const network_socket_t socket, void* buffer,
						  const size_t size, uint32_t* addr, uint16_t* port) {
	(void)socket;
	(void)buffer;
	(void)size;
	*addr = 0;
	*port = 0;
	return NETWORK_ERROR;
}

// ---- lookups --------------------------------------------------------------

struct network_lookup {
	int id;
};

network_lookup_t* network_lookup_start(const char* name) {
	network_lookup_t* lookup = calloc(1, sizeof(network_lookup_t));
	if (!lookup) error("Failed to allocate a host name lookup!");
	lookup->id = web_net_lookup_start(name, (int)strlen(name));
	return lookup;
}

bool network_lookup_done(network_lookup_t* lookup, uint32_t* addr) {
	if (!web_net_lookup_done(lookup->id)) return false;
	*addr = web_net_lookup_addr(lookup->id);
	return true;
}

void network_lookup_free(network_lookup_t* lookup) {
	if (!lookup) return;
	web_net_lookup_free(lookup->id); // an answer still to come is dropped
	free(lookup);
}

#endif // __EMSCRIPTEN__
