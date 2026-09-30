# WRM.081632 ABI

The conventions that let separately written code work together: data
layout, register roles, calls, the stack and system calls. They are meant
for compilers, libraries and operating systems. The hardware itself fixes
only `r0` = 0; `JAL` and `JALR` can link through any register.

The firmware in `firmware/` follows the register roles. Its demos keep
`sp` only 4-byte aligned, because they have no 8-byte data.

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

There is no FPU. Floating point is IEEE 754 in software (binary32 and
binary64), and float values are passed and stored like integers of the
same size.

## Registers

| Register  | Assembler | Role                                  | Preserved by the callee |
|-----------|-----------|---------------------------------------|-------------------------|
| `r0`      | `zero`    | always 0                              | —                       |
| `r1`–`r2` |           | arguments 1–2, return value           | no                      |
| `r3`–`r8` |           | arguments 3–8                         | no                      |
| `r9`      |           | scratch, system call number           | no                      |
| `r10`–`r28` |         | saved                                 | yes                     |
| `r29`     | `fp`      | frame pointer, or a saved register    | yes                     |
| `r30`     | `sp`      | stack pointer                         | yes                     |
| `r31`     | `ra`      | return address                        | no                      |

A function may use `r1`–`r9` and `r31` freely. It must restore
`r10`–`r30` to their values on entry before it returns. `r9` is the
scratch register of choice for instruction sequences that need a
temporary, such as a far call:

```
        la r9, far_function
        jalr ra, r9, 0
```

## Calls

A call is `call f` (`JAL r31, f`) and the return is `ret`
(`JALR r0, r31, 0`).

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
- Arguments that match `...` in a variadic function always go on the
  stack, even while registers are free. So `va_list` is just a pointer
  that walks up the stack. The usual C promotions apply: `char` and
  `short` become `int`, and `float` becomes `double`.

Stack arguments start at `sp` at the moment of the call and go upwards,
one 4-byte slot each. An 8-byte value takes an 8-aligned 8-byte slot, with
padding before it if needed. The caller allocates this area and the callee
may change it.

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
[SPECIFICATION.md](SPECIFICATION.md#boot-protocol)). How user programs
start is up to the operating system. It should at least hand over an
8-aligned `sp`.

## Not defined yet

Object and executable file formats, relocations and the dynamic linking
model belong here once a linker exists.
