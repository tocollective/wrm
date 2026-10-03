// Shared support for custom LA/IX CPU tests. All accesses are supervisor;
// user entry/Task creation belongs to stage 3. Never edit PTEs in a probe.
import { panic } from "../src/panic.m"
import { allocPage, PAGE_USER } from "../src/memory.m"
import { mmuCreateAddressSpace } from "../src/mmu.m"

let PROBE_VA: UWord = 0x40000000
let PROBE_OLD_VA: UWord = PROBE_VA + 4096

let probeRequire(ok: Bool): Void {
    if !ok panic("MMU CPU probe failed", null)
}

let probeSpace(owner: UWord): *mut UWord {
    let address: UWord = mmuCreateAddressSpace(owner)
    probeRequire(address != 0)
    return address as *mut UWord
}

let probePage(owner: UWord, value: UWord): UWord {
    let address: UWord = allocPage(owner, PAGE_USER)
    probeRequire(address != 0)
    let word: *volatile mut UWord = address as *volatile mut UWord
    word[0] = value
    return address
}

export { PROBE_VA, PROBE_OLD_VA, probeRequire, probeSpace, probePage }
