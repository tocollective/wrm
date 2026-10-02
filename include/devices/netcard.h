#ifndef WRM_NETCARD_H
#define WRM_NETCARD_H
#include "common.h"

#include "bus.h"
#include "devices/pic.h"
#include "network.h"

#define NET_SOCKET_COUNT 8
#define NET_BUFFER_SIZE 16384 // receive and send buffer of each socket
#define NET_DATAGRAM_MAX 8192 // longest UDP datagram SEND takes
#define NET_UDP_HEADER 8 // before each datagram in the receive buffer
#define NET_NAME_SIZE 256 // a host name for DNS, with its terminator

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define NET_REG_STATUS 0x00 // R
#define NET_REG_PENDING 0x04 // R: sockets (and DNS) asserting the IRQ line
#define NET_REG_SOCKETS 0x08 // R: NET_SOCKET_COUNT
#define NET_REG_DNS_COMMAND 0x10 // W: 1 = look up the name at DNS_NAME
#define NET_REG_DNS_STATUS 0x14 // RW: W 1 to DONE clears it
#define NET_REG_DNS_CONTROL 0x18 // RW
#define NET_REG_DNS_NAME 0x1C // RW: physical address of the host name
#define NET_REG_DNS_RESULT 0x20 // R: the address found, 0 if none
#define NET_REG_SOCKET0 0x100 // socket N at SOCKET0 + N * SOCKET_SIZE
#define NET_SOCKET_SIZE 0x40

// Socket registers (offsets from the socket's base)
#define NET_SOCKET_STATE 0x00 // R
#define NET_SOCKET_COMMAND 0x04 // W
#define NET_SOCKET_ERROR 0x08 // R: why the last command or connection failed
#define NET_SOCKET_EVENTS 0x0C // RW: W 1 to a bit clears it
#define NET_SOCKET_IRQ_MASK 0x10 // RW: EVENTS bits that assert the IRQ line
#define NET_SOCKET_LOCAL_PORT 0x14 // RW
#define NET_SOCKET_PEER_ADDR 0x18 // RW: IPv4, 127.0.0.1 = 0x7F000001
#define NET_SOCKET_PEER_PORT 0x1C // RW
#define NET_SOCKET_ADDRESS 0x20 // RW: physical address of the next byte
#define NET_SOCKET_COUNT_REG 0x24 // RW: bytes left to move
#define NET_SOCKET_RX_SIZE 0x28 // R: bytes in the receive buffer
#define NET_SOCKET_TX_FREE 0x2C // R: free bytes in the send buffer

#define NET_STATUS_LINK 0x01 // started without --no-net
#define NET_STATUS_LISTEN 0x02 // the host can take connections
#define NET_STATUS_UDP 0x04 // the host can do UDP

#define NET_PENDING_DNS 0x100

#define NET_DNS_LOOKUP 1 // DNS_COMMAND

#define NET_DNS_BUSY 0x01
#define NET_DNS_DONE 0x02
#define NET_DNS_FAILED 0x04

#define NET_DNS_CONTROL_IRQ 0x01 // assert the IRQ line while DONE

#define NET_STATE_CLOSED 0
#define NET_STATE_CONNECTING 1
#define NET_STATE_LISTENING 2
#define NET_STATE_CONNECTED 3
#define NET_STATE_PEER_CLOSED 4 // received bytes stay readable
#define NET_STATE_UDP 5

#define NET_COMMAND_CONNECT 1
#define NET_COMMAND_LISTEN 2
#define NET_COMMAND_UDP 3
#define NET_COMMAND_SEND 4
#define NET_COMMAND_RECEIVE 5
#define NET_COMMAND_CLOSE 6

#define NET_EVENT_CONNECTED 0x01
#define NET_EVENT_CLOSED 0x02 // by the other end, or the connection failed
#define NET_EVENT_RECEIVED 0x04
#define NET_EVENT_SENT 0x08 // the send buffer is empty again
#define NET_EVENT_MASK 0x0F

#define NET_ERROR_NONE 0
#define NET_ERROR_COMMAND 1 // unknown command
#define NET_ERROR_STATE 2 // not in this state
#define NET_ERROR_ADDRESS 3 // DMA outside RAM (or ROM, for reads)
#define NET_ERROR_LINK 4 // --no-net
#define NET_ERROR_UNSUPPORTED 5 // LISTEN or UDP in a browser
#define NET_ERROR_NETWORK 6 // the host's network failed
#define NET_ERROR_LENGTH 7 // the datagram is too long

#define NET_PORT_MASK 0xFFFF

typedef struct net_socket {
	uint32_t state;
	uint32_t error;
	uint32_t events;
	uint32_t irq_mask;
	uint32_t local_port;
	uint32_t peer_addr;
	uint32_t peer_port;
	uint32_t address;
	uint32_t count;
	network_socket_t host; // NETWORK_NO_SOCKET while closed
	uint8_t rx[NET_BUFFER_SIZE]; // received, oldest first
	uint32_t rx_size;
	uint8_t tx[NET_BUFFER_SIZE]; // to send, oldest first
	uint32_t tx_size;
} net_socket_t;

// Network card with TCP/IP in hardware: each socket is a socket of the
// host. Commands run at once, in the store that writes them; the network
// moves data when the host polls the card (netcard_poll).
// IRQ line is asserted while PENDING is not 0.
typedef struct netcard {
	pic_t* pic;
	uint8_t irq;
	bus_t dma; // reads RAM or ROM, writes RAM
	bool link; // connected to the host's network (not --no-net)
	uint32_t local_addr; // where LISTEN and UDP on a port listen
	net_socket_t socket[NET_SOCKET_COUNT];
	uint32_t dns_status;
	uint32_t dns_control;
	uint32_t dns_name;
	uint32_t dns_result;
	network_lookup_t* lookup; // the one running, NULL if none
} netcard_t;

// link = false makes a card whose link is down; local_addr as in netcard_t
netcard_t* netcard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
						  const bool link, const uint32_t local_addr);
void netcard_destroy(netcard_t* net);

// Closes every socket and forgets a running lookup.
void netcard_reset(netcard_t* net);
// The host's side of the sockets is gone (a snapshot was loaded): every
// socket that was open is closed by the other end with NET_ERROR_NETWORK,
// a lookup fails. What was received stays readable on a connection.
void netcard_disconnect(netcard_t* net);
// host side: moves data between the sockets and the host's network,
// often (every iteration of the main loop)
void netcard_poll(netcard_t* net);

// bus side: offset is relative to the device base; return true on bus error
bool netcard_read(netcard_t* net, const uint32_t offset, const uint8_t size,
				  uint32_t* value);
bool netcard_write(netcard_t* net, const uint32_t offset, const uint8_t size,
				   const uint32_t value);

#endif // WRM_NETCARD_H
