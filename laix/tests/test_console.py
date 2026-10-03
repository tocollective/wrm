"""Console failure handling, interpreted from console.m without building.

The video card is a register fixture: engine commands record what they draw
and can fail with a chosen ERROR. Font, glyph cache and UART are stubs.
"""

import unittest

from test_kernel import LAIX, parse_asm, asm_constants
from source_m import SourceM

C = asm_constants(parse_asm(LAIX / "src/arch/wrm081632/defs.inc"))
VIDEO = C["VIDEO_BASE"]
# Register offsets from docs/SPECIFICATION.md (Video card).
STATUS, MODE, WIDTH, HEIGHT, BPP, PITCH, VRAM_SIZE = 0x00, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C
COMMAND, ERROR, DST_XY = 0x40, 0x44, 0x50
FONT, GLYPHS = 0x200000, 0x201000  # synthetic Font and Glyph index
GLYPH_A, GLYPH_WIDE = 1, 2


class VideoRegisters(dict):
    """Memory whose COMMAND store runs a fake engine command at once."""

    def __init__(self):
        super().__init__()
        self.commands = []
        self.fail = {}  # command -> ERROR
        self.takes_mode = True

    def __setitem__(self, address, value):
        super().__setitem__(address, value)
        if address == VIDEO + COMMAND:
            self.commands.append((value, self.get(VIDEO + DST_XY, 0)))
            super().__setitem__(VIDEO + ERROR, self.fail.get(value, 0))
        elif address == VIDEO + MODE:
            # The card takes the 640x480x8 mode; other values are ignored.
            if self.takes_mode and value == C["VIDEO_MODE_640_480"] | C["VIDEO_8BPP"]:
                for offset, register in ((WIDTH, "SCREEN_WIDTH"), (HEIGHT, "SCREEN_HEIGHT"),
                                         (BPP, "SCREEN_BPP"), (PITCH, "SCREEN_PITCH")):
                    super().__setitem__(VIDEO + offset, C[register])


class ConsoleM(SourceM):
    def __init__(self):
        super().__init__(LAIX / "src/console/console.m", VideoRegisters())
        self.globals["video"] = VIDEO
        self.addresses.update(font=FONT, fontData=0x300000, fontDataEnd=0x300100)
        self.memory.update({VIDEO + STATUS: 0, VIDEO + VRAM_SIZE: 0x400000,
                            VIDEO + WIDTH: 320, VIDEO + HEIGHT: 240, VIDEO + BPP: 1,
                            VIDEO + PITCH: 40})
        self.cache = {GLYPH_A: 0, GLYPH_WIDE: 1}
        self.font_ok = self.cache_ok = True
        self.uart = []

    def call(self, name, *args):
        if name == "loadFont":
            # Font { count, index, fallback } and Glyph { code, advance }.
            self.memory.update({FONT: 3, FONT + 4: GLYPHS, FONT + 8: GLYPH_A})
            for glyph, advance in ((0, 8), (GLYPH_A, 8), (GLYPH_WIDE, 16)):
                self.memory[GLYPHS + 8 * glyph] = 0x40 + glyph
                self.memory[GLYPHS + 8 * glyph + 4] = advance
            return self.font_ok
        if name == "glyphCacheInit":
            return self.cache_ok
        if name == "glyphIndex":
            return args[0] - 0x40 if 0x40 <= args[0] < 0x43 else 3
        if name == "cacheGlyph":
            return self.cache.get(args[0], self.globals["CACHE_GLYPHS"])
        if name == "debugPrint":
            text = args[0]
            self.uart.append(text.decode() if isinstance(text, bytes) else text)
            return
        return super().call(name, *args)

    def failures(self):
        return [text for text in self.uart if text not in ("LA/IX: console failed: ", "\n")]


