#include "nat.h"

#include <string.h>

#include "network.h"

// Numbers in packets are big-endian. Checksums are the internet checksum
// (RFC 1071); the guest's are not checked, as a link with no errors can't
// spoil them.

#define ETH_HEADER 14
#define ETH_TYPE_IP 0x0800
#define ETH_TYPE_ARP 0x0806
#define IP_HEADER 20
#define IP_PAYLOAD (ETH_HEADER + IP_HEADER) // where an IP payload starts
#define IP_MAX 1500 // the IP packet in a frame
#define IP_ICMP 1
#define IP_TCP 6
#define IP_UDP 17
#define IP_LOOPBACK 0x7F000001
#define IP_BROADCAST 0xFFFFFFFF
#define UDP_HEADER 8
#define ICMP_HEADER 8
#define ICMP_ECHO_REPLY 0
#define ICMP_ECHO_REQUEST 8

#define TCP_HEADER 20
#define TCP_FIN 0x01
#define TCP_SYN 0x02
#define TCP_RST 0x04
#define TCP_PSH 0x08
#define TCP_ACK 0x10
#define TCP_OPTION_MSS 2

#define DHCP_SERVER_PORT 67
#define DHCP_CLIENT_PORT 68
#define DHCP_MAGIC 0x63825363
#define DHCP_OPTIONS 240 // where the options start
#define DHCP_MIN 300 // BOOTP's smallest message
#define DHCP_DISCOVER 1
#define DHCP_OFFER 2
#define DHCP_REQUEST 3
#define DHCP_ACK 5
#define DHCP_NAK 6
#define DHCP_LEASE 86400 // seconds

#define DNS_PORT 53
#define DNS_HEADER 12
#define DNS_TYPE_A 1
#define DNS_CLASS_IN 1
#define DNS_QUESTION_MAX 260 // a name of up to 255 bytes, type and class
#define DNS_TTL 60
#define DNS_NXDOMAIN 3
#define DNS_SERVFAIL 2

#define NAT_TCP_COUNT 32 // connections
#define NAT_TCP_BUFFER 32768 // each way, per connection
#define NAT_MSS 1460 // what the gateway takes
#define NAT_MSS_DEFAULT 536 // what the guest takes if it doesn't say
#define NAT_RTO 200 // ms before a retransmission, doubled each time
#define NAT_RTO_MAX 8000
#define NAT_RETRIES 10 // ... before the connection is given up
#define NAT_QUEUE_RESERVE 8 // queue slots TCP data leaves to the rest
#define NAT_UDP_COUNT 16 // the guest's ports with a host socket
#define NAT_UDP_IDLE 60000 // ms before an unused one is closed
#define NAT_PING_COUNT 8 // echo requests waiting for their reply
#define NAT_PING_TIMEOUT 5000 // ms
#define NAT_DNS_COUNT 16 // queries waiting for their lookup
#define NAT_PORT_FIRST 49152 // the gateway's ports for forwarded connections

static const uint8_t nat_gateway_mac[6] = { 0x52, 0x55, 0x0A, 0x00, 0x02, 0x02 };
static const uint8_t nat_broadcast_mac[6] = { 0xFF, 0xFF, 0xFF,
											  0xFF, 0xFF, 0xFF };

// One datagram at a time from the host: the largest UDP can carry
static uint8_t nat_datagram[65536];

typedef struct nat_frame {
	uint16_t length;
	uint8_t data[NAT_FRAME_MAX];
} nat_frame_t;

typedef enum nat_tcp_state {
	NAT_TCP_CONNECTING, // the guest's SYN came, the host connects
	NAT_TCP_ACCEPTING, // SYN-ACK sent, the guest's ACK to come
	NAT_TCP_OPENING, // a forwarded connection: SYN sent to the guest
	NAT_TCP_OPEN,
} nat_tcp_state_t;

// A TCP connection of the guest's, the gateway's end of it. The data the
// guest is sent starts at snd_una in out; snd_nxt is the next byte to
// send, snd_max the highest sent so far (a retransmission goes back).
typedef struct nat_tcp {
	nat_tcp_state_t state;
	uint16_t guest_port;
	uint32_t remote_addr; // as the guest sees the other end
	uint16_t remote_port;
	network_socket_t host;
	uint32_t isn; // the gateway's first sequence number
	uint32_t snd_una;
	uint32_t snd_nxt;
	uint32_t snd_max;
	uint32_t snd_wnd; // the guest's window
	uint32_t mss; // the guest's
	uint32_t rcv_nxt; // the guest's next byte
	uint32_t window_sent; // the window the last segment advertised
	bool host_eof; // the host's end has closed: FIN after the data
	bool fin_sent;
	bool fin_acked;
	bool guest_fin; // the guest has closed its end
	bool shut; // ... and so has the gateway towards the host
	uint64_t timer; // when to retransmit, 0 = off
	uint32_t rto;
	int retries;
	uint8_t out[NAT_TCP_BUFFER]; // to the guest
	uint32_t out_size;
	uint8_t in[NAT_TCP_BUFFER]; // to the host
	uint32_t in_size;
} nat_tcp_t;

typedef struct nat_udp {
	bool used;
	uint16_t guest_port;
	network_socket_t host;
	uint64_t last; // when it was last used
} nat_udp_t;

typedef struct nat_ping {
	bool used;
	network_socket_t host;
	uint32_t addr; // where the guest pings
	uint16_t id; // the guest's identifier and sequence number
	uint16_t seq;
	uint64_t sent;
} nat_ping_t;

typedef struct nat_dns {
	bool used;
	uint16_t guest_port;
	uint16_t id;
	uint16_t flags; // of the query
	uint8_t question[DNS_QUESTION_MAX];
	uint32_t question_size;
	network_lookup_t* lookup;
} nat_dns_t;

struct nat {
	const net_policy_t* policy;
	uint8_t mac[6]; // the guest's
	nat_frame_t queue[NAT_QUEUE_SIZE];
	uint32_t head;
	uint32_t count;
	uint64_t lost;
	uint16_t ip_id; // of the next packet
	uint32_t next_isn;
	uint16_t next_port;
	nat_tcp_t* tcp[NAT_TCP_COUNT];
	nat_udp_t udp[NAT_UDP_COUNT];
	nat_ping_t ping[NAT_PING_COUNT];
	nat_dns_t dns[NAT_DNS_COUNT];
	// the forwarded ports: TCP listening, UDP bound to the host's port
	network_socket_t listener[NET_FORWARD_MAX];
	network_socket_t udp_listener[NET_FORWARD_MAX];
	bool listening;
};

