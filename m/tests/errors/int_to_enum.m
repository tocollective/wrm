// Error: enums.m: no implicit conversion
// @error 7: an integer literal can't be 'Cause': convert it with 'as'

enum Cause: UWord { Interrupt, Syscall }

let main(argc: UWord, argv: *UByte[]): Word {
    let e: Cause = 12
    if e == Cause.Syscall return 1
    return 0
}
