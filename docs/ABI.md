# WRM.081632 ABI

The conventions that let separately written code work together: data
layout, register roles, calls, the stack, system calls, program startup,
runtime functions and the object file format. They are meant
for compilers, libraries and operating systems. The hardware itself fixes
only `r0` = 0; `JAL` and `JALR` can link through any register.

The firmware in `wfw/` follows these register roles and keeps its
stack 8-byte aligned at calls.

## Data types

ILP32, little-endian.

| C type                          | Size | Alignment |
|---------------------------------|------|-----------|
| `char` (signed), `_Bool`        | 1    | 1         |
| `short`                         | 2    | 2         |
| `int`, `long`, pointers, `enum` | 4    | 4         |
| `long long`                     | 8    | 8         |
| `float`                         | 4    | 4         |
| `double`, `long double`         | 8    | 8         |

`size_t` is `unsigned int`, and `ptrdiff_t`, `intptr_t` and `wchar_t` are
`int`.

A struct lays out its members in order, each at its own alignment. The
struct is aligned to its most aligned member and padded to a multiple of
that alignment. Bit-fields fill a storage unit from bit 0 upwards.

Floating point is IEEE 754. `float` (binary32) arithmetic is done by the
[floating-point instructions](INSTRUCTIONS.md#floating-point) in the
general purpose registers; `double` (binary64) is done in software. Float
values are passed and stored like integers of the same size.

`FCSR` is the floating-point environment of `<fenv.h>`: its rounding mode
is preserved across calls (a function that changes it puts it back,
unless changing it is what the function is for, like `fesetround`), its
exception flags aren't. It belongs to the thread: the kernel saves and
restores it with the user's registers when it switches threads, and a
signal handler starts with the rounding mode to nearest. The software
`double` routines read the rounding mode from `FCSR` and set its flags
like the instructions do, so `<fenv.h>` covers both types.

## Registers

| Register  | Assembler | Role                                  | Preserved by the callee |
|-----------|-----------|---------------------------------------|-------------------------|
| `r0`      | `zero`    | always 0                              | —                       |
| `r1`–`r2` |           | arguments 1–2, return value           | no                      |
| `r3`–`r8` |           | arguments 3–8                         | no                      |
| `r9`      |           | scratch, system call number, linker veneers | no                |
| `r10`–`r27` |         | saved                                 | yes                     |
| `r28`     | `tp`      | thread pointer                        | — (never changed)       |
| `r29`     | `fp`      | frame pointer, or a saved register    | yes                     |
| `r30`     | `sp`      | stack pointer                         | yes                     |
| `r31`     | `ra`      | return address                        | no                      |

A function may use `r1`–`r9` and `r31` freely. It must restore
`r10`–`r27`, `r29` and `r30` to their values on entry before it returns.
`r9` is the scratch register of choice for instruction sequences that
need a temporary, such as a far call:

```
        la r9, far_function
        jalr ra, r9, 0
```

`r9` doesn't survive a call even up to the callee's first instruction:
the linker may route a call through a veneer that uses it (see
[Linker veneers](#linker-veneers)).

`tp` points to the current thread's [thread-local storage](#thread-local-storage).
It is set by the operating system or the thread library when a thread
starts; other code only reads it. The kernel saves and restores the
user's `tp` with the other registers when it enters and leaves the
kernel.

## Calls

A call is `call f` (`JAL r31, f`) and the return is `ret`
(`JALR r0, r31, 0`). `JAL` reaches ±1MB; a compiler emits `call` for
every direct call and leaves farther targets to the linker (see
[Linker veneers](#linker-veneers)).

### Arguments

Arguments are assigned in order to `r1`–`r8`, then to the stack:

- A scalar of up to 32 bits takes one register. The caller extends it to
  32 bits by its type: sign extension for signed types, zero extension
  for unsigned ones.
- A 64-bit scalar (`long long`, `double`) takes the next two registers,
  low word first. Any two registers can form the pair.
- A struct or union of up to 8 bytes is passed like a 1- or 2-word
  integer that holds its bytes in memory order, as if loaded from memory
  with `LW`.
- A larger struct or union is copied by the caller, which passes the
  copy's address. The callee may change the copy.
- If an argument doesn't fit in the registers left, it goes on the stack,
  and so do all the arguments after it. A 64-bit value is never split
  between a register and the stack.
- Arguments that match C `...` in a variadic function always go on the
  stack, even while registers are free. So `va_list` is just a pointer
  that walks up the stack. The usual C promotions apply: `char` and
  `short` become `int`, and `float` becomes `double`.

Stack arguments start at `sp` at the moment of the call and go upwards,
one 4-byte slot each. An 8-byte value takes an 8-aligned 8-byte slot, with
padding before it if needed. The caller allocates this area and the callee
may change it.

### M variadic arguments

M's named trailing parameter `args: ...` uses a borrowed argument pack,
separate from the C `...` convention above. The pack is an 8-byte value
aligned to 4 bytes: a 32-bit data pointer at offset 0 and a `UWord` count
at offset 4. It is passed after the fixed parameters as a two-word small
aggregate, following the ordinary register/stack rules. It is never
split between registers and the stack; a stack pack occupies an 8-aligned
8-byte slot. A hidden aggregate-result pointer still precedes all parameters.

The caller evaluates fixed and trailing arguments from left to right.
Each trailing scalar is saved in one 4-aligned, 4-byte slot in its frame.
Signed narrow integers are sign-extended, unsigned ones are zero-extended,
`Bool` is 0 or 1, and `Float` retains its binary32 bits. Pointers and
function pointers are stored as addresses. Untyped integer literals use
`Word` when possible, otherwise `UWord`; an untyped `null` uses `*Void`.
Aggregates cannot be trailing arguments. An empty pack has pointer 0 and count 0.

`vaCount(args)` reads the count. `vaArg(args, i, T)` loads the word at
`data + 4*i`, interprets it as scalar type `T` and normalizes narrow
integer results. It performs no numeric conversion or runtime type/bounds
check: the callee must use a matching type and `i < count`.
The pack can be forwarded as the sole trailing argument of another M
variadic call, preserving its pointer and count. Its data remains borrowed
from the original caller and must not outlive that call.

External variadic functions declared in M must implement this pack ABI;
they do not directly call C-style variadic functions.

### Return values

- Up to 32 bits: `r1`.
- 64-bit: `r1` holds the low word and `r2` the high word.
- A struct or union of up to 8 bytes: `r1`–`r2`, in its memory image.
- Larger: the caller passes the address of a buffer for the result as a
  hidden first argument in `r1`, and the other arguments move one place
  up. The callee returns the same address in `r1`.

## Stack

- It grows down. `sp` points to the lowest byte in use.
- `sp` is a multiple of 8 at every call, and therefore on entry to every
  function.
- There is no red zone: an interrupt handler may use the memory below
  `sp` at any moment.
- A leaf function doesn't need to save `ra` or allocate a frame.

A frame with a frame pointer sets `fp` to the value `sp` had on entry.
The return address goes at `fp - 4` and the caller's `fp` at `fp - 8`, so
a debugger can walk the chain of frames:

```
f:      addi sp, sp, -16
        sw ra, 12(sp)
        sw fp, 8(sp)
        addi fp, sp, 16
        ...
        lw fp, 8(sp)
        lw ra, 12(sp)
        addi sp, sp, 16
        ret
```

Code without frame pointers uses `r29` as one more saved register.
Load and store offsets are 14-bit signed (±8KB). A larger frame reaches
its far slots through `r9`.

## Global data

There is no global pointer register. `la` loads any address in two
instructions (`LUI` + `ORI`), and variables in the first 8KB of the
address space can be reached directly as `offset(r0)`. Position-independent
code gets addresses relative to `pc` with `AUIPC`.

An address splits into `%hi(x)` = `x >> 13` (19 bits) and `%lo(x)` =
`x & 0x1FFF` (13 bits). The low part is never negative and fits the
signed `imm14` of `ADDI`, loads and stores, so the high part needs no
correction for it, and the pair works with `ORI` and `ADDI` alike:

```
        lui r1, %hi(x)
        lw  r1, %lo(x)(r1)          ; or: ori r1, r1, %lo(x)
```

The `pc`-relative pair takes the high part from `AUIPC` and adds the low
part to it; the adding instruction must directly follow the `AUIPC`,
and it must be `ADDI`, a load or a store — not `ORI`, because the
`AUIPC` result has the low bits of `pc`:

```
        auipc r9, %pcrel_hi(x)
        lw    r1, %pcrel_lo(x)(r9)
```

## Thread-local storage

Only the local-exec model is defined: a program's own thread-local
variables, linked into the executable. The TLS image is the `.tdata`
section (initialised) followed by `.tbss` (zeroed), aligned as its most
aligned variable. Each thread gets a copy of it, and `tp` holds the
address of the copy's first byte. A variable lives at `tp` + its offset
in the image:

```
        lw r1, %tprel(errno)(tp)            ; image smaller than 8KB

        lui r9, %tprel_hi(big)              ; anywhere in the image
        ori r9, r9, %tprel_lo(big)
        add r9, r9, tp
        lw  r1, 0(r9)
```

Dynamic linking will need the other TLS models; they are not defined
yet.

## System calls

The operating system chooses its calls and their numbers. This is the
convention for passing them:

- `SYSCALL` with the call number in `r9` and the arguments in `r1`–`r6`,
  laid out as for a function call but at most 6 words and never on the
  stack.
- The result is in `r1`, and a 64-bit result also uses `r2`. An error is
  returned as a negative value from -4095 to -1 (`-errno`).
- The kernel preserves every register except `r1` and `r2`, and resumes
  after the `SYSCALL` (it adds 4 to `EPC`).

Because the arguments are already in place, a C wrapper takes two
instructions plus the return:

```
write:  li r9, SYS_WRITE
        syscall
        ret
```

### LA/IX system calls

The first LA/IX user ABI fixes these numbers. Dispatch reads the saved
`r9`; argument words come from saved `r1`–`r6`. Unused arguments are
ignored. These calls never read a user pointer or the user stack.

No buffer syscall is assigned yet. The internal LA/IX helpers
`copyFromUser` / `copyToUser` return 0 or -14 (`-EFAULT`) after checking
the complete byte range, every page's user/access permissions and ownership,
and the supervisor physical aliases under one memory lock. Invalid user
buffers cause no partial destination writes. Zero-length copies do not access
either buffer; the address-space identity must still be valid. Kernel buffers
are trusted and must not overlap user frames or MMU metadata. See the
[user-buffer contract](../laix/docs/03_USER_TASK_SYSCALLS.md#пользовательские-указатели-и-ошибки).

| Number (`r9`) | Call | Arguments | Result (`r1`) / errors |
|---|---|---|---|
| 0 | `debugPutChar(code)` | `r1`: unsigned byte value, 0…255 | 0 on UART write; -22 (`-EINVAL`) for any other value, with no write |
| 1 | `exit(code)` | `r1`: signed 32-bit task exit code | Does not return; retains the full code in the task record |
| 2 | `yield()` | none | 0 when this task resumes; rotates the Ready queue |
| any other | unsupported | ignored | -38 (`-ENOSYS`) |

On a returning LA/IX syscall only `r1` changes: `r2`–`r31` (including
the argument words, `r9`, `tp`, `sp` and `ra`) and the complete `FCSR`
are preserved. Saved `EPC` advances by exactly 4, including unsupported
calls and invalid arguments. The saved exit context also records `EPC + 4`,
but that context is never resumed. A user fault retains the faulting EPC.

The cooperative scheduler has eight task slots, one thread per task and one
CPU. Yield saves the complete frame, advances EPC once, appends the current
task to the Ready queue and restores the next Ready task. A task yielding
alone resumes immediately. PTBR contains the task directory and its ASID;
every activation uses FENCE → TLBI.ALL → MTCR PTBR before restoring registers.
The kernel stack entry words and current TCB change while IRQs remain disabled.

Exit or a fatal user exception records a Dead context and selects the next
Ready task. An empty queue selects an independent supervisor context with
zeroed GPRs/FCSR, the boot kernel stack and IRQs/single-step disabled. The
assembly epilogue first moves onto the selected kernel stack, then releases
the Dead task's inactive directory, user frames, kernel stack and guard.
It restores registers from the selected TCB frame after cleanup; the terminal
TCB stays available for diagnostics and is never queued again. An empty queue
halts in the trusted supervisor continuation. Supervisor faults still panic.
Timer preemption and interrupt-driven idle wakeup are not implemented yet.

M user wrappers are in `laix/user/syscalls.m` and use the builtin
`syscall()`. The boot runtime is not a user crt0. The temporary first-task
entry uses `r1` = user data base, `r2` = data size, `r3` = task ID, an empty
8-aligned user stack, and all remaining GPRs/FCSR zero; it has no TLS or process-start block.

### Entering the kernel

The handler starts with no free register and must not trust the user's
`sp`. The recommended sequence keeps the kernel stack pointer of the
current thread in a word below 8KB, such as `KERNEL_SP`. That word is
reachable as `offset(r0)` without a free register. For this, the kernel
maps its first 8KB into every address space without `U`, which also
leaves the user's null page unmapped.

```
trap:   mtcr scratch, sp            ; the interrupted sp
        mfcr sp, status
        andi sp, sp, STATUS_PUM
        beqz sp, .kernel            ; from supervisor: stay on its stack
        lw sp, KERNEL_SP(r0)        ; from user mode: the kernel stack
        j .save
.kernel:
        mfcr sp, scratch
.save:  addi sp, sp, -FRAME
        sw r1, 4(sp)
        mfcr r1, scratch
        sw r1, 0(sp)                ; the interrupted sp
        ...                         ; the other registers, EPC, STATUS
```

`EXL` is set until the handler clears it, so these instructions must not
fault. `KERNEL_SP` and the kernel stack have to be mapped. A handler that
may fault later saves `EPC`, `CAUSE`, `BADADDR` and `STATUS` first (see
[INSTRUCTIONS.md](INSTRUCTIONS.md#exceptions)).

## Program entry

The firmware enters a boot image with `r1` = the boot info block and an
empty 8-aligned stack (see
[SPECIFICATION.md](SPECIFICATION.md#boot-protocol)). A boot image is a
flat binary: nothing zeroes its `.bss`, so its startup code does.

### Process start

The operating system starts a user program at the executable's entry
point in user mode. `sp` is 8-aligned and points to this block:

| Address                  | Contents                                          |
|--------------------------|---------------------------------------------------|
| `sp`                     | `argc`                                            |
| `sp + 4`                 | `argv[0]` … `argv[argc - 1]`, then a null pointer |
| after it                 | `envp[0]` …, then a null pointer                  |
| after it                 | auxiliary vector: pairs of words (type, value), ended by type `0` |
| higher                   | the strings and other data the pointers refer to, in any order |

The operating system chooses the auxiliary vector types; a program
ignores the ones it doesn't know. `ra` and `fp` are 0, so a debugger's
walk of the frame chain stops there, and so are all other registers,
including `tp`.

The program's startup code (`crt0`):

1. sets up the TLS block of the first thread and points `tp` to it,
2. zeroes `.bss` unless the loader already did (an ELF loader does, see
   [Executables](#executables)),
3. calls `main(argc, argv, envp)`,
4. passes the result to `exit`.

## Runtime functions

A compiler may call these functions for operations the instruction set
doesn't have, and for copying memory. Their names and meanings follow
libgcc, so existing implementations can be reused. Arguments and results
follow the calling convention: a 64-bit value is a register pair, a
`float` a word, a `double` two words.

| Group | Functions |
|---|---|
| 64-bit division | `__divdi3`, `__udivdi3`, `__moddi3`, `__umoddi3` |
| 64-bit shifts, when not inlined | `__ashldi3`, `__lshrdi3`, `__ashrdi3` |
| `float` ↔ 64-bit integer | `__fixsfdi`, `__fixunssfdi`, `__floatdisf`, `__floatundisf` |
| `double` arithmetic | `__adddf3`, `__subdf3`, `__muldf3`, `__divdf3`, `__negdf2` |
| `double` comparison | `__eqdf2`, `__nedf2`, `__ltdf2`, `__ledf2`, `__gtdf2`, `__gedf2`, `__unorddf2` |
| `double` conversion | `__fixdfsi`, `__fixunsdfsi`, `__fixdfdi`, `__fixunsdfdi`, `__floatsidf`, `__floatunsidf`, `__floatdidf`, `__floatundidf` |
| `float` ↔ `double` | `__extendsfdf2`, `__truncdfsf2` |
| memory | `memcpy`, `memmove`, `memset`, `memcmp` |

64-bit multiplication needs no function: the low word of the product is
`MUL` of the low words, and the high word is `MULHU` of the low words
plus `MUL` of each low word by the other high word.
The memory functions are the C library's, and a compiler may call them
for struct copies and initialisation even in code that doesn't include
`<string.h>`, so a kernel without a C library still has to provide them.

## Object files

Object files are 32-bit little-endian ELF: `ELFCLASS32`, `ELFDATA2LSB`,
`EV_CURRENT`, `ELFOSABI_NONE`, `e_machine` = `EM_WRM` = `0x0816` (not
registered, private to this project), `e_flags` = 0.

- Relocatable files (`ET_REL`) keep their relocations in `SHT_RELA`
  sections. The addend is always in `r_addend`; the relocated field
  holds zero.
- Symbols have the names of the source, without a leading underscore.
- The usual sections are `.text`, `.rodata`, `.data`, `.bss`, `.tdata`
  and `.tbss`. The linker keeps sections with other names too (for
  example, a kernel's table of fault fixups) and provides symbols for
  their bounds.

### Relocations

`S` is the value of the symbol, `A` the addend, `P` the address of the
relocated word, and `TLS` the address of the start of the TLS image
(see [Thread-local storage](#thread-local-storage)). The fields are
`imm14` (bits 31–18) and `imm19` (bits 31–13) of the instruction at `P`,
see [INSTRUCTIONS.md](INSTRUCTIONS.md#formats).

| Number | Name                 | Field   | Value                     | Must fit        | Assembler |
|--------|----------------------|---------|---------------------------|-----------------|-----------|
| 0      | `R_WRM_NONE`         | —       | —                         | —               | — |
| 1      | `R_WRM_32`           | word    | `S + A`                   | —               | `.word x` |
| 2      | `R_WRM_HI19`         | `imm19` | `(S + A) >> 13`           | —               | `%hi(x)` |
| 3      | `R_WRM_LO13`         | `imm14` | `(S + A) & 0x1FFF`        | —               | `%lo(x)` |
| 4      | `R_WRM_ABS14`        | `imm14` | `S + A`                   | −8192…8191      | `x(r0)`, `addi rd, r0, x` |
| 5      | `R_WRM_PCREL_HI19`   | `imm19` | `(S + A − P) >> 13`       | —               | `%pcrel_hi(x)` |
| 6      | `R_WRM_PCREL_LO13`   | `imm14` | `(S + A − (P − 4)) & 0x1FFF` | —            | `%pcrel_lo(x)` |
| 7      | `R_WRM_BRANCH14`     | `imm14` | `(S + A − P) >> 2`        | ±32KB, 4-aligned | branch target |
| 8      | `R_WRM_JAL19`        | `imm19` | `(S + A − P) >> 2`        | ±1MB, 4-aligned  | `JAL` target |
| 9      | `R_WRM_TPREL14`      | `imm14` | `S + A − TLS`             | 0…8191          | `%tprel(x)` |
| 10     | `R_WRM_TPREL_HI19`   | `imm19` | `(S + A − TLS) >> 13`     | —               | `%tprel_hi(x)` |
| 11     | `R_WRM_TPREL_LO13`   | `imm14` | `(S + A − TLS) & 0x1FFF`  | —               | `%tprel_lo(x)` |

- Values are computed modulo 2³²; `>>` keeps the high bits of that
  32-bit value, so the `HI19`/`LO13` pairs reach any address.
- `R_WRM_PCREL_LO13` is on the instruction right after the `AUIPC`, so
  `P − 4` is the address of the `AUIPC`, and it names the same target as
  the `R_WRM_PCREL_HI19` of that `AUIPC`.
- A value that doesn't fit is a link error. The linker reports the
  object file, section, offset and symbol.
- The linker leaves the other bits of the instruction unchanged.

`mc/asm.py -c` writes these object files: an address it can't know
becomes a relocation, and in a flat image (without `-c`) every value is
known, except `%tprel*`, which needs the linker. `mc/ld.py` links
them, adds the veneers and writes boot images, ROM images and
executables.

### Linker veneers

When the target of an `R_WRM_JAL19` is out of range, the linker may put
a veneer within range of the call and point the `JAL` at it:

```
veneer: lui  r9, %hi(target)
        ori  r9, r9, %lo(target)
        jalr r0, r9, 0
```

`ra` still holds the address after the original `JAL`, so the callee
returns to the caller. Calls to the same target can share a veneer. This
is why `r9` can't carry a value into a function. Branches out of range
are not fixed: the compiler avoids them (a reversed branch around a
`JAL`).

## Executables

An executable (`ET_EXEC`) is loaded through its `PT_LOAD` segments. Each
segment is aligned to 4KB (`p_align` = `0x1000`, `p_vaddr` ≡ `p_offset`
modulo 4KB), and its `p_flags` become the page permissions: `PF_R` → `R`,
`PF_W` → `W`, `PF_X` → `X`. The loader zeroes the part of a segment
beyond `p_filesz` up to `p_memsz` (the `.bss`). A `PT_TLS` segment
describes the TLS image. Execution starts at `e_entry` (see
[Process start](#process-start)).

Code and data of different permissions go into separate pages: a page
has one set of permissions.

A boot image is a flat binary cut from the same link (see
[SPECIFICATION.md](SPECIFICATION.md#boot-image)).

## Not defined yet

Dynamic linking and position-independent executables (they will need a
relocation applied at load time, `R_WRM_RELATIVE`), the other TLS models
and the debug information format.
