// Modules (6): local names of different files don't clash, 'export as'
// and 'import as' rename, imports can be cyclic, an enum crosses files.
// @output "modules a:1 b:2 mix:3 green:4 cycle:3 Down\n"
// @exit 0

import { puts } from "../../../examples/externs.m"
import { value as aValue, Dir } from "a.m"
import { bValue, combine, green, ping } from "b.m"
import { putd } from "../lib/print.m"

let helper(): Word {
    return 100
}

let name(d: Dir): *UByte {
    switch d {
        case Dir.Up: return "Up"
        case Dir.Down: return "Down"
    }
    return "?"
}

let main(argc: UWord, argv: *UByte[]): Word {
    puts("modules a:")
    putd(aValue())
    puts(" b:")
    putd(bValue())
    puts(" mix:")
    putd(combine(1, 2))
    puts(" green:")
    putd(green())
    puts(" cycle:")
    putd(ping(3))
    puts(" ")
    puts(name(Dir.Down))
    puts("\n")
    return helper() - 100
}
