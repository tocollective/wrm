// Error: enums.m: the type name is required
// @error 7: 'Syscall' is not declared; did you mean 'Cause.Syscall'?

enum Cause: UWord { Interrupt, Syscall }

let main(argc: UWord, argv: *UByte[]): Word {
    let s: Cause = Syscall
    if s == Cause.Syscall return 1
    return 0
}
