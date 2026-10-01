// switch, like in C:
//   - the value has no parentheses, like 'if'; the body is in '{}'
//   - works on integers and enums; 'case' labels are constants
//   - without 'break', execution falls through to the next 'case'
//   - 'default' runs when no 'case' matches
//   - completeness is not checked
//   - 'let' right inside a 'case' is an error: put it in a block '{ ... }'
//   - 'break' inside 'switch' leaves the switch, not the loop around it;
//     'continue' inside 'switch' goes to the next loop iteration

import { puts } from "externs.m"

enum Cause: UWord {
    Interrupt      = 0,
    FetchPageFault = 8,
    LoadPageFault  = 9,
    StorePageFault = 10,
    Syscall        = 12,
}

let describe(c: Cause): Void {
    switch c {
        case Cause.Interrupt:
            puts("interrupt\n")
            break
        case Cause.FetchPageFault:
        case Cause.LoadPageFault:
        case Cause.StorePageFault:
            // three labels, one body
            puts("page fault\n")
            break
        case Cause.Syscall:
            puts("syscall\n")
            break
        default:
            puts("other\n")
    }
}

let daysInMonth(month: UWord): UWord {
    switch month {
        case 2:
            return 28
        case 4:
        case 6:
        case 9:
        case 11:
            return 30
    }
    return 31
}

let countdown(n: UWord): Void {
    // Falling through on purpose: from 3 prints "3 2 1 go"
    switch n {
        case 3:
            puts("3 ")
        case 2:
            puts("2 ")
        case 1:
            puts("1 ")
        default:
            puts("go\n")
    }
}

let scopes(n: UWord): UWord {
    switch n {
        case 0: {
            // a variable in a 'case' needs its own block
            let half: UWord = n / 2
            return half
        }
        default:
            break
    }
    return n

    // Compile error: 'let' right inside a 'case'
    //     switch n {
    //         case 0:
    //             let half: UWord = n / 2
    //     }
}

let findFirstSpace(s: *UByte, n: UWord): UWord {
    // 'break' inside 'switch' leaves only the switch. To leave the loop,
    // use a flag (or 'return', as here).
    for i: UWord in 0..n {
        switch s[i] {
            case ' ':
            case '\t':
                return i
            case 0:
                return n
            default:
                continue  // 'continue' goes to the next iteration of 'for'
        }
    }
    return n
}

let main(argc: UWord, argv: *UByte[]): Word {
    describe(Cause.LoadPageFault)
    let days: UWord = daysInMonth(4)  // 30
    countdown(3)
    let half: UWord = scopes(0)
    let space: UWord = findFirstSpace("hello world", 11)  // 5
    return 0
}

// Test directives (m/tests/run.py)
// @output "page fault\n3 2 1 go\n"
// @exit 0
