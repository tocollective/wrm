#include "devices/ethcard.h"

#include <string.h>

#include "network.h"

// The card's address, as QEMU gives its first card
static const uint8_t ethcard_mac[6] = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

static void ethcard_update_irq(ethcard_t* eth) {
	uint32_t mask = 0;
	if (eth->control & ETH_CONTROL_RX_IRQ)
		mask |= ETH_PENDING_RX | ETH_PENDING_LOST | ETH_PENDING_FAULT;
	if (eth->control & ETH_CONTROL_TX_IRQ)
		mask |= ETH_PENDING_TX | ETH_PENDING_FAULT;
	pic_set_line(eth->pic, eth->irq, (eth->pending & mask) != 0);
}

ethcard_t* ethcard_create(pic_t* pic, const uint8_t irq, const bus_t dma,
						  const bool link, const net_policy_t* policy) {
	ethcard_t* eth = (ethcard_t*)calloc(1, sizeof(ethcard_t));
	if (!eth) error("Failed to allocate the Ethernet card!");
	eth->pic = pic;
	eth->irq = irq;
	eth->dma = dma;
	eth->link = link && network_init();
	memcpy(eth->mac, ethcard_mac, sizeof(eth->mac));
	if (eth->link) eth->nat = nat_create(policy, eth->mac);
	ethcard_reset(eth);
	return eth;
}

void ethcard_destroy(ethcard_t* eth) {
	if (!eth) return;
	nat_destroy(eth->nat);
	if (eth->link) network_quit();
	free(eth);
	eth = NULL;
}

void ethcard_reset(ethcard_t* eth) {
	if (!eth) return;
	eth->control = 0;
	eth->pending = 0;
	eth->rx_ring = 0;
	eth->rx_size = 0;
	eth->rx_next = 0;
	eth->tx_ring = 0;
	eth->tx_size = 0;
	eth->tx_next = 0;
	nat_listen(eth->nat, false);
	nat_reset(eth->nat);
	eth->lost = nat_lost(eth->nat);
	ethcard_update_irq(eth);
}

void ethcard_disconnect(ethcard_t* eth) {
	if (!eth) return;
	// the card goes on, with a network that has forgotten everything
	nat_reset(eth->nat);
	eth->lost = nat_lost(eth->nat);
	nat_listen(eth->nat, false);
	nat_listen(eth->nat, (eth->control & ETH_CONTROL_ENABLE) != 0);
}

// The DMA has reached memory it can't: the card stops at the descriptor.
static void ethcard_fault(ethcard_t* eth) {
	eth->control &= ~ETH_CONTROL_ENABLE;
	eth->pending |= ETH_PENDING_FAULT;
	nat_listen(eth->nat, false);
}

static bool ethcard_enabled(const ethcard_t* eth) {
	return (eth->control & ETH_CONTROL_ENABLE) != 0;
}

// Reads a descriptor; false if the DMA can't reach it.
static bool ethcard_descriptor(ethcard_t* eth, const uint32_t address,
							   uint32_t* buffer, uint32_t* word) {
	return !eth->dma.read(eth->dma.ctx, address, 4, buffer)
		&& !eth->dma.read(eth->dma.ctx, address + 4, 4, word);
}

// TX_KICK: sends the frames of the descriptors the card owns, from
// TX_NEXT on, up to one it doesn't own; once round the ring at most.
static void ethcard_send(ethcard_t* eth) {
	static uint8_t frame[NAT_FRAME_MAX];
	for (uint32_t n = 0; n < eth->tx_size && ethcard_enabled(eth); n++) {
		const uint32_t at = eth->tx_ring + eth->tx_next * ETH_DESC_SIZE;
		uint32_t buffer = 0, word = 0;
		if (!ethcard_descriptor(eth, at, &buffer, &word)) {
			ethcard_fault(eth);
			return;
		}
		if (!(word & ETH_DESC_OWN)) return;
		const uint32_t length = word & ETH_DESC_LENGTH;
		bool sent = length >= NAT_FRAME_MIN && length <= NAT_FRAME_MAX;
		for (uint32_t i = 0; sent && i < length; i++) {
			uint32_t byte = 0;
			if (eth->dma.read(eth->dma.ctx, buffer + i, 1, &byte)) {
				ethcard_fault(eth);
				return;
			}
			frame[i] = (uint8_t)byte;
		}
		// without the link the frame goes nowhere, but it has been sent
		if (sent && eth->nat) nat_input(eth->nat, frame, length, eth->now);
		word = (word & ETH_DESC_LENGTH) | (sent ? 0 : ETH_DESC_ERROR);
		if (eth->dma.write(eth->dma.ctx, at + 4, 4, word)) {
			ethcard_fault(eth);
			return;
		}
		eth->tx_next = (eth->tx_next + 1) % eth->tx_size;
		eth->pending |= ETH_PENDING_TX;
	}
}

