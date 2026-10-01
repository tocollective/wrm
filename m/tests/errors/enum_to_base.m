// Error: enums.m: no implicit conversion
// @error 8: expected 'UWord', found 'Cause'

enum Cause: UWord { Interrupt, Syscall }

let main(argc: UWord, argv: *UByte[]): Word {
    let c: Cause = Cause.Syscall
    let n: UWord = c
    if n == 0 return 1
    return 0
}