// ---- bytes and checksums ------------------------------------------------------

static uint32_t get16(const uint8_t* p) {
	return (uint32_t)p[0] << 8 | p[1];
}

static uint32_t get32(const uint8_t* p) {
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8
		 | p[3];
}

static void put16(uint8_t* p, const uint32_t value) {
	p[0] = (value >> 8) & 0xFF;
	p[1] = value & 0xFF;
}

static void put32(uint8_t* p, const uint32_t value) {
	put16(p, value >> 16);
	put16(p + 2, value);
}

static uint32_t nat_sum(const uint8_t* data, const size_t length,
						uint32_t sum) {
	for (size_t i = 0; i + 1 < length; i += 2) sum += get16(data + i);
	if (length & 1) sum += (uint32_t)data[length - 1] << 8;
	return sum;
}

static uint32_t nat_checksum(uint32_t sum) {
	while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
	return ~sum & 0xFFFF;
}

// The sum of the pseudo header TCP and UDP checksums cover.
static uint32_t nat_pseudo_sum(const uint32_t src, const uint32_t dst,
							   const uint8_t protocol, const size_t length) {
	return (src >> 16) + (src & 0xFFFF) + (dst >> 16) + (dst & 0xFFFF)
		 + protocol + (uint32_t)length;
}

// a < b in sequence space
static bool seq_lt(const uint32_t a, const uint32_t b) {
	return (int32_t)(a - b) < 0;
}

static bool seq_le(const uint32_t a, const uint32_t b) {
	return (int32_t)(a - b) <= 0;
}

static uint32_t min32(const uint32_t a, const uint32_t b) {
	return a < b ? a : b;
}

// ---- frames to the guest ------------------------------------------------------

static uint32_t nat_queue_free(const nat_t* nat) {
	return NAT_QUEUE_SIZE - nat->count;
}

// A frame to fill at the end of the queue, NULL if the queue is full (the
// frame is lost).
static uint8_t* nat_begin(nat_t* nat) {
	if (nat->count == NAT_QUEUE_SIZE) {
		nat->lost++;
		return NULL;
	}
	return nat->queue[(nat->head + nat->count) % NAT_QUEUE_SIZE].data;
}

static void nat_commit(nat_t* nat, const size_t length) {
	nat->queue[(nat->head + nat->count) % NAT_QUEUE_SIZE].length =
		(uint16_t)length;
	nat->count++;
}

static void nat_ethernet(const nat_t* nat, uint8_t* frame, const bool broadcast,
						 const uint32_t type) {
	memcpy(frame, broadcast ? nat_broadcast_mac : nat->mac, 6);
	memcpy(frame + 6, nat_gateway_mac, 6);
	put16(frame + 12, type);
}

// Writes the Ethernet and IP headers of a frame whose payload is in
// place, and queues it.
static void nat_send_ip(nat_t* nat, uint8_t* frame, const uint8_t protocol,
						const uint32_t src, const uint32_t dst,
						const size_t payload) {
	nat_ethernet(nat, frame, dst == IP_BROADCAST, ETH_TYPE_IP);
	uint8_t* ip = frame + ETH_HEADER;
	ip[0] = 0x45; // version 4, a 20-byte header
	ip[1] = 0;
	put16(ip + 2, IP_HEADER + payload);
	put16(ip + 4, nat->ip_id++);
	put16(ip + 6, 0x4000); // don't fragment
	ip[8] = 64; // TTL
	ip[9] = protocol;
	put16(ip + 10, 0);
	put32(ip + 12, src);
	put32(ip + 16, dst);
	put16(ip + 10, nat_checksum(nat_sum(ip, IP_HEADER, 0)));
	nat_commit(nat, IP_PAYLOAD + payload);
}

static void nat_send_udp(nat_t* nat, const uint32_t src, const uint16_t sport,
						 const uint32_t dst, const uint16_t dport,
						 const uint8_t* data, const size_t length) {
	if (length > IP_MAX - IP_HEADER - UDP_HEADER) return;
	uint8_t* frame = nat_begin(nat);
	if (!frame) return;
	uint8_t* udp = frame + IP_PAYLOAD;
	const size_t size = UDP_HEADER + length;
	put16(udp, sport);
	put16(udp + 2, dport);
	put16(udp + 4, size);
	put16(udp + 6, 0);
	memcpy(udp + UDP_HEADER, data, length);
	const uint32_t sum =
		nat_checksum(nat_sum(udp, size, nat_pseudo_sum(src, dst, IP_UDP, size)));
	put16(udp + 6, sum ? sum : 0xFFFF); // 0 would mean none
	nat_send_ip(nat, frame, IP_UDP, src, dst, size);
}

// A TCP segment from src:sport to the guest's dport. A SYN carries the
// gateway's MSS; ack only goes out with TCP_ACK.
static void nat_send_segment(nat_t* nat, const uint32_t src,
							 const uint16_t sport, const uint16_t dport,
							 const uint32_t seq, const uint32_t ack,
							 const uint8_t flags, const uint32_t window,
							 const uint8_t* data, const size_t length) {
	uint8_t* frame = nat_begin(nat);
	if (!frame) return;
	uint8_t* tcp = frame + IP_PAYLOAD;
	const size_t header = TCP_HEADER + ((flags & TCP_SYN) ? 4 : 0);
	const size_t size = header + length;
	put16(tcp, sport);
	put16(tcp + 2, dport);
	put32(tcp + 4, seq);
	put32(tcp + 8, (flags & TCP_ACK) ? ack : 0);
	tcp[12] = (uint8_t)(header / 4) << 4;
	tcp[13] = flags;
	put16(tcp + 14, window > 0xFFFF ? 0xFFFF : window);
	put16(tcp + 16, 0);
	put16(tcp + 18, 0);
	if (flags & TCP_SYN) {
		tcp[20] = TCP_OPTION_MSS;
		tcp[21] = 4;
		put16(tcp + 22, NAT_MSS);
	}
	if (length) memcpy(tcp + header, data, length);
	put16(tcp + 16,
		  nat_checksum(nat_sum(
			  tcp, size, nat_pseudo_sum(src, NAT_GUEST, IP_TCP, size))));
	nat_send_ip(nat, frame, IP_TCP, src, NAT_GUEST, size);
}