class ConsoleTests(unittest.TestCase):
    def ready(self):
        vm = ConsoleM()
        self.assertTrue(vm.call("consoleInit"))
        self.assertEqual(vm.uart, [])
        vm.memory.commands.clear()
        return vm

    def test_init_draws_and_checks_the_mode_it_set(self):
        vm = self.ready()
        self.assertEqual(vm.memory[VIDEO + MODE], C["VIDEO_MODE_640_480"] | C["VIDEO_8BPP"])
        self.assertEqual(vm.memory[VIDEO + 0x04], C["VIDEO_ENABLE"])
        self.assertFalse(vm.call("consoleFailed"))

    def test_init_fails_loudly_when_the_card_ignores_the_mode(self):
        vm = ConsoleM()
        vm.memory.takes_mode = False  # a card that keeps its previous mode
        self.assertFalse(vm.call("consoleInit"))
        self.assertEqual(len(vm.failures()), 1)
        self.assertIn("not taken", vm.failures()[0])
        self.assertTrue(vm.call("consoleFailed"))

    def test_init_reports_each_failure_reason(self):
        for setup, reason in ((lambda vm: vm.memory.fail.update({C["VIDEO_FILL"]: 2}), "engine"),
                              (lambda vm: setattr(vm, "font_ok", False), "font"),
                              (lambda vm: vm.memory.update({VIDEO + VRAM_SIZE: 0x1000}), "VRAM"),
                              (lambda vm: setattr(vm, "cache_ok", False), "glyph bitmaps")):
            with self.subTest(reason=reason):
                vm = ConsoleM()
                setup(vm)
                self.assertFalse(vm.call("consoleInit"))
                self.assertEqual(len(vm.failures()), 1)
                self.assertIn(reason, vm.failures()[0])
                self.assertNotEqual(vm.memory[VIDEO + 0x04], C["VIDEO_ENABLE"])

    def test_glyph_is_drawn_and_advances_only_on_success(self):
        vm = self.ready()
        vm.call("putChar", 0x41)
        self.assertEqual(vm.memory.commands, [(C["VIDEO_EXPAND"], 0)])
        self.assertEqual(vm.globals["column"], 1)
        vm.memory.fail[C["VIDEO_EXPAND"]] = 2
        vm.call("putChar", 0x41)
        self.assertEqual(vm.globals["column"], 1)
        self.assertTrue(vm.call("consoleFailed"))
        self.assertEqual(len(vm.failures()), 1)
        self.assertIn("engine", vm.failures()[0])

    def test_failure_is_reported_once_then_output_stops(self):
        vm = self.ready()
        vm.cache = {}
        for _ in range(3):
            vm.call("putChar", 0x41)
        self.assertEqual(len(vm.failures()), 1)
        self.assertIn("glyph", vm.failures()[0])
        self.assertEqual(vm.memory.commands, [])

    def test_scroll_failure_stops_before_drawing_the_glyph(self):
        vm = self.ready()
        rows = C["SCREEN_HEIGHT"] // C["GLYPH_HEIGHT"]
        vm.globals["row"] = rows - 1
        vm.memory.fail[C["VIDEO_COPY"]] = 2
        vm.call("putChar", 0x0A)  # newline on the last row scrolls
        self.assertEqual([command for command, _ in vm.memory.commands], [C["VIDEO_COPY"]])
        vm.call("putChar", 0x41)
        self.assertEqual([command for command, _ in vm.memory.commands], [C["VIDEO_COPY"]])
        self.assertEqual(len(vm.failures()), 1)

    def test_wide_glyph_at_the_last_column_wraps_before_drawing(self):
        vm = self.ready()
        columns = C["SCREEN_WIDTH"] // C["CELL_WIDTH"]
        vm.globals["column"] = columns - 1
        vm.call("putChar", 0x42)
        self.assertEqual(vm.memory.commands, [(C["VIDEO_EXPAND"], C["GLYPH_HEIGHT"] << 16)])
        self.assertEqual((vm.globals["row"], vm.globals["column"]), (1, 2))
        self.assertFalse(vm.call("consoleFailed"))


if __name__ == "__main__":
    unittest.main()
