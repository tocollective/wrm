# WRM.081632 ROM firmware

Create a ROM image with `python3 mc/mc.py --rom wfw/src/main.m -o firmware.rom`.
The CPU enters it at `0xFE000000` after reset. The M ROM runtime initializes
the stack and data and clears BSS. A local `src/romtrap.asm` handles faults
before the screen is ready without using the UART. The firmware installs
a screen-only fatal trap handler when `main` starts.

The firmware sets up a 640x480, 8 bpp screen console, prints the reset
cause and RAM size, then tries the floppy followed by disk 0. Before reading
each present drive, it prints `Loading from floppy...` or
`Loading from disk 0...`, so the source is visible while loading. A valid
`WRMB` image is loaded at `0x00010000` and entered with the boot info block
and CPU state specified in [the boot protocol](../docs/SPECIFICATION.md#boot-protocol).
Invalid images and disk errors are shown on the screen. The firmware does
not read or write the UART.

Sources are organized under `src/`:

| Path | Purpose |
| --- | --- |
| `main.m` | Startup and diagnostic menu |
| `romtrap.asm` | Early trap handler, kept beside the entry module |
| `arch/wrm081632/` | Hardware registers and boot structures |
| `boot/` | Disk boot, hardware probes and boot hand-off |
| `console/` | Console output and font data |
| `video/` | Video setup, text drawing, BMP decoding and logo embedding |
| `trap/` | Screen fatal trap handler and assembly entry |

[`images/logo.bmp`](images/logo.bmp) is embedded unchanged in ROM and drawn
at the upper right with an 8-pixel margin. The console width is calculated
from the image width, so scrolling leaves the image in place. The full
standard palette is restored before boot hand-off.

### Drawing another BMP

[`bmp.m`](src/video/bmp.m) provides `bmpInfo(data, length, &mut info)` to read the
dimensions and `bmpDraw(data, length, x, y, zeroIndex, oneIndex)` to draw at
any screen position. Both return `false` for invalid or unsupported input;
`bmpDraw` also returns `false` if the image does not fit on screen or DMA
fails. The functions accept a pointer and byte length, so images can come
from ROM or RAM. For a ROM image, use [`logo.asm`](src/video/logo.asm) and
[`logo.m`](src/video/logo.m) as the embedding pattern: `.incbin` the file between two
labels, then subtract the label addresses to get its length.

For example, after declaring and importing `pictureBmp` and
`pictureBmpEnd` like the logo symbols:

```m
let data: *UByte = &pictureBmp
let length: UWord = (&pictureBmpEnd as UWord) - (data as UWord)
let drawn: Bool = bmpDraw(data, length, 32, 24, 209, 210)
```

The `.incbin` path is relative to its assembly source file.

The supported format is an uncompressed Windows BMP with a 40-byte or larger
DIB header, 1 bit per pixel and two palette colours. Width, height, pixel
offset, 4-byte row padding and row direction are read from the file. A
top-down or bottom-up image works. Drawing uses the video card's current
8 bpp mode and copies one aligned line at a time before DMA, so the BMP
itself does not need extra padding in memory.

`zeroIndex` and `oneIndex` are palette entries assigned to the BMP's two
colours. Pick two distinct indices from 0–255. Palette entries are shared
by the whole screen: drawing another BMP with the same indices changes the
colours of earlier pixels that use them. The console uses indices 0 and 7;
the logo uses 208 and 15. Reserve other indices for additional images.

If neither drive boots, the diagnostic menu accepts these keys from the
emulated keyboard:

| Key | Action |
| --- | --- |
| `r` | Retry floppy, then disk 0 |
| `d` | Probe and list device page addresses and IDs |
| `h` | Show menu help |
| `p` | Power off |

The menu also handles the host power button. Interrupts stay disabled; the
menu polls the keyboard and power controller. The device probe and RAM
probe are in [`boot.asm`](src/boot/boot.asm) because they must recover from bus errors. The boot
transfer and temporary stack switch are there too. [`video.m`](src/video/video.m) and [`font.m`](src/console/font.m)
provide the screen state inherited by a boot image.