// ---- TCP ----------------------------------------------------------------------

static uint32_t nat_tcp_window(const nat_tcp_t* c) {
	return NAT_TCP_BUFFER - c->in_size;
}

static void nat_tcp_send(nat_t* nat, nat_tcp_t* c, const uint32_t seq,
						 const uint8_t flags, const uint8_t* data,
						 const uint32_t length) {
	c->window_sent = nat_tcp_window(c);
	nat_send_segment(nat,
					 c->remote_addr,
					 c->remote_port,
					 c->guest_port,
					 seq,
					 c->rcv_nxt,
					 flags,
					 c->window_sent,
					 data,
					 length);
	const uint32_t end =
		seq + length + ((flags & (TCP_SYN | TCP_FIN)) ? 1 : 0);
	if (seq_lt(c->snd_max, end)) c->snd_max = end;
}

static void nat_tcp_ack(nat_t* nat, nat_tcp_t* c) {
	nat_tcp_send(nat, c, c->snd_nxt, TCP_ACK, NULL, 0);
}

// Ends the connection: the guest gets a reset if rst, the host's socket is
// closed.
static void nat_tcp_free(nat_t* nat, const int index, const bool rst) {
	nat_tcp_t* c = nat->tcp[index];
	if (rst) nat_tcp_send(nat, c, c->snd_nxt, TCP_RST | TCP_ACK, NULL, 0);
	network_close(c->host);
	free(c);
	nat->tcp[index] = NULL;
}

static void nat_tcp_arm(nat_tcp_t* c, const uint64_t now) {
	if (!c->timer) c->timer = now + c->rto;
}

// Sends what the guest's window takes of the data, then the FIN once the
// host's end has closed and all of it is out.
static void nat_tcp_output(nat_t* nat, nat_tcp_t* c, const uint64_t now) {
	if (c->state != NAT_TCP_OPEN || c->fin_sent) return;
	while (true) {
		const uint32_t sent = c->snd_nxt - c->snd_una;
		const uint32_t unsent = c->out_size - sent;
		const int32_t room = (int32_t)(c->snd_una + c->snd_wnd - c->snd_nxt);
		if (unsent > 0 && room > 0) {
			if (nat_queue_free(nat) <= NAT_QUEUE_RESERVE) return;
			const uint32_t length =
				min32(min32(unsent, (uint32_t)room), c->mss);
			nat_tcp_send(
				nat, c, c->snd_nxt, TCP_ACK | TCP_PSH, c->out + sent, length);
			c->snd_nxt += length;
			nat_tcp_arm(c, now);
			continue;
		}
		if (unsent > 0) { // the window is shut: probe it later
			nat_tcp_arm(c, now);
			return;
		}
		if (c->host_eof) {
			nat_tcp_send(nat, c, c->snd_nxt, TCP_ACK | TCP_FIN, NULL, 0);
			c->snd_nxt++;
			c->fin_sent = true;
			nat_tcp_arm(c, now);
		}
		return;
	}
}

// Writes what the host takes of the guest's data. Returns false if the
// connection broke.
static bool nat_tcp_flush(nat_t* nat, nat_tcp_t* c) {
	if (c->in_size > 0) {
		const long sent = network_send(c->host, c->in, c->in_size);
		if (sent < 0 && sent != NETWORK_WOULD_BLOCK) return false;
		if (sent > 0) {
			c->in_size -= (uint32_t)sent;
			memmove(c->in, c->in + sent, c->in_size);
			// the window opens again: say so if it was nearly shut
			if (c->window_sent < c->mss && nat_tcp_window(c) >= c->mss)
				nat_tcp_ack(nat, c);
		}
	}
	// the guest's end has closed and all of it is with the host
	if (c->guest_fin && c->in_size == 0 && !c->shut) {
		network_shutdown(c->host);
		c->shut = true;
	}
	return true;
}

// Reads what fits from the host. Returns false if the connection broke.
static bool nat_tcp_fill(nat_tcp_t* c) {
	while (!c->host_eof && c->out_size < NAT_TCP_BUFFER) {
		const long got = network_receive(
			c->host, c->out + c->out_size, NAT_TCP_BUFFER - c->out_size);
		if (got == NETWORK_WOULD_BLOCK) break;
		if (got == NETWORK_EOF) {
			c->host_eof = true;
			break;
		}
		if (got < 0) return false;
		c->out_size += (uint32_t)got;
	}
	return true;
}

static void nat_tcp_timeout(nat_t* nat, const int index, const uint64_t now) {
	nat_tcp_t* c = nat->tcp[index];
	c->timer = 0;
	if (++c->retries > NAT_RETRIES) {
		nat_tcp_free(nat, index, true);
		return;
	}
	c->rto = min32(c->rto * 2, NAT_RTO_MAX);
	switch (c->state) {
		case NAT_TCP_ACCEPTING:
			nat_tcp_send(nat, c, c->isn, TCP_SYN | TCP_ACK, NULL, 0);
			nat_tcp_arm(c, now);
			return;
		case NAT_TCP_OPENING:
			nat_tcp_send(nat, c, c->isn, TCP_SYN, NULL, 0);
			nat_tcp_arm(c, now);
			return;
		case NAT_TCP_OPEN:
			break;
		default:
			return;
	}
	// go back to the first byte not acknowledged
	c->snd_nxt = c->snd_una;
	c->fin_sent = false;
	if (c->snd_wnd == 0 && c->out_size > 0) {
		// a shut window: one byte to make the guest say when it opens
		nat_tcp_send(nat, c, c->snd_una, TCP_ACK, c->out, 1);
		c->snd_nxt = c->snd_una + 1;
		nat_tcp_arm(c, now);
		return;
	}
	nat_tcp_output(nat, c, now);
}

