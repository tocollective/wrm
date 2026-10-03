// Runtime regression for the M loader and binary search. No screen required.
// @exit 0
import { font, loadFont, glyphIndex } from "../../../src/console/font/font.m"
import { fontData, fontDataEnd } from "../../../src/console/font/data.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let size: UWord = (&fontDataEnd as UWord) - (&fontData as UWord)
    if loadFont(&fontData, 31) return 1
    if loadFont(&fontData, size - 1) return 2
    if !loadFont(&fontData, size) return 3
    if font.count <= 512 return 4
    for i: UWord in 0..font.count {
        if glyphIndex(font.index[i].code) != i return 5
    }
    let narrow: UWord = glyphIndex(65)
    let wide: UWord = glyphIndex(0x5C3C)
    if narrow == font.count || wide == font.count return 6
    if font.index[narrow].advance != 8 || font.index[wide].advance != 16 return 7
    if glyphIndex(0x65E5) == font.count return 8
    if glyphIndex(0xD800) != font.count || glyphIndex(0x110000) != font.count return 9
    if glyphIndex(0xFFFFFFFF) != font.count return 10
    if font.fallback != glyphIndex(0xFFFD) return 11
    return 0
}
