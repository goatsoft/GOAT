#!/usr/bin/env python3
"""Check Finder's saved installer window and hide its inherited tab bar in place."""
import argparse
from pathlib import Path
import plistlib
import struct


def blob_record(data, name, code):
    marker = struct.pack(">I", len(name)) + name.encode("utf-16be") + code + b"blob"
    if data.count(marker) != 1:
        raise ValueError(f"expected one Finder {name} {code.decode()} record")
    start = data.index(marker) + len(marker)
    size = struct.unpack_from(">I", data, start)[0]
    start += 4
    blob = data[start:start + size]
    if len(blob) != size:
        raise ValueError("truncated Finder record")
    return start, blob


def window_record(data):
    start, blob = blob_record(data, ".", b"bwsp")
    options = plistlib.loads(blob)
    if not blob.startswith(b"bplist00") or not isinstance(options, dict):
        raise ValueError("expected a binary Finder window dictionary")
    return start, blob, options


def hide_tab_bar(data):
    start, blob, options = window_record(data)
    if options.get("ShowTabView") is False:
        return data
    if options.get("ShowTabView") is not True:
        raise ValueError("missing Finder tab bar flag")
    # Change the boolean object, preserving every record length and allocator
    # offset in the DS_Store. Fail if Finder changes its dictionary encoding.
    offset_size, ref_size, count, root, table = struct.unpack(">6xBBQQQ", blob[-32:])
    offsets = [int.from_bytes(blob[table + i * offset_size:table + (i + 1) * offset_size], "big")
               for i in range(count)]
    root_offset = offsets[root]
    marker = blob[root_offset]
    if marker >> 4 != 13 or marker & 15 != len(options) or len(options) >= 15:
        raise ValueError("unsupported Finder window dictionary encoding")
    value_ref = root_offset + 1 + (len(options) + list(options).index("ShowTabView")) * ref_size
    object_id = int.from_bytes(blob[value_ref:value_ref + ref_size], "big")
    target = offsets[object_id]
    if blob[target] != 9:
        raise ValueError("expected a true boolean object")
    changed = bytearray(blob)
    changed[target] = 8
    expected = {**options, "ShowTabView": False}
    if plistlib.loads(changed) != expected:
        raise ValueError("tab bar flag shares another window preference")
    result = bytearray(data)
    result[start:start + len(blob)] = changed
    return bytes(result)


def check_window(data):
    _, _, options = window_record(data)
    for key in ("ShowTabView", "ShowToolbar", "ShowStatusBar", "ShowSidebar"):
        if options.get(key) is not False:
            raise ValueError(f"installer window must hide {key}")
    if not options.get("WindowBounds", "").endswith("{720, 512}}"):
        raise ValueError("installer window must have a 720 x 480-point canvas plus title bar")


def check_layout(data):
    check_window(data)
    _, blob = blob_record(data, ".", b"icvp")
    options = plistlib.loads(blob)
    expected = {"iconSize": 96, "textSize": 12, "arrangeBy": "none", "backgroundType": 2,
                "labelOnBottom": True, "showIconPreview": False, "showItemInfo": False}
    for key, value in expected.items():
        if options.get(key) != value:
            raise ValueError(f"unexpected Finder icon option: {key}")
    if not options.get("backgroundImageAlias"):
        raise ValueError("missing Finder background reference")
    for name, position in {"GOAT.app": (215, 235), "Applications": (505, 235),
                           "CLI Tools": (520, 401), "Licence": (630, 401)}.items():
        _, blob = blob_record(data, name, b"Iloc")
        if len(blob) != 16 or struct.unpack_from(">II", blob) != position:
            actual = struct.unpack_from(">II", blob) if len(blob) >= 8 else None
            raise ValueError(f"unexpected Finder position: {name}: {actual}, expected {position}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("store", type=Path)
    parser.add_argument("--hide-tab-bar", action="store_true")
    args = parser.parse_args()
    data = args.store.read_bytes()
    if args.hide_tab_bar:
        data = hide_tab_bar(data)
    check_layout(data)
    if args.hide_tab_bar:
        args.store.write_bytes(data)
    print("Finder installer window verified")


if __name__ == "__main__":
    main()