static void nat_tcp_poll(nat_t* nat, const int index, const uint64_t now) {
	nat_tcp_t* c = nat->tcp[index];
	if (c->state == NAT_TCP_CONNECTING) {
		const int connected = network_connected(c->host);
		if (connected < 0) {
			// refused: as the host would answer the SYN
			nat_send_segment(nat,
							 c->remote_addr,
							 c->remote_port,
							 c->guest_port,
							 0,
							 c->rcv_nxt,
							 TCP_RST | TCP_ACK,
							 0,
							 NULL,
							 0);
			network_close(c->host);
			free(c);
			nat->tcp[index] = NULL;
			return;
		}
		if (connected == 0) return;
		c->state = NAT_TCP_ACCEPTING;
		nat_tcp_send(nat, c, c->isn, TCP_SYN | TCP_ACK, NULL, 0);
		c->snd_nxt = c->isn + 1;
		nat_tcp_arm(c, now);
		return;
	}
	if (c->state == NAT_TCP_OPEN) {
		if (!nat_tcp_flush(nat, c) || !nat_tcp_fill(c)) {
			nat_tcp_free(nat, index, true);
			return;
		}
		nat_tcp_output(nat, c, now);
		if (c->fin_acked && c->guest_fin && c->in_size == 0) {
			nat_tcp_free(nat, index, false); // closed both ways
			return;
		}
	}
	if (c->timer && now >= c->timer) nat_tcp_timeout(nat, index, now);
}

static int nat_tcp_find(const nat_t* nat, const uint16_t guest_port,
						const uint32_t remote_addr, const uint16_t remote_port) {
	for (int i = 0; i < NAT_TCP_COUNT; i++) {
		const nat_tcp_t* c = nat->tcp[i];
		if (c && c->guest_port == guest_port && c->remote_addr == remote_addr
			&& c->remote_port == remote_port)
			return i;
	}
	return -1;
}

static int nat_tcp_slot(const nat_t* nat) {
	for (int i = 0; i < NAT_TCP_COUNT; i++)
		if (!nat->tcp[i]) return i;
	return -1;
}

static nat_tcp_t* nat_tcp_new(nat_t* nat, const int index) {
	nat_tcp_t* c = calloc(1, sizeof(nat_tcp_t));
	if (!c) error("Failed to allocate a TCP connection!");
	c->isn = nat->next_isn;
	nat->next_isn += 0x01000193; // apart, and the same on every run
	c->snd_una = c->snd_nxt = c->snd_max = c->isn;
	c->mss = NAT_MSS_DEFAULT;
	c->rto = NAT_RTO;
	nat->tcp[index] = c;
	return c;
}

// The guest's MSS from the options of its SYN, if it gives one.
static void nat_tcp_options(nat_tcp_t* c, const uint8_t* tcp,
							const size_t header) {
	for (size_t i = TCP_HEADER; i < header;) {
		const uint8_t kind = tcp[i];
		if (kind == 0) break;
		if (kind == 1) {
			i++;
			continue;
		}
		if (i + 1 >= header || tcp[i + 1] < 2 || i + tcp[i + 1] > header)
			break;
		if (kind == TCP_OPTION_MSS && tcp[i + 1] == 4) {
			const uint32_t mss = get16(tcp + i + 2);
			if (mss >= 64) c->mss = min32(mss, NAT_MSS);
		}
		i += tcp[i + 1];
	}
}

// Where the guest's packets to addr really go: the gateway is the host.
static uint32_t nat_host_addr(const uint32_t addr) {
	return addr == NAT_GATEWAY ? IP_LOOPBACK : addr;
}

// Whether addr is the virtual network's but not the gateway: nothing is
// there for the guest to reach.
static bool nat_is_local(const uint32_t addr) {
	return (addr & NAT_NETMASK) == NAT_NETWORK && addr != NAT_GATEWAY;
}

// A segment of the guest's with no connection (or one refused): a reset,
// unless it is one.
static void nat_tcp_refuse(nat_t* nat, const uint32_t dst, const uint16_t dport,
						   const uint16_t sport, const uint32_t seq,
						   const uint32_t ack, const uint8_t flags,
						   const size_t length) {
	if (flags & TCP_RST) return;
	const uint32_t end =
		seq + (uint32_t)length + ((flags & TCP_SYN) ? 1 : 0)
		+ ((flags & TCP_FIN) ? 1 : 0);
	if (flags & TCP_ACK)
		nat_send_segment(
			nat, dst, dport, sport, ack, 0, TCP_RST, 0, NULL, 0);
	else
		nat_send_segment(
			nat, dst, dport, sport, 0, end, TCP_RST | TCP_ACK, 0, NULL, 0);
}

// The guest opens a connection: the host connects first, the SYN-ACK
// comes once it has.
static void nat_tcp_open(nat_t* nat, const uint32_t dst, const uint16_t dport,
						 const uint16_t sport, const uint8_t* tcp,
						 const size_t header) {
	const uint32_t seq = get32(tcp + 4);
	const uint32_t host_addr = nat_host_addr(dst);
	const int index = nat_tcp_slot(nat);
	if (nat_is_local(dst) || index < 0
		|| !net_policy_allows(nat->policy, host_addr, dport)) {
		nat_tcp_refuse(nat, dst, dport, sport, seq, 0, TCP_SYN, 0);
		return;
	}
	bool pending = false;
	const network_socket_t host = network_connect(host_addr, dport, &pending);
	if (host == NETWORK_NO_SOCKET) {
		nat_tcp_refuse(nat, dst, dport, sport, seq, 0, TCP_SYN, 0);
		return;
	}
	nat_tcp_t* c = nat_tcp_new(nat, index);
	c->state = NAT_TCP_CONNECTING;
	c->guest_port = sport;
	c->remote_addr = dst;
	c->remote_port = dport;
	c->host = host;
	c->rcv_nxt = seq + 1;
	c->snd_wnd = get16(tcp + 14);
	nat_tcp_options(c, tcp, header);
}

