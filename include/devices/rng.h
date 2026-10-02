#ifndef WRM_RNG_H
#define WRM_RNG_H
#include "common.h"

// Registers (offsets from the device base, see docs/SPECIFICATION.md)
#define RNG_REG_DATA 0x00 // R: 32 random bits, new ones on every read
#define RNG_REG_STATUS 0x04 // R

#define RNG_STATUS_SEEDED 0x01 // the bits come from a seed, not the host

#define RNG_POOL_WORDS 16 // one ChaCha20 block

// Random number generator: random bits from the host's cryptographic
// generator, taken a block at a time. Seeded (rng_set_seed), it gives the
// ChaCha20 stream of the seed instead, the same on every run. It has no
// IRQ and doesn't run on the clock; a reset leaves it alone.
typedef struct rng {
	bool seeded;
	uint32_t key[8]; // seeded: the ChaCha20 key
	uint64_t counter; // seeded: blocks made so far
	uint32_t pool[RNG_POOL_WORDS];
	uint32_t used; // words of pool given out, RNG_POOL_WORDS = empty
} rng_t;

rng_t* rng_create(void);
void rng_destroy(rng_t* rng);

// From now on the bits are the ChaCha20 stream with seed as the key.
void rng_set_seed(rng_t* rng, const uint64_t seed);
// Drops the bits taken but not given out yet; the next read takes new
// ones (after a snapshot is loaded, so as not to give the same twice).
void rng_drop_pool(rng_t* rng);

// bus side: offset is relative to the device base; return true on bus error
bool rng_read(rng_t* rng, const uint32_t offset, const uint8_t size,
			  uint32_t* value);
bool rng_write(rng_t* rng, const uint32_t offset, const uint8_t size,
			   const uint32_t value);

#endif // WRM_RNG_H
