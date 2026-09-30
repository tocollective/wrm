# WRM.081632 Specification

## Memory map

| Range                     | Device                                  |
|---------------------------|-----------------------------------------|
| `0x00000000`–…            | RAM, installed slots mapped back to back |
| `0xFD000000`–`0xFD000FFF` | PIC                                     |
| `0xFD001000`–`0xFD001FFF` | Keyboard                                |
| `0xFD002000`–`0xFD002FFF` | UART                                    |
| `0xFD003000`–`0xFD003FFF` | Timer                                   |
| `0xFD004000`–`0xFD004FFF` | Power controller                        |
| `0xFD005000`–`0xFD005FFF` | Disk 0                                  |
| `0xFD006000`–`0xFD006FFF` | Disk 1                                  |
| `0xFE000000`–`0xFFFFFFFF` | ROM (32MB, read-only)                   |

Addresses between the end of RAM and `0xFD000000` are unmapped, as are
unused pages of the I/O region (`0xFD000000`–`0xFDFFFFFF`).
Instructions can't be fetched from the I/O region: a fetch there is a
bus error that never reaches the device, and so is a page table entry
read from it (see [INSTRUCTIONS.md](INSTRUCTIONS.md#exceptions)).
RAM slots are laid out in slot order; empty slots take no address space.

These are physical addresses. While the MMU is on, software sees virtual
addresses (see [INSTRUCTIONS.md](INSTRUCTIONS.md#memory-management)).

## Devices

Each device takes one 4KB page of the I/O region. Registers are 32-bit and
must be accessed at a multiple of 4; byte and half-word accesses see the
low bits. Writes to read-only registers are ignored; other offsets are
unmapped.

### PIC

Interrupt controller with 32 level-triggered IRQ lines. A device keeps its
line asserted while it needs service; the handler clears the condition in
the device, which drops the line.

| Offset | Register  | Access | Description                                   |
|--------|-----------|--------|-----------------------------------------------|
| `0x00` | `PENDING` | R      | current level of every line                   |
| `0x04` | `ENABLE`  | RW     | 1 = line may interrupt the CPU, 0 on reset    |
| `0x08` | `ACTIVE`  | R      | `PENDING & ENABLE`                            |
| `0x0C` | `CLAIM`   | R      | lowest active line, `0xFFFFFFFF` if none      |

The PIC drives the CPU IRQ input while `ACTIVE` is non-zero (see
[INSTRUCTIONS.md](INSTRUCTIONS.md#interrupts)). Devices can also be polled
with `ENABLE` left at 0.

| IRQ | Device   | Asserted while          |
|-----|----------|-------------------------|
| 0   | Keyboard | event FIFO is not empty |
| 1   | UART     | RX FIFO is not empty    |
| 2   | Timer    | `STATUS.EXPIRED` is set |
| 3   | Disk 0   | `STATUS.DONE` is set    |
| 4   | Disk 1   | `STATUS.DONE` is set    |

### Keyboard

Queues key events in a 32-entry FIFO. Key repeat is not generated.

| Offset | Register  | Access | Description                              |
|--------|-----------|--------|------------------------------------------|
| `0x00` | `STATUS`  | R      | bit 0 = event ready, bit 1 = overflow    |
| `0x04` | `DATA`    | R      | pops the next event, `0` if empty        |
| `0x08` | `CONTROL` | W      | bit 0 = flush the FIFO                   |

Event: bits 0–15 = USB HID usage ID (page `0x07`), bit 31 = key released.
The overflow bit is set when an event is dropped because the FIFO is full
and is cleared when `STATUS` is read.

### UART

Serial port connected to the host terminal. Transmitted bytes go to the
host's stdout; bytes typed into the host's stdin are queued in a 64-byte RX
FIFO. When stdin is a terminal it is put in raw mode without local echo, so
software sees every key at once and has to echo input itself. The host only
feeds as many bytes as the FIFO can take, so piped input is not lost.

| Offset | Register  | Access | Description                                          |
|--------|-----------|--------|------------------------------------------------------|
| `0x00` | `DATA`    | RW     | W = transmit the low byte, R = pop RX byte (`0` if empty) |
| `0x04` | `STATUS`  | R      | bit 0 = RX ready, bit 1 = TX ready, bit 2 = RX overflow |
| `0x08` | `CONTROL` | W      | bit 0 = flush the RX FIFO                            |

TX never blocks, so TX ready is always set. The RX overflow bit is cleared
when `STATUS` is read.

### Timer

A free-running 64-bit counter and a down-counter that raises IRQ 2. Both
advance once per system clock tick.

| Offset | Register    | Access | Description                                   |
|--------|-------------|--------|-----------------------------------------------|
| `0x00` | `COUNT_LO`  | R      | ticks since reset, low 32 bits                |
| `0x04` | `COUNT_HI`  | R      | ticks since reset, high 32 bits               |
| `0x08` | `FREQUENCY` | R      | ticks per second (the clock rate)             |
| `0x0C` | `RELOAD`    | RW     | period in ticks                               |
| `0x10` | `VALUE`     | R      | ticks left until the timer expires            |
| `0x14` | `CONTROL`   | RW     | bit 0 = enable, bit 1 = periodic (0 = one-shot) |
| `0x18` | `STATUS`    | RW     | bit 0 = expired; writing 1 clears it          |

Writing `CONTROL` loads `VALUE` from `RELOAD`, so it (re)starts the
countdown. While enabled, `VALUE` goes down by one every tick; when it
reaches 0 the timer expires: `STATUS.EXPIRED` is set, and either `VALUE`
is reloaded from `RELOAD` (periodic) or the enable bit is cleared
(one-shot). A timer with `RELOAD` = N expires every N ticks; `RELOAD` = 0
acts as 1.

`STATUS.EXPIRED` stays set, and the IRQ line asserted, until software
writes 1 to it; expiries in between are not counted. Clearing the enable
bit does not clear `EXPIRED`.

`COUNT` can't be read in one access. To get a consistent value, read
`COUNT_HI`, `COUNT_LO`, then `COUNT_HI` again, and retry if the two high
halves differ.

### Power controller

Lets software turn the machine off or reset it. The request takes effect
at the end of the clock tick in which the store completes; the
instructions after the store never run.

| Offset | Register | Access | Description                                        |
|--------|----------|--------|----------------------------------------------------|
| `0x00` | `OFF`    | W      | power off; the low 8 bits are the exit code        |
| `0x04` | `RESET`  | W      | reset the machine, the value is ignored            |

Both registers read as `0`. On power off the emulator quits with the exit
code as its process status (see [README](../README.md#running)). Reset is
described [below](#reset).

### Disks

Two identical disk controllers, disk 0 and disk 1. Each one can hold a
disk image, which is a host file given with `--hdd` (see
[README](../README.md#running)). A disk is an array of 512-byte sectors.
The controller moves them between the disk and RAM by itself (DMA), so
the CPU only programs the transfer and waits for the end.

| Offset | Register  | Access | Description                                           |
|--------|-----------|--------|-------------------------------------------------------|
| `0x00` | `STATUS`  | RW     | bit 0 = present, bit 1 = read-only, bit 2 = busy, bit 3 = done, bit 4 = error; writing 1 to bit 3 clears it |
| `0x04` | `SECTORS` | R      | disk size in sectors, `0` without a disk              |
| `0x08` | `SECTOR`  | RW     | next sector to transfer                               |
| `0x0C` | `COUNT`   | RW     | sectors left to transfer                              |
| `0x10` | `ADDRESS` | RW     | physical RAM address of the next word                 |
| `0x14` | `COMMAND` | W      | `1` = read (disk to RAM), `2` = write (RAM to disk)   |
| `0x18` | `ERROR`   | R      | why the last command failed, `0` if it didn't         |

Writing `COMMAND` clears `DONE` and `ERROR` and checks the other
registers. A command that can't run finishes at once: `DONE` is set,
`ERROR` holds the reason, and nothing is transferred. Otherwise `BUSY` is
set and the transfer runs on its own, one word per clock tick starting
with the next tick. `ADDRESS` goes up by 4 with every word. After every
whole sector, `SECTOR` goes up by one and `COUNT` down by one. When
`COUNT` reaches 0, `BUSY` is cleared and `DONE` set. A sector takes
128 ticks. `COUNT` = 0 finishes at once without an error.

While `BUSY` is set, writes to `SECTOR`, `COUNT`, `ADDRESS` and `COMMAND`
are ignored. A transfer can't be stopped except by a reset. When it ends,
the registers point just past it, so reading on only takes a new `COUNT`
and `COMMAND`.

`DONE` keeps IRQ line 3 (disk 0) or 4 (disk 1) asserted until software
writes 1 to it or starts the next command. `ERROR`, and the error bit in
`STATUS`, stay until the next command.

| `ERROR` | Reason                                                        |
|---------|---------------------------------------------------------------|
| `1`     | unknown command                                               |
| `2`     | no disk                                                       |
| `3`     | `SECTOR` + `COUNT` runs past the end of the disk              |
| `4`     | `ADDRESS` is not a multiple of 4, or the transfer reached memory that isn't RAM |
| `5`     | write to a read-only disk image                               |
| `6`     | the host failed to read or write the image                    |

The DMA reaches only RAM. It uses physical addresses and ignores the MMU.
A word in ROM, in the I/O region or at an unmapped address stops the
transfer with error 4. `ADDRESS` then points at that word, and `SECTOR`
and `COUNT` at the sector it belongs to. A read has already stored the
words of that sector before it; a write doesn't store a partial sector.
RAM changes one word at a time while a read runs, so software should
leave the buffer alone until `DONE`.

The image size is taken in whole sectors, and extra bytes at the end are
not reachable. An image that the host can't write is attached read-only.
Writes reach the host file as each sector completes.

## Reset

On reset all registers are zero and `pc = 0xFE000000`, so execution starts
at the first byte of the firmware image. The CPU is in supervisor mode,
the MMU is off and its TLB empty. `CYCLE` and `INSTRET` start from zero.

The power controller's `RESET` does the same at run time: the CPU and all
devices return to their reset state (FIFOs are emptied, the PIC `ENABLE`
mask, the timer and its `COUNT` are cleared, disk transfers stop and the
disk registers are cleared). RAM and the disk images keep their contents,
including the sectors of an interrupted write that were already written.

## Boot protocol

After reset the firmware in ROM runs. The firmware in `firmware/` checks
disk 0 for a boot image. If there is one, it loads the image and jumps to
it; if not, it runs its demos. This section is the contract between the
firmware and the image it boots, such as an OS loader. The calling
conventions are in [ABI.md](ABI.md).

### Boot image

A boot image starts at sector 0 with a header:

| Offset | Field     | Description                                               |
|--------|-----------|-----------------------------------------------------------|
| `0x00` | `MAGIC`   | `0x424D5257` (the bytes `WRMB`)                           |
| `0x04` | `SECTORS` | image size in sectors, starting from sector 0, at least 1 |
| `0x08` | `ENTRY`   | entry point as an offset from the load address; a multiple of 4 and inside the image |
| `0x0C` | `FLAGS`   | `0`; other values are reserved                            |

The firmware loads sectors 0 to `SECTORS` − 1 to physical address
`0x00010000`. The header comes along, so an image is assembled at
`0x00010000` as a whole (see [README](../README.md#booting-from-disk)).
A disk that doesn't start with `MAGIC` is not bootable. The firmware
doesn't boot, and prints why on the UART, if the header is invalid, the
image runs past the end of the disk or doesn't fit in RAM, or the disk
reports an error.

### Memory

| Range                     | Contents                                          |
|---------------------------|---------------------------------------------------|
| `0x00000000`–`0x00000FFF` | unspecified                                       |
| `0x00001000`–`0x0000101F` | boot info block                                   |
| `0x00001020`–`0x0000FFFF` | free; the stack starts at `0x00010000` and grows down |
| `0x00010000`–…            | the image, `SECTORS` × 512 bytes                  |
| the rest of RAM           | unspecified: RAM is not cleared, not even at reset |

The boot info block describes the machine:

| Offset | Field          | Description                                        |
|--------|----------------|----------------------------------------------------|
| `0x00` | `MAGIC`        | `0x4F464E49` (the bytes `INFO`)                    |
| `0x04` | `SIZE`         | size of the block in bytes, 32 here; later fields go after the ones here, so check `SIZE` before reading them |
| `0x08` | `RAM_SIZE`     | bytes of RAM, all of it from address 0             |
| `0x0C` | `DISK`         | physical address of the boot disk's controller     |
| `0x10` | `DISK_SECTORS` | its size in sectors                                |
| `0x14` | `IMAGE`        | load address, `0x00010000`                         |
| `0x18` | `IMAGE_SIZE`   | bytes loaded                                       |
| `0x1C` | `CLOCK`        | timer ticks per second                             |

### State at the entry point

- `pc` = `0x00010000` + `ENTRY`, in supervisor mode.
- `r1` = `0x00001000`, the boot info block. `r30` = `0x00010000`, an
  empty stack. `r2` and `r31` are 0; the other registers are
  unspecified.
- `STATUS` = `0x10`, as after reset: interrupts are off, and a fault
  halts the CPU until the image sets `IVEC` and clears `EXL`.
  `IVEC` = 0 and `PTBR` = 0, so the MMU is off. The other control
  registers are unspecified.
- The PIC `ENABLE` mask is 0. The boot disk is idle with `DONE` clear.
  The timer is as after reset. The UART RX FIFO was flushed at reset, but
  it may hold input typed since then, as may the keyboard FIFO.

## Clock

The system clock runs at 48 MHz by default (`clock_rate` in the config).
On every tick the timer advances first, then the disks move a word each,
then the CPU samples the IRQ line and advances its pipeline by one stage. Nothing runs once the CPU has
halted or the machine is powered off.

## Pipeline

The CPU uses the classic five-stage RISC pipeline, one stage per clock cycle:

| Stage | Work                                                        |
|-------|-------------------------------------------------------------|
| IF    | translate `pc`, fetch the word (RAM or ROM only), `pc += 4` |
| ID    | decode, read registers, detect load-use hazards             |
| EX    | ALU, effective address, branch/jump resolution              |
| MEM   | translate the address, loads and stores                     |
| WB    | write `rd`, retire, raise faults, `HLT`, `IRET`, `MTCR`, `TLBI` |

The pipeline is invisible to software: there are no delay slots, and
results are always seen by the next instruction.

- **Forwarding:** EX takes operands from EX/MEM and MEM/WB. The register
  file is written before it is read in the same cycle.
- **Load-use:** an instruction that needs the result of the load right
  before it stalls for 1 cycle.
- **Branches:** predicted not taken and resolved in EX. A taken branch or
  any jump squashes the two following instructions (2-cycle penalty).
- **Interrupts** are precise: they are taken after the instruction in WB
  retires; the younger ones in flight are squashed and restarted from
  `EPC` on `IRET`. `MFCR`, `MTCR` and `IRET` stall in ID until EX and MEM
  are empty.
- **Faults** are precise: they are raised when the faulting instruction
  reaches WB, after all older instructions have completed and before any
  younger one has written memory or registers.
- **Speculative fetches:** IF runs ahead of branch resolution, so it may
  fetch (and walk page tables for) addresses the program never reaches.
  Fetches and walks don't access the I/O region, so this has no side
  effects. Loads and stores in MEM are never speculative: an instruction
  reaches MEM only once every older one has retired without redirecting
  the flow.
- **Mode and translation changes:** `MTCR STATUS`, `MTCR PTBR` and `TLBI`
  squash the younger instructions in flight when they retire and refetch
  them, so these see the new mode and translation. `IRET` jumps to `EPC`
  when it retires (4-cycle penalty) rather than in EX.
- **TLB misses** are walked in the same cycle; the walk takes no extra
  cycles.

Timing: an instruction takes 5 cycles to go through the pipeline; the
throughput is up to one instruction per cycle.

See [INSTRUCTIONS.md](INSTRUCTIONS.md) for the instruction set.
