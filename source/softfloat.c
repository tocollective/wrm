#include "softfloat.h"

// A finite nonzero value is worked on as sig * 2^exp: an integer
// significand and a power of two. Results are computed exactly, or with
// the bits that don't fit folded into bit 0 of the significand (a sticky
// bit), and then rounded once by sf_round_pack.

#define SF_INF 0x7F800000u
#define SF_MAX 0x7F7FFFFFu // the largest finite value
#define SF_QUIET 0x00400000u // the top fraction bit: a quiet NaN
#define SF_FRACTION 0x007FFFFFu
#define SF_HIDDEN 0x00800000u // the leading 1 of a normal significand
#define SF_BIAS 127
#define SF_FRACTION_BITS 23

static bool sf_is_nan(const uint32_t a) {
	return (a & ~SF_SIGN) > SF_INF;
}

static bool sf_is_signaling(const uint32_t a) {
	return sf_is_nan(a) && !(a & SF_QUIET);
}

static bool sf_is_inf(const uint32_t a) {
	return (a & ~SF_SIGN) == SF_INF;
}

static bool sf_is_zero(const uint32_t a) {
	return (a & ~SF_SIGN) == 0;
}

static bool sf_sign(const uint32_t a) {
	return (a & SF_SIGN) != 0;
}

static uint32_t sf_signed(const bool sign, const uint32_t magnitude) {
	return (sign ? SF_SIGN : 0) | magnitude;
}

// A NaN operand: the result is the canonical NaN, and a signaling one is
// an invalid operation.
static uint32_t sf_nan(const uint32_t a, const uint32_t b, uint8_t* flags) {
	if (sf_is_signaling(a) || sf_is_signaling(b)) *flags |= SF_FLAG_INVALID;
	return SF_NAN;
}

static uint32_t sf_invalid(uint8_t* flags) {
	*flags |= SF_FLAG_INVALID;
	return SF_NAN;
}

// The zero an exact cancellation gives: -0 when rounding down, +0 else.
static uint32_t sf_cancelled(const uint8_t rounding) {
	return rounding == SF_ROUND_DOWN ? SF_SIGN : 0;
}

// Leading zeros of a nonzero value.
static int sf_clz64(uint64_t x) {
	int n = 0;
	for (int step = 32; step > 0; step /= 2) {
		if (x >> (64 - step)) continue;
		n += step;
		x <<= step;
	}
	return n;
}

// x >> n with the bits shifted out OR-ed into bit 0.
static uint64_t sf_shift_right_jam(const uint64_t x, const int32_t n) {
	if (n <= 0) return x;
	if (n >= 64) return x != 0;
	return (x >> n) | ((x & ((1ULL << n) - 1)) != 0);
}

// A finite nonzero value as sig * 2^exp, sig < 2^24.
static void sf_unpack(const uint32_t a, bool* sign, int32_t* exp,
					  uint64_t* sig) {
	const uint32_t field = (a >> SF_FRACTION_BITS) & 0xFF;
	const uint32_t fraction = a & SF_FRACTION;
	*sign = sf_sign(a);
	*sig = field ? fraction | SF_HIDDEN : fraction;
	// subnormals have the exponent of the smallest normal numbers
	*exp = (field ? (int32_t)field : 1) - SF_BIAS - SF_FRACTION_BITS;
}

// ... with the leading 1 of sig moved to bit 23, as for a normal number
static void sf_unpack_normalized(const uint32_t a, bool* sign, int32_t* exp,
								 uint64_t* sig) {
	sf_unpack(a, sign, exp, sig);
	const int shift = sf_clz64(*sig) - (63 - SF_FRACTION_BITS);
	*sig <<= shift;
	*exp -= shift;
}

// The result of an overflow: infinity or the largest finite value,
// whichever the rounding direction gives.
static uint32_t sf_overflow(const bool sign, const uint8_t rounding,
							uint8_t* flags) {
	*flags |= SF_FLAG_OVERFLOW | SF_FLAG_INEXACT;
	bool infinite = true;
	switch (rounding) {
		case SF_ROUND_ZERO:
			infinite = false;
			break;
		case SF_ROUND_DOWN:
			infinite = sign;
			break;
		case SF_ROUND_UP:
			infinite = !sign;
			break;
	}
	return sf_signed(sign, infinite ? SF_INF : SF_MAX);
}

