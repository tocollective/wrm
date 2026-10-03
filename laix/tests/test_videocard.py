"""Interpret the videocard driver against register fixtures, without building."""

import unittest

from source_m import SourceM
from test_console import C, VIDEO, STATUS, VRAM_SIZE, VideoRegisters
from test_kernel import LAIX


class TimedVideoRegisters(VideoRegisters):
    def __init__(self):
        super().__init__()
        self.busy_reads = 0
        self.frame_reads = 0
        self.writes_while_busy = []

    def __getitem__(self, address):
        if address == VIDEO + STATUS and self.busy_reads:
            self.busy_reads -= 1
            return C["VIDEO_BUSY"]
        if address == VIDEO + 0x24:
            self.frame_reads += 1
            return 7 if self.frame_reads <= 3 else 8
        return super().__getitem__(address)

    def __setitem__(self, address, value):
        if self.busy_reads:
            self.writes_while_busy.append(address)
        super().__setitem__(address, value)


class VideoM(SourceM):
    def __init__(self):
        super().__init__(LAIX / "src/drivers/videocard.m", TimedVideoRegisters())
        self.globals["video"] = VIDEO
        self.memory.update({VIDEO + STATUS: 0, VIDEO + VRAM_SIZE: 0x400000})


class VideocardTests(unittest.TestCase):
    def test_mode_and_drawing_drain_previous_dma_before_register_writes(self):
        for name, args in (("videoSetMode", (C["VIDEO_MODE_640_480"] | C["VIDEO_8BPP"],)),
                           ("videoFill", (0, 640, 0, 16 << 16 | 8, 1)),
                           ("videoCopy", (0, 640, 0, 0, 640, 16 << 16, 464 << 16 | 640)),
                           ("videoExpand", (0, 640, 0, 640 * 480, 2, 0, 16 << 16 | 8, 1, 0))):
            with self.subTest(operation=name):
                vm = VideoM()
                vm.memory.busy_reads = 3
                vm.call(name, *args)
                self.assertEqual(vm.memory.busy_reads, 0)
                self.assertEqual(vm.memory.writes_while_busy, [])

    def test_upload_last_words_of_vram_and_fence_before_return(self):
        vm = VideoM()
        source, offset = 0x200000, 0x400000 - 8
        vm.memory.update({source: 0x12345678, source + 4: 0xABCDEF01})
        vm.memory.busy_reads = 2
        self.assertTrue(vm.call("videoWriteWords", offset, source, 2))
        self.assertEqual(vm.memory[C["VRAM_BASE"] + offset], 0x12345678)
        self.assertEqual(vm.memory[C["VRAM_BASE"] + offset + 4], 0xABCDEF01)
        self.assertEqual(vm.events, [("fence", [])])
        self.assertEqual(vm.memory.writes_while_busy, [])

    def test_invalid_upload_never_partially_writes_or_wraps(self):
        for offset, source, count in ((0, 0, 1), (0, 0x200001, 1),
                                      (1, 0x200000, 1), (0x400000, 0x200000, 1),
                                      (0x400004, 0x200000, 1),
                                      (0x3FFFFC, 0x200000, 2),
                                      (0, 0x200000, 0x40000001)):
            with self.subTest(offset=offset, source=source, count=count):
                vm = VideoM()
                before = dict(vm.memory)
                self.assertFalse(vm.call("videoWriteWords", offset, source, count))
                self.assertEqual(vm.memory, before)
                self.assertEqual(vm.events, [])

    def test_empty_upload_needs_no_source_or_vram_access(self):
        vm = VideoM()
        vm.memory.clear()
        self.assertTrue(vm.call("videoWriteWords", 0xFFFFFFFF, 0, 0))
        self.assertEqual(vm.memory, {})
        self.assertEqual(vm.events, [])

    def test_wait_frame_returns_only_after_frame_changes(self):
        vm = VideoM()
        vm.call("videoWaitFrame")
        self.assertEqual(vm.memory.frame_reads, 4)


if __name__ == "__main__":
    unittest.main()