static void nat_tcp_input(nat_t* nat, const uint32_t dst, const uint8_t* tcp,
						  const size_t size, const uint64_t now) {
	if (size < TCP_HEADER) return;
	const size_t header = (size_t)(tcp[12] >> 4) * 4;
	if (header < TCP_HEADER || header > size) return;
	const uint16_t sport = (uint16_t)get16(tcp);
	const uint16_t dport = (uint16_t)get16(tcp + 2);
	const uint32_t seq = get32(tcp + 4);
	const uint32_t ack = get32(tcp + 8);
	const uint8_t flags = tcp[13];
	const uint8_t* data = tcp + header;
	size_t length = size - header;

	const int index = nat_tcp_find(nat, sport, dst, dport);
	if (index < 0) {
		if ((flags & (TCP_SYN | TCP_ACK | TCP_RST)) == TCP_SYN)
			nat_tcp_open(nat, dst, dport, sport, tcp, header);
		else
			nat_tcp_refuse(nat, dst, dport, sport, seq, ack, flags, length);
		return;
	}
	nat_tcp_t* c = nat->tcp[index];
	if (flags & TCP_RST) {
		nat_tcp_free(nat, index, false);
		return;
	}

	switch (c->state) {
		case NAT_TCP_CONNECTING: // the SYN again: the answer is to come
			return;
		case NAT_TCP_OPENING:
			if ((flags & (TCP_SYN | TCP_ACK)) != (TCP_SYN | TCP_ACK)
				|| ack != c->isn + 1)
				return;
			c->rcv_nxt = seq + 1;
			c->snd_una = c->snd_nxt = c->isn + 1;
			c->snd_wnd = get16(tcp + 14);
			nat_tcp_options(c, tcp, header);
			c->state = NAT_TCP_OPEN;
			c->timer = 0;
			c->retries = 0;
			c->rto = NAT_RTO;
			nat_tcp_ack(nat, c);
			return;
		case NAT_TCP_ACCEPTING:
			if (flags & TCP_SYN) { // the SYN-ACK got lost
				nat_tcp_send(nat, c, c->isn, TCP_SYN | TCP_ACK, NULL, 0);
				return;
			}
			if (!(flags & TCP_ACK) || ack != c->isn + 1) return;
			c->state = NAT_TCP_OPEN;
			c->snd_una = c->isn + 1;
			c->timer = 0;
			c->retries = 0;
			c->rto = NAT_RTO;
			break; // the ACK may carry data
		case NAT_TCP_OPEN:
			if (flags & TCP_SYN) { // our ACK of its SYN-ACK got lost
				nat_tcp_ack(nat, c);
				return;
			}
			break;
	}

	// what the guest acknowledges
	if (flags & TCP_ACK) {
		c->retries = 0;
		if (seq_lt(c->snd_una, ack) && seq_le(ack, c->snd_max)) {
			uint32_t acked = ack - c->snd_una;
			if (acked > c->out_size) { // the FIN too
				c->fin_acked = true;
				acked = c->out_size;
			}
			c->out_size -= acked;
			memmove(c->out, c->out + acked, c->out_size);
			c->snd_una = ack;
			if (seq_lt(c->snd_nxt, c->snd_una)) c->snd_nxt = c->snd_una;
			c->rto = NAT_RTO;
			c->timer = c->snd_una != c->snd_max ? now + c->rto : 0;
		}
		c->snd_wnd = get16(tcp + 14);
	}

	// what the guest sends: in order only, as much as the buffer takes
	bool fin = flags & TCP_FIN;
	if (length > 0 || fin) {
		if (seq_le(seq, c->rcv_nxt) && !c->guest_fin) {
			const uint32_t skip = c->rcv_nxt - seq;
			if (skip <= length) {
				data += skip;
				length -= skip;
				const uint32_t take =
					min32((uint32_t)length, NAT_TCP_BUFFER - c->in_size);
				memcpy(c->in + c->in_size, data, take);
				c->in_size += take;
				c->rcv_nxt += take;
				if (fin && take == length) {
					c->guest_fin = true;
					c->rcv_nxt++;
				}
			}
		}
		nat_tcp_ack(nat, c);
		if (!nat_tcp_flush(nat, c)) {
			nat_tcp_free(nat, index, true);
			return;
		}
	}
	nat_tcp_output(nat, c, now);
	if (c->fin_acked && c->guest_fin && c->in_size == 0)
		nat_tcp_free(nat, index, false);
}

// A connection to a forwarded host port: the gateway opens one to the
// guest's port, from one of its own.
static void nat_tcp_accept(nat_t* nat, const network_socket_t host,
						   const uint16_t guest_port, const uint64_t now) {
	const int index = nat_tcp_slot(nat);
	if (index < 0) {
		network_close(host);
		return;
	}
	nat_tcp_t* c = nat_tcp_new(nat, index);
	c->state = NAT_TCP_OPENING;
	c->guest_port = guest_port;
	c->remote_addr = NAT_GATEWAY;
	c->remote_port = nat->next_port;
	nat->next_port = nat->next_port == 0xFFFF ? NAT_PORT_FIRST
											  : nat->next_port + 1;
	c->host = host;
	nat_tcp_send(nat, c, c->isn, TCP_SYN, NULL, 0);
	c->snd_nxt = c->isn + 1;
	nat_tcp_arm(c, now);
}

// ---- UDP, DHCP and DNS ----------------------------------------------------------

static void nat_dhcp_option(uint8_t** p, const uint8_t code,
							const uint8_t length, const uint32_t value) {
	*(*p)++ = code;
	*(*p)++ = length;
	if (length == 1) {
		*(*p)++ = (uint8_t)value;
	} else {
		put32(*p, value);
		*p += 4;
	}
}

static void nat_dhcp(nat_t* nat, const uint8_t* msg, const size_t size) {
	if (size < DHCP_OPTIONS || msg[0] != 1 || get32(msg + 236) != DHCP_MAGIC)
		return;
	uint8_t type = 0;
	uint32_t requested = 0;
	for (size_t i = DHCP_OPTIONS; i < size;) {
		const uint8_t code = msg[i];
		if (code == 255) break;
		if (code == 0) {
			i++;
			continue;
		}
		if (i + 1 >= size || i + 2 + msg[i + 1] > size) break;
		const uint8_t length = msg[i + 1];
		if (code == 53 && length == 1) type = msg[i + 2];
		if (code == 50 && length == 4) requested = get32(msg + i + 2);
		i += 2 + length;
	}
	if (!requested) requested = get32(msg + 12); // ciaddr
	uint8_t reply_type;
	if (type == DHCP_DISCOVER)
		reply_type = DHCP_OFFER;
	else if (type == DHCP_REQUEST)
		reply_type =
			requested && requested != NAT_GUEST ? DHCP_NAK : DHCP_ACK;
	else
		return; // RELEASE, DECLINE, INFORM: nothing to say

	uint8_t reply[DHCP_MIN];
	memset(reply, 0, sizeof(reply));
	reply[0] = 2; // a reply
	reply[1] = 1; // Ethernet
	reply[2] = 6;
	memcpy(reply + 4, msg + 4, 4); // xid
	memcpy(reply + 10, msg + 10, 2); // flags
	if (reply_type != DHCP_NAK) {
		put32(reply + 16, NAT_GUEST); // yiaddr
		put32(reply + 20, NAT_GATEWAY); // siaddr
	}
	memcpy(reply + 28, msg + 28, 16); // chaddr
	put32(reply + 236, DHCP_MAGIC);
	uint8_t* p = reply + DHCP_OPTIONS;
	nat_dhcp_option(&p, 53, 1, reply_type);
	nat_dhcp_option(&p, 54, 4, NAT_GATEWAY); // the server
	if (reply_type != DHCP_NAK) {
		nat_dhcp_option(&p, 51, 4, DHCP_LEASE);
		nat_dhcp_option(&p, 1, 4, NAT_NETMASK);
		nat_dhcp_option(&p, 3, 4, NAT_GATEWAY); // router
		nat_dhcp_option(&p, 6, 4, NAT_DNS);
	}
	*p++ = 255;
	nat_send_udp(nat,
				 NAT_GATEWAY,
				 DHCP_SERVER_PORT,
				 IP_BROADCAST,
				 DHCP_CLIENT_PORT,
				 reply,
				 sizeof(reply));
}