// Rounds sig * 2^exp to a binary32. sig is not 0; its bit 0 may be a
// sticky bit, which has to lie at least two bits below the last bit kept.
static uint32_t sf_round_pack(const bool sign, int32_t exp, uint64_t sig,
							  const uint8_t rounding, uint8_t* flags) {
	const int shift = sf_clz64(sig);
	sig <<= shift;
	exp -= shift;
	// the leading 1 is bit 63: the value is 1.f * 2^(exp + 63)
	int32_t biased = exp + 63 + SF_BIAS;
	if (biased >= 0xFF) return sf_overflow(sign, rounding, flags);

	// a normal number keeps 24 bits; one below the smallest normal number
	// keeps fewer, as a subnormal
	int32_t drop = 63 - SF_FRACTION_BITS;
	const bool tiny = biased < 1;
	if (tiny) {
		drop += 1 - biased;
		biased = 1;
	}
	uint64_t kept, rest, half;
	if (drop < 64) {
		kept = sig >> drop;
		rest = sig & ((1ULL << drop) - 1);
		half = 1ULL << (drop - 1);
	} else { // nothing is kept: the rest is all of sig, or less than half
		kept = 0;
		rest = drop == 64 ? sig : 1;
		half = drop == 64 ? 1ULL << 63 : 2;
	}

	if (rest) {
		*flags |= SF_FLAG_INEXACT;
		if (tiny) *flags |= SF_FLAG_UNDERFLOW;
		bool up = false;
		switch (rounding) {
			case SF_ROUND_NEAREST_EVEN:
				up = rest > half || (rest == half && (kept & 1));
				break;
			case SF_ROUND_NEAREST_MAX:
				up = rest >= half;
				break;
			case SF_ROUND_DOWN:
				up = sign;
				break;
			case SF_ROUND_UP:
				up = !sign;
				break;
		}
		kept += up;
	}

	// kept has the leading 1 at bit 23 (or none, for a subnormal), which
	// adds 1 to the exponent field: a carry out of the fraction lands there
	// too, and a subnormal that rounds up becomes the smallest normal
	const uint32_t bits =
		((uint32_t)(biased - 1) << SF_FRACTION_BITS) + (uint32_t)kept;
	if (bits >= SF_INF) return sf_overflow(sign, rounding, flags);
	return sf_signed(sign, bits);
}

// Adds two finite nonzero values: a_sign a_sig * 2^a_exp and the same
// for b. Both significands have their leading 1 at bit 61 or below.
static uint32_t sf_add_finite(bool a_sign, int32_t a_exp, uint64_t a_sig,
							  bool b_sign, int32_t b_exp, uint64_t b_sig,
							  const uint8_t rounding, uint8_t* flags) {
	if (a_exp < b_exp) {
		const bool sign = a_sign;
		const int32_t exp = a_exp;
		const uint64_t sig = a_sig;
		a_sign = b_sign, a_exp = b_exp, a_sig = b_sig;
		b_sign = sign, b_exp = exp, b_sig = sig;
	}
	b_sig = sf_shift_right_jam(b_sig, a_exp - b_exp);
	uint64_t sig;
	bool sign = a_sign;
	if (a_sign == b_sign) {
		sig = a_sig + b_sig;
	} else if (a_sig >= b_sig) {
		sig = a_sig - b_sig;
	} else {
		sig = b_sig - a_sig;
		sign = b_sign;
	}
	if (!sig) return sf_cancelled(rounding);
	return sf_round_pack(sign, a_exp, sig, rounding, flags);
}

