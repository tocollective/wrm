#ifndef WRM_SOFTFLOAT_H
#define WRM_SOFTFLOAT_H
#include "common.h"

// IEEE 754 binary32 arithmetic done with integers, for the CPU's floating
// point. The host's float can't do it: WebAssembly has neither rounding
// modes nor exception flags, and hosts differ in how they detect
// underflow. So every host gets the same results and the same flags.
//
// Values are the bits of a float. Every NaN result is the canonical NaN.
// Underflow is detected before rounding: a nonzero result below the
// smallest normal number that is inexact raises SF_FLAG_UNDERFLOW.

// Rounding modes, the values of FCSR.FRM (see docs/INSTRUCTIONS.md)
typedef enum sf_rounding {
	SF_ROUND_NEAREST_EVEN = 0, // RNE, ties to even
	SF_ROUND_ZERO = 1, // RTZ
	SF_ROUND_DOWN = 2, // RDN, toward -infinity
	SF_ROUND_UP = 3, // RUP, toward +infinity
	SF_ROUND_NEAREST_MAX = 4, // RMM, ties away from zero
	SF_ROUND_COUNT,
} sf_rounding_t;

// Exception flags, the bits of FCSR.FFLAGS; operations only set them
#define SF_FLAG_INEXACT 0x01 // NX
#define SF_FLAG_UNDERFLOW 0x02 // UF
#define SF_FLAG_OVERFLOW 0x04 // OF
#define SF_FLAG_DIVIDE_BY_ZERO 0x08 // DZ
#define SF_FLAG_INVALID 0x10 // NV
#define SF_FLAG_MASK 0x1F

#define SF_NAN 0x7FC00000u // the canonical NaN
#define SF_SIGN 0x80000000u

// rounding is an sf_rounding_t; flags get the exceptions the operation
// raises OR-ed in.
uint32_t sf_add(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags);
uint32_t sf_sub(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags);
uint32_t sf_mul(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags);
uint32_t sf_div(const uint32_t a, const uint32_t b, const uint8_t rounding,
				uint8_t* flags);
uint32_t sf_sqrt(const uint32_t a, const uint8_t rounding, uint8_t* flags);
// a * b + c, rounded once
uint32_t sf_fma(const uint32_t a, const uint32_t b, const uint32_t c,
				const uint8_t rounding, uint8_t* flags);

// a NaN operand is ignored, -0 is less than +0
uint32_t sf_min(const uint32_t a, const uint32_t b, uint8_t* flags);
uint32_t sf_max(const uint32_t a, const uint32_t b, uint8_t* flags);

// false with a NaN operand; FEQ is quiet (only a signaling NaN is
// invalid), FLT and FLE are signaling (any NaN is)
bool sf_eq(const uint32_t a, const uint32_t b, uint8_t* flags);
bool sf_lt(const uint32_t a, const uint32_t b, uint8_t* flags);
bool sf_le(const uint32_t a, const uint32_t b, uint8_t* flags);

// Conversions to integers round toward zero, like a C cast, and saturate:
// a value out of range, or NaN, is invalid
uint32_t sf_to_int(const uint32_t a, uint8_t* flags);
uint32_t sf_to_uint(const uint32_t a, uint8_t* flags);
uint32_t sf_from_int(const int32_t value, const uint8_t rounding,
					 uint8_t* flags);
uint32_t sf_from_uint(const uint32_t value, const uint8_t rounding,
					  uint8_t* flags);

#endif // WRM_SOFTFLOAT_H