// Answers a query: the address found, or none.
static void nat_dns_answer(nat_t* nat, const nat_dns_t* query,
						   const bool type_a, const uint32_t addr,
						   const uint32_t rcode) {
	uint8_t reply[DNS_HEADER + DNS_QUESTION_MAX + 16];
	const bool found = type_a && addr != 0;
	put16(reply, query->id);
	// a response, recursion desired as asked and available
	put16(reply + 2, 0x8080 | (query->flags & 0x0100) | rcode);
	put16(reply + 4, 1);
	put16(reply + 6, found ? 1 : 0);
	put16(reply + 8, 0);
	put16(reply + 10, 0);
	memcpy(reply + DNS_HEADER, query->question, query->question_size);
	size_t size = DNS_HEADER + query->question_size;
	if (found) {
		uint8_t* p = reply + size;
		put16(p, 0xC000 | DNS_HEADER); // the name of the question
		put16(p + 2, DNS_TYPE_A);
		put16(p + 4, DNS_CLASS_IN);
		put32(p + 6, DNS_TTL);
		put16(p + 10, 4);
		put32(p + 12, addr);
		size += 16;
	}
	nat_send_udp(
		nat, NAT_DNS, DNS_PORT, NAT_GUEST, query->guest_port, reply, size);
}

// A query to the DNS server: an A record is looked up on the host, other
// types have no answer (so a resolver falls back to A).
static void nat_dns(nat_t* nat, const uint16_t sport, const uint8_t* msg,
					const size_t size) {
	if (size < DNS_HEADER) return;
	const uint32_t flags = get16(msg + 2);
	if ((flags & 0x8000) || (flags & 0x7800) || get16(msg + 4) != 1) return;
	nat_dns_t query = { 0 };
	query.guest_port = sport;
	query.id = (uint16_t)get16(msg);
	query.flags = (uint16_t)flags;

	// the name, as dotted text
	char name[256];
	size_t length = 0;
	size_t i = DNS_HEADER;
	while (true) {
		if (i >= size) return;
		const uint8_t label = msg[i++];
		if (label == 0) break;
		if (label > 63 || i + label > size || length + label + 1 >= sizeof(name))
			return;
		if (length) name[length++] = '.';
		memcpy(name + length, msg + i, label);
		length += label;
		i += label;
	}
	name[length] = '\0';
	if (i + 4 > size || i + 4 - DNS_HEADER > DNS_QUESTION_MAX) return;
	const uint32_t type = get16(msg + i);
	const uint32_t class = get16(msg + i + 2);
	query.question_size = (uint32_t)(i + 4 - DNS_HEADER);
	memcpy(query.question, msg + DNS_HEADER, query.question_size);

	if (type != DNS_TYPE_A || class != DNS_CLASS_IN || length == 0) {
		nat_dns_answer(nat, &query, false, 0, 0);
		return;
	}
	for (int n = 0; n < NAT_DNS_COUNT; n++) {
		nat_dns_t* slot = &nat->dns[n];
		if (slot->used) continue;
		*slot = query;
		slot->used = true;
		slot->lookup = network_lookup_start(name);
		return;
	}
	nat_dns_answer(nat, &query, false, 0, DNS_SERVFAIL); // too many at once
}

static void nat_dns_poll(nat_t* nat) {
	for (int n = 0; n < NAT_DNS_COUNT; n++) {
		nat_dns_t* query = &nat->dns[n];
		uint32_t addr = 0;
		if (!query->used || !network_lookup_done(query->lookup, &addr))
			continue;
		nat_dns_answer(nat, query, true, addr, addr ? 0 : DNS_NXDOMAIN);
		network_lookup_free(query->lookup);
		query->used = false;
	}
}

// A datagram the guest sends out: through a host socket of its port.
static void nat_udp_out(nat_t* nat, const uint32_t dst, const uint16_t sport,
						const uint16_t dport, const uint8_t* data,
						const size_t length, const uint64_t now) {
	const uint32_t host_addr = nat_host_addr(dst);
	if (!network_can_udp() || nat_is_local(dst) || dst == IP_BROADCAST
		|| !net_policy_allows(nat->policy, host_addr, dport))
		return;
	// a forwarded port sends from its port of the host
	const net_forward_t* forward = net_policy_forward(nat->policy, sport);
	if (forward) {
		const network_socket_t host =
			nat->udp_listener[forward - nat->policy->forward];
		if (host != NETWORK_NO_SOCKET)
			network_send_to(host, data, length, host_addr, dport);
		return;
	}
	nat_udp_t* binding = NULL;
	nat_udp_t* oldest = &nat->udp[0];
	for (int i = 0; i < NAT_UDP_COUNT && !binding; i++) {
		nat_udp_t* u = &nat->udp[i];
		if (u->used && u->guest_port == sport) binding = u;
		if (!u->used || (oldest->used && u->last < oldest->last)) oldest = u;
	}
	if (!binding) { // a new one, in place of the least used if need be
		if (oldest->used) network_close(oldest->host);
		oldest->used = false;
		const network_socket_t host = network_udp(0, 0);
		if (host == NETWORK_NO_SOCKET) return;
		binding = oldest;
		binding->used = true;
		binding->guest_port = sport;
		binding->host = host;
	}
	binding->last = now;
	// a datagram the host has no room for is lost, as UDP allows
	network_send_to(binding->host, data, length, host_addr, dport);
}