uint32_t sf_add(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags) {
	if (sf_is_nan(a) || sf_is_nan(b)) return sf_nan(a, b, flags);
	if (sf_is_inf(a)) {
		if (sf_is_inf(b) && sf_sign(a) != sf_sign(b)) return sf_invalid(flags);
		return a;
	}
	if (sf_is_inf(b)) return b;
	if (sf_is_zero(a) && sf_is_zero(b))
		return sf_sign(a) == sf_sign(b) ? a : sf_cancelled(rounding);
	if (sf_is_zero(a)) return b;
	if (sf_is_zero(b)) return a;

	// 38 bits to spare below the significands: guard bits for the
	// alignment, enough that the sticky bit never reaches the rounding
	bool a_sign, b_sign;
	int32_t a_exp, b_exp;
	uint64_t a_sig, b_sig;
	sf_unpack(a, &a_sign, &a_exp, &a_sig);
	sf_unpack(b, &b_sign, &b_exp, &b_sig);
	return sf_add_finite(a_sign,
						 a_exp - 38,
						 a_sig << 38,
						 b_sign,
						 b_exp - 38,
						 b_sig << 38,
						 rounding,
						 flags);
}

uint32_t sf_sub(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags) {
	return sf_add(a, b ^ SF_SIGN, rounding, flags);
}

uint32_t sf_mul(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags) {
	if (sf_is_nan(a) || sf_is_nan(b)) return sf_nan(a, b, flags);
	const bool sign = sf_sign(a) != sf_sign(b);
	if (sf_is_inf(a) || sf_is_inf(b)) {
		if (sf_is_zero(a) || sf_is_zero(b)) return sf_invalid(flags);
		return sf_signed(sign, SF_INF);
	}
	if (sf_is_zero(a) || sf_is_zero(b)) return sf_signed(sign, 0);

	bool a_sign, b_sign;
	int32_t a_exp, b_exp;
	uint64_t a_sig, b_sig;
	sf_unpack(a, &a_sign, &a_exp, &a_sig);
	sf_unpack(b, &b_sign, &b_exp, &b_sig);
	// the 48-bit product is exact
	return sf_round_pack(sign, a_exp + b_exp, a_sig * b_sig, rounding, flags);
}

uint32_t sf_div(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags) {
	if (sf_is_nan(a) || sf_is_nan(b)) return sf_nan(a, b, flags);
	const bool sign = sf_sign(a) != sf_sign(b);
	if (sf_is_inf(a)) {
		if (sf_is_inf(b)) return sf_invalid(flags);
		return sf_signed(sign, SF_INF);
	}
	if (sf_is_inf(b)) return sf_signed(sign, 0);
	if (sf_is_zero(b)) {
		if (sf_is_zero(a)) return sf_invalid(flags);
		*flags |= SF_FLAG_DIVIDE_BY_ZERO;
		return sf_signed(sign, SF_INF);
	}
	if (sf_is_zero(a)) return sf_signed(sign, 0);

	// both normalized, so the quotient has 40 or 41 bits
	bool a_sign, b_sign;
	int32_t a_exp, b_exp;
	uint64_t a_sig, b_sig;
	sf_unpack_normalized(a, &a_sign, &a_exp, &a_sig);
	sf_unpack_normalized(b, &b_sign, &b_exp, &b_sig);
	const uint64_t dividend = a_sig << 40;
	uint64_t quotient = dividend / b_sig;
	quotient |= (dividend % b_sig) != 0;
	return sf_round_pack(
			sign, a_exp - 40 - b_exp, quotient, rounding, flags);
}

// floor(sqrt(n)); exact tells whether that is the whole root
static uint64_t sf_isqrt(uint64_t n, bool* exact) {
	uint64_t root = 0;
	uint64_t bit = 1ULL << 62;
	while (bit > n) bit >>= 2;
	while (bit) {
		if (n >= root + bit) {
			n -= root + bit;
			root = (root >> 1) + bit;
		} else {
			root >>= 1;
		}
		bit >>= 2;
	}
	*exact = n == 0;
	return root;
}

