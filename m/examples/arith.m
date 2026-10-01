// Integer arithmetic:
//   - the result has the type of the operands, both operands must have the
//     same type; mixing types needs 'as'
//   - '+', '-', '*', '++', '--' wrap around modulo 2^n, signed types too
//   - '+|', '-|', '*|' saturate at the minimum or maximum of the type
//   - division by zero does not trap: 'x / 0' is all ones, 'x % 0' is 'x'
//   - shifts work on the 32-bit value, the shift amount uses its low 5 bits,
//     and the result is cut to the type
//   - an array index or a shift amount can be any unsigned integer type

let wrapping(): Void {
    let a: UByte = 0xFF
    let b: UByte = a + 1        // 0x00
    let c: UByte = 0 - a        // 0x01

    let s: Byte = 127
    let t: Byte = s + 1         // -128

    let mut i: UHalf = 0xFFFF
    i++                         // 0x0000
}

let saturating(): Void {
    let a: UByte = 0xFF
    let b: UByte = a +| 1       // 0xFF
    let c: UByte = 0 -| a       // 0x00
    let sixteen: UByte = 0x10
    let d: UByte = sixteen *| sixteen  // 0xFF

    let s: Byte = -128
    let t: Byte = s -| 1        // -128
}

let colorChannelAdd(x: UByte, y: UByte): UByte {
    // Colors want saturation: red + red stays red
    return x +| y
}

let mixedTypes(): Void {
    let a: UByte = 200
    let b: UWord = 1000

    let c: UWord = (a as UWord) + b     // 1200
    let d: UByte = (b as UByte) + a     // 1000 as UByte = 0xE8, + 200 = 0xB0

    // Compile errors:
    //     let e: UWord = a + b         // UByte + UWord
    //     let f: UWord = a             // no implicit widening
}

let division(): Void {
    let n: UWord = 7
    let zero: UWord = 0
    let q: UWord = n / zero         // 0xFFFFFFFF
    let r: UWord = n % zero         // 7

    let m: Word = -7
    let z: Word = 0
    let sq: Word = m / z            // -1
    let sr: Word = m % z            // -7

    let min: Word = -2147483648
    let neg: Word = -1
    let x: Word = min / neg         // -2147483648 (wraps, like '+')
    let y: Word = min % neg         // 0

    let small: UByte = 9
    let bz: UByte = 0
    let bq: UByte = small / bz      // 0xFF: all ones of UByte
}

let shifts(): Void {
    let one: UWord = 1
    let n: UWord = 33
    let a: UWord = one << n         // 2: only the low 5 bits of 33 are used

    let x: UByte = 0x81
    let k: UByte = 1
    let b: UByte = x << k           // 0x02: 0x102 cut to UByte
    let c: UByte = x >> 8           // 0x00
    let d: UByte = x << 8           // 0x00

    let s: Byte = -16
    let e: Byte = s >> 2            // -4: '>>' is arithmetic for signed types
    let u: UByte = 0xF0
    let f: UByte = u >> 2           // 0x3C: logical for unsigned types
}

let lookup(table: UByte[], b: UByte, h: UHalf, w: UWord): UByte {
    // Any unsigned type works as an index, without 'as'
    let x: UByte = table[b]
    let y: UByte = table[h]
    let z: UByte = table[w]

    // Compile error: signed index
    //     let s: Word = 1
    //     let v: UByte = table[s]
    return x +| y +| z
}

let main(argc: UWord, argv: *UByte[]): Word {
    wrapping()
    saturating()
    mixedTypes()
    division()
    shifts()
    let c: UByte = colorChannelAdd(0xF0, 0x20)  // 0xFF
    return 0
}

// Test directives (m/tests/run.py)
// @output ""
// @exit 0