// Passes on what a host socket has received to the guest's port; true if
// anything came.
static bool nat_udp_receive(nat_t* nat, const network_socket_t host,
							const uint16_t guest_port) {
	bool came = false;
	while (true) {
		uint32_t addr = 0;
		uint16_t port = 0;
		const long got = network_receive_from(
			host, nat_datagram, sizeof(nat_datagram), &addr, &port);
		if (got < 0) return came;
		came = true;
		nat_send_udp(nat,
					 addr == IP_LOOPBACK ? NAT_GATEWAY : addr,
					 port,
					 NAT_GUEST,
					 guest_port,
					 nat_datagram,
					 (size_t)got);
	}
}

static void nat_udp_poll(nat_t* nat, const uint64_t now) {
	for (int i = 0; i < nat->policy->forwards && nat->listening; i++)
		if (nat->udp_listener[i] != NETWORK_NO_SOCKET)
			nat_udp_receive(
				nat, nat->udp_listener[i], nat->policy->forward[i].guest_port);
	for (int i = 0; i < NAT_UDP_COUNT; i++) {
		nat_udp_t* u = &nat->udp[i];
		if (!u->used) continue;
		if (nat_udp_receive(nat, u->host, u->guest_port)) u->last = now;
		if (now - u->last >= NAT_UDP_IDLE) {
			network_close(u->host);
			u->used = false;
		}
	}
}

static void nat_udp_input(nat_t* nat, const uint32_t dst, const uint8_t* udp,
						  const size_t size, const uint64_t now) {
	if (size < UDP_HEADER) return;
	const size_t length = get16(udp + 4);
	if (length < UDP_HEADER || length > size) return;
	const uint16_t sport = (uint16_t)get16(udp);
	const uint16_t dport = (uint16_t)get16(udp + 2);
	const uint8_t* data = udp + UDP_HEADER;
	const size_t data_length = length - UDP_HEADER;
	if (dport == DHCP_SERVER_PORT
		&& (dst == IP_BROADCAST || dst == NAT_GATEWAY)) {
		nat_dhcp(nat, data, data_length);
		return;
	}
	if (dst == NAT_DNS) {
		if (dport == DNS_PORT) nat_dns(nat, sport, data, data_length);
		return;
	}
	nat_udp_out(nat, dst, sport, dport, data, data_length, now);
}

// ---- ICMP -------------------------------------------------------------------------

static void nat_send_echo_reply(nat_t* nat, const uint32_t src,
								const uint32_t id, const uint32_t seq,
								const uint8_t* data, const size_t length) {
	if (length > IP_MAX - IP_HEADER - ICMP_HEADER) return;
	uint8_t* frame = nat_begin(nat);
	if (!frame) return;
	uint8_t* icmp = frame + IP_PAYLOAD;
	icmp[0] = ICMP_ECHO_REPLY;
	icmp[1] = 0;
	put16(icmp + 2, 0);
	put16(icmp + 4, id);
	put16(icmp + 6, seq);
	memcpy(icmp + ICMP_HEADER, data, length);
	put16(icmp + 2, nat_checksum(nat_sum(icmp, ICMP_HEADER + length, 0)));
	nat_send_ip(nat, frame, IP_ICMP, src, NAT_GUEST, ICMP_HEADER + length);
}

// An echo request: the gateway and the DNS server answer themselves, other
// addresses through the host's ICMP socket, if it has one.
static void nat_icmp_input(nat_t* nat, const uint32_t dst, const uint8_t* icmp,
						   const size_t size, const uint64_t now) {
	if (size < ICMP_HEADER || icmp[0] != ICMP_ECHO_REQUEST || icmp[1] != 0)
		return;
	const uint32_t id = get16(icmp + 4);
	const uint32_t seq = get16(icmp + 6);
	if (dst == NAT_GATEWAY || dst == NAT_DNS) {
		nat_send_echo_reply(
			nat, dst, id, seq, icmp + ICMP_HEADER, size - ICMP_HEADER);
		return;
	}
	if (nat_is_local(dst) || dst == IP_BROADCAST
		|| !net_policy_allows(nat->policy, dst, 0))
		return;
	for (int i = 0; i < NAT_PING_COUNT; i++) {
		nat_ping_t* ping = &nat->ping[i];
		if (ping->used) continue;
		const network_socket_t host = network_icmp();
		if (host == NETWORK_NO_SOCKET) return;
		if (network_send_to(host, icmp, size, dst, 0) < 0) {
			network_close(host);
			return;
		}
		ping->used = true;
		ping->host = host;
		ping->addr = dst;
		ping->id = (uint16_t)id;
		ping->seq = (uint16_t)seq;
		ping->sent = now;
		return;
	}
}

static void nat_ping_poll(nat_t* nat, const uint64_t now) {
	for (int i = 0; i < NAT_PING_COUNT; i++) {
		nat_ping_t* ping = &nat->ping[i];
		if (!ping->used) continue;
		uint32_t addr = 0;
		uint16_t port = 0;
		const long got = network_receive_from(
			ping->host, nat_datagram, sizeof(nat_datagram), &addr, &port);
		bool done = now - ping->sent >= NAT_PING_TIMEOUT;
		if (got > 0) {
			// some hosts give the IP header too
			size_t start = 0;
			if (got >= IP_HEADER && (nat_datagram[0] >> 4) == 4)
				start = (size_t)(nat_datagram[0] & 0x0F) * 4;
			const uint8_t* icmp = nat_datagram + start;
			if ((size_t)got >= start + ICMP_HEADER
				&& icmp[0] == ICMP_ECHO_REPLY) {
				// the reply goes back with the guest's identifier
				nat_send_echo_reply(nat,
									ping->addr,
									ping->id,
									ping->seq,
									icmp + ICMP_HEADER,
									(size_t)got - start - ICMP_HEADER);
				done = true;
			}
		}
		if (done) {
			network_close(ping->host);
			ping->used = false;
		}
	}
}

// ---- ARP and IP -------------------------------------------------------------------