uint32_t sf_sqrt(const uint32_t a, const uint8_t rounding, uint8_t* flags) {
	if (sf_is_nan(a)) return sf_nan(a, 0, flags);
	if (sf_is_zero(a)) return a; // sqrt(-0) is -0
	if (sf_sign(a)) return sf_invalid(flags);
	if (sf_is_inf(a)) return a;

	bool sign;
	int32_t exp;
	uint64_t sig;
	sf_unpack_normalized(a, &sign, &exp, &sig);
	if (exp & 1) { // an even exponent halves exactly
		sig <<= 1;
		exp -= 1;
	}
	// sig < 2^25: shifted by 38 it still fits, and its root has 31 or 32
	// bits
	bool exact;
	uint64_t root = sf_isqrt(sig << 38, &exact);
	root |= !exact;
	return sf_round_pack(false, (exp - 38) / 2, root, rounding, flags);
}

uint32_t sf_fma(const uint32_t a, const uint32_t b, const uint32_t c,
				const uint8_t rounding, uint8_t* flags) {
	const bool inf_times_zero = (sf_is_inf(a) && sf_is_zero(b))
							 || (sf_is_zero(a) && sf_is_inf(b));
	if (sf_is_nan(a) || sf_is_nan(b) || sf_is_nan(c)) {
		// infinity times zero is invalid whatever is added to it
		if (inf_times_zero) *flags |= SF_FLAG_INVALID;
		if (sf_is_signaling(c)) *flags |= SF_FLAG_INVALID;
		return sf_nan(a, b, flags);
	}
	const bool product_sign = sf_sign(a) != sf_sign(b);
	if (inf_times_zero) return sf_invalid(flags);
	if (sf_is_inf(a) || sf_is_inf(b)) {
		if (sf_is_inf(c) && sf_sign(c) != product_sign)
			return sf_invalid(flags);
		return sf_signed(product_sign, SF_INF);
	}
	if (sf_is_inf(c)) return c;
	if (sf_is_zero(a) || sf_is_zero(b)) {
		if (!sf_is_zero(c) || sf_sign(c) == product_sign) return c;
		return sf_cancelled(rounding);
	}

	// the product is exact, 48 bits
	bool a_sign, b_sign, c_sign;
	int32_t a_exp, b_exp, c_exp;
	uint64_t a_sig, b_sig, c_sig;
	sf_unpack(a, &a_sign, &a_exp, &a_sig);
	sf_unpack(b, &b_sign, &b_exp, &b_sig);
	uint64_t product = a_sig * b_sig;
	int32_t product_exp = a_exp + b_exp;
	if (sf_is_zero(c))
		return sf_round_pack(
				product_sign, product_exp, product, rounding, flags);

	// Both with the leading 1 at bit 61: the sum fits, and when the two
	// are close enough to cancel, the smaller one is shifted by a bit at
	// most and loses nothing.
	sf_unpack(c, &c_sign, &c_exp, &c_sig);
	int shift = sf_clz64(product) - 2;
	product <<= shift;
	product_exp -= shift;
	shift = sf_clz64(c_sig) - 2;
	c_sig <<= shift;
	c_exp -= shift;
	return sf_add_finite(product_sign,
						 product_exp,
						 product,
						 c_sign,
						 c_exp,
						 c_sig,
						 rounding,
						 flags);
}

// a < b for numbers that aren't NaN
static bool sf_less(const uint32_t a, const uint32_t b) {
	if (sf_is_zero(a) && sf_is_zero(b)) return false;
	if (sf_sign(a) != sf_sign(b)) return sf_sign(a);
	// the same sign: the bits are in order, reversed for negative numbers
	return sf_sign(a) ? a > b : a < b;
}

static uint32_t sf_min_max(const uint32_t a, const uint32_t b,
						   const bool max, uint8_t* flags) {
	if (sf_is_signaling(a) || sf_is_signaling(b)) *flags |= SF_FLAG_INVALID;
	if (sf_is_nan(a)) return sf_is_nan(b) ? SF_NAN : b;
	if (sf_is_nan(b)) return a;
	// -0 < +0: the zeros only differ in the sign bit
	if (sf_is_zero(a) && sf_is_zero(b)) return max ? a & b : a | b;
	const bool less = sf_less(a, b);
	return less != max ? a : b;
}

