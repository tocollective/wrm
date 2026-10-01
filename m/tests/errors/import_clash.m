// Error: an imported name and a declaration
// @error 5: 'puts' is already declared at line 4

import { puts } from "../../examples/externs.m"
let puts: UWord = 1

let main(argc: UWord, argv: *UByte[]): Word {
    puts("x")
    return 0
}
