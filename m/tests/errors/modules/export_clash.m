// Error: two modules export the same name (a linker error)
// @error 'mix' is exported by both

import { mix } from "clash_a.m"
import { mix as mix2 } from "clash_b.m"

let main(argc: UWord, argv: *UByte[]): Word {
    return mix() + mix2()
}
