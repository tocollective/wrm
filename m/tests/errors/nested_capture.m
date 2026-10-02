// Error: a nested function can't use the locals of the function around it
// @error 9: 'count' is a local of 'main': a nested function can't capture it
// @error 13: 'argc' is a local of 'main': a nested function can't capture it

import { puts } from "../../examples/externs.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let mut count: UWord = 0
    let bump(): Void { count++ }
    bump()
    let f: (): UWord = (): UWord {
        puts("argc\n")
        return argc
    }
    if f() != 0 return 1
    return 0
}
