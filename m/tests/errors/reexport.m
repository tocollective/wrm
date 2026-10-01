// Error: an imported name can't be exported again
// @error 5: 'puts' is imported

import { puts } from "../../examples/externs.m"
export { puts }

let main(argc: UWord, argv: *UByte[]): Word {
    puts("x")
    return 0
}
