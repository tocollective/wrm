// Float: 32-bit floating point ('float' in C). Uses the general registers
// and the FADD...UTOF instructions. Can be implemented after the integers.
//
// Literals have digits on both sides of the point: 1.5, 0.5, 2.0.
// '1.' and '.5' are not float literals, so '0..10' stays a range.

let average(a: Float, b: Float): Float {
    return (a + b) / 2.0
}

let conversions(): Void {
    let n: Word = 7
    let f: Float = n as Float           // ITOF: 7.0

    let g: Float = 2.75
    let i: Word = g as Word             // FTOI rounds toward zero: 2
    let h: Float = -2.75
    let j: Word = h as Word             // -2

    // FTOI saturates instead of undefined behaviour:
    let big: Float = 3000000000.0
    let k: Word = big as Word           // 0x7FFFFFFF

    // Compile error: no implicit conversion
    //     let e: Float = n
}

let specialValues(): Void {
    let zero: Float = 0.0
    let one: Float = 1.0
    let inf: Float = one / zero         // +infinity, no trap
    let nan: Float = zero / zero        // NaN
    let isNan: Bool = nan != nan        // true: NaN is not equal to itself
}

let main(argc: UWord, argv: *UByte[]): Word {
    let m: Float = average(1.5, 2.5)    // 2.0
    conversions()
    specialValues()
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
