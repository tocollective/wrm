# WRM.081632 Specification

## Memory map

| Range                     | Device                                  |
|---------------------------|-----------------------------------------|
| `0x00000000`–…            | RAM, installed slots mapped back to back |
| `0xFC000000`–`0xFC3FFFFF` | VRAM window, see [Video card](#vram-window) |
| `0xFD000000`–`0xFD000FFF` | PIC                                     |
| `0xFD001000`–`0xFD001FFF` | Keyboard                                |
| `0xFD002000`–`0xFD002FFF` | UART                                    |
| `0xFD003000`–`0xFD003FFF` | Timer                                   |
| `0xFD004000`–`0xFD004FFF` | Power controller                        |
| `0xFD005000`–`0xFD005FFF` | Disk 0                                  |
| `0xFD006000`–`0xFD006FFF` | Disk 1                                  |
| `0xFD007000`–`0xFD007FFF` | Video card                              |
| `0xFD008000`–`0xFD008FFF` | Floppy drive                            |
| `0xFD009000`–`0xFD009FFF` | Beeper                                  |
| `0xFD00A000`–`0xFD00AFFF` | Mouse                                   |
| `0xFD00B000`–`0xFD00BFFF` | Ethernet card                           |
| `0xFD00C000`–`0xFD00CFFF` | Audio card                              |
| `0xFD00D000`–`0xFD00DFFF` | Real-time clock                         |
| `0xFD00E000`–`0xFD00EFFF` | Random number generator                 |
| `0xFD00F000`–`0xFD00FFFF` | Shared folder                           |
| `0xFD010000`–`0xFD010FFF` | Watchdog                                |
| `0xFE000000`–`0xFFFFFFFF` | ROM (32MB, read-only)                   |

Addresses between the end of RAM and `0xFD000000`, but the VRAM window,
are unmapped, as are unused pages of the I/O region
(`0xFD000000`–`0xFDFFFFFF`). Instructions can't be fetched from the I/O
region or the VRAM window: a fetch there is a bus error that never
reaches the device, and so is a page table entry read from there (see
[INSTRUCTIONS.md](INSTRUCTIONS.md#exceptions)).
RAM slots are laid out in slot order; empty slots take no address space.

These are physical addresses. While the MMU is on, software sees virtual
addresses (see [INSTRUCTIONS.md](INSTRUCTIONS.md#memory-management)).

## Devices

Each device takes one 4KB page of the I/O region. Registers are 32-bit and
must be accessed at a multiple of 4; byte and half-word accesses see the
low bits. Writes to read-only registers are ignored; other offsets are
unmapped.

The last word of every device's page, offset `0xFFC`, is its read-only
`ID` register, so software can find the devices and check what they
are; an unused page has none, so reading it is a bus error. The firmware
lists the devices it finds for the image it boots (see
[Boot protocol](#memory)).

| Bits  | Field     | Description                                   |
|-------|-----------|-----------------------------------------------|
| 31:16 | `TYPE`    | what the device is, see below; never 0        |
| 15:8  | `VERSION` | its register interface, `1` for this document |
| 7:0   | `IRQ`     | its PIC line, `0xFF` if it has none           |

| `TYPE` | Device          | `TYPE` | Device          |
|--------|-----------------|--------|-----------------|
| `1`    | PIC             | `9`    | Beeper          |
| `2`    | Keyboard        | `10`   | Mouse           |
| `3`    | UART            | `11`   | Ethernet card   |
| `4`    | Timer           | `12`   | Audio card      |
| `5`    | Power controller| `13`   | Real-time clock |
| `6`    | Hard disk       | `14`   | Random number generator |
| `7`    | Video card      | `15`   | Shared folder   |
| `8`    | Floppy drive    | `16`   | Watchdog        |

For example, disk 1's `ID` reads `0x00060104`.

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
| 5   | Video    | `STATUS.DONE` or `STATUS.VBLANK` is set and enabled in `CONTROL` |
| 6   | Floppy   | `STATUS.DONE` or `STATUS.CHANGED` is set |
| 7   | Mouse    | event FIFO is not empty |
| 8   | Ethernet | a bit of `PENDING` is set and enabled in `CONTROL` |
| 9   | Audio    | `STATUS` is not zero    |
| 10  | RTC      | `STATUS.ALARM` is set   |
| 11  | Power    | `STATUS` is not zero    |
| 12  | Watchdog | `STATUS.BARK` is set    |

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

Lets software turn the machine off or reset it, passes on the host's
request to power off, and tells why the machine last started. A request
from software takes effect at the end of the clock tick in which the
store completes; the instructions after the store never run.

| Offset | Register      | Access | Description                                   |
|--------|---------------|--------|-----------------------------------------------|
| `0x00` | `OFF`         | W      | power off; the low 8 bits are the exit code   |
| `0x04` | `RESET`       | W      | reset the machine, the value is ignored       |
| `0x08` | `STATUS`      | RW     | bit 0 = the host asks to power off; writing 1 clears it |
| `0x0C` | `RESET_CAUSE` | R      | why the machine last started, see below       |

`OFF` and `RESET` read as `0`. On power off the emulator quits with the
exit code as its process status (see [README](../README.md#running)).
Reset is described [below](#reset).

`STATUS` bit 0 is the power button: the host sets it when the user closes
the window or presses Ctrl+C, so software can save its state and power
off. It stays set, and IRQ 11 asserted, until software writes 1 to it.
The host sets it only while IRQ 11 is enabled in the PIC and the CPU
hasn't halted; otherwise it quits at once, as it does on a second request
whatever software does with the first.

| `RESET_CAUSE` | The machine started after |
|---------------|---------------------------|
| `0`           | power-on                  |
| `1`           | a write to `RESET`        |
| `2`           | the host's reset key (Ctrl+Alt+R) |
| `3`           | reserved: a double fault halts the CPU instead, see [Exceptions](INSTRUCTIONS.md#exceptions) |
| `4`           | the [watchdog](#watchdog) |

### Disks

Three identical disk controllers: two hard disks, disk 0 and disk 1, and
the floppy drive. Each one can hold a disk image, which is a host file
given with `--hdd` or `--floppy` (see [README](../README.md#running)). A
disk is an array of 512-byte sectors. The controller moves them between
the disk and RAM by itself (DMA), so the CPU only programs the transfer
and waits for the end.

| Offset | Register  | Access | Description                                           |
|--------|-----------|--------|-------------------------------------------------------|
| `0x00` | `STATUS`  | RW     | bit 0 = present, bit 1 = read-only, bit 2 = busy, bit 3 = done, bit 4 = error, bit 5 = changed (floppy only); writing 1 to bit 3 or 5 clears it |
| `0x04` | `SECTORS` | R      | disk size in sectors, `0` without a disk              |
| `0x08` | `SECTOR`  | RW     | next sector to transfer                               |
| `0x0C` | `COUNT`   | RW     | sectors left to transfer                              |
| `0x10` | `ADDRESS` | RW     | physical RAM address of the next word                 |
| `0x14` | `COMMAND` | W      | bits 7:0 = the command, see below; bit 8 = `LIST`     |
| `0x18` | `ERROR`   | R      | why the last command failed, `0` if it didn't         |
| `0x1C` | `LIST`    | RW     | physical address of the next descriptor, with `COMMAND.LIST` |

| Command | Name       | Does                                                    |
|---------|------------|---------------------------------------------------------|
| `1`     | `READ`     | `COUNT` sectors from `SECTOR` on, disk to RAM           |
| `2`     | `WRITE`    | `COUNT` sectors from `SECTOR` on, RAM to disk           |
| `3`     | `FLUSH`    | makes the writes so far durable, see below              |
| `4`     | `IDENTIFY` | the 512-byte [identify block](#identify-block) to RAM   |

Writing `COMMAND` clears `DONE` and `ERROR` and checks the other
registers. A command that can't run finishes at once: `DONE` is set,
`ERROR` holds the reason, and nothing is transferred. Otherwise `BUSY` is
set and the transfer runs on its own. A hard disk moves data at 4000000
bytes per second, whatever the clock rate: one word every W = clock rate
× 4 / 4000000 ticks, rounded down (32 ticks at 32 MHz, so a sector takes
4096 ticks); the first word moves W ticks after the store to `COMMAND`.
The floppy is slower (see [Floppy drive](#floppy-drive)). `ADDRESS` goes up
by 4 with every word. After every whole sector, `SECTOR` goes up by one
and `COUNT` down by one. When `COUNT` reaches 0, `BUSY` is cleared and
`DONE` set. `COUNT` = 0 finishes at once without an error.

`IDENTIFY` moves one block of 512 bytes, in the time of a sector, the way
`READ` moves a sector; it ignores `SECTOR` and `COUNT` and leaves them
alone. It needs a disk in the drive, like the other commands.

While `BUSY` is set, writes to `SECTOR`, `COUNT`, `ADDRESS`, `LIST` and
`COMMAND` are ignored. A transfer can't be stopped except by a reset.
When it ends, the registers point just past it, so reading on only takes
a new `COUNT` and `COMMAND`.

`DONE` keeps IRQ line 3 (disk 0), 4 (disk 1) or 6 (floppy) asserted
until software writes 1 to it or starts the next command. `ERROR`, and the error bit in
`STATUS`, stay until the next command.

| `ERROR` | Reason                                                        |
|---------|---------------------------------------------------------------|
| `1`     | unknown command, or `LIST` with `FLUSH`                       |
| `2`     | no disk                                                       |
| `3`     | `SECTOR` + `COUNT` runs past the end of the disk              |
| `4`     | `ADDRESS` (`LIST` with `COMMAND.LIST`) is not a multiple of 4, or the transfer reached memory that isn't RAM or the VRAM window |
| `5`     | write to a read-only disk image                               |
| `6`     | the host failed to read, write or flush the image             |
| `7`     | a descriptor's address or length is not a multiple of 4, or its length is 0 |

The DMA reaches RAM and the [VRAM window](#vram-window). It uses physical
addresses and ignores the MMU.
A word in ROM, in the I/O region or at an unmapped address stops the
transfer with error 4. `ADDRESS` then points at that word, and `SECTOR`
and `COUNT` at the sector it belongs to. A read has already stored the
words of that sector before it; a write doesn't store a partial sector.
RAM changes one word at a time while a read runs, so software should
leave the buffer alone until `DONE`.

The image size is taken in whole sectors, and extra bytes at the end are
not reachable. An image that the host can't write is attached read-only.

#### Scatter-gather

With `COMMAND` bit 8 (`LIST`) set, `READ`, `WRITE` and `IDENTIFY` move
the data to or from several pieces of RAM instead of one, so a buffer
needn't be physically contiguous: the pages of a virtual buffer, for
example. The pieces are given by a list of descriptors in RAM:

| Offset | Field     | Description                                         |
|--------|-----------|-----------------------------------------------------|
| `0x00` | `ADDRESS` | physical address of the piece, a multiple of 4      |
| `0x04` | `LENGTH`  | its length in bytes, a multiple of 4 and not 0      |

`LIST` holds the address of the first descriptor, a multiple of 4. The
controller reads a descriptor when the transfer reaches it, on the tick
of the piece's first word, and takes no extra time for it: it copies
the piece's address into `ADDRESS` and goes on to the next descriptor,
8 bytes on, in `LIST`. Pieces needn't follow sector boundaries; when a
piece runs out, the next word goes to the next one. The list has no end
marker: the transfer ends when `COUNT` reaches 0, and what is left of
the last piece, and the descriptors after it, are not used. `ADDRESS`
is not checked when the command starts.

A descriptor outside RAM stops the transfer with error 4 and a bad one
with error 7; `LIST` then points at that descriptor. As without `LIST`,
a read has stored the words before it and a write stores no partial
sector. Each command starts with the descriptor at `LIST`, so going on
after a transfer that ended mid-piece takes a new descriptor for the
rest of that piece.

#### Flush

Writes reach the host file as each `WRITE` completes, but the host may
keep them in its own caches for a while, and they are lost if the host
crashes or loses power. `FLUSH` has the host write everything written
to the image so far to its storage medium, and ends with `DONE` once
that is done. It finishes at once, in the tick of the store to
`COMMAND`, however long the host takes; the machine stands still
meanwhile. A read-only image has nothing to flush, so `FLUSH` succeeds
at once. If the host fails, `ERROR` is 6, and writes since the last
successful `FLUSH` may not be on the medium.

An OS should flush before it reports a write as durable (`fsync`), and
before it powers off.

#### Identify block

`IDENTIFY` describes the disk in the drive; numbers are little-endian,
bytes not listed are 0.

| Offset | Size | Field         | Description                                    |
|--------|------|---------------|------------------------------------------------|
| `0x00` | 4    | `MAGIC`       | `0x444D5257` (the bytes `WRMD`)                |
| `0x04` | 4    | `VERSION`     | `1`                                            |
| `0x08` | 4    | `SECTORS`     | as the register                                |
| `0x0C` | 4    | `SECTOR_SIZE` | `512`                                          |
| `0x10` | 4    | `FLAGS`       | bit 0 = removable (the floppy), bit 1 = read-only |
| `0x20` | 16   | `UUID`        | a UUID (RFC 9562, version 8) made from the serial number, in the usual big-endian byte order |
| `0x30` | 32   | `SERIAL`      | serial number, ASCII, padded with zero bytes    |
| `0x50` | 40   | `MODEL`       | `WRM.081632 hard disk` or `WRM.081632 floppy disk`, padded with zero bytes |

The serial number is given with `--hdd-serial` (see
[README](../README.md#running)), or else it is 16 hexadecimal digits of
a hash of the image's absolute path: the same image file gives the same
serial number, and so the same UUID, until it is moved or renamed. With
`--deterministic` it is a hash of the file name alone, so a run doesn't
depend on where the image is. An OS can find its disks by UUID wherever
they are attached; a file system's own UUID is its business.

#### Sharing images

An emulator locks the images it has attached: exclusively when it can
write the image, shared when it is read-only. An image that another
emulator has attached is attached read-only, with a warning; one that
another emulator writes can't be attached at all: the emulator doesn't
start, and the floppy drive stays empty. So two machines never write
one image, and a machine never reads an image that another one is
changing. Images of up to 2TB (2³² sectors) work on every host.

#### Floppy drive

The floppy moves data at 62500 bytes per second, the rate of a 1.44MB
drive, whatever the clock rate: one word every W = clock rate × 4 /
62500 ticks, rounded down (2048 ticks at 32 MHz, so a sector takes
262144 ticks, about 8ms). The first word moves W ticks after the store
to `COMMAND`, and each next one W ticks after it. Reading a 64KB boot
image takes about a second.

The floppy drive's disk is removable: the host can eject it or put in
another one while the machine runs (a file dropped on the emulator's
window goes in the drive). The disk can be of any size up to 1.44MB (2880 sectors); a bigger image
isn't put in the drive. `SECTORS` and
the read-only bit follow the disk in the drive. Ejecting it during a
transfer stops the transfer with error 2, as if the command had found
no disk; the sectors already written stay written.

Every insertion or ejection sets `STATUS.CHANGED`, which keeps IRQ line
6 asserted, like `DONE`, until software writes 1 to it. It is clear
after reset, also with a disk in the drive, so it only tells of changes
since then. Software that caches what it read from the floppy should
drop the cache when it sees `CHANGED`. The hard disks never set it.

### Video card

A graphics card with 4MB of its own video memory (VRAM), a 2D drawing
engine and a hardware cursor. The CPU draws with engine commands, moves
data between memory and VRAM by DMA, or reads and writes VRAM directly
through the [VRAM window](#vram-window). Once per frame the card shows
the visible frame, a part of VRAM, in the emulator's window. There is no
text mode; text is drawn from a font in VRAM with `EXPAND` (see
[Text](#text)).

| Offset | Register        | Access | Description                                   |
|--------|-----------------|--------|-----------------------------------------------|
| `0x00` | `STATUS`        | RW     | bit 0 = busy, bit 1 = done, bit 2 = error, bit 3 = VBLANK; writing 1 to bit 1 or 3 clears it |
| `0x04` | `CONTROL`       | RW     | bit 0 = display on, bit 1 = IRQ on `DONE`, bit 2 = IRQ on `VBLANK` |
| `0x08` | `MODE`          | RW     | bits 0–1 = resolution, bits 4–6 = depth       |
| `0x0C` | `WIDTH`         | R      | of the mode, in pixels                        |
| `0x10` | `HEIGHT`        | R      | of the mode, in pixels                        |
| `0x14` | `BPP`           | R      | bits per pixel of the mode                    |
| `0x18` | `PITCH`         | R      | bytes per line of the visible frame, `WIDTH` × `BPP` / 8 |
| `0x1C` | `VRAM_SIZE`     | R      | `0x00400000`                                  |
| `0x20` | `START`         | RW     | VRAM offset of the visible frame              |
| `0x24` | `FRAME`         | R      | frames since reset                            |
| `0x28` | `PALETTE_INDEX` | RW     | palette entry that `PALETTE_DATA` accesses, 0–255 |
| `0x2C` | `PALETTE_DATA`  | RW     | the entry, `0x00RRGGBB`; a write moves `PALETTE_INDEX` to the next entry |
| `0x40` | `COMMAND`       | W      | starts an engine command                      |
| `0x44` | `ERROR`         | R      | why the last command failed, `0` if it didn't |
| `0x48` | `DST_BASE`      | RW     | destination surface: VRAM offset of its first line |
| `0x4C` | `DST_PITCH`     | RW     | destination surface: bytes per line           |
| `0x50` | `DST_XY`        | RW     | destination pixel: bits 0–15 = x, bits 16–31 = y |
| `0x54` | `SRC_BASE`      | RW     | source surface: VRAM offset of its first line, or its physical address for `EXPAND` from memory |
| `0x58` | `SRC_PITCH`     | RW     | source surface: bytes per line                |
| `0x5C` | `SRC_XY`        | RW     | source pixel: bits 0–15 = x, bits 16–31 = y   |
| `0x60` | `SIZE`          | RW     | rectangle: bits 0–15 = width, bits 16–31 = height, in pixels |
| `0x64` | `FG`            | RW     | pixel value of `FILL`, and of 1 bits in `EXPAND` |
| `0x68` | `BG`            | RW     | pixel value of 0 bits in `EXPAND`             |
| `0x6C` | `ADDRESS`       | RW     | physical address of the next DMA word         |
| `0x70` | `COUNT`         | RW     | bytes left to move by DMA                     |
| `0x80` | `CURSOR_CONTROL`| RW     | bit 0 = the cursor is shown                   |
| `0x84` | `CURSOR_BASE`   | RW     | VRAM offset of the cursor's image, bits 21:2  |
| `0x88` | `CURSOR_XY`     | RW     | where the hotspot is on the screen: bits 0–15 = x, bits 16–31 = y, both signed |
| `0x8C` | `CURSOR_HOT`    | RW     | the hotspot in the image: bits 0–5 = x, bits 16–21 = y |

#### Modes

`MODE` is a resolution and a depth; every pairing is valid.

| Resolution | Size      |   | Depth | Bits per pixel | Pixel value               |
|------------|-----------|---|-------|----------------|---------------------------|
| `0`        | 320×240   |   | `0`   | 1              | palette entry 0–1         |
| `1`        | 640×480   |   | `1`   | 4              | palette entry 0–15        |
| `2`        | 800×600   |   | `2`   | 8              | palette entry 0–255       |
| `3`        | 1024×768  |   | `3`   | 16             | RGB565: red in bits 11–15, green 5–10, blue 0–4 |
|            |           |   | `4`   | 32             | XRGB8888: `0x00RRGGBB`, bits 24–31 are ignored |

A write of a depth above 4 or with other bits set is ignored, so `MODE`
keeps its value. Changing the mode leaves VRAM and the palette alone;
the engine uses the new depth at once, the display from the next frame.

Pixels are stored line by line, `PITCH` bytes apart for the visible
frame. 1 and 4 bpp pixels are packed from the most significant bits of a
byte, so the leftmost pixel is bit 7 (1 bpp) or bits 4–7 (4 bpp). 16 and
32 bpp pixels are little-endian. The palette has 256 entries of
`0x00RRGGBB`; the 1, 4 and 8 bpp depths use its first 2, 16 or 256.

#### Display

The card counts frames: a frame lasts 1/60 s of clock ticks (the clock
rate / 60). At the end of every frame it shows the visible frame: the
current mode, read from VRAM at `START` with `PITCH` bytes per line and
coloured through the palette. So everything drawn during a frame appears
at once, and a change to `START` flips to another frame in VRAM (double
buffering) at the end of the frame. Lines that run past the end of VRAM
are black, and so is the whole screen while `CONTROL` bit 0 is clear.

Then `FRAME` goes up by one and `STATUS.VBLANK` is set. `VBLANK` stays
set until software writes 1 to it, so it tells that at least one frame
has ended since then.

#### Drawing engine

The engine draws on surfaces: images in VRAM described by the offset of
their first line (`*_BASE`) and the bytes per line (`*_PITCH`), which
need not be those of the visible frame, so drawing off screen is the
same as on screen. `*_XY` picks the top left pixel of the rectangle
within the surface and `SIZE` its size. The pixels are in the depth of
the current mode, except for the source of `EXPAND`, which is 1 bpp.

Writing `COMMAND` clears `DONE` and `ERROR` and runs the command in its
bits 0–7. `FILL`, `COPY` and `EXPAND` finish at once, in the same store:
`DONE` is set when the store completes. `LOAD`, `STORE` and `EXPAND` from
memory run by DMA, see below.

| `COMMAND` | Name     | Operation                                        |
|-----------|----------|--------------------------------------------------|
| `1`       | `FILL`   | the destination rectangle takes the value `FG`   |
| `2`       | `COPY`   | the source rectangle is copied to the destination rectangle |
| `3`       | `EXPAND` | the source rectangle, 1 bpp, is drawn at the destination: 1 bits as `FG`, 0 bits as `BG`; with bit 8 (`TRANSPARENT`) set 0 bits leave the destination alone; with bit 9 (`MEMORY`) set the source is in RAM or ROM (see [EXPAND from memory](#expand-from-memory)) |
| `4`       | `LOAD`   | DMA: `COUNT` bytes from memory at `ADDRESS` to VRAM at `DST_BASE` |
| `5`       | `STORE`  | DMA: `COUNT` bytes from VRAM at `SRC_BASE` to RAM at `ADDRESS` |

`FG` and `BG` are pixel values of the mode: only their low `BPP` bits are
used. A rectangle with a zero width or height draws nothing. A rectangle
must lie inside its surface's lines and inside VRAM: x + width pixels must
fit in `*_PITCH` bytes, and the end of its last line in VRAM. Otherwise
the command fails with error 2 and draws nothing. `COPY` works like
`memmove` when both surfaces have the same pitch: overlapping rectangles
are copied as if through a buffer, so it can scroll. With different
pitches the result of an overlap is undefined.

`LOAD` reads RAM, ROM or the VRAM window, so data can come straight from
the firmware. `STORE` writes RAM or the VRAM window; it is the engine's way
to copy VRAM to RAM (the CPU can also read the VRAM window). `ADDRESS`,
the VRAM offset and `COUNT` must be multiples of 4, and the VRAM range
must lie inside VRAM. A DMA command that can't run finishes at once with
the error; `COUNT` = 0 finishes at once without one. Otherwise `BUSY` is
set and the card moves one word per clock tick starting with the next
tick. `ADDRESS` and the VRAM offset (`DST_BASE` for `LOAD`, `SRC_BASE`
for `STORE`) go up by 4 and `COUNT` down by 4 with every word. When
`COUNT` reaches 0, `BUSY` is cleared and `DONE` set. A word the DMA
can't reach (the I/O region, ROM for `STORE`, an unmapped address) stops
the transfer with error 3; `ADDRESS` then points at that word. The DMA
uses physical addresses and ignores the MMU.

#### EXPAND from memory

With `COMMAND` bit 9 set, `EXPAND` reads its 1 bpp source by DMA from RAM
or ROM, e.g. a font in the firmware, without loading it into VRAM first.
`SRC_BASE` is then the physical address of the source's first line;
`SRC_PITCH` and `SRC_XY` mean the same as in VRAM, and the lines can
start at any byte and bit. The source lines must fit in `SRC_PITCH`
(error 2); there is no other check on the source.

The command sets `BUSY` and fetches the source a line at a time, starting
with the next tick: one word per tick, all the aligned words that hold
the line's bits (an 8-pixel line within a word takes one tick). When the
last word of a line is in, the line is drawn at the destination. After
the last line `BUSY` is cleared and `DONE` set. The destination uses the
depth the mode had when the command started. A word the DMA can't reach
(the I/O region, an unmapped address, past `0xFFFFFFFF`) stops the
command with error 3; the lines before it stay drawn. The engine's
registers keep their values.

While `BUSY` is set, writes to `COMMAND` and the engine's registers
(`DST_*`, `SRC_*`, `SIZE`, `FG`, `BG`, `ADDRESS`, `COUNT`) are ignored.
The other registers, the mode and the palette can be changed at any time.

| `ERROR` | Reason                                                   |
|---------|----------------------------------------------------------|
| `1`     | unknown command                                          |
| `2`     | a rectangle runs past its pitch or the end of VRAM, or a DMA range runs past the end of VRAM |
| `3`     | `ADDRESS`, the VRAM offset or `COUNT` of `LOAD` or `STORE` is not a multiple of 4, or the DMA reached memory it can't |

`DONE` and `VBLANK` share IRQ line 5: it is asserted while `DONE` is set
and `CONTROL` bit 1 is set, or `VBLANK` is set and `CONTROL` bit 2 is
set. The handler clears the condition by writing 1 to the bit in
`STATUS` (or, for `DONE`, by starting the next command).

#### VRAM window

VRAM is also mapped at `0xFC000000`–`0xFC3FFFFF`: byte N of VRAM is at
`0xFC000000` + N. Loads and stores of any size reach it like RAM, at no
cost in ticks beyond the access, and see the same bytes as the engine
and the display: a store there shows at the end of the frame like a
pixel the engine draws. DMA reaches it too, so a disk can read an image
straight into VRAM and `LOAD` can copy within VRAM; wherever a device's
DMA reaches RAM, it reaches the VRAM window as well. Instructions can't
run from it and page tables can't be in it.

`LL` and `SC` work on it, but the engine's writes don't clear a
reservation there; DMA's and the CPU's do, as in RAM.

#### Cursor

The hardware cursor is a 64×64 image of ARGB8888 pixels in VRAM,
`0xAARRGGBB` little-endian, 256 bytes per line, starting at
`CURSOR_BASE`. While `CURSOR_CONTROL` bit 0 and the display are on, it
is blended over the frame as the frame is shown: each colour channel is
(cursor × A + frame × (255 − A)) / 255, rounded to nearest, so A = 255 is
the cursor alone and A = 0 the frame alone. VRAM itself never changes,
whatever the depth of the mode.

The image is placed so that its pixel `CURSOR_HOT` falls on the screen
pixel `CURSOR_XY`. Pixels off the screen, and pixels past the end of
VRAM, aren't drawn. The registers can be changed at any time; the
display shows them as they are at the end of the frame. They are zero
after reset: the cursor is hidden.

#### Text

A font is a 1 bpp bitmap in VRAM, loaded once with `LOAD` from ROM or
RAM (a glyph cache). With glyphs of 8×16 pixels stored one after
another, a byte per line, character `c` is drawn by one `EXPAND` with
`SRC_BASE` = font + 16 × `c`, `SRC_PITCH` = 1, `SRC_XY` = 0 and `SIZE` =
8×16, in any depth. The same `EXPAND` with `MEMORY` draws straight from a
font in RAM or ROM, at 16 ticks a character. The firmware keeps its font there, see
[State at the entry point](#state-at-the-entry-point).

### Beeper

A square wave generator for simple sounds, like the PC speaker. It
plays one tone at a time through the host's sound output; without a
window (`--headless`) or with `--mute` nothing is heard, but the device
works the same.

| Offset | Register    | Access | Description                                   |
|--------|-------------|--------|-----------------------------------------------|
| `0x00` | `CONTROL`   | RW     | bit 0 = on                                    |
| `0x04` | `FREQUENCY` | RW     | the tone, in Hz; `0` is silence               |
| `0x08` | `DURATION`  | RW     | ticks left to sound, `0` = until turned off   |

While `CONTROL` bit 0 is set the beeper sounds the square wave of
`FREQUENCY`; a change to it takes effect at once. Turning it on starts
the wave from the beginning. A tone above half the clock rate is
silence, and tones above about 20kHz are inaudible anyway.

`DURATION` times a tone without the CPU: while the beeper is on and
`DURATION` is not 0, it goes down by one every clock tick, starting with
the next tick, and when it reaches 0 bit 0 of `CONTROL` is cleared. So
writing `DURATION` = N and then `CONTROL` = 1 sounds the tone for N
ticks; with `FREQUENCY` = 0 it is a pause of N ticks that software can
poll `CONTROL` for. `DURATION` stands still while the beeper is off, and
turning it off by hand keeps what is left of it. With `DURATION` = 0 the
beeper sounds until software clears the bit.

The output is mixed down to 48000 samples per second, each the average
of the wave over its clock ticks. The host plays it with a delay of up
to about 85ms. There is no IRQ line.

### Mouse

A relative mouse, like a PS/2 one: it reports how far it moved and which
buttons are down, not where the pointer is; or, in absolute mode, like a
USB tablet: it reports where the host's pointer is in the frame.
Software draws its own pointer, or has the video card's
[cursor](#cursor) draw it. Events are queued in a 64-entry FIFO, and only
while the mouse is enabled.

| Offset | Register   | Access | Description                              |
|--------|------------|--------|------------------------------------------|
| `0x00` | `STATUS`   | R      | bit 0 = event ready, bit 1 = overflow    |
| `0x04` | `DATA`     | R      | pops the next event, `0` if empty        |
| `0x08` | `CONTROL`  | RW     | bit 0 = flush the FIFO (reads as 0), bit 1 = enabled, bit 2 = absolute |
| `0x0C` | `POSITION` | R      | absolute mode: where the event last popped from `DATA` happened, bits 0–15 = x, bits 16–31 = y |

Event:

| Bits  | Field   | Description                                              |
|-------|---------|----------------------------------------------------------|
| 0–7   | `DX`    | motion to the right, signed, −128…127                    |
| 8–15  | `DY`    | motion down, signed (the screen's y goes down too)       |
| 16–23 | `WHEEL` | wheel steps, signed, positive away from the user         |
| 24    | `LEFT`  | the left button is down                                  |
| 25    | `RIGHT` | the right button is down                                 |
| 26    | `MIDDLE`| the middle button is down                                |
| 27    | `ABSOLUTE` | the event is of absolute mode: `DX` and `DY` are 0, `POSITION` has its place |
| 31    | —       | always 1, so an event is never `0`                       |

The buttons are their state after the event: an event that only presses
or releases a button has no motion. A motion that doesn't fit in one
event is split into several. Motion is merged into the newest event in
the FIFO while it holds only motion, the buttons haven't changed and the
sum still fits, so a slow reader loses no motion. Units are the host's
pointer units (window pixels), whatever the video mode. The overflow bit
is set when an event is dropped because the FIFO is full, and is cleared
when `STATUS` is read.

The mouse is disabled at reset. While it is disabled nothing is queued
and the host keeps its own pointer. Once software sets bit 1, a click in
the emulator's window captures the host pointer for the machine (that
click is not an event); Ctrl+Alt, switching to another window, or
clearing bit 1 gives it back. Buttons held when the pointer is given back count as
released: if the mouse is still enabled, an event says so. Without a
window (`--headless`) there are no events, but those of an
[input script](../README.md#input-scripts).

#### Absolute mode

With `CONTROL` bit 2 set the mouse follows the host's pointer over the
window without capturing it: the host's pointer stays the host's, and
the machine learns where it is. Positions are pixels of the current
video mode, from 0, 0 at the top left to `WIDTH` − 1, `HEIGHT` − 1; a
pointer beside the frame (the window is wider or taller than the frame's
shape) counts as on its nearest edge.

Every event of absolute mode has `ABSOLUTE` set, no motion and the
position of the pointer when it happened, which `POSITION` holds once
the event is popped from `DATA`. A move is an event with neither a
button change nor a wheel step; a move after a move in the FIFO, with the
same buttons, replaces the older one's position instead of queueing
another event, so a slow reader sees where the pointer went, not every
step. Buttons and wheel steps are events as in relative mode, at the
pointer's position. Switching to another window releases the buttons.

`POSITION` keeps its value while the FIFO is empty; reset clears it.
Relative motion is ignored in absolute mode, and positions in relative
mode.

### Ethernet card

A network card that sends and receives Ethernet frames: software brings
a TCP/IP stack of its own. Its cable leads to a virtual network in the
emulator, as in QEMU's user networking: a gateway that does NAT for the
guest, a DHCP server and a DNS server. The guest needs no setup on the
host and no privileges.

| Address     | What it is                                              |
|-------------|---------------------------------------------------------|
| `10.0.2.0/24` | the network                                           |
| `10.0.2.2`  | the gateway, router and DHCP server; connections to it go to the host itself (its `127.0.0.1`) |
| `10.0.2.3`  | the DNS server: it answers A queries with the host's lookups, other types with no answer |
| `10.0.2.15` | the guest's address, which DHCP gives (any request for another is refused) |

The card's MAC address is `52:54:00:12:34:56`, the gateway's (and the
DNS server's) `52:55:0A:00:02:02`. The gateway answers ARP for both and
ping itself. Through it the guest reaches the host's networks with TCP
and UDP, and with ping where the host allows it without privileges
(macOS; Linux if `net.ipv4.ping_group_range` lets the user). By default
the guest reaches public addresses only, not the host itself (so not
`10.0.2.2` either) or the networks around it; the rules of `--net-allow`
and `--net-deny` open or close more (see [README](../README.md#network)).
A connection they deny is refused with a reset, a datagram or ping is
dropped. Ports forwarded with `--net-forward` lead to the guest's TCP and
UDP ports while the card is on: a connection to the host's port comes to
`10.0.2.15` from `10.0.2.2`, and so does a datagram; what the guest
sends from that UDP port leaves from the host's port. In a browser the
gateway has TCP and DNS only, through the network proxy.

The card is connected unless the emulator is started with `--no-net`;
otherwise the link is down: frames are sent into nothing and none come
in. Frames are Ethernet II, 14 to 1514 bytes, without the FCS. The
gateway doesn't put fragments together and doesn't send them; TCP takes
an MSS of up to 1460 bytes.

| Offset | Register   | Access | Description                                   |
|--------|------------|--------|-----------------------------------------------|
| `0x00` | `STATUS`   | R      | bit 0 = link up                               |
| `0x04` | `CONTROL`  | RW     | bit 0 = on, bit 1 = IRQ on `RX` and `LOST`, bit 2 = IRQ on `TX` |
| `0x08` | `PENDING`  | RW     | bit 0 = `RX`, bit 1 = `TX`, bit 2 = `LOST`, bit 3 = `FAULT`; writing 1 to a bit clears it |
| `0x0C` | `MAC_LO`   | R      | bytes 0–3 of the MAC address, byte 0 in bits 0–7 |
| `0x10` | `MAC_HI`   | R      | bytes 4–5 in bits 0–15                        |
| `0x14` | `RX_RING`  | RW     | physical address of the receive ring, a multiple of 8 |
| `0x18` | `RX_SIZE`  | RW     | descriptors in it, up to 1024                 |
| `0x1C` | `RX_NEXT`  | R      | the descriptor the next frame goes in         |
| `0x20` | `TX_RING`  | RW     | physical address of the send ring, a multiple of 8 |
| `0x24` | `TX_SIZE`  | RW     | descriptors in it, up to 1024                 |
| `0x28` | `TX_NEXT`  | R      | the descriptor the card sends next            |
| `0x2C` | `TX_KICK`  | W      | any value: send what software has handed over |

The rings are arrays of 8-byte descriptors in RAM, used in order and
round again from the first after the last:

| Offset | Field     | Description                                         |
|--------|-----------|-----------------------------------------------------|
| `0x00` | `ADDRESS` | physical address of the buffer, any byte            |
| `0x04` | `CONTROL` | bits 0–15 = length, bit 30 = `ERROR`, bit 31 = `OWN` |

A descriptor with `OWN` set is the card's. Software gives the card a
receive buffer by writing its address, its size as the length and
`OWN`; the card stores a frame in it, writes the frame's length and
clears `OWN` (and sets `ERROR` if the frame was longer than the buffer:
the length is then the bytes stored). To send, software writes the
frame's address and length and `OWN`, then writes `TX_KICK`; the card
sends the frames of the descriptors it owns, from `TX_NEXT` on, up to one
it doesn't own, and clears `OWN` of each, keeping the length; a frame
shorter than 14 bytes or longer than 1514 isn't sent and gets `ERROR`.
Sending is done when the store to `TX_KICK` completes. Frames come in
when the host polls the network (between batches of ticks, or every
millisecond of machine time with `--deterministic`); those that find no
free receive descriptor wait, up to 64, and the next ones are lost.

`RX_RING`, `RX_SIZE`, `TX_RING` and `TX_SIZE` can only be written while
the card is off. Turning it on sets `RX_NEXT` and `TX_NEXT` to 0. The
card sets `RX` when it has stored a frame, `TX` when it has sent one,
`LOST` when a frame was lost, and `FAULT` when its DMA reached memory
that isn't RAM or the VRAM window (or ROM, for what it reads): then it
stops at that
descriptor and turns itself off. IRQ 8 is asserted while a bit of
`PENDING` is set whose IRQ `CONTROL` enables (`FAULT` with either).
Frames that come while the card is off are dropped.

The gateway's connections live in the host's sockets: a reset of the
machine drops them, and a [snapshot](../README.md#snapshots) can't hold
them, so after loading one the guest's connections are gone, as if the
network had been down a while.

### Audio card

Eight voices that play samples straight from memory, like the Amiga's
Paula or the Gravis Ultrasound: each voice reads its sample by DMA at
its own rate, and the card mixes the voices in stereo with a volume for
each side. A voice can loop a part of its sample and raise an interrupt
at its end and half way, so a looping buffer that software refills is a
stream.

| Offset  | Register  | Access | Description                                     |
|---------|-----------|--------|-------------------------------------------------|
| `0x00`  | `STATUS`  | RW     | bit N = voice N has signalled; writing 1 to a bit clears it |
| `0x04`  | `FAULT`   | RW     | bit N = voice N was stopped by a bad sample address; writing 1 to a bit clears it |
| `0x08`  | `MASTER`  | RW     | volume of the mix: bits 0–7 left, bits 8–15 right |
| `0x0C`  | `VOICES`  | R      | `8`                                             |
| `0x10`  | `RATE`    | R      | `48000`, frames per second of the mix           |
| `0x100` | voice 0   |        | the voice registers below                       |
| …       |           |        | voice N at `0x100` + N × `0x20`                 |

Voice registers (offsets from the voice's base):

| Offset | Register   | Access | Description                                  |
|--------|------------|--------|----------------------------------------------|
| `0x00` | `CONTROL`  | RW     | bit 0 = on, bit 1 = loop, bit 2 = 16-bit, bit 3 = stereo, bit 4 = signal at the end, bit 5 = signal half way |
| `0x04` | `ADDRESS`  | RW     | physical address of the sample's first frame |
| `0x08` | `LENGTH`   | RW     | the sample's length in frames                |
| `0x0C` | `LOOP`     | RW     | the frame a loop goes back to                |
| `0x10` | `POSITION` | RW     | the frame playing now                        |
| `0x14` | `RATE`     | RW     | frames per second, low 24 bits              |
| `0x18` | `VOLUME`   | RW     | bits 0–7 left, bits 8–15 right               |

A sample is an array of frames at `ADDRESS` in RAM or ROM. A frame is one
sample value, or two (left, then right) with `CONTROL` bit 3 set; a value
is a signed byte, or a signed little-endian half-word with bit 2 set. So
a frame takes 1, 2 or 4 bytes. Volumes go from 0 (silent) to 255 (as
recorded). Reserved bits of `CONTROL`, `VOLUME` and `MASTER` read as 0.

The card makes 48000 stereo frames a second of clock ticks, one every
clock rate / 48000 ticks. For each frame, every voice that is on plays
the sample frame at `POSITION` and then moves `POSITION` on by `RATE` /
48000 frames, keeping the fraction internally: `RATE` = 48000 plays a
frame per frame, 24000 plays each one twice, 0 holds the frame. There is
no interpolation. When `POSITION` reaches `LENGTH` or goes past it, the
voice is at its end:

- with bit 1 (loop) set and `LOOP` < `LENGTH`, `POSITION` goes back by
  `LENGTH` − `LOOP` frames (as many times as it takes to be below
  `LENGTH` again), and the voice plays on;
- otherwise bit 0 is cleared and `POSITION` stays at `LENGTH`.

With bit 4 set, the end sets bit N of `STATUS`. With bit 5 set, so does
`POSITION` reaching `LENGTH` / 2 (rounded down) from below. A stream
plays a buffer of two halves with loop on, `LOOP` = 0 and bits 4 and 5:
each signal says which half to fill next.

Writing `POSITION` moves the voice to that frame and drops the fraction.
Turning a voice on doesn't move it, so to play a sample again software
writes `POSITION` = 0 too; a voice turned on at `LENGTH` or past it is at
its end at once, before it plays anything. `CONTROL` and the other
registers can be changed while the voice plays and take effect with the
next frame.

The DMA uses physical addresses and ignores the MMU. A frame that is not
in RAM, ROM or the VRAM window, or a 16-bit value at an odd address, stops the voice: bit
0 of its `CONTROL` is cleared and bit N of `FAULT` is set (without a
signal).

The left and right sides of each voice are scaled by its `VOLUME`,
summed over the voices, scaled by `MASTER` and clipped to 16 bits; the
beeper is added after that. `MASTER` is 0 at reset, so the card is
silent until software sets it. The host plays the mix with a delay of up
to about 85ms; without a window or with `--mute` nothing is heard, but
the card runs the same.

IRQ line 9 is asserted while `STATUS` is not zero.

### Real-time clock

The date and time, taken from the host's wall clock, and a one-shot
alarm that raises IRQ 10. Unlike the timer, it keeps counting across a
reset and follows the host even when the machine runs slower than its
clock rate.

| Offset | Register      | Access | Description                                       |
|--------|---------------|--------|---------------------------------------------------|
| `0x00` | `SECONDS_LO`  | R      | seconds since 1970-01-01 00:00:00 UTC, low 32 bits; reading it latches the time |
| `0x04` | `SECONDS_HI`  | R      | latched seconds, high 32 bits                     |
| `0x08` | `NANOSECONDS` | R      | latched fraction of the second, 0–999999999       |
| `0x0C` | `UTC_OFFSET`  | R      | latched local time minus UTC, in seconds, signed (36000 for UTC+10) |
| `0x10` | `ALARM_LO`    | RW     | alarm time in seconds since the epoch, low 32 bits |
| `0x14` | `ALARM_HI`    | RW     | alarm time, high 32 bits                          |
| `0x18` | `CONTROL`     | RW     | bit 0 = alarm armed                               |
| `0x1C` | `STATUS`      | RW     | bit 0 = alarm went off; writing 1 clears it       |

The time can't change between the reads of one value: reading
`SECONDS_LO` takes a snapshot of the time, and `SECONDS_HI`,
`NANOSECONDS` and `UTC_OFFSET` return that snapshot until the next read of
`SECONDS_LO`. So read `SECONDS_LO` first. `UTC_OFFSET` is the host's time
zone, daylight saving time included, at the latched time; it is 0 if the
host doesn't know it. The time is not settable: an OS that wants another
time keeps its own offset. Leap seconds are not counted, as in Unix time.

While `CONTROL` bit 0 is set, the clock compares the time in whole
seconds with `ALARM`: once `SECONDS` ≥ `ALARM`, it sets `STATUS.ALARM`
and clears `CONTROL` bit 0, so the alarm goes off once. The clock
compares them when `CONTROL` is written, so an alarm in the past goes
off at once, and then once every clock rate / 1000 ticks; the alarm can
be up to that late. Changing `ALARM` while armed takes effect with the
next comparison.

`STATUS.ALARM` stays set, and the IRQ line asserted, until software
writes 1 to it. Clearing `CONTROL` bit 0 does not clear it.

With a virtual time (`--rtc=SECONDS`, or `--deterministic`, see the
README) the clock doesn't ask the host: the time is `SECONDS` plus the
clock ticks since power-on, the alarm compares against it the same way,
and `UTC_OFFSET` is 0. A run then reads the same times whenever and
however fast it happens.

### Random number generator

Random bits for seeds: of ASLR, hash tables, TCP sequence numbers and
cryptographic keys. They come from the host's cryptographic random
number generator, so they are fit for keys. The device has no IRQ.

| Offset | Register | Access | Description                                     |
|--------|----------|--------|-------------------------------------------------|
| `0x00` | `DATA`   | R      | 32 random bits; every read gives new ones       |
| `0x04` | `STATUS` | R      | bit 0 = seeded: the bits are not from the host  |

A read of `DATA` never blocks and always uses up the next bits: a word is
never handed out twice, though two random words can happen to be equal. A
byte or half-word read gets the low bits and uses up the word as well.

With a seed (`--seed=N`, or `--deterministic`, see the README) the bits
are the ChaCha20 stream with N as the key instead (the 256-bit key holds
N little-endian in its first 8 bytes, the rest 0; nonce 0; the 64-bit
block counter from 0; the words of each block in order). A run then
reads the same bits every time, and `STATUS` bit 0 is set so an OS can
tell that they are not secret.

The generator keeps going across a reset. A snapshot doesn't keep the
host's bits: a machine loaded from one reads new ones, so two machines
started from one snapshot don't share keys. A seeded generator goes on
with its stream.

### Shared folder

A folder of the host that the guest uses file by file, given with
`--share PATH` (see the README): the way to move files in and out of the
machine without a disk image. The device has the file system: software
opens, reads and writes files by path and
needs no file system driver of its own. Commands run at once, in the
tick of the store to `COMMAND`, so software reads `ERROR` and `RESULT`
right after it; there is no IRQ.

| Offset | Register      | Access | Description                                   |
|--------|---------------|--------|-----------------------------------------------|
| `0x00` | `STATUS`      | R      | bit 0 = a folder is shared, bit 1 = it is read-only |
| `0x04` | `COMMAND`     | W      | runs a command, see below                     |
| `0x08` | `ERROR`       | R      | why the last command failed, `0` if it didn't |
| `0x0C` | `HANDLE`      | RW     | an open file or directory, `0`–`15`; `OPEN` sets it |
| `0x10` | `PATH`        | RW     | physical address of a path                    |
| `0x14` | `PATH2`       | RW     | physical address of the new path, for `RENAME` |
| `0x18` | `ADDRESS`     | RW     | physical address of the data                  |
| `0x1C` | `COUNT`       | RW     | bytes to move, or the size of the buffer at `ADDRESS` |
| `0x20` | `POSITION_LO` | RW     | byte offset in the file, low 32 bits          |
| `0x24` | `POSITION_HI` | RW     | high 32 bits                                  |
| `0x28` | `FLAGS`       | RW     | how `OPEN` opens, see below                   |
| `0x2C` | `RESULT`      | R      | bytes moved by the last command, `0` if none  |
| `0x30` | `HANDLES`     | R      | `16`                                          |

| Command | Name       | Uses                     | Does                                  |
|---------|------------|--------------------------|---------------------------------------|
| `1`     | `OPEN`     | `PATH`, `FLAGS`          | opens a file or directory; `HANDLE` = its handle |
| `2`     | `CLOSE`    | `HANDLE`                 | closes it                             |
| `3`     | `READ`     | `HANDLE`, `POSITION`, `ADDRESS`, `COUNT` | file to RAM            |
| `4`     | `WRITE`    | `HANDLE`, `POSITION`, `ADDRESS`, `COUNT` | RAM or ROM to file     |
| `5`     | `STAT`     | `PATH`, `ADDRESS`, `COUNT` | a stat record of the path to RAM    |
| `6`     | `READDIR`  | `HANDLE`, `ADDRESS`, `COUNT` | the next directory entry to RAM   |
| `7`     | `MKDIR`    | `PATH`                   | makes a directory                     |
| `8`     | `REMOVE`   | `PATH`                   | removes a file or an empty directory  |
| `9`     | `RENAME`   | `PATH`, `PATH2`          | renames or moves; replaces a file at `PATH2` |
| `10`    | `TRUNCATE` | `HANDLE`, `POSITION`     | makes the file `POSITION` bytes long  |
| `11`    | `SYNC`     | `HANDLE`                 | puts the file's writes on the host's medium, like a disk's [`FLUSH`](#flush) |

Writing `COMMAND` sets `RESULT` to 0 and `ERROR` to the command's
outcome; the other registers keep their values unless the command says
otherwise. Without a shared folder every command fails with error 2.

**Paths** are NUL-terminated strings of up to 1023 bytes in RAM or ROM,
relative to the shared folder: names separated by `/`. Empty names (a
leading, trailing or doubled `/`) are skipped, so `""` and `"/"` are the
folder itself. A name can't be `.` or `..` and can't hold control
characters, `\` or `:`; such a path fails with error 3, and so does
one without a NUL in its first 1024 bytes. The names are bytes; the host
decides what they mean (UTF-8 on most hosts) and whether case matters.
A symbolic link in the folder, made by the host's user, is followed only
while it leads to somewhere in the folder; otherwise error 14 (on Windows
links are not checked).

**`OPEN`** takes the flags:

| Bit | Flag        | Effect                                                     |
|-----|-------------|------------------------------------------------------------|
| 0   | `WRITE`     | the file can be written as well as read                    |
| 1   | `CREATE`    | a file that isn't there is made, empty; needs `WRITE`      |
| 2   | `TRUNCATE`  | the file is cut to 0 bytes; needs `WRITE`                  |
| 3   | `EXCLUSIVE` | with `CREATE`: fails with error 5 if the file is there     |
| 4   | `DIRECTORY` | opens a directory for `READDIR`; alone                     |

Flags that don't go together fail with error 1. A directory opened
without `DIRECTORY`, or a file with it, fails with error 9; so does
anything that is neither a file nor a directory. `OPEN` takes the lowest
free handle and puts it in `HANDLE`; with all 16 open it fails with
error 8. Handles stay open until `CLOSE` or a reset.

**`READ`** moves up to `COUNT` bytes, at most 1MB, from the file at
`POSITION` to RAM at `ADDRESS`; **`WRITE`** moves them from RAM or ROM to
the file, growing it if it has to (a gap reads as zeros). `ADDRESS` and
`POSITION` go up and `COUNT` down by the bytes moved, and `RESULT` holds
how many: fewer than asked at the end of the file, 0 past it, and also
when the DMA reaches memory it can't (error 11; the bytes before are
moved). There is no alignment to keep. Written bytes reach the host file
by the end of the command.

**`STAT`** writes a 32-byte record about the path to `ADDRESS`, if
`COUNT` is at least 32 (otherwise error 12); `RESULT` is 32. Numbers are
little-endian:

| Offset | Size | Field    | Description                                        |
|--------|------|----------|----------------------------------------------------|
| `0x00` | 4    | `TYPE`   | `1` = file, `2` = directory, `3` = something else  |
| `0x08` | 8    | `SIZE`   | bytes in a file, `0` otherwise                     |
| `0x10` | 8    | `MTIME`  | last modified, seconds since 1970-01-01 UTC        |

**`READDIR`** writes the next entry of the directory open at `HANDLE`:
its stat record and then, from offset `0x20`, its name, NUL-terminated
(at most 255 bytes and the NUL). `COUNT` must be at least 288, room for
any entry (otherwise error 12). `RESULT` is the size of the entry
written, 32 + the name's length + 1, and 0 when there are no more
entries. `.`, `..` and names a path can't hold are left out. The order
is the host's.

`MKDIR` on a path that is there fails with error 5, `REMOVE` of a
directory that isn't empty with error 10. `REMOVE` and `RENAME` of the
folder itself fail with error 3. `REMOVE` of a symbolic link removes the
link. With `--share PATH:ro` every command that would change the folder
fails with error 6, and so does `OPEN` with `WRITE`; `WRITE` and
`TRUNCATE` on a handle opened without it fail with error 6 too.

| `ERROR` | Reason                                                          |
|---------|-----------------------------------------------------------------|
| `1`     | unknown command, or `FLAGS` that don't go together              |
| `2`     | no folder is shared                                             |
| `3`     | a path that isn't allowed (see above)                           |
| `4`     | the path is not there                                           |
| `5`     | the path is there already                                       |
| `6`     | read-only: the folder, or the handle                            |
| `7`     | `HANDLE` is not open, or not a file (a directory for `READDIR`) |
| `8`     | all 16 handles are open                                         |
| `9`     | a directory where a file has to be, or the other way round      |
| `10`    | the directory is not empty                                      |
| `11`    | the DMA reached memory it can't: not RAM or the VRAM window, or also not ROM for `WRITE` and paths |
| `12`    | `COUNT` is too small for the record                             |
| `13`    | the host refused or failed, e.g. no permission or no space      |
| `14`    | a symbolic link leads out of the folder                         |

A reset closes every handle. The files stay as they are: what was
written is in the folder. A snapshot doesn't hold open files either, so
after a load every handle is closed and using one fails with error 7.

### Watchdog

A watchdog timer: software that is still running kicks it before the
timeout; if it doesn't, the watchdog barks (an interrupt, the last chance
to save a log or to recover) and then, after a grace period, resets the
machine. Both periods count clock ticks.

| Offset | Register  | Access | Description                                   |
|--------|-----------|--------|-----------------------------------------------|
| `0x00` | `CONTROL` | RW     | bit 0 = enable, bit 1 = lock                  |
| `0x04` | `TIMEOUT` | RW     | ticks from a kick until it barks              |
| `0x08` | `GRACE`   | RW     | ticks from the bark until it resets the machine |
| `0x0C` | `KICK`    | W      | any value: start again from `TIMEOUT`         |
| `0x10` | `VALUE`   | R      | ticks left in the current period              |
| `0x14` | `STATUS`  | RW     | bit 0 = `BARK`, writing 1 clears it; bit 1 = in the grace period |

Turning bit 0 of `CONTROL` on loads `VALUE` from `TIMEOUT` and starts the
countdown; from the next tick `VALUE` goes down by one every tick.
`TIMEOUT` = N barks after N ticks; 0 acts as 1, and so does a `GRACE`
of 0. On the tick `VALUE` reaches 0 the watchdog barks: `STATUS.BARK`
is set, which asserts IRQ 12, and `VALUE` is loaded from `GRACE`
(`STATUS` bit 1). If that runs out too, the machine resets at the end of
the tick, like the power controller's `RESET`, with `RESET_CAUSE` = 4.

`KICK` loads `VALUE` from `TIMEOUT` again, ends the grace period and
clears `BARK`; while the watchdog is off it does nothing. Writing 1 to
`BARK` only quiets the interrupt: the grace period goes on. A change to
`TIMEOUT` or `GRACE` counts from the next kick. Turning bit 0 off stops
the countdown where it is.

Bit 1 of `CONTROL`, `LOCK`, makes `CONTROL`, `TIMEOUT` and `GRACE`
read-only until the next reset, so a runaway program can't turn the
watchdog off; kicks still work. The watchdog is off and unlocked after
reset.

There is no non-maskable interrupt: a program stuck with interrupts off
doesn't take the bark, and the grace period ends in the reset. Nothing
runs once the CPU has halted, the watchdog neither.

## Reset

On reset all registers are zero except `STATUS` = `0x10`, and
`pc = 0xFE000000`, so execution starts at the first byte of the firmware
image. `EXL` is set: a fault halts the CPU until software installs a
handler, see [Exceptions](INSTRUCTIONS.md#exceptions). The CPU is in supervisor mode,
the MMU is off and its TLB empty. `CYCLE` and `INSTRET` start from zero.

The power controller's `RESET` does the same at run time: the CPU and all
devices return to their reset state (FIFOs are emptied, the PIC `ENABLE`
mask, the timer and its `COUNT` are cleared, disk transfers stop and the
disk registers are cleared, the video card stops its DMA, turns the
display off, hides the cursor and clears its palette and `FRAME`, the
beeper goes quiet, the mouse is disabled and made relative, the Ethernet
card is turned off and its network drops every connection, the audio
card's voices stop, the real-time clock's alarm is
disarmed and cleared, the shared folder closes its handles, the power
controller's `STATUS` is cleared, the watchdog is turned off and
unlocked). The real-time clock's time is not reset: it keeps following the host's
clock, and neither is the random number generator.
The power controller's `RESET_CAUSE` says which reset it was. The host's
reset key, Ctrl+Alt+R in the window, resets the machine the same way,
even after the CPU has halted.
RAM, VRAM and the disk images, and the disk in the floppy drive, keep
their contents, including the sectors of an interrupted
write that were already written. VRAM is zero at power-on.

## Boot protocol

After reset the firmware in ROM runs. The firmware in `wfw/` beeps,
initializes the screen console, then checks the floppy and disk 0 for a
boot image. It loads the first one it finds and jumps to it; if there is
none, it opens a diagnostic menu. This section is the contract between the
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
doesn't boot from a disk, and shows why on the screen, if the header is
invalid, the image runs past the end of the disk or doesn't fit in RAM,
or the disk reports an error; it goes on to the next drive. A drive
without a disk is skipped silently.

### Memory

| Range                     | Contents                                          |
|---------------------------|---------------------------------------------------|
| `0x00000000`–`0x00000FFF` | unspecified                                       |
| `0x00001000`–`0x00001FFF` | boot info block, then the device table            |
| `0x00002000`–`0x0000FFFF` | free; the stack starts at `0x00010000` and grows down |
| `0x00010000`–…            | the image, `SECTORS` × 512 bytes                  |
| the rest of RAM           | unspecified: RAM is not cleared, not even at reset |

The boot info block describes the machine:

| Offset | Field          | Description                                        |
|--------|----------------|----------------------------------------------------|
| `0x00` | `MAGIC`        | `0x4F464E49` (the bytes `INFO`)                    |
| `0x04` | `SIZE`         | size of the block in bytes, 40 here; later fields go after the ones here, so check `SIZE` before reading them |
| `0x08` | `RAM_SIZE`     | bytes of RAM, all of it from address 0             |
| `0x0C` | `DISK`         | physical address of the boot disk's controller: the floppy's or disk 0's |
| `0x10` | `DISK_SECTORS` | its size in sectors                                |
| `0x14` | `IMAGE`        | load address, `0x00010000`                         |
| `0x18` | `IMAGE_SIZE`   | bytes loaded                                       |
| `0x1C` | `CLOCK`        | timer ticks per second                             |
| `0x20` | `DEVICES`      | number of entries in the device table              |
| `0x24` | `DEVICE_TABLE` | physical address of the device table, right after the block |

The device table lists every page of the I/O region that holds a device,
in address order: `DEVICES` entries of 8 bytes, the page's address and
the device's [`ID`](#devices). The firmware finds them by reading the
`ID` of each page. The table ends below `0x00002000`, so it holds at
most 507 devices.

| Offset | Field     | Description                              |
|--------|-----------|------------------------------------------|
| `0x00` | `ADDRESS` | physical address of the device's page    |
| `0x04` | `ID`      | the device's `ID` register               |

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
  The beeper may still be sounding the firmware's beep, for up to 1/10 s
  of ticks.
  The timer, the mouse, the Ethernet card, the audio card, the
  real-time clock's alarm and the watchdog are as after reset. The UART RX FIFO was flushed at reset, but
  it may hold input typed since then, as may the keyboard FIFO.
- The video card shows the firmware's screen console: 640×480, 8 bpp,
  `START` = 0, display on, IRQs off, the engine idle. The palette holds
  the 16 VGA colours in entries 0–15, the xterm 6×6×6 colour cube in
  16–231 and a grey ramp in 232–255. The firmware's font is at VRAM
  offset `0x003FF000`: 256 glyphs of 8×16 pixels, 16 bytes each, top line
  first, bit 7 on the left, laid out as described in [Text](#text);
  codes `0x20`–`0xFF` follow Windows-1252, `0x00`–`0x1F` hold box drawing
  and symbols. The rest of VRAM is unspecified.

## Clock

The system clock runs at 32 MHz by default (`clock_rate` in the config).
On every tick the timer advances first, then the hard disks count the
tick towards their next word, then the video card moves a DMA word and counts the tick towards
the end of the frame, then the floppy counts the tick towards its next
word, then the beeper
advances its wave and `DURATION`, then the audio card counts the tick
towards its next frame, then the real-time clock counts the tick
towards its next alarm comparison, then the watchdog counts the tick,
then the CPU samples the IRQ line and advances its pipeline by one
stage. Nothing runs once the CPU has
halted or the machine is powered off.

The emulator gets the same result with less work: a device runs only on
the ticks where it does something software can see without reading its
registers (an IRQ line changes, a DMA word moves, a frame ends) and
catches up on the ticks in between, in the same order, just before the
CPU reads or writes it. While the CPU waits in `WFI` with the IRQ line
low, the cycles up to the next such tick only count.

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
- **Mode and translation changes:** `MTCR STATUS`, `MTCR PTBR`, `MTCR`
  to a trigger register or `FCSR`, and `TLBI` squash the younger
  instructions in flight when they retire and refetch them, so these see
  the new mode, translation, triggers and rounding mode.
- **FP flags** are computed in EX and set in `FCSR` when the instruction
  retires in WB, so a squashed instruction sets none. `IRET` jumps to `EPC`
  when it retires (4-cycle penalty) rather than in EX.
- **TLB misses** are walked in the same cycle; the walk takes no extra
  cycles.

Timing: an instruction takes 5 cycles to go through the pipeline; the
throughput is up to one instruction per cycle.

See [INSTRUCTIONS.md](INSTRUCTIONS.md) for the instruction set.
