#ifndef WRM_NAT_H
#define WRM_NAT_H
#include "common.h"

#include "netpolicy.h"

// The network on the other end of the Ethernet card's cable, in user
// space like QEMU's user networking (slirp): a gateway that answers ARP,
// hands out an address by DHCP, answers DNS queries with the host's
// lookups, answers ping itself and passes TCP, UDP and ping on to the
// host's sockets, as if the guest were behind a router doing NAT.
//
//   10.0.2.0/24   the network
//   10.0.2.2      the gateway; to the guest it is also the host itself
//                 (its 127.0.0.1)
//   10.0.2.3      the DNS server
//   10.0.2.15     the guest's address, given by DHCP
//
// Frames are Ethernet II without the FCS. The policy says where the guest
// may connect, send and ping to, and which host ports are forwarded to
// the guest's TCP and UDP ports.

#define NAT_FRAME_MAX 1514 // the Ethernet header and 1500 bytes
#define NAT_FRAME_MIN 14 // the Ethernet header alone
#define NAT_QUEUE_SIZE 64 // frames waiting for the guest

#define NAT_NETWORK 0x0A000200 // 10.0.2.0
#define NAT_NETMASK 0xFFFFFF00 // /24
#define NAT_GATEWAY 0x0A000202 // 10.0.2.2
#define NAT_DNS 0x0A000203 // 10.0.2.3
#define NAT_GUEST 0x0A00020F // 10.0.2.15

typedef struct nat nat_t;

// The guest's card has the address mac.
nat_t* nat_create(const net_policy_t* policy, const uint8_t mac[6]);
void nat_destroy(nat_t* nat);

// Forgets everything: connections, bindings, lookups, the frames waiting.
// The forwarded ports stay as they are.
void nat_reset(nat_t* nat);
// Listens on the forwarded host ports (the card is on), or stops.
void nat_listen(nat_t* nat, const bool on);

// A frame from the guest; now is the machine's time in milliseconds.
void nat_input(nat_t* nat, const uint8_t* frame, const size_t length,
			   const uint64_t now);
// Moves data between the connections and the host's sockets, runs the
// timers; often (when the host polls the network).
void nat_poll(nat_t* nat, const uint64_t now);

// The oldest frame waiting for the guest; false if there is none.
bool nat_peek(const nat_t* nat, const uint8_t** frame, size_t* length);
// ... is taken.
void nat_pop(nat_t* nat);
// Frames dropped because the queue was full, since the NAT was created.
uint64_t nat_lost(const nat_t* nat);

#endif // WRM_NAT_H
