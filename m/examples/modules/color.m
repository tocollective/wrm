// A module: everything here is local unless it is listed in 'export'.

type Color {
    r: UByte,
    g: UByte,
    b: UByte,
}

// Local helper: not exported, other files cannot import it.
let colorMake(r: UByte, g: UByte, b: UByte): Color {
    let c: Color = { .r = r, .g = g, .b = b }
    return c
}

let colorRed(): Color {
    return colorMake(0xFF, 0x00, 0x00)
}

let colorGreen(): Color {
    return colorMake(0x00, 0xFF, 0x00)
}

let colorMix(a: Color, b: Color): Color {
    return colorMake(a.r | b.r, a.g | b.g, a.b | b.b)
}

// 'export' can appear anywhere in the file and any number of times.
export { Color }
export { colorRed, colorGreen }

// 'as' exports under another name: importers see 'mix', not 'colorMix'.
export { colorMix as mix }

// Compile error: 'colorBlue' is not declared in this file
//     export { colorBlue }
