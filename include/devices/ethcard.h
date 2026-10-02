#ifndef WRM_ETHCARD_H
#define WRM_ETHCARD_H
#include "common.h"

#include "bus.h"
#include "devices/pic.h"
#include "nat.h"
#include "netpolicy.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define ETH_REG_STATUS 0x00 // R
#define ETH_REG_CONTROL 0x04 // RW
#define ETH_REG_PENDING 0x08 // RW: W 1 to a bit clears it
#define ETH_REG_MAC_LO 0x0C // R: MAC bytes 0-3, byte 0 in bits 7:0
#define ETH_REG_MAC_HI 0x10 // R: MAC bytes 4-5
#define ETH_REG_RX_RING 0x14 // RW while off: the receive ring, 8-aligned
#define ETH_REG_RX_SIZE 0x18 // RW while off: its descriptors, up to 1024
#define ETH_REG_RX_NEXT 0x1C // R: the descriptor the next frame goes in
#define ETH_REG_TX_RING 0x20 // RW while off: the send ring, 8-aligned
#define ETH_REG_TX_SIZE 0x24 // RW while off
#define ETH_REG_TX_NEXT 0x28 // R: the descriptor sent next
#define ETH_REG_TX_KICK 0x2C // W: send what software has given the card

#define ETH_STATUS_LINK 0x01 // started without --no-net

#define ETH_CONTROL_ENABLE 0x01 // the card sends and receives
#define ETH_CONTROL_RX_IRQ 0x02 // assert the IRQ line on RX and LOST
#define ETH_CONTROL_TX_IRQ 0x04 // ... on TX
#define ETH_CONTROL_MASK 0x07

#define ETH_PENDING_RX 0x01 // frames were received
#define ETH_PENDING_TX 0x02 // frames were sent
#define ETH_PENDING_LOST 0x04 // a frame was dropped: no room
#define ETH_PENDING_FAULT 0x08 // a descriptor or buffer out of reach
#define ETH_PENDING_MASK 0x0F

// A descriptor: the buffer's physical address, then this word
#define ETH_DESC_SIZE 8
#define ETH_DESC_LENGTH 0x0000FFFF // bytes of the buffer, or of the frame
#define ETH_DESC_ERROR 0x40000000 // RX: cut short; TX: not sent
#define ETH_DESC_OWN 0x80000000 // the card's until it clears it

#define ETH_RING_MAX 1024

// Ethernet card: software gives it buffers through two rings of
// descriptors in RAM, one to receive frames into and one of frames to
// send, and the card moves the frames by DMA. Its cable leads to the NAT
// (nat.h), a virtual network with a gateway to the host's. Sending runs at
// once, in the store to TX_KICK; frames come in when the host polls the
// card. IRQ line is asserted while PENDING has a bit CONTROL enables.
typedef struct ethcard {
	pic_t* pic;
	uint8_t irq;
	bus_t dma; // reads RAM or ROM, writes RAM
	bool link; // connected to the host's network (not --no-net)
	nat_t* nat; // NULL without the link
	uint8_t mac[6];
	uint32_t control;
	uint32_t pending;
	uint32_t rx_ring;
	uint32_t rx_size;
	uint32_t rx_next;
	uint32_t tx_ring;
	uint32_t tx_size;
	uint32_t tx_next;
	uint64_t lost; // the NAT's count of lost frames, as seen last
	uint64_t now; // the machine's time in ms, as of the last poll
} ethcard_t;

// link = false makes a card whose link is down
ethcard_t* ethcard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
						  const bool link, const net_policy_t* policy);
void ethcard_destroy(ethcard_t* eth);

// Turns the card off and drops every connection of the network behind it.
void ethcard_reset(ethcard_t* eth);
// The host's side of the connections is gone (a snapshot was loaded).
void ethcard_disconnect(ethcard_t* eth);
// host side: runs the network and passes on the frames that came, often;
// now is the machine's time in ms
void ethcard_poll(ethcard_t* eth, const uint64_t now);

// bus side: offset is relative to the device base; return true on bus error
bool ethcard_read(ethcard_t* eth, const uint32_t offset, const uint8_t size,
				  uint32_t* value);
bool ethcard_write(ethcard_t* eth, const uint32_t offset, const uint8_t size,
				   const uint32_t value);

#endif // WRM_ETHCARD_H
