// Heterogeneous scalar arguments, count, typed reads and pack forwarding.
import { puts } from "externs.m"

let sum(initial: Word, args: ...): Word {
    let mut total: Word = initial
    for i: UWord in 0..vaCount(args) total += vaArg(args, i, Word)
    return total
}

let forwarded(args: ...): Word { return sum(0, args) }

let mixed(args: ...): Word {
    if vaCount(args) != 4 return 1
    if vaArg(args, 0, Word) != 42 return 2
    if vaArg(args, 1, Float) != 42.0 return 3
    if vaArg(args, 2, UWord) != 0x42 return 4
    puts(vaArg(args, 3, *UByte))
    puts("\n")
    return 0
}

type Sum = (initial: Word, args: ...): Word

let main(argc: UWord, argv: *UByte[]): Word {
    if sum(10) != 10 return 10
    if sum(10, 20, 30) != 60 return 11
    if forwarded(1, 2, 3) != 6 return 12
    let indirect: Sum = sum
    if indirect(10, 20, 30) != 60 return 13
    return mixed(42, 42.0, 0x42, "correct")
}

// @output "correct\n"
// @exit 0
