#include "netpolicy.h"

// Address ranges denied by default: the host itself and networks that
// aren't the internet (RFC 6890), where the host's services and those
// of its network are.
static const struct {
	uint32_t addr;
	int bits;
} net_policy_denied[] = {
	{ 0x00000000, 8 }, // "this network"
	{ 0x0A000000, 8 }, // 10.0.0.0/8, private
	{ 0x64400000, 10 }, // 100.64.0.0/10, carrier-grade NAT
	{ 0x7F000000, 8 }, // 127.0.0.0/8, loopback
	{ 0xA9FE0000, 16 }, // 169.254.0.0/16, link-local
	{ 0xAC100000, 12 }, // 172.16.0.0/12, private
	{ 0xC0000000, 24 }, // 192.0.0.0/24, protocol assignments
	{ 0xC0A80000, 16 }, // 192.168.0.0/16, private
	{ 0xC6120000, 15 }, // 198.18.0.0/15, benchmarking
	{ 0xE0000000, 4 }, // 224.0.0.0/4, multicast
	{ 0xF0000000, 4 }, // 240.0.0.0/4, reserved, and the broadcast
};

static uint32_t net_policy_mask(const int bits) {
	return bits == 0 ? 0 : UINT32_MAX << (32 - bits);
}

void net_policy_defaults(net_policy_t* policy) {
	policy->rules = 0;
	policy->forwards = 0;
	const net_rule_t everything = {
		.allow = true, .addr = 0, .mask = 0, .port_min = 0, .port_max = 65535
	};
	net_policy_add(policy, everything);
	for (size_t i = 0; i < sizeof(net_policy_denied) / sizeof(net_policy_denied[0]);
		 i++) {
		const net_rule_t deny = {
			.allow = false,
			.addr = net_policy_denied[i].addr,
			.mask = net_policy_mask(net_policy_denied[i].bits),
			.port_min = 0,
			.port_max = 65535,
		};
		net_policy_add(policy, deny);
	}
}

bool net_policy_add(net_policy_t* policy, const net_rule_t rule) {
	if (policy->rules == NET_RULE_MAX) return false;
	policy->rule[policy->rules++] = rule;
	return true;
}

bool net_policy_allows(const net_policy_t* policy, const uint32_t addr,
					   const uint16_t port) {
	bool allowed = false;
	for (int i = 0; i < policy->rules; i++) {
		const net_rule_t* rule = &policy->rule[i];
		if ((addr & rule->mask) == (rule->addr & rule->mask)
			&& port >= rule->port_min && port <= rule->port_max)
			allowed = rule->allow;
	}
	return allowed;
}

const net_forward_t* net_policy_forward(const net_policy_t* policy,
										const uint16_t guest_port) {
	for (int i = 0; i < policy->forwards; i++)
		if (policy->forward[i].guest_port == guest_port)
			return &policy->forward[i];
	return NULL;
}
