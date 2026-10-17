"""Проверки разметки установочного окна Finder."""

import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "dmg_layout", Path(__file__).resolve().parents[1] / "dmg_layout.py"
)
layout = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(layout)


def read_records(data):
    """Читает записи единственного листа .DS_Store независимо от генератора."""
    offset = 4100
    _, count = struct.unpack_from(">II", data, offset)
    offset += 8
    records = {}
    for _ in range(count):
        length = struct.unpack_from(">I", data, offset)[0]
        offset += 4
        name = data[offset:offset + length * 2].decode("utf-16-be")
        offset += length * 2
        code, kind = data[offset:offset + 4], data[offset + 4:offset + 8]
        offset += 8
        if kind == b"blob":
            size = struct.unpack_from(">I", data, offset)[0]
            offset += 4
            value = data[offset:offset + size]
            offset += size
        elif kind in (b"long", b"shor", b"type"):
            value = data[offset:offset + 4]
            offset += 4
        else:
            raise AssertionError(f"Unexpected record type: {kind}")
        records[name, code] = value
    return records


class DMGLayoutTests(unittest.TestCase):
    def test_installer_opens_compactly_with_support_icons_outside_viewport(self):
        """Обе установочные иконки видны, служебные элементы находятся за границами окна."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".background").mkdir()
            (root / ".background/background.tiff").touch()
            bookmark = b"book" + struct.pack("<I", 2000) + bytes(1992)
            with patch.object(layout, "create_carbon_alias", return_value=b"alias"), \
                 patch.object(layout, "create_url_bookmark", return_value=bookmark):
                layout.build_volume_ds_store(root)
            records = read_records((root / ".DS_Store").read_bytes())
        self.assertEqual(records[".", b"pBBk"], bookmark)
        window = plistlib.loads(records[".", b"bwsp"])
        self.assertEqual(window["WindowBounds"], "{{200, 240}, {660, 400}}")
        self.assertFalse(window["ShowStatusBar"])
        self.assertIn((".", b"icvl"), records)
        self.assertEqual(records[".", b"icvl"], b"icnv")
        options = plistlib.loads(records[".", b"icvp"])
        self.assertEqual(options["scrollPositionX"], 0.0)
        self.assertEqual(options["scrollPositionY"], 0.0)
        for name in ("PangoZip.app", "Applications"):
            x, y = struct.unpack(">IIII", records[name, b"Iloc"])[:2]
            self.assertTrue(64 < x < 596)
            self.assertTrue(64 < y < 280)
        for name in (".background", ".fseventsd", ".VolumeIcon.icns", ".DS_Store", ".Trashes"):
            x, y = struct.unpack(">IIII", records[name, b"Iloc"])[:2]
            self.assertGreater(y - 64, 400, name)


if __name__ == "__main__":
    unittest.main()
