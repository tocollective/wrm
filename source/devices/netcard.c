#include "devices/netcard.h"

#include <string.h>

// One datagram at a time from the host: the largest UDP can carry
static uint8_t netcard_datagram[65536];

static uint32_t netcard_pending(const netcard_t* net) {
	uint32_t pending = 0;
	for (int i = 0; i < NET_SOCKET_COUNT; i++) {
		const net_socket_t* s = &net->socket[i];
		if (s->events & s->irq_mask) pending |= 1u << i;
	}
	if ((net->dns_status & NET_DNS_DONE)
		&& (net->dns_control & NET_DNS_CONTROL_IRQ))
		pending |= NET_PENDING_DNS;
	return pending;
}

static void netcard_update_irq(netcard_t* net) {
	pic_set_line(net->pic, net->irq, netcard_pending(net) != 0);
}

netcard_t* netcard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
						  const bool link, const uint32_t local_addr) {
	netcard_t* net = (netcard_t*)calloc(1, sizeof(netcard_t));
	if (!net) error("Failed to allocate network card!");
	net->pic = pic;
	net->irq = irq;
	net->dma = dma;
	net->link = link && network_init();
	net->local_addr = local_addr;
	for (int i = 0; i < NET_SOCKET_COUNT; i++)
		net->socket[i].host = NETWORK_NO_SOCKET;
	netcard_reset(net);
	return net;
}

void netcard_destroy(netcard_t* net) {
	if (!net) return;
	netcard_reset(net);
	if (net->link) network_quit();
	free(net);
	net = NULL;
}

// Closes the host socket and empties the buffers.
static void netcard_close(net_socket_t* s) {
	network_close(s->host);
	s->host = NETWORK_NO_SOCKET;
	s->state = NET_STATE_CLOSED;
	s->rx_size = 0;
	s->tx_size = 0;
}

void netcard_reset(netcard_t* net) {
	if (!net) return;
	for (int i = 0; i < NET_SOCKET_COUNT; i++) {
		net_socket_t* s = &net->socket[i];
		netcard_close(s);
		s->error = NET_ERROR_NONE;
		s->events = 0;
		s->irq_mask = 0;
		s->local_port = 0;
		s->peer_addr = 0;
		s->peer_port = 0;
		s->address = 0;
		s->count = 0;
	}
	// a lookup still running ends on its own, unheard
	network_lookup_free(net->lookup);
	net->lookup = NULL;
	net->dns_status = 0;
	net->dns_control = 0;
	net->dns_name = 0;
	net->dns_result = 0;
	netcard_update_irq(net);
}

// The connection has ended: by the other end (error 0) or broken. What
// was received stays for RECEIVE.
static void netcard_lost(net_socket_t* s, const uint32_t error) {
	network_close(s->host);
	s->host = NETWORK_NO_SOCKET;
	s->state = NET_STATE_PEER_CLOSED;
	s->tx_size = 0;
	if (error) s->error = error;
	s->events |= NET_EVENT_CLOSED;
}

// Sends what the host takes of the send buffer.
static void netcard_flush(net_socket_t* s) {
	if (s->state != NET_STATE_CONNECTED || s->tx_size == 0) return;
	const long sent = network_send(s->host, s->tx, s->tx_size);
	if (sent == NETWORK_WOULD_BLOCK) return;
	if (sent < 0) {
		netcard_lost(s, NET_ERROR_NETWORK);
		return;
	}
	s->tx_size -= (uint32_t)sent;
	memmove(s->tx, s->tx + sent, s->tx_size);
	if (s->tx_size == 0) s->events |= NET_EVENT_SENT;
}

// Receives what fits in the receive buffer.
static void netcard_fill(net_socket_t* s) {
	while (s->state == NET_STATE_CONNECTED && s->rx_size < NET_BUFFER_SIZE) {
		const long got = network_receive(
				s->host, s->rx + s->rx_size, NET_BUFFER_SIZE - s->rx_size);
		if (got == NETWORK_WOULD_BLOCK) return;
		if (got == NETWORK_EOF) {
			netcard_lost(s, NET_ERROR_NONE);
			return;
		}
		if (got < 0) {
			netcard_lost(s, NET_ERROR_NETWORK);
			return;
		}
		s->rx_size += (uint32_t)got;
		s->events |= NET_EVENT_RECEIVED;
	}
}

static void netcard_put16(uint8_t* p, const uint32_t value) {
	p[0] = value & 0xFF;
	p[1] = (value >> 8) & 0xFF;
}

