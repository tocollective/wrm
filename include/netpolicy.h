#ifndef WRM_NETPOLICY_H
#define WRM_NETPOLICY_H
#include "common.h"

#define NET_RULE_MAX 64
#define NET_FORWARD_MAX 16
#define NET_LOCAL_ADDR 0x7F000001 // 127.0.0.1: where forwards listen by default

// An address range and a port range the guest may or may not reach.
typedef struct net_rule {
	bool allow;
	uint32_t addr; // IPv4, the first byte of the dotted form on top
	uint32_t mask; // of the bits addr fixes
	uint16_t port_min;
	uint16_t port_max;
} net_rule_t;

// A port of the host whose TCP connections and datagrams go to a port of
// the guest.
typedef struct net_forward {
	uint32_t host_addr;
	uint16_t host_port;
	uint16_t guest_port;
} net_forward_t;

// Where the guest may connect and send to, and which of its ports the
// host forwards. Rules are matched in order and the last one that
// matches decides; the defaults come first (net_policy_defaults): every
// address but the host itself, private networks and other non-public
// ones. What comes in through the forwards is not filtered.
typedef struct net_policy {
	net_rule_t rule[NET_RULE_MAX];
	int rules;
	net_forward_t forward[NET_FORWARD_MAX];
	int forwards;
} net_policy_t;

// Makes the policy the default one, without forwards.
void net_policy_defaults(net_policy_t* policy);
// Adds a rule; false if there are NET_RULE_MAX already.
bool net_policy_add(net_policy_t* policy, const net_rule_t rule);
// Whether the guest may connect or send to addr:port.
bool net_policy_allows(const net_policy_t* policy, const uint32_t addr,
					   const uint16_t port);
// The forward of the guest's port, NULL if there is none.
const net_forward_t* net_policy_forward(const net_policy_t* policy,
										const uint16_t guest_port);

#endif // WRM_NETPOLICY_H
