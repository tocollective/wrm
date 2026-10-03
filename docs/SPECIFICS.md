# WRM.081632 considerations for the kernel, runtime and drivers

This document explains which WRM properties matter when developing
LA/IX and programs in M: what the CPU does, what software must do and
which mistakes cause context loss, isolation failures or a machine halt.
It covers the ISA, ABI, boot, memory, every device and emulator facilities.
The full opcode and register tables remain in the original specifications.

Sources: [ISA](INSTRUCTIONS.md), [machine and devices](SPECIFICATION.md),
[ABI](ABI.md), [emulator](../README.md). Current implementation details
have been checked against the [CPU](../source/cpu.c), [MMU](../source/mmu.c),
[bus](../source/motherboard.c) and [emulator device drivers](../source/devices/).
Discrepancies between specifications and implementation are corrected in the
specifications themselves; current implementation limits and LA/IX choices
are collected in [section 13](#clarifications).

The checklists below are development and verification requirements, rather
than a report that LA/IX has already implemented everything. Stage status is
in the [microkernel plan](../laix/docs/KERNEL.md).

## Contents

- [1. Architecture, instructions and addresses](#architecture)
- [2. ABI, stack, M and executables](#abi)
- [3. Reset, firmware and kernel entry](#boot)
- [4. Traps, IRQs, EPC and return](#traps)
- [5. Low entry words and TrapFrame](#entry)
- [6. MMU, permissions, ASIDs and TLB](#mmu)
- [7. Atomics, memory ordering and code modification](#ordering)
- [8. Floating point and FCSR](#floating-point)
- [9. MMIO and DMA: general rules](#io-dma)
- [10. Device-specific considerations](#devices)
- [11. Time, pipeline and performance](#timing)
- [12. Diagnostics, debugging and snapshots](#diagnostics)
- [13. Current implementation limits and LA/IX choices](#clarifications)
- [14. End-to-end LA/IX verification](#acceptance)

<a id="architecture"></a>

## 1. Architecture, instructions and addresses

### Sizes and modes

WRM is a 32-bit little-endian machine. A pointer and a word occupy 4 bytes.
The CPU has 32 integer registers, `pc` and control registers. Only `r0`
is hardwired to zero; the ABI assigns the other registers' roles.
Writing a result to `r0` discards it, but the instruction still executes:
a load into `r0` can fault or read MMIO with a side effect.

Every instruction occupies 4 bytes and must be 4-byte aligned. There are
no variable-length instructions or delay slots. Data addresses for `LH/SH`
are aligned to 2 bytes, and those for `LW/SW/LL/SC` to 4. Misaligned accesses
raise exceptions; packed structures require byte accesses or explicit value assembly.

`STATUS.UM` selects user/supervisor mode. `HLT`, `WFI`, `IRET`, `TLBI` and
ordinary control register access require supervisor mode. Users may
read `CYCLE/CYCLEH/INSTRET/INSTRETH`, and read and write `FCSR`.
With the MMU disabled, user mode **does not restrict physical memory access**:
isolation requires `UM=1`, `PTBR.EN=1` and correct tables together.

`CPUID` is currently `0x010000FF`: ISA version 1 in bits 31–24, and the
MMU, binary32, LL/SC, high multiply, additional TLBI modes, debug,
bit operations and FCSR extensions in bits 0–7. The kernel reads it in supervisor mode.
`HARTID=0`: the current machine has one CPU. The ISA's discussion of multiple
cores describes a future model, rather than operational SMP.

### Encoding and integer operations

The opcode occupies the low 8 bits. R/I/U/N formats differ in the placement
of registers and immediates. Reserved instruction fields must be
zero; invalid encoding, an unknown control register or a write to a
read-only control register causes an illegal instruction exception.
This rule also applies to unused fields: for example, `rs1` in `MFCR`,
`rd` in `MTCR/TLBI`, and `rs2` in single-input R instructions.

Most `imm14` values are signed: range −8192…8191. In `ANDI/ORI/XORI` and
immediate shifts/rotates, the field is unsigned. Shifts and rotates use only
the low 5 bits of the count: a shift by 32 acts as a shift by 0.
`SHR` is logical, `SAR` arithmetic. `LB/LH` sign-extend,
`LBU/LHU` zero-extend. In `SW`, the `rd` field identifies the store source.

Addition, subtraction and multiplication operate modulo 2³², without overflow traps.
`MULH/MULHU/MULHSU` distinguish signedness when computing the high word.
`DIV/REM` are signed, `DIVU/REMU` unsigned. On division by zero, the CPU
returns `0xFFFFFFFF` and the remainder equals the dividend; there is no exception.
For `INT_MIN / -1`, the result is `INT_MIN`, remainder 0. If the language
requires a division error, the compiler/runtime must check for it.

There are `CLZ/CTZ/POPCNT`, `BSWAP`, sign extension, `ROL/ROR/RORI`, and signed
and unsigned min/max. `CLZ(0)` and `CTZ(0)` equal 32. There is no separate `ROLI`:
to rotate left by n, rotate right by `(32-n) & 31`.
The full list and exact names are in [opcodes](INSTRUCTIONS.md#opcodes).

### Address construction and branches

`LUI` shifts the immediate by **13**, rather than 12 or 16 bits:

```text
hi(x) = x >> 13
lo(x) = x & 0x1FFF
x = (hi(x) << 13) | lo(x)
```

The low part is nonnegative and fits a signed `imm14`, so
`LUI` + `ORI` and `LUI` + `ADDI` need no correction to the high part.
`AUIPC` adds to the address of the instruction itself. In `%pcrel_hi/%pcrel_lo`,
the second instruction must immediately follow `AUIPC` and be
`ADDI`, a load or a store. `ORI` is incorrect for this pair: the `AUIPC`
result already contains the low bits of the `pc` address.

A conditional branch computes its offset from its own address: `imm14 << 2`,
range about ±32 KiB. `JAL` has `imm19 << 2`, about ±1 MiB;
the return address is `pc+4`. `JALR` computes `(rs1 + imm14) & ~3`:
it discards the low two bits instead of causing an alignment fault.
Such a jump can conceal a corrupted function pointer.

Checklist:

- [ ] Check instruction, stack and data alignment in assembly/runtime code.
- [ ] Do not apply another ISA's constant and offset splitting rules to WRM.
- [ ] Distinguish signed/unsigned loads, comparisons, division and high multiply.
- [ ] Explicitly check for division by zero if the language semantics require it.
- [ ] Run untrusted code only with the MMU enabled and user permissions.

<a id="abi"></a>

## 2. ABI, stack, M and executables

The [ABI](ABI.md) uses ILP32: `int`, `long` and pointers are 4 bytes;
`long long`, `double` and `long double` are 8 bytes with alignment 8. `float` is
binary32 in GPRs, `double` binary64 in the software runtime. Structure fields
have their own alignment; structure size is padded to a multiple of
its maximum alignment. C bit-fields fill from the low bit upwards.

| Registers | ABI convention |
| --- | --- |
| `r1–r8` | Arguments; `r1–r2` also hold the result |
| `r9` | Scratch, syscall number, linker veneer temporary register |
| `r10–r27` | Callee-saved |
| `r28/tp` | Thread pointer; an ordinary function does not change it |
| `r29/fp` | Frame pointer or callee-saved |
| `r30/sp` | Stack pointer |
| `r31/ra` | Return address, caller-saved |

A 64-bit argument occupies two consecutive registers, low word first;
the pair need not start at an even number. If an entire argument does not
fit in the remaining registers, it and all subsequent arguments go on the stack.
Structs/unions up to 8 bytes are passed as one/two words; larger ones through
a pointer to a copy. For a large result, a hidden pointer to the result
buffer is passed as the first argument.

The stack grows downwards; `sp` is a multiple of 8 at every call. **There is no red zone**:
an interrupt handler may use memory below `sp`. `ra` is not saved
by hardware on an ordinary call. With a frame pointer, `fp` equals the entry
`sp`, and saved `ra` and `fp` are at `fp-4` and `fp-8`.
Without frame pointers, walking the stack frame chain is not guaranteed.
A frame larger than the `imm14` range requires additional address calculation.

`r9` cannot be used for a hidden function argument or expected to survive
until the function's first instruction: the linker may route a far `JAL`
through a veneer that loads the target into `r9` and executes `JALR`.
The linker does not fix far conditional branches; the compiler inverts
the condition and uses a jump. There is no global pointer register.

### Two different variadic ABIs

C `...` always passes additional arguments on the stack with C promotions:
`char/short → int`, `float → double`. M `args: ...` passes a borrowed pack
`{data: pointer, count: UWord}`, size 8 bytes, alignment 4, as a small
aggregate after the fixed arguments. On the stack, the pack occupies
an 8-aligned slot and is never split between registers and the stack.

In M, each trailing scalar occupies one 4-byte word;
`Float` retains binary32, `Bool` is normalized to 0/1. Aggregates in
trailing arguments are prohibited. An empty pack is `{0, 0}`.
`vaArg(args, i, T)` checks neither bounds nor type and does not convert the number:
the callee must know the format and ensure `i < vaCount(args)`.
A pack can be forwarded, but it borrows the original caller's memory and cannot
outlive that call. An M variadic function is not directly compatible with C `...`.
This is particularly important for `panic/debugPrint` and format strings.

### TLS, ELF and process startup

Only local-exec TLS is defined: `.tdata`, then `.tbss`, a separate copy
per thread, with `tp` pointing to its start. The kernel saves the user's
`tp` on a trap; kernel code must not automatically treat it as its own TLS.

The object/executable format is ELF32 little-endian, private `EM_WRM=0x0816`,
`e_flags=0`; relocations are in `SHT_RELA`, with explicit addends. `%hi/%lo`,
`%pcrel*`, `%tprel*`, branches and JAL have their own WRM relocation types.
Ordinary ELF tools can read the headers, but support for another ISA
does not imply support for WRM disassembly or relocation.

The ELF loader uses `PT_LOAD`, preserves `p_vaddr ≡ p_offset mod 4096`,
applies `PF_R/PF_W/PF_X` and zeroes `p_memsz-p_filesz`.
`PT_TLS` describes TLS. Sections with different permissions require separate pages.
A flat boot image is not ELF and does not provide automatic BSS zero-fill.
Dynamic linking, PIE, other TLS models and the debug information format
are not yet defined by the ABI.

At user process startup, the OS creates an 8-aligned stack with `argc`, `argv`,
a null terminator, `envp`, a terminator and auxv (type/value, ending with type 0).
`ra/fp` and all other GPRs, including `tp`, initially contain 0. `crt0` creates TLS,
zeroes BSS if the loader has not done so, and calls `main` and `exit`.
Firmware boot entry has a different contract, described below.

The compiler may generate calls to `memcpy/memmove/memset/memcmp`,
64-bit arithmetic functions and software double even in freestanding code.
The kernel needs the corresponding runtime symbols and correct ABI for these functions.

Checklist:

- [ ] Assembly↔M follows register roles, hidden result and alignment 8.
- [ ] A trap saves more than callee-saved registers: the entire interrupted context.
- [ ] Variadic printing uses M's pack ABI and checks the argument count.
- [ ] Packs and pointers into the caller's frame do not remain after return.
- [ ] The loader checks sizes, range overflow, entry and ELF permissions.
- [ ] TLS and required compiler runtime functions are prepared before user startup.

<a id="boot"></a>

## 3. Reset, firmware and kernel entry

Hardware reset starts execution at `pc=0xFE000000`, in supervisor mode,
with `STATUS=0x10` (`EXL=1`), the MMU disabled, and TLB and counters cleared.
The remaining CPU registers initially contain 0. Until `IVEC` is set and
`EXL` cleared, any fault halts the CPU: early startup must be fault-free.

Reset preserves **RAM, VRAM and disk contents**. It stops DMA,
clears FIFOs/IRQ masks, and disables the timer, sound, watchdog, network and display;
it resets the palette and cursor and closes shared-folder handles. RTC time
and the RNG sequence continue. VRAM is zero at power-on, but
BSS and free RAM cannot be assumed to contain zeros.

Firmware looks for a boot image on the floppy first, then disk 0. Disk 1 is
not the next boot candidate in the current firmware. Without a usable
image, an on-screen menu opens; firmware messages do not go to UART.

The flat image header contains `MAGIC=0x424D5257` (`WRMB`), the number of 512-byte
sectors, `ENTRY` as a 4-aligned offset within the image, and `FLAGS=0`.
Firmware loads the entire image, including its header, at physical `0x10000`.
Its code must not be addressed as though the loader had removed the header.

| At boot image entry | Value/property |
| --- | --- |
| `pc` | `0x10000 + ENTRY` |
| `r1` | Boot info at `0x1000` |
| `sp` | `0x10000`, empty downward-growing stack |
| `r2`, `ra` | 0; other GPRs are unspecified |
| `STATUS`, `IVEC`, `PTBR` | `0x10`, 0, 0 |
| PIC `ENABLE` | 0 |
| Boot disk | Idle, `DONE` clear |
| Video | Firmware console 640×480×8 bpp, display on, IRQ off |

Boot info contains the `INFO` magic `0x4F464E49`, `SIZE` (currently 40),
`RAM_SIZE`, boot controller, disk size, image address/size, clock frequency,
and the count and physical address of device entries. Check `SIZE` before
accessing fields; the device table consists of 8-byte `{ADDRESS, ID}` pairs
and ends below `0x2000`. Other control registers are unspecified at boot entry.

Low memory: `0…0xFFF` is unspecified; `0x1000…0x1FFF` holds boot info/table;
`0x2000…0xFFFF` is free, but contains the firmware stack. The kernel copies the
boot data it needs, switches to its own stack, zeroes its BSS and reserves
the image, BSS, stack, MMU tables and entry state before distributing pages.
A RAM page outside the file image is not necessarily free:
uninitialized sections and the stack also occupy RAM.

The firmware font is in VRAM at offset `0x3FF000`: 256 glyphs of 8×16,
16 bytes per glyph, bit 7 on the left. Codes `0x20–0xFF` are Windows-1252,
low codes are symbols/box drawing. This is not a UTF-8/Unicode font.
Changing modes does not clear VRAM; a custom console must explicitly
initialize the screen, font/palette and engine state.

Checklist:

- [ ] Save entry `r1` before calls; validate boot info and ranges.
- [ ] Zero BSS even after a warm reset with dirty RAM.
- [ ] Set up your own `sp`, entry state and `IVEC` before clearing `EXL`.
- [ ] Reserve all occupied physical pages, including low memory.
- [ ] Do not enable IRQs until handlers and device acknowledgement are ready.

<a id="traps"></a>

## 4. Traps, IRQs, EPC and return

### Control registers and STATUS

| CR | Name | Purpose |
| --- | --- | --- |
| 0 | STATUS | Mode, IRQ, exception level and step flags |
| 1, 2, 3 | EPC, IVEC, SCRATCH | Return PC, common vector and software temporary |
| 4, 5, 6 | CAUSE, BADADDR, PTBR | Trap cause, additional data and MMU context |
| 7, 8 | CYCLE, CYCLEH | Low/high word of the cycle counter, read-only |
| 9, 10 | INSTRET, INSTRETH | Low/high retired count, read-only |
| 11 | CPUID | ISA version/extensions, read-only |
| 12, 13, 14, 15 | TADDR0, TCTRL0, TADDR1, TCTRL1 | Two debug triggers |
| 16 | HARTID | Core number, currently 0, read-only |
| 17 | FCSR | FP flags/rounding mode |

STATUS bit numbers: `IE=0`, `PIE=1`, `UM=2`, `PUM=3`, `EXL=4`, `SS=5`,
`PSS=6`; all other bits read as zero. Do not confuse a bit number with a mask:
for example, the `EXL` mask is `1<<4`, or `0x10`.
`MFCR/MTCR/IRET` wait for older instructions to complete; a control write
takes effect for subsequent instructions. CR numbers and TLBI modes
are encoded directly in the instruction; in M, `mfcr/mtcr` require
a constant expression, rather than a runtime index.

### What the CPU saves and what it leaves to software

On a trap, the CPU records control state, but **does not save GPRs, change
`sp`, switch `PTBR` or create a hardware stack frame**.
One `IVEC` handles every cause. Entry:

```text
PIE = IE;   IE = 0
PUM = UM;   UM = 0
PSS = SS;   SS = 0
EXL = 1
CAUSE = cause
EPC = address according to the event type
pc = IVEC
```

`PUM` identifies the trap's origin; current `UM` is already 0 at entry.
`PIE/PSS` are saved values, rather than active IRQ/step flags.
`SCRATCH` is a software control register for temporary storage,
rather than an automatically populated pointer or a swap instruction.

### Exact EPC rules

| CAUSE | Event | EPC at entry | BADADDR | Action before return |
| --- | --- | --- | --- | --- |
| 0 | IRQ | Next instruction not yet executed | Unchanged | Leave EPC unchanged |
| 1 | Illegal instruction | Faulting instruction | Instruction word | Fix/emulate or terminate the task |
| 2 | Misaligned fetch | Faulting PC | PC | Fix the target or terminate the task |
| 3, 4 | Misaligned load/store | Faulting instruction | Data address | Emulate or terminate the task |
| 5, 6, 7 | Fetch/load/store bus error | Faulting instruction | Fetch/data address | Investigate the failed physical access |
| 8, 9, 10 | Fetch/load/store page fault | Faulting instruction | Virtual address | Retry at the same EPC after fixing the mapping |
| 11 | Privileged instruction in UM | Faulting instruction | Instruction word | Usually terminate the task |
| 12 | SYSCALL | SYSCALL itself | 0 | Add 4 for an ordinary completed syscall |
| 13 | BREAK | BREAK itself | 0 | Add 4 when continuing past the breakpoint |
| 14 | Single-step | Next instruction | Previous PC | Leave EPC unchanged |
| 15 | Debug trigger | Matching instruction | Match address | Remove the cause of the match, then retry |

For a fault, the faulting instruction's own result has not completed; all
older instructions have completed, and younger ones have no architectural effects.
After fixing a page fault, `EPC += 4` would skip the required load/store.
After an IRQ, the same adjustment would lose the next instruction. With `SYSCALL/BREAK`,
leaving EPC unchanged causes another trap at the same instruction.
On an IRQ, `BADADDR` may contain a value from an earlier fault: it must not
be printed as the address that caused the IRQ. For illegal/privileged instructions,
it is an instruction word, rather than a pointer that can be dereferenced.

Syscall ABI: number in `r9`, at most 6 argument words in `r1–r6`,
no stack arguments; result in `r1` or `r1/r2`, errors `-4095…-1`.
All other GPRs must be preserved. The OS chooses syscall numbers and meanings.
A blocking syscall must resume according to an agreed kernel protocol,
rather than accidentally repeat because EPC was not saved.

### IE, EXL, nested faults and IRET

`IE` masks only IRQs. Exceptions are possible with `IE=0` in either mode.
`EXL=1` blocks IRQs and handling of a new fault: a second fault **halts
the CPU**, without a second entry into `IVEC`. This is not a separate exception vector,
a hardware emergency stack or an automatic reset.
The first saved `EPC/CAUSE/BADADDR` remains the first trap's state;
look for the second faulting instruction in the emulator dump/pipeline.

If the kernel wants to handle faults during `copy_from_user`, it first needs
a complete frame, a valid kernel stack, saved `EPC/STATUS/CAUSE/BADADDR`
and a fault-fixup protocol, then it can clear `EXL`. `IE=0` may remain in effect.
If nested IRQs are required, additionally set `IE=1` after saving the context.
Nesting requires separate frames; a shared temporary slot is dangerous.

`IRET` performs `pc=EPC`, `IE=PIE`, `UM=PUM`, `SS=PSS`, `EXL=0`.
Before restoring EPC, ensure `IE=0, EXL=1` again;
user `UM` and `sp` must not become active midway through restoration.
Writing `MTCR STATUS` with `UM=1` changes the mode for the very next instruction;
`IRET` is normally used for controlled entry into user mode.
An IRQ may be accepted immediately after an enabling `MTCR STATUS`.

### WFI and HLT

`WFI` waits for an **asserted CPU IRQ line**, even with `IE=0` or `EXL=1`.
With `IE=1, EXL=0`, the CPU enters the handler with EPC after `WFI`;
otherwise, it simply continues with the next instruction. The PIC must still
enable at least the corresponding line: pending with `ENABLE=0` does not wake it.
A continuously asserted IRQ can turn idle into a busy loop.

`HLT` stops the machine until reset; it is not an idle instruction. After HLT,
devices no longer tick, the watchdog does not run and DMA does not complete.

Checklist:

- [ ] Select retry/skip/next according to CAUSE; do not apply a blanket `EPC += 4`.
- [ ] Determine user origin from `PUM`; save the original `sp` and GPRs.
- [ ] Do not perform potentially faulting accesses until the frame/nesting is ready.
- [ ] Restore with `IE=0, UM=0, EXL=1`, followed by a single `IRET`.
- [ ] Idle uses `WFI`; panic stop has a separate HLT/power-off policy.

<a id="entry"></a>

## 5. Low entry words and TrapFrame

### Why words below 8 KiB are needed

At the first trap instruction, no GPR is free: each holds an interrupted
value. The user's `sp` cannot be trusted. An `offset(r0)` address within
the signed `imm14` range allows access to a known word without loading
its address into a temporary register. The [ABI recommends](ABI.md#entering-the-kernel)
storing the current kernel stack pointer in such a low word.

In current LA/IX, [defs.inc](../laix/src/arch/wrm081632/defs.inc) allocates:

| Virtual address | LA/IX purpose |
| --- | --- |
| `0x00001FF0` | `KERNEL_SP`: current task's kernel stack |
| `0x00001FF4` | `KERNEL_STACK_BOTTOM` |
| `0x00001FF8` | `KERNEL_STACK_TOP` |
| `0x00001FFC` | `TRAP_SAVED_R1`: temporary storage for `r1` |

**LA/IX chooses these addresses; hardware does not reserve them.**
The words lie at the end of the boot info page, so boot info and the device
table must end below `0x1FF0`; the kernel checks this.
The OS must reserve physical storage and establish the mapping itself. For each user
page directory, the low virtual words must point to the appropriate kernel
page with `U=0`; this mapping must already exist at trap entry.
The CPU will not switch the directory for the kernel.

These words should not be placed in page zero. `U=0` would exclude only
users: in the kernel, **dereferencing NULL would not fault**, but would read
or corrupt entry state. A call through NULL would execute the word `0x00000000`,
which is `HLT`, and the headless emulator would exit with code 0, as on success.
LA/IX therefore leaves page zero unmapped in every directory: NULL loads, stores
and calls with offsets below 4 KiB cause page faults. This protection does not
apply before the MMU is enabled. User aliases of the physical page holding
entry words are prohibited: otherwise, a task could overwrite the stack pointer/bounds through another VA.
Supervisor access also requires `R/W` according to the operation.
Protect the entire physical frame, rather than just four addresses.

The entry path, stack, frame, handler code, required tables and emergency
output must be accessible in **every active address space**. When changing
`PTBR`, the new tables must already map the current code/stack;
a partially prepared directory will fault under EXL and halt the CPU.

### Frame and current entry limits

`TrapFrame` is an OS software structure, rather than a CPU format. The current
[LA/IX layout](../laix/src/trap/trap_layout.inc) has 32 GPRs (128 bytes),
`EPC/STATUS/CAUSE/BADADDR/FCSR/PTBR` (24 bytes) and two reserved words;
a total of **160 bytes**, a multiple of 8. `r30` in the frame is the interrupted
stack pointer, rather than the frame address. `r0` is explicitly saved as 0 for diagnostics.

[trap.asm](../laix/src/trap/trap.asm) first saves `sp` in `SCRATCH`,
checks `PUM`, and selects a trusted kernel stack for user origin or
the interrupted stack for supervisor origin. It saves `r1` through a low word,
checks alignment and bounds with room for the frame, a bottom canary and
512 bytes of dispatcher headroom, then saves the remaining values.
This reserve is LA/IX policy, rather than a hardware guarantee of maximum
M call depth. A canary supplements, but does not replace, an MMU guard page.

A single `TRAP_SAVED_R1` suits the current single-CPU, non-nested
initial entry phase with `EXL=1`. If nesting is extended, it must not be
live during the next entry; future SMP needs per-core entry state
and stacks. A user branch in assembly does not yet prove user-mode return:
a real entry with a malicious user `sp` must be tested.

`PTBR` in the frame is useful for diagnostics, but saving the field does not
automatically switch address spaces. The scheduler must select the
returning task's directory, retain access to the frame and restore
the rest of the thread state. `FCSR` requires separate restoration.

Checklist:

- [ ] Low words and all their physical aliases are inaccessible to users.
- [ ] Every address space maps entry code/state, the stack and the panic path.
- [ ] M/assembly agree on TrapFrame offsets, size and alignment.
- [ ] All GPRs, original `sp`, `tp`, `ra`, EPC, STATUS and FCSR are checked.
- [ ] A task switch updates `KERNEL_SP`, stack bounds and selected PTBR.
- [ ] A user trap with `sp=0`, misaligned or kernel-like `sp` uses the kernel stack.
- [ ] Stack overflow has a verified emergency path that does not access the bad stack.

<a id="mmu"></a>

## 6. MMU, permissions, ASIDs and TLB

### Tables and permissions

WRM uses two-level tables: a 4 KiB directory with 1024 entries of
4 bytes each; the next level has the same size. A VA is split into
`dir[31:22]`, `table[21:12]`, `offset[11:0]`. Base page size is 4 KiB,
superpage size 4 MiB. `PTBR` contains the physical directory base in bits 31–12,
an 8-bit ASID in 11–4 and `EN` in bit 0; bits 3–1 are reserved/read-as-zero.

PTE bit numbers: `V=0`, `R=1`, `W=2`, `X=3`, `U=4`, `A=5`, `D=6`, `G=7`,
bits 11–8 reserved, physical base in 31–12. A non-leaf PDE has `V=1`,
`R/W/X=0`, with its base pointing to a table. If a PDE has any `R/W/X`, it is a leaf
superpage; physical bits 21–12 must be 0. A PTE without `V` or without
any `R/W/X` does not map a page.

Fetch requires `X`, load `R`, store `W`, independently of each other.
`W` does not imply `R`. User mode additionally requires `U` in the leaf;
`U` in a non-leaf PDE does not set child permissions. Supervisor bypasses only
the `U` check, rather than `R/W/X`. There is no automatic supervisor prohibition
on user pages: checking user pointers remains the OS's responsibility.

`IVEC/EPC` and address values in `BADADDR` are virtual with the MMU on.
Directory/table storage is addressed physically. Walks read RAM/ROM,
rather than MMIO/VRAM; an inaccessible entry causes a page fault, without device side effects.
After successful translation, hardware sets `A`, and on writes `D`,
in the **leaf** entry; for a superpage, this is the PDE. Writeback failure is also a page fault.
Tables should normally be in RAM; read-only ROM is possible only if
the required A/D bits are already set.

`A` may be set by speculative fetch even if the instruction never
executes. Clearing A/D in memory without TLB invalidation is insufficient:
a cached entry may retain old flags. A failed `SC` does not set D.
PTE permissions do not override physical bus rules: `X` on MMIO/VRAM still
does not permit fetch, and `W` on ROM still causes a store bus error.

### ASIDs and invalidation

| Operation | What is invalidated |
| --- | --- |
| `TLBI rs1, 0` | One 4 KiB VA page of the current ASID and a matching global translation |
| `TLBI rs1, 1` | All non-global translations for the ASID in `rs1 & 255` |
| `TLBI r0, 2` / `TLBI.ALL` | The entire TLB, including global entries; `rs1` must be 0 |
| `MTCR PTBR` with the same ASID | Non-global entries for that ASID |
| `MTCR PTBR` with a different ASID | Old contexts are retained; global entries are retained |

An ASID is a tag, rather than a permission or CPU number. Before assigning a
previously used ASID to another address space, invalidate that ASID
or perform a full flush. Different directories with one ASID require a consistent
refresh policy; changing the physical directory base alone is insufficient for global entries.

`G` on a leaf makes the translation shared across ASIDs; `G` on a non-leaf PDE makes
**all** pages in that table global. An incorrect `G` in a user directory entry
allows the TLB to use another task's translation. Global mappings must
have identical addresses, backing and permissions in every context.

A superpage is cached as separate 4 KiB fragments. One page TLBI does not
remove the remaining cached fragments of a 4 MiB region. After changing a
superpage, all corresponding page invalidations or a broader flush are
required; for a global superpage, `TLBI.ALL` is a simple safe option.

`V=0` is not cached, so turning a known invalid entry into a valid one
does not require removing a negative translation. This does not remove the need
to fully prepare the table before publishing the PDE and check that no old
valid mapping remains in the TLB.

A valid entry enters the TLB during a walk **before permission checks**. TLBI
is therefore required for any change to `R/W/X/U`, including **expanding** permissions:
if a store page fault is followed by adding `W` to the PTE and returning without TLBI,
the retried store will page-fault again on the old cached entry, and the task
will loop. This applies to COW, demand write and granting `U`/`X`.
For valid→invalid, a frame change or permission restriction, stale translations
must be removed **before reusing the frame**.

A guard page must be absent along with all alternative mappings to
its physical storage. A large identity superpage does not leave a 4 KiB hole:
the corresponding region must be split into ordinary pages for a guard.
The same applies to RX code, R-only constants, RW data and W^X policy.

Checklist:

- [ ] Tables are 4 KiB aligned and reserved in the physical allocator.
- [ ] A large superpage does not map nonexistent frames beyond the end of RAM.
- [ ] User/kernel permissions are checked for fetch/load/store, including supervisor R/W/X.
- [ ] Unmap/revoke removes translations before freeing the physical frame.
- [ ] A fault handler expanding permissions (COW, demand write) performs TLBI before retry.
- [ ] ASID reuse, global mappings and superpage fragments have an explicit TLBI policy.
- [ ] Guards, read-only sections and low entry frames have no permissive aliases.
- [ ] A/D collection accounts for speculative fetch and cached flags.

<a id="ordering"></a>

## 7. Atomics, memory ordering and code modification

`LL` reads a word and reserves the **physical**, 4-aligned word. `SC` writes
only if the reservation remains: result **0 means success, 1 means failure**.
Every `SC` clears the reservation. Even a failed SC checks alignment
and write permissions; it cannot be used as a safe pointer probe.
It can fault, but an ordinary failure does not mark the page dirty.

Overlapping CPU/DMA writes, traps, `MTCR PTBR`, `TLBI` and reset clear
the reservation. Two VA aliases of one physical word share one
reservation. An IRQ between `LL/SC` can cause failure without a competing
thread, so updates always use a retry loop, with an appropriate waiting
policy for locks. On success, SC is atomic with respect to the CPU and DMA.

For MMIO, `LL/SC` is not an ordinary lock primitive: a read may already
remove a FIFO item, and a write attempt may have device-specific consequences.
LL/SC works on VRAM, but **direct drawing engine writes do not clear
the reservation**; CPU and DMA writes do. SC therefore does not guarantee
the absence of an intervening engine draw in the same pixel storage.

`FENCE` orders data memory operations. The current single-core CPU
executes them in order, but the compiler must also preserve the required ordering
of MMIO, descriptor publication and `OWN`. M uses
`*volatile T` / `*volatile mut T` for MMIO: accesses occur individually, at their
own width, in source order relative to other volatile accesses.
Ordinary memory may be reordered relative to volatile; `fence()`
orders them. `mtcr`, `tlbi`, atomics and `asm` also have a compiler
ordering contract. See the [M hardware API](../mc/docs/spec/07-hardware.md).
M's `atomicCompareSwap` returns the old value, rather than the SC code.
`asm` has no operands and does not permit changing the stack/callee-saved registers
or transferring control outside the insertion: a complete trap entry
is written as a separate assembly function.

The frontend fetches instructions ahead of time. After a code patch store,
a control transfer that discards prefetched instructions is required: a taken branch, `JAL/JALR`,
`IRET`, `MTCR STATUS/PTBR` or `TLBI`. Falling through into modified code
may execute either the old or new instruction. **FENCE does not synchronize
instruction fetch.** For DMA-generated code, first wait for completion,
then perform such a control transfer and ensure an `X` mapping.

Checklist:

- [ ] SC success is compared with 0; failures are retried without losing updates.
- [ ] Interrupt/nesting paths do not expect to preserve a reservation.
- [ ] Atomics are not used on FIFO/MMIO with side effects.
- [ ] Descriptor data is published before OWN/start doorbell.
- [ ] CPU/DMA-modified code is started after completion and a refetch transition.

<a id="floating-point"></a>

## 8. Floating point and FCSR

Hardware float is IEEE binary32 in the same GPRs. There is no separate FPU register
file or lazy FPU trap; float loads/stores use ordinary words.
`FMADD/FMSUB` use the **old rd value** as the addend and round
once: FMSUB computes `old_rd - rs1*rs2`.
Subnormals are supported; floating-point exceptions do not trap,
but set sticky flags in `FCSR`.

| FCSR | Meaning |
| --- | --- |
| bits 0–4 | `NX` inexact, `UF` underflow, `OF` overflow, `DZ` division by zero, `NV` invalid |
| bits 7–5 | `FRM`: 0 nearest ties-even, 1 toward zero, 2 down, 3 up, 4 nearest ties-away |
| FRM 5–7 | Reserved: a write retains the previous mode but updates flags |

Reset sets FCSR=0: nearest ties-even, flags clear. Writing flags replaces them,
rather than performing W1C as many device status registers do.
Flags are set at retirement; squashed instructions do not leave them behind.
`MFCR` sees older operations' effects; `MTCR FCSR` refetches younger
instructions with the new rounding mode. The ABI preserves the mode across ordinary
calls, but not exception flags. Both belong to the **thread** and must
be saved by the kernel; software double uses the same FCSR environment.

On a trap, the kernel saves FCSR before doing its own FP work and may set
its own mode/flags; on return, it restores the task's state. Saving GPRs
alone is insufficient. Current LA/IX does this in trap entry/exit.

Edge-case semantics:

- Arithmetic NaNs are canonicalized to `0x7FC00000`, without preserving payload/sign.
  `FSGNJ/FSGNJN/FSGNJX` change only the sign and preserve the payload.
- `FEQ/FLT/FLE` return false for NaN; `+0` and `-0` are equal.
  `FMIN/FMAX` choose the non-NaN operand when only one is NaN; two NaNs produce
  canonical NaN. For min/max, `-0 < +0`.
- `FTOI/FTOU` **always truncate toward zero**, regardless of FRM, with
  saturation to the integer range limits; NaN produces the maximum integer value.
- `NV` occurs for invalid arithmetic, out-of-range conversion,
  signaling NaN; for `FLT/FLE`, any NaN. `DZ` is finite nonzero / 0;
  `0/0` produces NV. Overflow also produces NX. Underflow uses tininess
  **before rounding** and requires an inexact result.
- `FCLASS` returns one bit for the class: −∞, negative normal/subnormal,
  −0, +0, positive subnormal/normal, +∞, signaling/quiet NaN (bits 0–9).
  Sign operations and FCLASS do not set flags. Exact cancellation produces
  +0, except under rounding down, which produces −0.

Checklist:

- [ ] FCSR is saved on syscall, IRQ and context switch, including sticky flags.
- [ ] Kernel FP does not change the interrupted task's environment.
- [ ] NaNs, signed zero, subnormals, saturation and rounding modes are checked.
- [ ] Software double/runtime follow the same FCSR contract.

<a id="io-dma"></a>

## 9. MMIO and DMA: general rules

### Physical map and register access

| Physical range | Purpose |
| --- | --- |
| `0x00000000…RAM_SIZE-1` | RAM; installed slots are contiguous without gaps |
| `0xFC000000…0xFC3FFFFF` | 4 MiB VRAM window |
| `0xFD000000…0xFDFFFFFF` | I/O region, a separate 4 KiB page per device |
| `0xFE000000…0xFFFFFFFF` | 32 MiB read-only ROM |

Other addresses do not exist on the physical bus. The emulator supports
four RAM slots: 1/2/4/8/16/32 MiB each, default 4 MiB total in one
slot, maximum 128 MiB. An empty slot consumes no address space.
The OS obtains the actual size from boot info, rather than the default config.

MMIO registers are 32-bit; **every access address must be a multiple of 4, even
for a byte/half-word operation**. `LBU UART+0` reads the low byte, while `LBU UART+1`
causes a bus error; this is not a byte-addressable array of register parts.
A narrow read retains the register read's full side effect:
for example, RNG consumes a word and a FIFO removes an event. A narrow write writes
the low value, rather than universally merging one byte into the old word.
Use the width specified by the register interface, usually `UWord`.

Writes to existing read-only device registers are ignored. Accessing an
undefined offset or an absent device page causes a bus error.
Each device page has a read-only `ID` at `+0xFFC`:
`TYPE[31:16]`, `VERSION[15:8]` (currently 1), `IRQ[7:0]` (`0xFF` means no IRQ).
Checking type/version and using the firmware device table is preferable
to probing every address without a handler. Such a probe may fault.

Device status often uses **W1C**: writing a one clears
the corresponding flag. `status = status | mask` may accidentally acknowledge
other events read in status. Write only the known acknowledgement mask.
Other status bits are clear-on-read: a diagnostic read also
changes the device. Snapshotting an entire MMIO structure is dangerous for DATA/FIFO.

### DMA bypasses the MMU

A DMA register/descriptor contains a **physical address**. The device does not read
`PTBR`, check PTE `U/R/W/X` or generate a CPU page fault:
an invalid bus access is reflected in device error/fault state.
A virtual buffer at VA `0x40000000` does not acquire the same DMA address;
physical frames, a contiguous buffer or scatter-gather are required if the device
supports it. A contiguous VA range may consist of scattered frames.

Accessibility in the current emulator, according to [DMA bus callbacks](../source/motherboard.c):

| Device family | DMA read | DMA write |
| --- | --- | --- |
| HDD/floppy | RAM and VRAM window | RAM and VRAM window |
| Video/Ethernet/audio/shared folder | RAM, VRAM window, ROM | RAM and VRAM window |
| All | MMIO and unmapped addresses prohibited | MMIO, ROM and unmapped addresses prohibited |

The device itself adds alignment, length and descriptor constraints.
ROM readability does not make ROM suitable for a descriptor that the device must
update. Ethernet returns OWN through a descriptor write;
rings should be placed in writable RAM.

WRM has no implemented IOMMU or hardware DMA frame whitelist.
A driver issuing raw MMIO commands can specify a physical address belonging to the
kernel, entry state or another task. **Moving such a driver into user mode does
not by itself isolate its DMA**. A capability for an MMIO page restricts access
to the controller, but not the destinations it can program.

Viable microkernel options:

1. The kernel/trusted broker accepts requests, checks physical ranges,
   builds descriptors and has exclusive access to raw DMA command registers.
2. The driver receives raw DMA/MMIO access and is considered a trusted component
   with the corresponding authority; this is an explicit trust boundary.
3. Full isolation of a raw DMA driver requires changing the hardware model itself:
   adding an IOMMU/allowed-range checks. Current WRM has neither.

A bounce buffer alone does not protect against an untrusted driver if it can still
program an arbitrary ADDRESS. After descriptors are validated,
the user must not change them or their pointer graph until completion:
the disk reads scatter-gather entries as it progresses, otherwise
allowing substitution after validation.

While DMA is active, frames and descriptors are pinned: the allocator does not give them
to other tasks, unmapping does not free backing, and the owner neither modifies the source
nor uses an incomplete destination. IPC cancellation or driver death
does not automatically cancel DMA. A buffer may be freed after device stop
or confirmed completion; an HDD transfer stops only on reset.

DMA failure can occur after a partial transfer. Check completion,
error and progress together; do not treat DONE as proof of success. Disk WRITE commits
only whole sectors, while disk READ may already have changed part of a sector in RAM;
video EXPAND may have drawn only the first lines; shared READ/WRITE has
a partial byte count. Reset does not roll back external writes already performed.

Checklist:

- [ ] MMIO pointers are volatile; register offsets/widths are correct.
- [ ] Clear-on-read and W1C do not lose events during diagnostics/acknowledgement.
- [ ] The DMA API accepts validated ranges/handles and translates VA→PA.
- [ ] `address+length` overflow, frame ownership and alignment are checked.
- [ ] DMA buffers/descriptors are pinned and protected from changes after validation.
- [ ] Exit/crash/cancel does not free storage used by active DMA.
- [ ] A trust boundary is defined for each user driver with raw DMA MMIO.

<a id="devices"></a>

## 10. Device-specific considerations

All 17 occupied device pages are listed below (16 types: two HDDs of the same
type). The IRQ column identifies the PIC line; the CPU receives one shared IRQ input.
Full register layouts are in [Devices](SPECIFICATION.md#devices).

| Device | Physical page | IRQ | Key consideration |
| --- | --- | --- | --- |
| PIC | `0xFD000000` | — | 32 level-triggered lines; CLAIM does not acknowledge the event |
| Keyboard | `0xFD001000` | 0 | HID events, FIFO, clear-on-read overflow |
| UART | `0xFD002000` | 1 | DATA has read/write side effects; TX is always ready |
| Timer | `0xFD003000` | 2 | 64-bit COUNT; EXPIRED coalesces missed periods |
| Power | `0xFD004000` | 11 | OFF/RESET stop execution after the store |
| HDD 0 | `0xFD005000` | 3 | DMA, 512-byte sectors, DONE even on error |
| HDD 1 | `0xFD006000` | 4 | Same interface; firmware does not boot from it |
| Video | `0xFD007000` | 5 | VRAM, sync/async commands, shared DONE/VBLANK IRQ |
| Floppy | `0xFD008000` | 6 | Removable, slow DMA, CHANGED |
| Beeper | `0xFD009000` | — | One tone, duration in ticks |
| Mouse | `0xFD00A000` | 7 | FIFO of relative/absolute events, disabled on reset |
| Ethernet | `0xFD00B000` | 8 | Physical descriptor rings, OWN, host NAT |
| Audio | `0xFD00C000` | 9 | 8 DMA voices; FAULT alone does not raise an IRQ |
| RTC | `0xFD00D000` | 10 | Read-low latch, host wall time, one-shot alarm |
| RNG | `0xFD00E000` | — | A read consumes a word; seeded mode is not secret |
| Shared folder | `0xFD00F000` | — | Synchronous host operations, 16 handles |
| Watchdog | `0xFD010000` | 12 | Bark, grace, reset; acknowledgement does not replace a kick |

### 10.1 PIC

`PENDING` holds current device line levels, `ENABLE` is the mask (reset 0),
`ACTIVE = PENDING & ENABLE`. `CLAIM` returns the **lowest-numbered**
active line or `0xFFFFFFFF`. Reading CLAIM does not change state; there is no separate
EOI register. The handler must clear the source **in the device**, otherwise
the same IRQ will recur immediately after IRET.

A low number takes priority on every CLAIM; one unserviced source
can obstruct the others. A handler may have a budget and mask a problematic line,
but masking does not remove the pending condition. Polling is allowed with ENABLE=0.
Always check the sentinel during IRQ dispatch; do not use it as an index.

- [ ] Service the device source before IRQ return; check all shared flags.
- [ ] Check two simultaneously pending IRQs and the absence of starvation.
- [ ] The mask/unmask protocol is consistent with device polling and event delivery.

### 10.2 Keyboard

The FIFO holds 32 events; `DATA` removes an event, or returns 0 when empty. The low 16 bits hold USB
HID usages from page `0x07`; bit 31 indicates release. This is a key code, not ASCII or
Unicode; software implements layout, modifiers, compose and autorepeat.
There is no hardware key repeat. Overflow means an event was lost and is cleared
by reading STATUS; a lost release can leave software key state stuck.
CONTROL bit 0 flushes the FIFO. IRQ 0 remains asserted while the queue is nonempty.

- [ ] Separate HID key events from text input and handle press/release.
- [ ] Drain the FIFO and handle overflow by recovering key state.

### 10.3 UART

A `DATA` write sends the low byte to host stdout; a read removes an RX byte.
An empty read returns 0, indistinguishable from a real NUL without STATUS.
The RX FIFO holds 64 bytes; IRQ 1 remains asserted while it is nonempty. STATUS overflow
is clear-on-read; CONTROL bit 0 flushes. TX does not block, TX-ready is always 1;
there is no TX IRQ. No wait loop for transmit FIFO space is needed.

The native stdin terminal operates in raw mode without local echo: the guest does
echo/line editing. The host limits piped input reads to free FIFO space; input
scripts can overflow it. UART stdout is separate from emulator stderr.
In the browser, UART input is absent and output goes to the page/JS console.

- [ ] Check RX-ready before reading; do not treat NUL as an absent byte.
- [ ] Panic output does not depend on IRQs, heap, scheduler or a complex formatter.

### 10.4 Timer

The 64-bit free-running COUNT and down-counter advance on every system tick.
Read COUNT consistently: **HI, LO, HI**, retrying if HI values differ.
FREQUENCY reports ticks/second. Writing CONTROL loads VALUE from RELOAD,
so even a mode/enable change restarts the counter.
`RELOAD=N` expires after N ticks; 0 acts as 1.

One-shot clears enable after expiry; periodic reloads VALUE.
EXPIRED is W1C; disabling does not clear it. While the bit is set, multiple expiries
are not counted separately. To measure time and missed quanta, compute a delta
from COUNT, rather than multiplying the IRQ count by RELOAD.

- [ ] Obtain frequency from boot info/the register; convert time with overflow checks.
- [ ] CONTROL restart and separate EXPIRED acknowledgement are checked.
- [ ] Check a delayed handler: one IRQ after multiple periods.

### 10.5 Power controller

OFF uses the low 8 bits as the emulator process exit code; the RESET value
is ignored. A request is applied at the end of the store tick; subsequent instructions
do not execute. OFF/RESET reads return 0. Before OFF, data saving and
disk FLUSH/shared SYNC must finish; code after the store cannot fix anything.

Host close/Ctrl+C sets the STATUS power-request and IRQ 11 only if
the PIC has enabled IRQ 11 and the CPU is not halted. Otherwise, the host exits immediately;
a repeated request also exits immediately. The STATUS request is W1C.
RESET_CAUSE: 0 power-on, 1 software, 2 host key, 4 watchdog;
3 is reserved for double fault, but currently a double fault halts the CPU.

- [ ] A shutdown request has a worker for flushing, then OFF; acknowledgement does not mean shutdown.
- [ ] Distinguish clean guest exit, HLT and unhandled fault by log and exit code.

### 10.6 HDD 0 and HDD 1

Sectors are 512 bytes. READ/WRITE use SECTOR, COUNT and physical ADDRESS;
FLUSH and IDENTIFY are separate commands. COMMAND clears previous DONE/ERROR,
then validates arguments; an invalid command may complete synchronously with DONE.
COUNT=0 for READ/WRITE completes without error. While BUSY, writes to transfer
registers and COMMAND are ignored; there is no separate cancel command.

HDD DMA: 4000000 bytes/s, one word every `floor(clock_rate*4/4000000)` ticks
(32 at 32 MHz), 4096 ticks/sector; the first word arrives W ticks after COMMAND.
ADDRESS advances by a word; SECTOR/COUNT change after a whole sector.
DONE is a level IRQ, W1C or cleared by the next COMMAND; ERROR remains until
the next command. Check SECTOR+COUNT bounds without integer wrap,
alignment 4 and device ERROR (1…7), rather than DONE alone.

Scatter-gather: COMMAND.LIST bit 8; LIST points to an array of 8-byte entries
`{physical ADDRESS, LENGTH}`; address/length are multiples of 4, length>0.
There is no end marker: COUNT sectors defines the volume (IDENTIFY uses one block).
An entry is read at the first word of its segment; LIST advances by 8;
a descriptor need not coincide with a sector boundary. After ending midway through
an entry, continuation requires a new descriptor for the remainder, rather than
reusing the current LIST as a continuation pointer.

READ failure may leave a partial sector in memory; WRITE failure does not
write a partial sector to disk, but previous whole sectors have already been written.
Progress registers are needed for diagnostics and retry policy.
Disk DMA also reaches the [VRAM window](SPECIFICATION.md#vram-window).

WRITE completion means bytes reached the host file, **not durable
storage**. FLUSH performs host sync; the machine pauses while the host performs
the operation, but to the guest the command completes in the store tick. Read-only FLUSH
succeeds. A successful FLUSH is required before reporting `fsync` success and shutting down.

IDENTIFY writes a 512-byte `WRMD` block: version, size, flags, UUID, serial,
model. Numeric fields are little-endian; UUID bytes use ordinary big-endian UUID
order. IDENTIFY ignores SECTOR/COUNT and requires an inserted disk.
The default serial depends on the absolute image path; in deterministic mode, on the
file name. Renaming/moving may change identity; an explicit serial stabilizes it.
The host locks images for access: writable exclusive, read-only
shared; do not rely on live sharing of a changing image between VMs.
Only whole sectors are accessible; trailing file bytes are invisible.

- [ ] Immediate error, partial failure, BUSY writes and zero COUNT are checked.
- [ ] The entire SG list is validated, pinned until completion and unchanged.
- [ ] Flush failure does not report false durable success to the client.
- [ ] Controller UUID/serial are not confused with filesystem UUID.

### 10.7 Floppy

The register interface matches HDD, but media is removable and DMA slower: 62500 bytes/s,
word period `floor(clock_rate*4/62500)` ticks (2048 at 32 MHz).
Insertion/ejection sets CHANGED; CHANGED and DONE hold shared IRQ 6,
and each flag requires acknowledgement. After reset, CHANGED is clear even with a disk inserted.
Ejection while BUSY stops the transfer with no-disk error 2; whole sectors
already written to the image remain.
The size need not be 1.44 MB, but cannot exceed it: at most 2880 sectors; a larger
image cannot be inserted. Reread SECTORS on media changes.

- [ ] CHANGED invalidates cached sectors, geometry and filesystem state.
- [ ] Both IRQ sources and removal during DMA are handled.

### 10.8 Video card and VRAM

4 MiB VRAM, a 2D engine and cursor. There is no text mode: text is drawn with glyph bitmaps.
Resolutions 320×240/640×480/800×600/1024×768 combine with 1/4/8/16/32 bpp.
1/4 bpp are packed **MSB first**, 8 bpp is paletted, 16 bpp little-endian RGB565,
32 bpp little-endian XRGB8888. Palette values are `0x00RRGGBB`, cursor ARGB.
MODE with invalid depth/extra bits is ignored; a valid mode change preserves
VRAM/palette. WIDTH/HEIGHT/BPP/PITCH reflect the mode; visible PITCH is fixed.

The display shows the visible region from START at frame end (~60 Hz in ticks).
A START flip allows double buffering, but a write does not trigger immediate
scanout. Lines outside VRAM and a disabled display are black. FRAME increments,
VBLANK is sticky until W1C; multiple frames coalesce into one bit.
Engine surfaces have their own BASE/PITCH/XY and can be offscreen.

FILL/COPY/EXPAND from VRAM execute synchronously on the COMMAND store.
LOAD/STORE and EXPAND.MEMORY use DMA, remaining BUSY until completion; engine register writes
while BUSY are ignored. Other registers, including MODE/palette, can change;
EXPAND.MEMORY uses the destination depth at startup.
A zero-size rectangle draws nothing; invalid bounds cause an error before drawing.
COPY with identical pitch has memmove overlap semantics;
with different pitches, overlapping results are undefined.

LOAD copies physical RAM/ROM/VRAM into VRAM; STORE copies VRAM into RAM/VRAM,
one word/tick, with addresses/count multiples of 4. EXPAND.MEMORY reads aligned words
containing source line bits; the source may start at any byte/bit,
but **all words read**, including the edges, must be accessible and permitted
by the DMA broker. Completed lines remain after a subsequent error.
The VRAM window also allows CPU reads/writes of any ordinary width.
Code fetch and page table walks from it are prohibited.

DONE and VBLANK share IRQ 5 with separate CONTROL enables and W1C bits.
ENGINE ERROR means failure, even with DONE. The cursor is 64×64 ARGB8888,
256 bytes/line, alpha-blended over the frame without changing VRAM;
XY is signed, HOT defines the hotspot, and offscreen pixels are clipped.
This is a separate VRAM resource that the screen/font allocator must not overwrite.

- [ ] The VRAM allocator reserves visible buffers, font and cursor without overlap.
- [ ] Pixel packing, pitch, mode and rectangle bounds are checked before commands.
- [ ] BUSY prevents handing the engine to another request.
- [ ] Both IRQ sources are acknowledged separately; MODE/START updates are coordinated with frames.
- [ ] DMA validation accounts for aligned-word overread in EXPAND.MEMORY.

### 10.9 Beeper

One square-wave tone; FREQUENCY is in Hz, 0 means silence. DURATION is in ticks,
0 means indefinitely until disabled; a nonzero duration decreases only while on,
and expiry clears CONTROL on. Manual off preserves remaining duration.
Enabling again restarts the wave. A frequency above half the clock rate
produces silence. There is no IRQ; completion can be polled.
Host sound may be delayed by up to roughly 85 ms; headless/mute does not change
device state or timing, only playback.

- [ ] Do not wait for a beeper IRQ; delays/timeouts use ticks, rather than host playback.

### 10.10 Mouse

The FIFO holds 64 events and is disabled after reset; CONTROL enable is required. DATA pops,
returning 0 when empty; each event has bit 31=1. Relative DX/DY/WHEEL are signed 8-bit,
Y increases downwards; buttons represent state after the event. Long movements are split,
and adjacent compatible motion events merge. STATUS overflow is clear-on-read.
IRQ 7 remains asserted while the FIFO is nonempty; flushing does not replace updating button state.

Relative units are host window pixels, not necessarily video mode pixels.
The guest gains pointer capture after a click; the capture click itself is not an event;
Ctrl+Alt/focus loss releases the pointer and reports releases for held buttons.
There is no capture in absolute mode: event bit 27=1, DX/DY are 0, POSITION is in
current mode pixels. **Read DATA first, then POSITION**: POSITION belongs to
the last popped event, rather than the FIFO head. Adjacent moves coalesce;
do not expect an event for every intermediate position. Headless events
may arrive from an input script.

- [ ] Signed motion and button state are handled separately.
- [ ] Absolute position is read after its DATA; mode switching is checked.
- [ ] Overflow/focus loss does not leave stuck buttons.

### 10.11 Ethernet card

Ethernet II frames are 14…1514 bytes without FCS. Link status does not imply CONTROL on.
RX/TX rings are physical arrays of 8-byte descriptors `{ADDRESS, CONTROL}`,
ring base alignment 8, up to 1024 entries. The buffer byte address does not require
word alignment. Length is in the low 16 bits, ERROR bit 30, OWN bit 31.
OWN=1 hands the descriptor to the device; the buffer/descriptor must not change during this time.

For RX, length initially means capacity; the device writes the frame and actual length,
then returns OWN=0. An oversized frame is truncated with ERROR. For TX, length
is the frame size; publishing OWN must be followed by TX_KICK. Sending completes
within the TX_KICK store, processing descriptors until the first OWN=0.
Ring base/size change only while off; enabling resets NEXT indices to 0.

RX/TX/LOST/FAULT in PENDING are W1C; IRQ 8 depends on CONTROL masks; FAULT
is enabled by either RX/TX IRQ enable. A DMA fault stops the card at the
descriptor and disables it. Without a free RX descriptor, the host queue retains
up to 64 frames, then loses them. An off card drops incoming frames.
The driver reads ring state, rather than treating the sticky RX bit as a packet count.

The guest implements ARP/IP/TCP/UDP/DHCP itself. The native backend is host NAT:
guest `10.0.2.15/24`, gateway/DHCP `10.0.2.2`, DNS `10.0.2.3`,
guest MAC `52:54:00:12:34:56`. The gateway supports TCP/UDP and, conditionally,
unprivileged ping; it neither reassembles nor sends fragments, with MSS up to 1460.
DNS answers A queries; other types receive no answer. By default, public
destinations are allowed and local/private ones blocked; the last matching allow/deny rule
determines access. Port forwarding separately opens the host→guest path.

`--no-net` gives link down. The browser backend uses a proxy for TCP/DNS,
without native UDP/ping. Reset/snapshot load loses host connections:
guest networking must handle the disappearance of transport state.

- [ ] OWN publication/return are ordered; rings are writable and buffers pinned.
- [ ] RX truncation, TX invalid length, ring exhaustion and FAULT do not cause hangs.
- [ ] Indices and descriptors are reinitialized after off/fault/restart.
- [ ] Tests account for backend/network policy and snapshot disconnection.

### 10.12 Audio card

8 DMA voices, host mix of 48000 stereo frames/s. Sample data is signed 8-bit or
signed 16-bit little-endian, mono/stereo: frames are 1/2/4 bytes. ADDRESS is physical,
LENGTH/LOOP/POSITION are in **frames**, rather than bytes; RATE uses the low 24 bits in frames/s.
16-bit values require even addresses. RAM/ROM/VRAM can be read.
There is no interpolation; fractional advance accumulates inside the device, and RATE 0
holds the current frame. MASTER and voice VOLUME specify left/right 0…255;
MASTER resets to 0, so a voice being on does not yet imply audible sound.

Enabling does not reset POSITION; set it to 0 for replay. Writing POSITION
resets the fractional phase. With loop and LOOP<LENGTH, the voice returns
to the loop region; otherwise, it ends at LENGTH and turns off.
End/halfway signals set the voice bit in STATUS; IRQ 9 is asserted when STATUS≠0,
and STATUS is W1C. Multiple signals from one voice coalesce; stream refill
must check POSITION and time, otherwise an underrun is possible.

Bad DMA/alignment disables the voice and sets the FAULT bit **without a STATUS signal**;
FAULT alone does not raise an IRQ. Software must check for errors.
A loop buffer is pinned while the voice plays; refill one half after
the device passes that half, rather than on any voice IRQ.
Mute/headless preserve device operation. Host playback latency differs from
guest POSITION and can reach roughly 85 ms.

- [ ] Frame sizes/length multiplication and sample physical ranges are checked.
- [ ] STATUS and FAULT are serviced separately; silent MASTER is accounted for.
- [ ] Streaming tolerates delayed handlers and repeated half/end events.

### 10.13 RTC

Host wall time is in Unix seconds + nanoseconds; local UTC_OFFSET is in signed
seconds, including DST. **Read LO first**: this latches the entire date;
HI/NANOSECONDS/UTC_OFFSET refer to that latch until the next LO.
This protocol differs from HI–LO–HI counters. The guest cannot set the RTC;
the OS stores an offset for its own time. Leap seconds are not accounted for.

The alarm is one-shot: whole seconds are compared with ALARM when armed, then
roughly every 1 ms of machine time. A past alarm fires immediately.
ALARM is sticky/IRQ 10 W1C; disarming does not clear status. Host time may
differ from guest ticks; monotonic deadlines/the scheduler use Timer.
`--rtc` provides a virtual epoch + ticks since power-on, with UTC_OFFSET 0;
like host RTC, virtual RTC does not roll back time on guest reset.

- [ ] Clock APIs separate monotonic ticks from wall time.
- [ ] Latch reads, past alarms, clear/disarm and reset are checked.

### 10.14 RNG

DATA returns a new 32-bit word without waiting; a narrow read consumes the entire
word. STATUS bit 0 means **seeded**, rather than “ready” or “enough entropy”.
In ordinary mode, the source is the host CSPRNG. `--seed`/deterministic select
a reproducible ChaCha20 stream: N little-endian in the first 8 key bytes,
the remainder 0, nonce 0, and a 64-bit block counter starting at 0.
Such a seed is not a source of secret keys.

The sequence continues on reset. A snapshot's seeded stream
continues from its state; host mode obtains new bytes after load.
A new sample may numerically equal the previous one: ID uniqueness must
be ensured separately, rather than assumed from random32.

- [ ] Seeded mode is explicitly distinguished from host entropy mode.
- [ ] Key/ID generation does not rely on every random word being unique.

### 10.15 Shared folder

A host filesystem proxy, **not a block disk or LA/IX filesystem**. Commands
OPEN/CLOSE/READ/WRITE/STAT/READDIR/MKDIR/REMOVE/RENAME/TRUNCATE/SYNC
execute synchronously in the COMMAND store, without IRQs. A host operation may
take wall time even though the guest tick does not advance. Read ERROR/RESULT
immediately; the next COMMAND will reset RESULT/change the outcome.

PATH/PATH2/data are physical; under the current bus implementation, paths can be in RAM/ROM/VRAM,
and READ destinations in writable RAM/VRAM. Paths are NUL-terminated, at most 1023
bytes + NUL, relative to the shared root. Empty slash components are skipped;
`.`/`..`, control characters, backslash and colon are prohibited. The host determines
encoding/case. Symlinks outside the root are prohibited on native POSIX; **Windows links
are not checked** under the current documented contract; do not attribute this sandbox
to LA/IX filesystem policy. A read-only share or handle prohibits modifications.

There are 16 handles, 0…15; OPEN chooses the lowest free one. Directories require a separate
DIRECTORY flag; handles are shared across the entire device, with the server providing
client isolation. READ/WRITE allow up to 1 MiB per command, without alignment constraints;
64-bit POSITION and ADDRESS increase, COUNT decreases, RESULT is actual bytes.
EOF/partial DMA errors permit a short result. Writes may extend the file,
and gaps read as zeros. SYNC is required for durable acknowledgement.

A STAT record is 32 bytes with type/size/mtime; READDIR returns a record and name, with a buffer
of at least 288 bytes; RESULT 0 means end of directory. Entry order is host-dependent;
`.`/`..` and invalid names are omitted. Reset/snapshot load closes all
handles; files are not rolled back. Error 7 after load requires reopening.

- [ ] The server checks paths, flags, handles, short I/O and RESULT/ERROR.
- [ ] Physical buffers are validated before a synchronous host command.
- [ ] Read-only and SYNC are part of the contract; a snapshot closes client handles.
- [ ] Tests do not depend on READDIR order or host case/encoding behavior.

### 10.16 Watchdog

TIMEOUT/GRACE are in ticks; 0 acts as 1. Enabling loads TIMEOUT.
Expiry sets BARK/IRQ 12 and starts grace; its end resets with cause 4.
KICK reloads TIMEOUT, leaves grace and clears BARK.
W1C BARK only deasserts the IRQ; it **does not cancel reset after grace**.
Changed TIMEOUT/GRACE take effect after the next kick.

LOCK makes CONTROL/TIMEOUT/GRACE read-only until reset; KICK remains available.
There is no NMI: with a masked IRQ/EXL=1, bark will not reach the handler, but the countdown
continues to reset. HLT stops ticks, so the watchdog **cannot
recover the CPU after HLT/double fault**. The countdown continues during WFI.

- [ ] Kick, acknowledgement alone, locked state and reset cause 4 are checked.
- [ ] Do not rely on bark with IE=0 or watchdog recovery after halt.

<a id="timing"></a>

## 11. Time, pipeline and performance

The default 32 MHz clock is host-configurable; it is not a mandatory ISA constant.
Timer, DMA, video frames, beep duration, audio sampling and watchdog operate
in machine ticks. Ordinary RTC uses the host wall clock, a separate
time scale. Under slow emulation, guest monotonic time lags host time;
unthrottled, it may advance faster. CPU HLT stops ticks; WFI does not.

On each tick, devices run in a fixed order: Timer → HDD0/HDD1 →
Video → Floppy → Beeper → Audio → RTC → Watchdog → CPU. An IRQ/DMA event
on that tick may be visible to the CPU in the same tick. The emulator optimizes
empty intervals and synchronizes lazy devices before register access;
this does not permit software to rely on host polling-loop speed.

The IF/ID/EX/MEM/WB pipeline has a latency of 5 cycles and throughput up to 1 instruction
per cycle. Forwarding is present; an immediate load-use dependency adds 1 cycle.
Branches are predicted not taken; a taken branch/jump discards the two younger
instructions, with a 2-cycle penalty. Arithmetic, including division and float,
executes in one EX cycle in the current model; this is not the latency of actual
host arithmetic. An `IRET` redirect at WB has a 4-cycle penalty.
Control accesses serialize older operations; mode/PTBR/trigger/FCSR
changes and TLBI refetch younger instructions.
A TLB walk occurs in the same cycle without an additional timing penalty.

There are no delay slots or requirements to insert NOPs for forwarding. Loads/stores
in MEM do not execute speculatively; speculative IF may walk page tables
and set A. Squashed instructions do not change GPRs, RAM or FCSR flags,
but observing A does not prove retirement. Fetch/walk cause no MMIO
side effects because MMIO/VRAM are prohibited for these bus operations.

64-bit `CYCLE` and `INSTRET` are read HI–LO–HI with retry on rollover.
CYCLE includes WFI, but not HLT; INSTRET counts only successfully retired
instructions: faulting SYSCALL/BREAK are not added, IRQ is not an instruction,
and squashed instructions are not counted. Guest reset zeroes CPU counters
and Timer COUNT; RTC virtual epoch + power-on ticks continues advancing.
These origins must not be mixed after reset.

TLB size (currently 64 entries in [mmu.h](../include/mmu.h)), replacement,
host-side caches and lazy-device acceleration are emulator details. Kernel
correctness must not depend on eviction accidentally clearing a stale mapping.
Pipeline timing is suitable for ISA regression, but host emulator throughput
is not an estimate of a real hardware WRM implementation.

Checklist:

- [ ] All deadlines explicitly state their scale: ticks, monotonic duration or wall time.
- [ ] 64-bit counters are read consistently; reset origins are accounted for.
- [ ] Timing-sensitive tests set the clock and control external input.
- [ ] Stale mappings are removed with TLBI, rather than hoping for eviction.

<a id="diagnostics"></a>

## 12. Diagnostics, debugging and snapshots

### Kernel panic and early failure path

Kernel panic should print the stage, origin from PUM, CAUSE and its name,
EPC, BADADDR, STATUS with flags, PTBR, FCSR, all GPRs and stack bounds state.
The current task/address space, last IRQ/device error and kernel image
identity are useful. Hex addresses need leading zeros for comparison with the symbol map.
Do not dereference unknown pointers to improve a diagnostic message.

An entry failure before a complete frame requires a separate early panic path:
do not read fields that have not yet been saved, call an ordinary function on a bad
stack or access a missing framebuffer mapping.
Polling UART is a simple foundation: no TX IRQ, DMA wait or allocation.
A later graphical dump is possible only with guaranteed valid video
mapping/engine state; another invalid operation under EXL will halt the CPU.
Recursive panic/formatter failure must have a bounded fallback.

A record such as `CAUSE=13 (breakpoint), stage=trap-selftest` proves that
BREAK reached the handler and the dump was printed. It **does not prove correct
IRET or preservation of all registers**. For an expected self-test BREAK,
check the allow condition, advance EPC by exactly 4, return and compare
the context. Do not turn every BREAK into success: an unexpected breakpoint
in the kernel still requires diagnostics.

After a CPU double fault, software panic may no longer execute. The emulator
prints unhandled fault state to stderr, and `--debug` also dumps HLT,
power-off and quit. A stopped CPU retains its pipeline: MEM/WB shows
the second instruction that caused the halt; saved EPC may refer to the first trap.
For EPC lookup, use the map **of the same image**, rather than fresh symbols
for an old binary. For a page fault, also inspect PTBR/PDE/PTE,
permissions and physical accessibility; a missing page mapping and a bus error
after successful translation are different failures.

### Guest single-step and triggers

`STATUS.SS` causes trap 14 after an instruction, with EPC at the next instruction and BADADDR at the previous one.
SS is evaluated at instruction start: the MTCR that enables it is not stepped,
the next instruction is; an instruction clearing an already set
SS still causes a step. HLT does not produce a step; WFI under stepping does not wait,
but produces a step trap. Entry saves SS in PSS; IRET restores SS=PSS.
Guest step/triggers are suppressed during EXL=1.

There are two triggers: TADDR0/TCTRL0 and TADDR1/TCTRL1, using virtual addresses.
TCTRL contains X/R/W bits 0/1/2 and SIZE bits 12–8: an aligned region of 2^SIZE
containing TADDR. A match on any accessed byte raises cause 15 **before the instruction's
effects**. For data, alignment is checked before the trigger, and the trigger before
translation; for fetch, fetch comes first (its fault takes priority), then
the trigger. After IRET to the same EPC, the trigger will match again.
To execute one instruction, the debugger temporarily disables the trigger,
steps through PSS and enables the trigger again. If triggers belong to
tasks, the scheduler saves/restores this state too.

### Host monitor and trace

The host monitor (`--monitor`, `--pause`) has its own breakpoints and
watchpoints, **not guest triggers**. It stops between instructions,
does not enter IVEC, does not change the guest trap frame and works with ROM. A breakpoint
fires before the instruction, a watchpoint after the load/store. Host watchpoints
and guest triggers therefore observe effects at different points.

Useful commands: `r`, `d`, virtual `x`, physical `xp`, `b`, `watch`,
`s`, `c`, `info`. `w/wp` change RAM; such edits are debugger actions,
rather than a safe kernel runtime memory API. The monitor listens on localhost.
When inspecting active mappings, distinguish VA and PA; a physical read
does not prove user permissions.

`--trace` records instructions that reach WB, changes and faults,
with IRQs on a separate line. Squashed instructions are invisible; a faulting instruction
is visible even though it does not increase INSTRET. Trace grows by roughly 80 bytes/instruction
and slows the host; run it on a short reproducible scenario.
Save UART stdout logs and emulator diagnostic stderr separately.

### Snapshots and reproducibility

A snapshot stores CPU/pipeline/TLB, RAM/VRAM and devices. It requires the same ROM,
clock, RAM config and **the same emulator build**. Disk images **are not copied**:
a snapshot does not roll back disk/shared-folder writes; load warns of
an altered image. Network connections are lost and shared handles closed;
host RNG obtains fresh bits, while seeded RNG continues its stream.
A snapshot is a convenient point for CPU investigation, but not a transaction of the entire host environment.

`--deterministic` enables unthrottled operation, virtual RTC, seeded RNG and fixed-tick
network polling. By itself, it does not make live terminal/window/network,
shared directory contents/order or host server responses reproducible.
For regression, specify ROM/disk/config/seed/input script and control
the external network; for pure CPU tests, normally disable it.
An input script injects key/UART/mouse/power events before the specified power-on tick;
a full FIFO drops events and a disabled mouse ignores them, as with real input.

The browser has additional limits: no UART input, network through a
proxy, and images saved in IndexedDB for the origin. Disk writes are persisted
on FLUSH and periodically; a downloaded image is a separate artifact.
Native shutdown/host filesystem behavior must not be automatically assumed
for browser persistence.

Checklist:

- [ ] A fault dump works without heap/scheduler and does not create a new fault.
- [ ] Trap self-test checks return state, rather than only the presence of a dump.
- [ ] EPC is matched to the correct map/image and instruction bytes.
- [ ] Tests do not confuse guest triggers with host monitor breakpoints.
- [ ] Regression preserves config, input, logs and the identity of the ready binary.
- [ ] Snapshot tests account for external files, closed handles and connections.

<a id="clarifications"></a>

## 13. Current implementation limits and LA/IX choices

This section collects details easily mistaken for ISA properties or completed
functionality. This file does not change the ISA, emulator code or LA/IX readiness.

| Topic | Clarification and source |
| --- | --- |
| Multi-core section | [Cores](INSTRUCTIONS.md#cores) is an extension direction. HARTID=0, one CPU; AP startup, operational shootdown and an SMP scheduler are absent. |
| LA/IX low words/frame | `0x1FF0…0x1FFC`, unmapped page zero, frame 160, stack 8192 and headroom 512 are [LA/IX choices](../laix/src/arch/wrm081632/defs.inc), rather than mandatory hardware constants. |
| Kernel features | A machine instruction/branch in assembly does not imply a ready user launcher, allocator, scheduler, IPC or isolated driver. Check the [plan and stage criteria](../laix/docs/KERNEL.md). |

The CPU ISA does not specify syscall numbers, IPC/capability policies, fault fixup
tables, user virtual layout, allocator ownership or service restart.
These are LA/IX contracts that must be described and verified separately.
The ABI does not yet define dynamic linking/PIE/debug information; hardware does not yet
implement SMP/IOMMU/NMI. Do not build the microkernel architecture on their availability.

<a id="acceptance"></a>

## 14. End-to-end LA/IX verification

Checks are performed against sources and on a ready image with known
ROM/config/map. The following items are acceptance criteria, rather than a report
of passed tests.

| Area | Where to find the original contract/scenarios |
| --- | --- |
| ISA, modes, traps, atomics, FP | [tests/isa](../tests/isa/), [INSTRUCTIONS](INSTRUCTIONS.md) |
| Precise effects, redirects, timing | [tests/pipeline](../tests/pipeline/) |
| MMU, permissions, superpages, TLB | [tests/mmu](../tests/mmu/) |
| IRQ/device/DMA behaviour | [tests](../tests/), corresponding SPECIFICATION sections |
| LA/IX boot/trap/guard and ready image | [LA/IX acceptance](../laix/tests/ACCEPTANCE.md), [stage 1](../laix/docs/01_BOOT_TRAPS.md) |
| User/tasks/IPC/services | [stage 3](../laix/docs/03_USER_TASK_SYSCALLS.md), [stage 4](../laix/docs/04_SCHEDULER_IRQ.md), [stage 5](../laix/docs/05_IPC_RIGHTS.md), [stage 6](../laix/docs/06_USER_SERVICES.md) |

- [ ] Warm boot with dirty BSS zeroes it, preserves boot info and reserved regions.
- [ ] Supervisor and user traps restore all GPRs, sp/tp/FCSR/status.
- [ ] User entry works with a bad user stack pointer.
- [ ] IRQ returns to the next EPC; syscall/BREAK skip 4; page fault retries.
- [ ] EXL nesting policy and failure before the frame are checked separately from ordinary panic.
- [ ] Kernel frames, entry state, RX/RW sections and guards are protected without aliases.
- [ ] ASID reuse and mapping revocation leave no access through the old TLB.
- [ ] Two tasks do not corrupt each other's memory/TLS/FCSR/debug state.
- [ ] Device IRQ acknowledgement actually deasserts the source, including shared flags.
- [ ] WFI idle wakes up; pending/masked IRQs do not create an endless busy loop.
- [ ] DMA does not use VA as PA; frames are pinned and partial errors visible to the client.
- [ ] An untrusted driver cannot bypass the broker through raw DMA registers.
- [ ] Device/service crashes do not free storage used by incomplete DMA.
- [ ] Shutdown waits for durable FLUSH/SYNC and exits with an explicit exit code.
- [ ] Native/browser/reset/snapshot checks account for their different contracts.

For the microkernel, the main next milestone is a real user task with a separate
address space and safe trap return. Supervisor self-test is necessary,
but does not replace this check or prove DMA driver isolation.
