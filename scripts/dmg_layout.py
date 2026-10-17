#!/usr/bin/env python3
"""Формирует Retina-фон, иконку тома и разметку окна Finder (.DS_Store) для DMG-образа PangoZip."""

import argparse
import ctypes
import ctypes.util
import math
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zlib

WINDOW_WIDTH = 660
WINDOW_HEIGHT = 400
WINDOW_BOUNDS = "{{200, 240}, {660, 400}}"
APP_ICON_POSITION = (180, 170)
APPLICATIONS_ICON_POSITION = (480, 170)
ICON_SIZE = 128.0
TEXT_SIZE = 16.0
FINDER_CUSTOM_ICON_FLAG = 0x0400


class FSRef(ctypes.Structure):
    """Непрозрачная структура Carbon FSRef для создания записи Alias на томе HFS+."""

    _fields_ = [("hidden", ctypes.c_uint8 * 80)]


def _box_gaussian(distance, half_width, sigma):
    """Вычисляет аналитическую свёртку прямоугольного импульса с гауссианом."""
    scale = sigma * 1.4142135623730951
    return 0.5 * (math.erf((distance + half_width) / scale) - math.erf((distance - half_width) / scale))


def _distance_to_segment(px, py, ax, ay, bx, by):
    """Возвращает кратчайшее расстояние от точки до отрезка для сглаживания шеврона."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    proj = vx * wx + vy * wy
    if proj <= 0.0:
        return math.hypot(px - ax, py - ay)
    norm_sq = vx * vx + vy * vy
    if norm_sq <= proj:
        return math.hypot(px - bx, py - by)
    ratio = proj / norm_sq
    return math.hypot(px - (ax + ratio * vx), py - (ay + ratio * vy))


def _write_png(path, width, height, rgb_rows):
    """Записывает 24-битный RGB PNG без сторонних библиотек."""
    raw = bytearray()
    for row in rgb_rows:
        raw.append(0)
        raw.extend(row)

    def make_chunk(tag, payload):
        crc = zlib.crc32(tag + payload) & 0xFFFFFFFF
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    compressed = zlib.compress(bytes(raw), 6)
    png_bytes = b"\x89PNG\r\n\x1a\n" + make_chunk(b"IHDR", ihdr) + make_chunk(b"IDAT", compressed) + make_chunk(b"IEND", b"")
    Path(path).write_bytes(png_bytes)


def render_background_png(path, scale):
    """Рендерит фон окна DMG (свечение под PangoZip.app и стрелку-шеврон) в заданном масштабе."""
    width = WINDOW_WIDTH * scale
    height = WINDOW_HEIGHT * scale

    # Глубокий синий оттенок подложки иконки PangoZip.
    glow_r, glow_g, glow_b = 20.0, 62.0, 132.0

    norm_x1 = _box_gaussian(0.0, 48.0, 32.0)
    norm_y1 = _box_gaussian(0.0, 44.0, 28.0)
    norm_x2 = _box_gaussian(0.0, 70.0, 46.0)
    norm_y2 = _box_gaussian(0.0, 56.0, 42.0)

    glow_limit_x = 330 * scale
    x_profile_inner = [_box_gaussian((x / scale) - 180.0, 48.0, 32.0) / norm_x1 for x in range(glow_limit_x)]
    x_profile_outer = [_box_gaussian((x / scale) - 180.0, 70.0, 46.0) / norm_x2 for x in range(glow_limit_x)]
    y_profile_inner = [_box_gaussian((y / scale) - 170.0, 44.0, 28.0) / norm_y1 for y in range(height)]
    y_profile_outer = [_box_gaussian((y / scale) - 152.0, 56.0, 42.0) / norm_y2 for y in range(height)]

    white_tail = b"\xff" * ((width - glow_limit_x) * 3)
    chevron_x0, chevron_x1 = int(315 * scale), int(345 * scale)
    chevron_y0, chevron_y1 = int(150 * scale), int(190 * scale)

    rows = []
    for y in range(height):
        yp_in = y_profile_inner[y]
        yp_out = y_profile_outer[y]
        row = bytearray(width * 3)
        if yp_in < 0.001 and yp_out < 0.001:
            row[:] = b"\xff" * (width * 3)
        else:
            idx = 0
            for x in range(glow_limit_x):
                strength = min(1.0, 0.72 * (x_profile_inner[x] * yp_in) + 0.36 * (x_profile_outer[x] * yp_out))
                row[idx] = int(255.0 - strength * (255.0 - glow_r) + 0.5)
                row[idx + 1] = int(255.0 - strength * (255.0 - glow_g) + 0.5)
                row[idx + 2] = int(255.0 - strength * (255.0 - glow_b) + 0.5)
                idx += 3
            row[glow_limit_x * 3:] = white_tail

        if chevron_y0 <= y <= chevron_y1:
            py = (y + 0.5) / scale
            for x in range(chevron_x0, chevron_x1):
                px = (x + 0.5) / scale
                d1 = _distance_to_segment(px, py, 322.0, 156.0, 338.0, 170.0)
                d2 = _distance_to_segment(px, py, 338.0, 170.0, 322.0, 184.0)
                dist = min(d1, d2)
                edge = (2.75 - dist) * scale + 0.5
                if edge > 0.0:
                    alpha = min(1.0, edge)
                    idx = x * 3
                    row[idx] = int(row[idx] * (1.0 - alpha) + 84.0 * alpha + 0.5)
                    row[idx + 1] = int(row[idx + 1] * (1.0 - alpha) + 86.0 * alpha + 0.5)
                    row[idx + 2] = int(row[idx + 2] * (1.0 - alpha) + 89.0 * alpha + 0.5)
        rows.append(row)

    _write_png(path, width, height, rows)


def build_background_tiff(output_path):
    """Создаёт многослойный HiDPI TIFF (1x + 2x) для фона окна Finder."""
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pangozip-dmg-bg-") as tmp_dir:
        tmp = Path(tmp_dir)
        png_1x = tmp / "base.png"
        png_2x = tmp / "hidpi.png"
        tiff_1x = tmp / "base.tiff"
        tiff_2x = tmp / "hidpi.tiff"
        render_background_png(png_1x, 1)
        render_background_png(png_2x, 2)
        subprocess.run(
            ["sips", "-s", "format", "tiff", "-s", "formatOptions", "lzw", str(png_1x), "--out", str(tiff_1x)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            ["sips", "-s", "format", "tiff", "-s", "formatOptions", "lzw", str(png_2x), "--out", str(tiff_2x)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(
            ["tiffutil", "-cathidpicheck", str(tiff_1x), str(tiff_2x), "-out", str(output)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def create_carbon_alias(target_path, relative_to_path=None):
    """Создаёт системную запись Carbon Alias для файла фона внутри смонтированного тома."""
    cs_path = ctypes.util.find_library("CoreServices")
    if not cs_path:
        raise RuntimeError("CoreServices framework not found")
    cs = ctypes.cdll.LoadLibrary(cs_path)
    cs.FSPathMakeRef.argtypes = [ctypes.c_char_p, ctypes.POINTER(FSRef), ctypes.c_void_p]
    cs.FSPathMakeRef.restype = ctypes.c_int32
    cs.FSNewAlias.argtypes = [ctypes.POINTER(FSRef), ctypes.POINTER(FSRef), ctypes.POINTER(ctypes.c_void_p)]
    cs.FSNewAlias.restype = ctypes.c_int32
    cs.GetHandleSize.argtypes = [ctypes.c_void_p]
    cs.GetHandleSize.restype = ctypes.c_long
    cs.DisposeHandle.argtypes = [ctypes.c_void_p]

    target_ref = FSRef()
    err = cs.FSPathMakeRef(os.fsencode(os.path.realpath(target_path)), ctypes.byref(target_ref), None)
    if err != 0:
        raise RuntimeError(f"FSPathMakeRef failed for {target_path}: {err}")

    from_ref_ptr = None
    if relative_to_path is not None:
        from_ref = FSRef()
        err = cs.FSPathMakeRef(os.fsencode(os.path.realpath(relative_to_path)), ctypes.byref(from_ref), None)
        if err != 0:
            raise RuntimeError(f"FSPathMakeRef failed for {relative_to_path}: {err}")
        from_ref_ptr = ctypes.byref(from_ref)

    alias_handle = ctypes.c_void_p()
    err = cs.FSNewAlias(from_ref_ptr, ctypes.byref(target_ref), ctypes.byref(alias_handle))
    if err != 0 or not alias_handle.value:
        raise RuntimeError(f"FSNewAlias failed for {target_path}: {err}")
    try:
        size = cs.GetHandleSize(alias_handle)
        deref = ctypes.cast(alias_handle, ctypes.POINTER(ctypes.c_void_p)).contents.value
        return ctypes.string_at(deref, size)
    finally:
        cs.DisposeHandle(alias_handle)


def create_url_bookmark(target_path):
    """Создаёт полную системную закладку фона без обрезания бинарных данных."""
    cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
    cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
    cf.CFURLCreateBookmarkData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    cf.CFURLCreateBookmarkData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    encoded = os.fsencode(os.path.realpath(target_path))
    url = cf.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), False)
    if not url:
        raise RuntimeError("Failed to create background URL")
    try:
        bookmark = cf.CFURLCreateBookmarkData(None, url, 1 << 29, None, None, None)
        if not bookmark:
            raise RuntimeError("Failed to create background bookmark")
        try:
            return ctypes.string_at(cf.CFDataGetBytePtr(bookmark), cf.CFDataGetLength(bookmark))
        finally:
            cf.CFRelease(bookmark)
    finally:
        cf.CFRelease(url)


def serialize_ds_store(records):
    """Собирает бинарный файл .DS_Store (формат Bud1/DSDB) из отсортированного списка записей."""
    sorted_records = sorted(records, key=lambda item: (item[0].lower().encode("utf-16-be"), item[1].encode("latin1")))
    leaf_payload = bytearray(struct.pack(">II", 0, len(sorted_records)))
    for filename, code, dtype, value in sorted_records:
        encoded_name = filename.encode("utf-16-be")
        leaf_payload.extend(struct.pack(">I", len(filename)))
        leaf_payload.extend(encoded_name)
        leaf_payload.extend(code.encode("latin1"))
        leaf_payload.extend(dtype.encode("latin1"))
        if dtype in ("long", "shor"):
            leaf_payload.extend(struct.pack(">I", int(value)))
        elif dtype == "type":
            if len(value) != 4:
                raise ValueError("DS_Store type value must contain four bytes")
            leaf_payload.extend(value)
        elif dtype == "bool":
            leaf_payload.append(1 if value else 0)
        elif dtype == "blob":
            leaf_payload.extend(struct.pack(">I", len(value)))
            leaf_payload.extend(value)
        elif dtype == "ustr":
            encoded_str = value.encode("utf-16-be")
            leaf_payload.extend(struct.pack(">I", len(value)))
            leaf_payload.extend(encoded_str)
        else:
            raise ValueError(f"Unsupported DS_Store record type: {dtype}")

    if len(leaf_payload) > 4096:
        raise ValueError(f"DS_Store leaf node overflow: {len(leaf_payload)} bytes")
    leaf_block = bytes(leaf_payload).ljust(4096, b"\x00")

    buf = bytearray(0x2800)
    # Заголовок распределителя блоков Bud1.
    buf[0:32] = (
        b"Bud1"
        + struct.pack(">III", 0x2000, 0x800, 0x2000)
        + bytes.fromhex("0000100c000000000000000000000000")
    )
    # Блок 1 (0x40..0x60, 32 байта): суперблок B-дерева DSDB.
    buf[0x40:0x54] = struct.pack(">IIIII", 2, 0, len(sorted_records), 1, 0x1000)
    # Блок 2 (0x1000..0x2000, 4096 байт): корневой листовой узел B-дерева.
    buf[0x1000:0x2000] = leaf_block

    # Блок 0 (0x2000..0x2800, 2048 байт): таблица блоков, каталог DSDB и списки свободных областей.
    meta = bytearray()
    meta.extend(struct.pack(">II", 3, 0))
    block_addresses = [0x2000 | 11, 0x40 | 5, 0x1000 | 12] + [0] * 253
    meta.extend(struct.pack(">256I", *block_addresses))
    meta.extend(struct.pack(">IB4sI", 1, 4, b"DSDB", 1))

    freelists = {
        5: [0x20, 0x60],
        7: [0x80],
        8: [0x100],
        9: [0x200],
        10: [0x400],
        11: [0x800, 0x2800],
        12: [0x3000],
        14: [0x4000],
    }
    for bit in range(15, 31):
        freelists[bit] = [1 << bit]
    for bit in range(32):
        offsets = freelists.get(bit, [])
        meta.extend(struct.pack(f">I{len(offsets)}I", len(offsets), *offsets))

    buf[0x2000 : 0x2000 + len(meta)] = meta
    return b"\x00\x00\x00\x01" + bytes(buf)


def build_volume_ds_store(mountpoint, app_name="PangoZip.app"):
    """Формирует .DS_Store для смонтированного тома DMG с привязкой к его фоновому изображению."""
    root = Path(mountpoint)
    background_path = root / ".background/background.tiff"
    if not background_path.is_file():
        raise FileNotFoundError(f"Missing DMG background image: {background_path}")

    alias_bytes = create_carbon_alias(background_path, root)
    bookmark_bytes = create_url_bookmark(background_path)

    bwsp = {
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "ShowStatusBar": False,
        "ShowTabView": False,
        "ShowToolbar": False,
        "WindowBounds": WINDOW_BOUNDS,
    }
    icvp = {
        "arrangeBy": "none",
        "backgroundColorBlue": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorRed": 1.0,
        "backgroundImageAlias": alias_bytes,
        "backgroundType": 2,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": ICON_SIZE,
        "labelOnBottom": True,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "showIconPreview": True,
        "showItemInfo": False,
        "textSize": TEXT_SIZE,
        "viewOptionsVersion": 1,
    }

    records = [
        (".", "bwsp", "blob", plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)),
        (".", "icvl", "type", b"icnv"),
        (".", "icvp", "blob", plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)),
        (".", "pBBk", "blob", bookmark_bytes),
        (".", "vSrn", "long", 1),
        (
            "Applications",
            "Iloc",
            "blob",
            struct.pack(">IIII", APPLICATIONS_ICON_POSITION[0], APPLICATIONS_ICON_POSITION[1], 0xFFFFFFFF, 0xFFFF0000),
        ),
        (
            app_name,
            "Iloc",
            "blob",
            struct.pack(">IIII", APP_ICON_POSITION[0], APP_ICON_POSITION[1], 0xFFFFFFFF, 0xFFFF0000),
        ),
    ]
    # Finder может показывать скрытые файлы по глобальной настройке пользователя.
    # Фиксируем служебные значки ниже окна, чтобы они не попадали в установочную область.
    for index, name in enumerate((".background", ".fseventsd", ".VolumeIcon.icns", ".DS_Store", ".Trashes")):
        records.append((name, "Iloc", "blob", struct.pack(">IIII", 100 + index * 140, 1000, 0xFFFFFFFF, 0xFFFF0000)))

    ds_store_bytes = serialize_ds_store(records)
    (root / ".DS_Store").write_bytes(ds_store_bytes)


def set_custom_volume_icon(mountpoint, icns_path):
    """Устанавливает .VolumeIcon.icns и флаг kHasCustomIcon в FinderInfo корневого каталога тома."""
    root = Path(mountpoint)
    source = Path(icns_path)
    if not source.is_file():
        raise FileNotFoundError(f"Missing volume icon: {source}")
    target = root / ".VolumeIcon.icns"
    shutil.copyfile(source, target)

    finder_info = bytes(bytearray(8) + struct.pack(">H", FINDER_CUSTOM_ICON_FLAG) + bytearray(22))
    libc = ctypes.CDLL(ctypes.util.find_library("c"))
    libc.setxattr.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_size_t,
        ctypes.c_uint32,
        ctypes.c_int,
    ]
    libc.setxattr.restype = ctypes.c_int
    if libc.setxattr(os.fsencode(root), b"com.apple.FinderInfo", finder_info, len(finder_info), 0, 0) != 0:
        raise OSError(f"Failed to set com.apple.FinderInfo on {root}")


def prepare_payload(payload_dir, icns_path, app_name="PangoZip.app"):
    """Подготавливает каталог полезной нагрузки до создания HFS+ образа (резервируя место под ресурсы и .DS_Store)."""
    root = Path(payload_dir)
    build_background_tiff(root / ".background/background.tiff")
    set_custom_volume_icon(root, icns_path)
    build_volume_ds_store(root, app_name=app_name)


def finalize_volume(mountpoint, icns_path=None, app_name="PangoZip.app"):
    """Записывает на смонтированный HFS+ том финальный .DS_Store с CNID и UUID тома, а также атрибут иконки."""
    root = Path(mountpoint)
    icon_target = root / ".VolumeIcon.icns"
    if icns_path is not None:
        set_custom_volume_icon(root, icns_path)
    elif icon_target.is_file():
        finder_info = bytes(bytearray(8) + struct.pack(">H", FINDER_CUSTOM_ICON_FLAG) + bytearray(22))
        libc = ctypes.CDLL(ctypes.util.find_library("c"))
        libc.setxattr.argtypes = [
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_size_t,
            ctypes.c_uint32,
            ctypes.c_int,
        ]
        libc.setxattr.restype = ctypes.c_int
        if libc.setxattr(os.fsencode(root), b"com.apple.FinderInfo", finder_info, len(finder_info), 0, 0) != 0:
            raise OSError(f"Failed to set com.apple.FinderInfo on {root}")
    build_volume_ds_store(root, app_name=app_name)


def configure_volume(mountpoint, icns_path, app_name="PangoZip.app"):
    """Полностью настраивает смонтированный пишущий том DMG перед конвертацией в UDZO."""
    prepare_payload(mountpoint, icns_path, app_name=app_name)


def main():
    """Точка входа командной строки для генерации фона и настройки смонтированного DMG."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    bg_parser = subparsers.add_parser("render-background")
    bg_parser.add_argument("output", help="Путь к выходному файлу background.tiff")

    prep_parser = subparsers.add_parser("prepare-payload")
    prep_parser.add_argument("payload", help="Каталог полезной нагрузки DMG")
    prep_parser.add_argument("--icon", required=True, help="Путь к файлу AppIcon.icns")
    prep_parser.add_argument("--app-name", default="PangoZip.app", help="Имя пакета приложения")

    fin_parser = subparsers.add_parser("finalize-volume")
    fin_parser.add_argument("mountpoint", help="Точка монтирования пишущего тома DMG")
    fin_parser.add_argument("--icon", help="Путь к файлу AppIcon.icns")
    fin_parser.add_argument("--app-name", default="PangoZip.app", help="Имя пакета приложения")

    vol_parser = subparsers.add_parser("configure-volume")
    vol_parser.add_argument("mountpoint", help="Точка монтирования пишущего тома DMG")
    vol_parser.add_argument("--icon", required=True, help="Путь к файлу AppIcon.icns")
    vol_parser.add_argument("--app-name", default="PangoZip.app", help="Имя пакета приложения")

    args = parser.parse_args()
    if args.command == "render-background":
        build_background_tiff(args.output)
    elif args.command == "prepare-payload":
        prepare_payload(args.payload, args.icon, app_name=args.app_name)
    elif args.command == "finalize-volume":
        finalize_volume(args.mountpoint, icns_path=args.icon, app_name=args.app_name)
    elif args.command == "configure-volume":
        configure_volume(args.mountpoint, args.icon, app_name=args.app_name)


if __name__ == "__main__":
    main()
