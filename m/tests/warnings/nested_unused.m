// Warnings: an unused nested function; 'let mut f()' never changed
// @warning 9: 'unused' is never used
// @warning 10: 'fixed' is never changed, so 'let' is enough

import { puts } from "../../examples/externs.m"

let main(argc: UWord, argv: *UByte[]): Word {
    let used(): Void { puts("used\n") }
    let unused(): Void {}
    let mut fixed(): Void { puts("fixed\n") }
    used()
    fixed()
    return 0
}