// Receives datagrams, each after its header; one that doesn't fit in the
// receive buffer is dropped.
static void netcard_fill_datagrams(net_socket_t* s) {
	while (true) {
		uint32_t addr = 0;
		uint16_t port = 0;
		const long got = network_receive_from(
				s->host, netcard_datagram, sizeof(netcard_datagram), &addr, &port);
		// an error here (such as an ICMP reply to an earlier datagram)
		// leaves the socket open, as on any host
		if (got < 0) return;
		const uint32_t length = (uint32_t)got;
		if (NET_UDP_HEADER + length > NET_BUFFER_SIZE - s->rx_size) continue;

		uint8_t* p = s->rx + s->rx_size;
		netcard_put16(p, addr);
		netcard_put16(p + 2, addr >> 16);
		netcard_put16(p + 4, port);
		netcard_put16(p + 6, length);
		memcpy(p + NET_UDP_HEADER, netcard_datagram, length);
		s->rx_size += NET_UDP_HEADER + length;
		s->events |= NET_EVENT_RECEIVED;
	}
}

static void netcard_poll_socket(net_socket_t* s) {
	if (s->state == NET_STATE_CONNECTING) {
		const int connected = network_connected(s->host);
		if (connected > 0) {
			s->state = NET_STATE_CONNECTED;
			s->local_port = network_local_port(s->host);
			s->events |= NET_EVENT_CONNECTED;
		} else if (connected < 0) {
			netcard_close(s);
			s->error = NET_ERROR_NETWORK;
			s->events |= NET_EVENT_CLOSED;
		}
	} else if (s->state == NET_STATE_LISTENING) {
		uint32_t addr = 0;
		uint16_t port = 0;
		const network_socket_t client = network_accept(s->host, &addr, &port);
		if (client != NETWORK_NO_SOCKET) {
			// one connection per LISTEN: the listening socket goes
			network_close(s->host);
			s->host = client;
			s->peer_addr = addr;
			s->peer_port = port;
			s->state = NET_STATE_CONNECTED;
			s->events |= NET_EVENT_CONNECTED;
		}
	}

	if (s->state == NET_STATE_CONNECTED) {
		netcard_flush(s);
		netcard_fill(s);
	} else if (s->state == NET_STATE_UDP) {
		netcard_fill_datagrams(s);
	}
}

static void netcard_dns_finish(netcard_t* net, const uint32_t addr) {
	net->dns_result = addr;
	net->dns_status = NET_DNS_DONE | (addr ? 0 : NET_DNS_FAILED);
}

void netcard_poll(netcard_t* net) {
	if (!net || !net->link) return;
	uint32_t addr = 0;
	if (net->lookup && network_lookup_done(net->lookup, &addr)) {
		network_lookup_free(net->lookup);
		net->lookup = NULL;
		netcard_dns_finish(net, addr);
	}
	for (int i = 0; i < NET_SOCKET_COUNT; i++)
		netcard_poll_socket(&net->socket[i]);
	netcard_update_irq(net);
}

// DNS_COMMAND: reads the name and starts the lookup; without the link or
// a terminator it fails at once.
static void netcard_dns_start(netcard_t* net) {
	if (net->dns_status & NET_DNS_BUSY) return;
	net->dns_result = 0;
	if (!net->link) {
		netcard_dns_finish(net, 0);
		return;
	}
	char name[NET_NAME_SIZE];
	for (uint32_t i = 0; i < NET_NAME_SIZE; i++) {
		uint32_t c = 0;
		if (net->dma.read(net->dma.ctx, net->dns_name + i, 1, &c)) break;
		name[i] = (char)c;
		if (c != 0) continue;
		net->lookup = network_lookup_start(name);
		net->dns_status = NET_DNS_BUSY;
		return;
	}
	netcard_dns_finish(net, 0);
}

// SEND on a UDP socket: one datagram, straight to the host.
static uint32_t netcard_send_datagram(netcard_t* net, net_socket_t* s) {
	if (s->count > NET_DATAGRAM_MAX) return NET_ERROR_LENGTH;
	// the send buffer is free on a UDP socket
	const uint32_t length = s->count;
	for (uint32_t i = 0; i < length; i++) {
		uint32_t byte = 0;
		if (net->dma.read(net->dma.ctx, s->address, 1, &byte))
			return NET_ERROR_ADDRESS;
		s->tx[i] = (uint8_t)byte;
		s->address++;
		s->count--;
	}
	const long sent = network_send_to(
			s->host, s->tx, length, s->peer_addr, (uint16_t)s->peer_port);
	// a datagram the host has no room for is lost, as UDP allows
	return sent == NETWORK_ERROR ? NET_ERROR_NETWORK : NET_ERROR_NONE;
}

