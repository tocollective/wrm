// Error: enums have no arithmetic
// @error 7: '+' is not defined for enums

enum Dir: UByte { Up, Down }

let main(argc: UWord, argv: *UByte[]): Word {
    let d: Dir = Dir.Up + Dir.Down
    if d == Dir.Up return 1
    return 0
}