static void nat_arp_input(nat_t* nat, const uint8_t* arp, const size_t size) {
	if (size < 28 || get16(arp) != 1 || get16(arp + 2) != ETH_TYPE_IP
		|| arp[4] != 6 || arp[5] != 4 || get16(arp + 6) != 1)
		return;
	const uint32_t target = get32(arp + 24);
	if (target != NAT_GATEWAY && target != NAT_DNS) return;
	uint8_t* frame = nat_begin(nat);
	if (!frame) return;
	nat_ethernet(nat, frame, false, ETH_TYPE_ARP);
	uint8_t* reply = frame + ETH_HEADER;
	put16(reply, 1);
	put16(reply + 2, ETH_TYPE_IP);
	reply[4] = 6;
	reply[5] = 4;
	put16(reply + 6, 2); // a reply
	memcpy(reply + 8, nat_gateway_mac, 6);
	put32(reply + 14, target);
	memcpy(reply + 18, arp + 8, 10); // the asker's MAC and address
	nat_commit(nat, ETH_HEADER + 28);
}

static void nat_ip_input(nat_t* nat, const uint8_t* ip, const size_t size,
						 const uint64_t now) {
	if (size < IP_HEADER || (ip[0] >> 4) != 4) return;
	const size_t header = (size_t)(ip[0] & 0x0F) * 4;
	const size_t total = get16(ip + 2);
	if (header < IP_HEADER || total < header || total > size) return;
	if (get16(ip + 6) & 0x3FFF) return; // a fragment: not put together
	const uint32_t dst = get32(ip + 16);
	const uint8_t* payload = ip + header;
	const size_t length = total - header;
	switch (ip[9]) {
		case IP_ICMP:
			nat_icmp_input(nat, dst, payload, length, now);
			break;
		case IP_TCP:
			nat_tcp_input(nat, dst, payload, length, now);
			break;
		case IP_UDP:
			nat_udp_input(nat, dst, payload, length, now);
			break;
	}
}

// ---- the NAT ------------------------------------------------------------------------

nat_t* nat_create(const net_policy_t* policy, const uint8_t mac[6]) {
	nat_t* nat = calloc(1, sizeof(nat_t));
	if (!nat) error("Failed to allocate the NAT!");
	nat->policy = policy;
	memcpy(nat->mac, mac, 6);
	for (int i = 0; i < NET_FORWARD_MAX; i++) {
		nat->listener[i] = NETWORK_NO_SOCKET;
		nat->udp_listener[i] = NETWORK_NO_SOCKET;
	}
	nat_reset(nat);
	return nat;
}

void nat_destroy(nat_t* nat) {
	if (!nat) return;
	nat_listen(nat, false);
	nat_reset(nat);
	free(nat);
}

void nat_reset(nat_t* nat) {
	if (!nat) return;
	for (int i = 0; i < NAT_TCP_COUNT; i++)
		if (nat->tcp[i]) nat_tcp_free(nat, i, false);
	for (int i = 0; i < NAT_UDP_COUNT; i++) {
		if (nat->udp[i].used) network_close(nat->udp[i].host);
		nat->udp[i].used = false;
	}
	for (int i = 0; i < NAT_PING_COUNT; i++) {
		if (nat->ping[i].used) network_close(nat->ping[i].host);
		nat->ping[i].used = false;
	}
	for (int i = 0; i < NAT_DNS_COUNT; i++) {
		// a lookup still running ends on its own, unheard
		if (nat->dns[i].used) network_lookup_free(nat->dns[i].lookup);
		nat->dns[i].used = false;
	}
	nat->head = 0;
	nat->count = 0;
	nat->ip_id = 0;
	nat->next_isn = 0x57524D00; // "WRM"
	nat->next_port = NAT_PORT_FIRST;
}

void nat_listen(nat_t* nat, const bool on) {
	if (!nat || nat->listening == on) return;
	nat->listening = on;
	for (int i = 0; i < nat->policy->forwards; i++) {
		const net_forward_t* forward = &nat->policy->forward[i];
		if (!on) {
			network_close(nat->listener[i]);
			network_close(nat->udp_listener[i]);
			nat->listener[i] = NETWORK_NO_SOCKET;
			nat->udp_listener[i] = NETWORK_NO_SOCKET;
			continue;
		}
		if (network_can_listen()) {
			nat->listener[i] =
				network_listen(forward->host_addr, forward->host_port);
			if (nat->listener[i] == NETWORK_NO_SOCKET)
				warning("Ethernet: can't listen on port %u of the host",
						(unsigned)forward->host_port);
		}
		if (network_can_udp()) {
			nat->udp_listener[i] =
				network_udp(forward->host_addr, forward->host_port);
			if (nat->udp_listener[i] == NETWORK_NO_SOCKET)
				warning("Ethernet: can't take UDP on port %u of the host",
						(unsigned)forward->host_port);
		}
	}
}

void nat_input(nat_t* nat, const uint8_t* frame, const size_t length,
			   const uint64_t now) {
	if (!nat || length < ETH_HEADER) return;
	// for the gateway, or for everyone
	if (memcmp(frame, nat_gateway_mac, 6) != 0
		&& memcmp(frame, nat_broadcast_mac, 6) != 0)
		return;
	switch (get16(frame + 12)) {
		case ETH_TYPE_ARP:
			nat_arp_input(nat, frame + ETH_HEADER, length - ETH_HEADER);
			break;
		case ETH_TYPE_IP:
			nat_ip_input(nat, frame + ETH_HEADER, length - ETH_HEADER, now);
			break;
	}
}

void nat_poll(nat_t* nat, const uint64_t now) {
	if (!nat) return;
	for (int i = 0; i < nat->policy->forwards && nat->listening; i++) {
		if (nat->listener[i] == NETWORK_NO_SOCKET) continue;
		uint32_t addr = 0;
		uint16_t port = 0;
		const network_socket_t client =
			network_accept(nat->listener[i], &addr, &port);
		if (client != NETWORK_NO_SOCKET)
			nat_tcp_accept(
				nat, client, nat->policy->forward[i].guest_port, now);
	}
	for (int i = 0; i < NAT_TCP_COUNT; i++)
		if (nat->tcp[i]) nat_tcp_poll(nat, i, now);
	nat_udp_poll(nat, now);
	nat_ping_poll(nat, now);
	nat_dns_poll(nat);
}

bool nat_peek(const nat_t* nat, const uint8_t** frame, size_t* length) {
	if (!nat || nat->count == 0) return false;
	const nat_frame_t* first = &nat->queue[nat->head];
	*frame = first->data;
	*length = first->length;
	return true;
}

void nat_pop(nat_t* nat) {
	if (!nat || nat->count == 0) return;
	nat->head = (nat->head + 1) % NAT_QUEUE_SIZE;
	nat->count--;
}

uint64_t nat_lost(const nat_t* nat) {
	return nat ? nat->lost : 0;
}
