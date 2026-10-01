// Error: structs can't be compared
// @error 9: 'Color' values can't be compared

type Color { r: UByte, g: UByte, b: UByte }

let main(argc: UWord, argv: *UByte[]): Word {
    let a: Color = {}
    let b: Color = {}
    if a == b return 1
    return 0
}