static uint32_t netcard_send(netcard_t* net, net_socket_t* s) {
	if (s->state == NET_STATE_UDP) return netcard_send_datagram(net, s);
	if (s->state != NET_STATE_CONNECTED) return NET_ERROR_STATE;
	uint32_t error = NET_ERROR_NONE;
	while (s->count > 0 && s->tx_size < NET_BUFFER_SIZE) {
		uint32_t byte = 0;
		if (net->dma.read(net->dma.ctx, s->address, 1, &byte)) {
			error = NET_ERROR_ADDRESS;
			break;
		}
		s->tx[s->tx_size++] = (uint8_t)byte;
		s->address++;
		s->count--;
	}
	netcard_flush(s); // what has been moved goes out at once
	return error;
}

static uint32_t netcard_receive(netcard_t* net, net_socket_t* s) {
	if (s->state != NET_STATE_CONNECTED && s->state != NET_STATE_PEER_CLOSED
		&& s->state != NET_STATE_UDP)
		return NET_ERROR_STATE;
	uint32_t error = NET_ERROR_NONE;
	uint32_t moved = 0;
	while (s->count > 0 && moved < s->rx_size) {
		if (net->dma.write(net->dma.ctx, s->address, 1, s->rx[moved])) {
			error = NET_ERROR_ADDRESS;
			break;
		}
		moved++;
		s->address++;
		s->count--;
	}
	s->rx_size -= moved;
	memmove(s->rx, s->rx + moved, s->rx_size);
	return error;
}

// Runs a command; returns its error.
static uint32_t netcard_command(netcard_t* net, net_socket_t* s,
								const uint32_t command) {
	if (command == NET_COMMAND_CLOSE) {
		netcard_close(s);
		s->events = 0;
		return NET_ERROR_NONE;
	}
	if (command < NET_COMMAND_CONNECT || command > NET_COMMAND_CLOSE)
		return NET_ERROR_COMMAND;
	if (!net->link) return NET_ERROR_LINK;

	switch (command) {
		case NET_COMMAND_CONNECT: {
			if (s->state != NET_STATE_CLOSED) return NET_ERROR_STATE;
			bool pending = false;
			s->host =
				network_connect(s->peer_addr, (uint16_t)s->peer_port, &pending);
			// refused at once (as on a loopback): the same as refused later
			if (s->host == NETWORK_NO_SOCKET) {
				s->events |= NET_EVENT_CLOSED;
				return NET_ERROR_NETWORK;
			}
			// even a connection made at once is reported by the next poll
			s->state = NET_STATE_CONNECTING;
			return NET_ERROR_NONE;
		}
		case NET_COMMAND_LISTEN:
			if (s->state != NET_STATE_CLOSED) return NET_ERROR_STATE;
			if (!network_can_listen()) return NET_ERROR_UNSUPPORTED;
			s->host = network_listen(net->local_addr, (uint16_t)s->local_port);
			if (s->host == NETWORK_NO_SOCKET) return NET_ERROR_NETWORK;
			s->local_port = network_local_port(s->host);
			s->state = NET_STATE_LISTENING;
			return NET_ERROR_NONE;
		case NET_COMMAND_UDP: {
			if (s->state != NET_STATE_CLOSED) return NET_ERROR_STATE;
			if (!network_can_udp()) return NET_ERROR_UNSUPPORTED;
			// a client's socket takes replies on any address, a server's
			// listens where LISTEN does
			const uint32_t local = s->local_port ? net->local_addr : 0;
			s->host = network_udp(local, (uint16_t)s->local_port);
			if (s->host == NETWORK_NO_SOCKET) return NET_ERROR_NETWORK;
			s->local_port = network_local_port(s->host);
			s->state = NET_STATE_UDP;
			return NET_ERROR_NONE;
		}
		case NET_COMMAND_SEND:
			return netcard_send(net, s);
		case NET_COMMAND_RECEIVE:
			return netcard_receive(net, s);
	}
	return NET_ERROR_COMMAND;
}

// The socket that offset falls in, with offset made relative to it; NULL
// if it is outside the sockets.
static net_socket_t* netcard_find_socket(netcard_t* net, const uint32_t offset,
										 uint32_t* reg) {
	if (offset < NET_REG_SOCKET0) return NULL;
	const uint32_t index = (offset - NET_REG_SOCKET0) / NET_SOCKET_SIZE;
	if (index >= NET_SOCKET_COUNT) return NULL;
	*reg = (offset - NET_REG_SOCKET0) % NET_SOCKET_SIZE;
	return &net->socket[index];
}

