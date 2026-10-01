// Error: a program has one 'main' (a linker error)
// @error a second 'main'

import { helper } from "second_main.m"

let main(argc: UWord, argv: *UByte[]): Word {
    helper()
    return 0
}
