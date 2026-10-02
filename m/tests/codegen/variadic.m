// Runtime regression fixture. Frontend checks can run without building:
//   python3 -B tools/m.py --check m/tests/codegen/variadic.m
import { puts } from "../../examples/externs.m"

type Result { total: Word, tail: Word, count: UWord }
type Action = (value: Word): Word
enum Flag: UByte { Off, On }

let mut counter: Word = 0
let next(): Word { counter++ return counter }
let increment(value: Word): Word { return value + 1 }

let sum(initial: Word, args: ...): Word {
    let mut total: Word = initial
    for i: UWord in 0..vaCount(args) total += vaArg(args, i, Word)
    return total
}

let forward(args: ...): Word { return sum(0, args) }

let sequence(args: ...): Word {
    return vaArg(args, 0, Word) * 100 + vaArg(args, 1, Word) * 10 + vaArg(args, 2, Word)
}

// Seven fixed words leave one register: the entire pack goes on the stack.
let seven(a: Word, b: Word, c: Word, d: Word, e: Word, f: Word, g: Word, args: ...): Word {
    return a + b + c + d + e + f + g + vaArg(args, 0, Word)
}

// The ninth fixed word goes on the stack; the pack needs padding after it.
let nine(a: Word, b: Word, c: Word, d: Word, e: Word, f: Word, g: Word,
         h: Word, i: Word, args: ...): Word {
    return a + b + c + d + e + f + g + h + i + vaArg(args, 0, Word)
}

// The hidden result pointer plus six words also force the pack to the stack.
let result(a: Word, b: Word, c: Word, d: Word, e: Word, f: Word, args: ...): Result {
    return { .total = a + b + c + d + e + f,
             .tail = vaArg(args, 0, Word), .count = vaCount(args) }
}

let scalars(args: ...): Word {
    if vaArg(args, 0, Byte) != -42 return 1
    if vaArg(args, 1, UHalf) != 65535 return 2
    if !vaArg(args, 2, Bool) return 3
    if vaArg(args, 3, Flag) != Flag.On return 4
    if vaArg(args, 4, Float) != 42.25 return 5
    if vaArg(args, 5, UWord) != 0xFFFFFFFF return 6
    if vaArg(args, 6, *Void) != null return 7
    let action: Action = vaArg(args, 7, Action)
    if action(7) != 8 return 8
    puts(vaArg(args, 8, *UByte))
    return 0
}

let main(argc: UWord, argv: *UByte[]): Word {
    if forward() != 0 return 10
    if forward(1, 2, 3) != 6 return 11
    if seven(1, 2, 3, 4, 5, 6, 7, 8) != 36 return 12
    if nine(1, 2, 3, 4, 5, 6, 7, 8, 9, 10) != 55 return 13
    let r: Result = result(1, 2, 3, 4, 5, 6, 7, 8)
    if r.total != 21 || r.tail != 7 || r.count != 2 return 14
    if sum(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
              17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32) != 528 return 15
    if sequence(next(), next(), sum(0, next(), next())) != 127 return 16
    if counter != 4 return 17
    let callback: (a: Word, b: Word, c: Word, d: Word, e: Word, f: Word,
                   g: Word, args: ...): Word = seven
    if callback(1, 2, 3, 4, 5, 6, 7, 8) != 36 return 18
    return scalars(-42 as Byte, 65535 as UHalf, true, Flag.On, 42.25,
                   0xFFFFFFFF, null, increment, "variadic ok\n")
}

// @output "variadic ok\n"
// @exit 0
