#!/usr/bin/env python3
"""Preserve selected upstream notices byte-for-byte; not redistribution clearance."""
import argparse
from pathlib import Path
import re


def copy_notices(source, destination, required, optional=()):
    source = Path(source).resolve(strict=True)
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError("许可输出目录不能是符号链接")
    selected = []
    for name in (*required, *optional):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) or ".." in name:
            raise ValueError("许可文件名必须是单个安全文件名")
        path = source / name
        if not path.exists() and name in optional:
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError("缺少上游许可原文或文件是链接：" + name)
        if not 20 <= path.stat().st_size <= 4 * 1024 * 1024:
            raise ValueError("许可原文大小异常：" + name)
        data = path.read_bytes()
        text = data.decode("utf-8")
        # Upstream notice collections can contain literal form-feed page breaks.
        # Preserve these bytes; reject binary NUL and terminal control sequences.
        if any(ord(c) < 32 and c not in "\n\r\t\f" for c in text):
            raise ValueError("许可文件不是纯文本：" + name)
        target = destination / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError("许可目标不能是链接或特殊文件：" + name)
        if target.resolve() == path:
            raise ValueError("许可来源与输出不能相同")
        selected.append((target, data))
    destination.mkdir(parents=True, exist_ok=True)
    for target, data in selected:
        target.write_bytes(data)
    return len(selected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--required", nargs="+", required=True)
    parser.add_argument("--optional", nargs="*", default=[])
    args = parser.parse_args()
    try:
        count = copy_notices(args.source, args.destination, args.required, args.optional)
    except (ValueError, OSError) as exc:
        parser.exit(1, "许可打包失败：" + str(exc) + "\n")
    print(f"已保留 {count} 份上游许可原文；仍须核对其他组件许可与源码义务")
