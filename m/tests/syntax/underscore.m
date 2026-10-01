// Syntax error: '_' goes only between digits
// @error 5: '_' goes only between digits

let main(argc: UWord, argv: *UByte[]): Word {
    let u: UWord = 0x_FF
    return 0
}
