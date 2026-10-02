// Error: the name of a nested function is a local of the function around,
// and the functions it can see can't be shadowed
// @error 10: 'x' is already declared at line 9; there is no shadowing
// @error 12: parameter 'helper' has the name of the function at line 11; there is no shadowing

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