// Moves the frames that came in to the descriptors the card owns, from
// RX_NEXT on; the rest wait in the network's queue.
static void ethcard_receive(ethcard_t* eth) {
	const uint8_t* frame = NULL;
	size_t length = 0;
	while (ethcard_enabled(eth) && eth->rx_size > 0
		   && nat_peek(eth->nat, &frame, &length)) {
		const uint32_t at = eth->rx_ring + eth->rx_next * ETH_DESC_SIZE;
		uint32_t buffer = 0, word = 0;
		if (!ethcard_descriptor(eth, at, &buffer, &word)) {
			ethcard_fault(eth);
			return;
		}
		if (!(word & ETH_DESC_OWN)) return;
		const uint32_t room = word & ETH_DESC_LENGTH;
		const uint32_t stored = length < room ? (uint32_t)length : room;
		for (uint32_t i = 0; i < stored; i++) {
			if (eth->dma.write(eth->dma.ctx, buffer + i, 1, frame[i])) {
				ethcard_fault(eth);
				return;
			}
		}
		word = stored | (stored < length ? ETH_DESC_ERROR : 0);
		if (eth->dma.write(eth->dma.ctx, at + 4, 4, word)) {
			ethcard_fault(eth);
			return;
		}
		nat_pop(eth->nat);
		eth->rx_next = (eth->rx_next + 1) % eth->rx_size;
		eth->pending |= ETH_PENDING_RX;
	}
}

void ethcard_poll(ethcard_t* eth, const uint64_t now) {
	if (!eth || !eth->nat) return;
	eth->now = now;
	nat_poll(eth->nat, now);
	if (ethcard_enabled(eth)) {
		ethcard_receive(eth);
	} else {
		// nobody listens on a card that is off
		const uint8_t* frame = NULL;
		size_t length = 0;
		while (nat_peek(eth->nat, &frame, &length)) nat_pop(eth->nat);
	}
	const uint64_t lost = nat_lost(eth->nat);
	if (lost != eth->lost && ethcard_enabled(eth))
		eth->pending |= ETH_PENDING_LOST;
	eth->lost = lost;
	ethcard_update_irq(eth);
}

bool ethcard_read(ethcard_t* eth, const uint32_t offset, const uint8_t size,
				  uint32_t* value) {
	(void)size; // narrower loads get the low bits
	switch (offset) {
		case ETH_REG_STATUS:
			*value = eth->link ? ETH_STATUS_LINK : 0;
			return false;
		case ETH_REG_CONTROL:
			*value = eth->control;
			return false;
		case ETH_REG_PENDING:
			*value = eth->pending;
			return false;
		case ETH_REG_MAC_LO:
			*value = (uint32_t)eth->mac[0] | (uint32_t)eth->mac[1] << 8
				   | (uint32_t)eth->mac[2] << 16 | (uint32_t)eth->mac[3] << 24;
			return false;
		case ETH_REG_MAC_HI:
			*value = (uint32_t)eth->mac[4] | (uint32_t)eth->mac[5] << 8;
			return false;
		case ETH_REG_RX_RING:
			*value = eth->rx_ring;
			return false;
		case ETH_REG_RX_SIZE:
			*value = eth->rx_size;
			return false;
		case ETH_REG_RX_NEXT:
			*value = eth->rx_next;
			return false;
		case ETH_REG_TX_RING:
			*value = eth->tx_ring;
			return false;
		case ETH_REG_TX_SIZE:
			*value = eth->tx_size;
			return false;
		case ETH_REG_TX_NEXT:
			*value = eth->tx_next;
			return false;
		case ETH_REG_TX_KICK:
			*value = 0; // write-only
			return false;
	}
	return true;
}

static uint32_t ethcard_ring_size(const uint32_t value) {
	return value > ETH_RING_MAX ? ETH_RING_MAX : value;
}

bool ethcard_write(ethcard_t* eth, const uint32_t offset, const uint8_t size,
				   const uint32_t value) {
	(void)size;
	const bool off = !ethcard_enabled(eth);
	switch (offset) {
		case ETH_REG_STATUS:
		case ETH_REG_MAC_LO:
		case ETH_REG_MAC_HI:
		case ETH_REG_RX_NEXT:
		case ETH_REG_TX_NEXT:
			return false; // read-only, writes are ignored
		case ETH_REG_CONTROL: {
			eth->control = value & ETH_CONTROL_MASK;
			// turned on: both rings start from their first descriptor
			if (off && ethcard_enabled(eth)) {
				eth->rx_next = 0;
				eth->tx_next = 0;
			}
			nat_listen(eth->nat, ethcard_enabled(eth));
			break;
		}
		case ETH_REG_PENDING:
			eth->pending &= ~value;
			break;
		case ETH_REG_RX_RING:
			if (off) eth->rx_ring = value & ~(uint32_t)(ETH_DESC_SIZE - 1);
			return false;
		case ETH_REG_RX_SIZE:
			if (off) eth->rx_size = ethcard_ring_size(value);
			return false;
		case ETH_REG_TX_RING:
			if (off) eth->tx_ring = value & ~(uint32_t)(ETH_DESC_SIZE - 1);
			return false;
		case ETH_REG_TX_SIZE:
			if (off) eth->tx_size = ethcard_ring_size(value);
			return false;
		case ETH_REG_TX_KICK:
			ethcard_send(eth);
			break;
		default:
			return true;
	}
	ethcard_update_irq(eth);
	return false;
}
