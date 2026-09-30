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
| `0xFE000000`–`0xFFFFFFFF` | ROM (32MB, read-only)                   |

Addresses between the end of RAM and `0xFD000000` are unmapped, as are
unused pages of the I/O region (`0xFD000000`–`0xFDFFFFFF`).
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

## Reset

On reset all registers are zero and `pc = 0xFE000000`, so execution starts
at the first byte of the firmware image. The CPU is in supervisor mode,
the MMU is off and its TLB empty. `CYCLE` and `INSTRET` start from zero.

The power controller's `RESET` does the same at run time: the CPU and all
devices return to their reset state (FIFOs are emptied, the PIC `ENABLE`
mask, the timer and its `COUNT` are cleared). RAM keeps its contents.

## Clock

The system clock runs at 48 MHz by default (`clock_rate` in the config).
On every tick the timer advances first, then the CPU samples the IRQ line
and advances its pipeline by one stage. Nothing runs once the CPU has
halted or the machine is powered off.

## Pipeline

The CPU uses the classic five-stage RISC pipeline, one stage per clock cycle:

| Stage | Work                                                        |
|-------|-------------------------------------------------------------|
| IF    | translate `pc`, fetch the word, `pc += 4`                   |
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
- **Mode and translation changes:** `MTCR STATUS`, `MTCR PTBR` and `TLBI`
  squash the younger instructions in flight when they retire and refetch
  them, so these see the new mode and translation. `IRET` jumps to `EPC`
  when it retires (4-cycle penalty) rather than in EX.
- **TLB misses** are walked in the same cycle; the walk takes no extra
  cycles.

Timing: an instruction takes 5 cycles to go through the pipeline; the
throughput is up to one instruction per cycle.

See [INSTRUCTIONS.md](INSTRUCTIONS.md) for the instruction set.
