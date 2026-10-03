// Custom LA/IX runtime. Unbounded kernel recursion runs into the stack guard;
// the trap entry then rejects the stack. Expected: the early line
// "LA/IX EARLY PANIC: invalid kernel stack" with sp=scratch below bottom,
// then the full dump "LA/IX PANIC: invalid kernel stack" with
// stage=stack-overflow-test, origin=supervisor, CAUSE=10, BADADDR in the
// guard page and r30 = the interrupted sp; exit 254.
import { kernelInit } from "../../../src/kernel/boot.m"
import { panic, setPanicStage } from "../../../src/kernel/panic.m"

let recurse(depth: UWord): UWord {
    // The addition after the call keeps a stack frame for every level.
    return recurse(depth + 1) + depth
}

let main(argc: UWord, argv: *UByte[]): Word {
    kernelInit()
    setPanicStage("stack-overflow-test")
    recurse(0)
    panic("unbounded recursion unexpectedly returned", null)
    return 1
}