static bool netcard_socket_read(const net_socket_t* s, const uint32_t reg,
								uint32_t* value) {
	switch (reg) {
		case NET_SOCKET_STATE:
			*value = s->state;
			return false;
		case NET_SOCKET_COMMAND:
			*value = 0; // write-only
			return false;
		case NET_SOCKET_ERROR:
			*value = s->error;
			return false;
		case NET_SOCKET_EVENTS:
			*value = s->events;
			return false;
		case NET_SOCKET_IRQ_MASK:
			*value = s->irq_mask;
			return false;
		case NET_SOCKET_LOCAL_PORT:
			*value = s->local_port;
			return false;
		case NET_SOCKET_PEER_ADDR:
			*value = s->peer_addr;
			return false;
		case NET_SOCKET_PEER_PORT:
			*value = s->peer_port;
			return false;
		case NET_SOCKET_ADDRESS:
			*value = s->address;
			return false;
		case NET_SOCKET_COUNT_REG:
			*value = s->count;
			return false;
		case NET_SOCKET_RX_SIZE:
			*value = s->rx_size;
			return false;
		case NET_SOCKET_TX_FREE:
			*value = NET_BUFFER_SIZE - s->tx_size;
			return false;
	}
	return true;
}

static bool netcard_socket_write(netcard_t* net, net_socket_t* s,
								 const uint32_t reg, const uint32_t value) {
	switch (reg) {
		case NET_SOCKET_STATE:
		case NET_SOCKET_ERROR:
		case NET_SOCKET_RX_SIZE:
		case NET_SOCKET_TX_FREE:
			return false; // read-only, writes are ignored
		case NET_SOCKET_COMMAND:
			s->error = NET_ERROR_NONE;
			s->error = netcard_command(net, s, value);
			return false;
		case NET_SOCKET_EVENTS:
			s->events &= ~value;
			return false;
		case NET_SOCKET_IRQ_MASK:
			s->irq_mask = value & NET_EVENT_MASK;
			return false;
		case NET_SOCKET_LOCAL_PORT:
			s->local_port = value & NET_PORT_MASK;
			return false;
		case NET_SOCKET_PEER_ADDR:
			s->peer_addr = value;
			return false;
		case NET_SOCKET_PEER_PORT:
			s->peer_port = value & NET_PORT_MASK;
			return false;
		case NET_SOCKET_ADDRESS:
			s->address = value;
			return false;
		case NET_SOCKET_COUNT_REG:
			s->count = value;
			return false;
	}
	return true;
}

bool netcard_read(netcard_t* net, const uint32_t offset, const uint8_t size,
				  uint32_t* value) {
	(void)size; // narrower loads get the low bits
	uint32_t reg = 0;
	const net_socket_t* s = netcard_find_socket(net, offset, &reg);
	if (s) return netcard_socket_read(s, reg, value);
	switch (offset) {
		case NET_REG_STATUS:
			*value = 0;
			if (net->link) {
				*value |= NET_STATUS_LINK;
				if (network_can_listen()) *value |= NET_STATUS_LISTEN;
				if (network_can_udp()) *value |= NET_STATUS_UDP;
			}
			return false;
		case NET_REG_PENDING:
			*value = netcard_pending(net);
			return false;
		case NET_REG_SOCKETS:
			*value = NET_SOCKET_COUNT;
			return false;
		case NET_REG_DNS_COMMAND:
			*value = 0; // write-only
			return false;
		case NET_REG_DNS_STATUS:
			*value = net->dns_status;
			return false;
		case NET_REG_DNS_CONTROL:
			*value = net->dns_control;
			return false;
		case NET_REG_DNS_NAME:
			*value = net->dns_name;
			return false;
		case NET_REG_DNS_RESULT:
			*value = net->dns_result;
			return false;
	}
	return true;
}

bool netcard_write(netcard_t* net, const uint32_t offset, const uint8_t size,
				   const uint32_t value) {
	(void)size;
	uint32_t reg = 0;
	net_socket_t* s = netcard_find_socket(net, offset, &reg);
	if (s) {
		const bool fail = netcard_socket_write(net, s, reg, value);
		netcard_update_irq(net);
		return fail;
	}
	switch (offset) {
		case NET_REG_STATUS:
		case NET_REG_PENDING:
		case NET_REG_SOCKETS:
		case NET_REG_DNS_RESULT:
			return false; // read-only, writes are ignored
		case NET_REG_DNS_COMMAND:
			if (value == NET_DNS_LOOKUP) netcard_dns_start(net);
			netcard_update_irq(net);
			return false;
		case NET_REG_DNS_STATUS:
			if (value & NET_DNS_DONE) net->dns_status &= ~NET_DNS_DONE;
			netcard_update_irq(net);
			return false;
		case NET_REG_DNS_CONTROL:
			net->dns_control = value & NET_DNS_CONTROL_IRQ;
			netcard_update_irq(net);
			return false;
		case NET_REG_DNS_NAME:
			net->dns_name = value;
			return false;
	}
	return true;
}
