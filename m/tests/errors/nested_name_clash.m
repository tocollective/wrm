// Error: the name of a nested function is a local of the function around:
// it can't repeat a name of the same block. Shadowing it from a parameter
// of another nested function is only a warning (warnings/shadow.m)
// @error 10: 'x' is already declared at line 9 in the same block

import { puts } from "../../examples/externs.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let x: UWord = 1
    let x(): Void {}
    let helper(): Void { puts("helper\n") }
    let other(helper: UWord): Void {}
    // the locals of main are not visible inside, so 'argc' is free
    let free(argc: UWord): UWord { return argc }
    helper()
    other(1)
    return free(0) as Word
}