uint32_t sf_min(const uint32_t a, const uint32_t b, uint8_t* flags) {
	return sf_min_max(a, b, false, flags);
}

uint32_t sf_max(const uint32_t a, const uint32_t b, uint8_t* flags) {
	return sf_min_max(a, b, true, flags);
}

bool sf_eq(const uint32_t a, const uint32_t b, uint8_t* flags) {
	if (sf_is_nan(a) || sf_is_nan(b)) {
		sf_nan(a, b, flags);
		return false;
	}
	return a == b || (sf_is_zero(a) && sf_is_zero(b));
}

bool sf_lt(const uint32_t a, const uint32_t b, uint8_t* flags) {
	if (sf_is_nan(a) || sf_is_nan(b)) {
		*flags |= SF_FLAG_INVALID;
		return false;
	}
	return sf_less(a, b);
}

bool sf_le(const uint32_t a, const uint32_t b, uint8_t* flags) {
	if (sf_is_nan(a) || sf_is_nan(b)) {
		*flags |= SF_FLAG_INVALID;
		return false;
	}
	return !sf_less(b, a);
}

// The magnitude of a finite value rounded toward zero, up to 2^40;
// inexact tells whether a fraction was cut off.
static uint64_t sf_truncate(const uint32_t a, bool* inexact) {
	*inexact = false;
	if (sf_is_zero(a)) return 0;
	bool sign;
	int32_t exp;
	uint64_t sig;
	sf_unpack(a, &sign, &exp, &sig);
	if (exp >= 0) return exp >= 16 ? 1ULL << 40 : sig << exp; // 2^40: too big
	if (exp <= -32) {
		*inexact = true; // sig < 2^24: nothing is left
		return 0;
	}
	*inexact = (sig & ((1ULL << -exp) - 1)) != 0;
	return sig >> -exp;
}

uint32_t sf_to_int(const uint32_t a, uint8_t* flags) {
	if (sf_is_nan(a)) {
		*flags |= SF_FLAG_INVALID;
		return INT32_MAX;
	}
	const bool sign = sf_sign(a);
	bool inexact = false;
	const uint64_t magnitude =
		sf_is_inf(a) ? 1ULL << 40 : sf_truncate(a, &inexact);
	if (magnitude > (sign ? 0x80000000ULL : 0x7FFFFFFFULL)) {
		*flags |= SF_FLAG_INVALID;
		return sign ? (uint32_t)INT32_MIN : (uint32_t)INT32_MAX;
	}
	if (inexact) *flags |= SF_FLAG_INEXACT;
	return sign ? (uint32_t)(0 - magnitude) : (uint32_t)magnitude;
}

uint32_t sf_to_uint(const uint32_t a, uint8_t* flags) {
	if (sf_is_nan(a)) {
		*flags |= SF_FLAG_INVALID;
		return UINT32_MAX;
	}
	const bool sign = sf_sign(a);
	bool inexact = false;
	const uint64_t magnitude =
		sf_is_inf(a) ? 1ULL << 40 : sf_truncate(a, &inexact);
	// -0.5 rounds to 0, which fits; -1 doesn't
	if (sign && magnitude) {
		*flags |= SF_FLAG_INVALID;
		return 0;
	}
	if (magnitude > UINT32_MAX) {
		*flags |= SF_FLAG_INVALID;
		return UINT32_MAX;
	}
	if (inexact) *flags |= SF_FLAG_INEXACT;
	return (uint32_t)magnitude;
}

uint32_t sf_from_int(const int32_t value, const uint8_t rounding,
					 uint8_t* flags) {
	if (!value) return 0;
	const bool sign = value < 0;
	const uint64_t magnitude = sign ? 0 - (uint64_t)(int64_t)value
									: (uint64_t)value;
	return sf_round_pack(sign, 0, magnitude, rounding, flags);
}

uint32_t sf_from_uint(const uint32_t value, const uint8_t rounding,
					  uint8_t* flags) {
	if (!value) return 0;
	return sf_round_pack(false, 0, value, rounding, flags);
}
