// getentropy under strict C99
#ifndef _WIN32
#define _DEFAULT_SOURCE
#endif

#include "devices/rng.h"

#include <string.h>

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#else
#include <sys/types.h>
#include <sys/random.h>
#include <unistd.h>
#endif

// The host's cryptographic generator; false if it fails.
static bool rng_host_bytes(void* data, const size_t size) {
#ifdef _WIN32
	return BCRYPT_SUCCESS(BCryptGenRandom(
			NULL, data, (ULONG)size, BCRYPT_USE_SYSTEM_PREFERRED_RNG));
#else
	return getentropy(data, size) == 0; // up to 256 bytes at a time
#endif
}

#define RNG_ROTL(x, n) ((x) << (n) | (x) >> (32 - (n)))
#define RNG_QUARTER(a, b, c, d)                                                \
	do {                                                                       \
		a += b;                                                                \
		d ^= a;                                                                \
		d = RNG_ROTL(d, 16);                                                   \
		c += d;                                                                \
		b ^= c;                                                                \
		b = RNG_ROTL(b, 12);                                                   \
		a += b;                                                                \
		d ^= a;                                                                \
		d = RNG_ROTL(d, 8);                                                    \
		c += d;                                                                \
		b ^= c;                                                                \
		b = RNG_ROTL(b, 7);                                                    \
	} while (0)

// One ChaCha20 block (the original variant: a 64-bit block counter and a
// 64-bit nonce, here 0).
static void rng_chacha20(const uint32_t key[8], const uint64_t counter,
						 uint32_t out[RNG_POOL_WORDS]) {
	const uint32_t in[RNG_POOL_WORDS] = {
		0x61707865, 0x3320646E, 0x79622D32, 0x6B206574, // "expand 32-byte k"
		key[0],		key[1],		key[2],		key[3],
		key[4],		key[5],		key[6],		key[7],
		(uint32_t)counter, (uint32_t)(counter >> 32), 0, 0,
	};
	uint32_t x[RNG_POOL_WORDS];
	memcpy(x, in, sizeof(x));
	for (int round = 0; round < 10; round++) {
		RNG_QUARTER(x[0], x[4], x[8], x[12]);
		RNG_QUARTER(x[1], x[5], x[9], x[13]);
		RNG_QUARTER(x[2], x[6], x[10], x[14]);
		RNG_QUARTER(x[3], x[7], x[11], x[15]);
		RNG_QUARTER(x[0], x[5], x[10], x[15]);
		RNG_QUARTER(x[1], x[6], x[11], x[12]);
		RNG_QUARTER(x[2], x[7], x[8], x[13]);
		RNG_QUARTER(x[3], x[4], x[9], x[14]);
	}
	for (int i = 0; i < RNG_POOL_WORDS; i++) out[i] = x[i] + in[i];
}

static void rng_fill(rng_t* rng) {
	if (rng->seeded)
		rng_chacha20(rng->key, rng->counter++, rng->pool);
	else if (!rng_host_bytes(rng->pool, sizeof(rng->pool)))
		error("Failed to get random bytes from the host");
	rng->used = 0;
}

rng_t* rng_create(void) {
	rng_t* rng = (rng_t*)calloc(1, sizeof(rng_t));
	if (!rng) error("Failed to allocate the random number generator!");
	rng->used = RNG_POOL_WORDS;
	return rng;
}

void rng_destroy(rng_t* rng) {
	if (!rng) return;
	// the bits may have become a guest's keys
	memset(rng->pool, 0, sizeof(rng->pool));
	free(rng);
	rng = NULL;
}

void rng_set_seed(rng_t* rng, const uint64_t seed) {
	if (!rng) return;
	memset(rng->key, 0, sizeof(rng->key));
	rng->key[0] = (uint32_t)seed;
	rng->key[1] = (uint32_t)(seed >> 32);
	rng->seeded = true;
	rng->counter = 0;
	rng->used = RNG_POOL_WORDS;
}

void rng_drop_pool(rng_t* rng) {
	if (!rng) return;
	rng->used = RNG_POOL_WORDS;
}

bool rng_read(rng_t* rng, const uint32_t offset, const uint8_t size,
			  uint32_t* value) {
	(void)size; // narrower loads get the low bits, and use up a word too
	switch (offset) {
		case RNG_REG_DATA:
			if (rng->used >= RNG_POOL_WORDS) rng_fill(rng);
			*value = rng->pool[rng->used];
			rng->pool[rng->used++] = 0; // given out once
			return false;
		case RNG_REG_STATUS:
			*value = rng->seeded ? RNG_STATUS_SEEDED : 0;
			return false;
	}
	return true;
}

bool rng_write(rng_t* rng, const uint32_t offset, const uint8_t size,
			   const uint32_t value) {
	(void)rng;
	(void)size;
	(void)value;
	switch (offset) {
		case RNG_REG_DATA:
		case RNG_REG_STATUS:
			return false; // read-only, writes are ignored
	}
	return true;
}
