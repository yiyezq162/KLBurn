#!/usr/bin/env python3
"""Preserve selected upstream notices byte-for-byte; not redistribution clearance."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def copy_boot_notices(source, destination, iso_sha256):
    """Bind selected boot notices to the pinned input ISO, not license clearance."""
    source = Path(source)
    manifest = source / "boot-components.json"
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size > 65536:
        raise ValueError("启动许可索引缺失或不安全")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    if (not isinstance(data, dict) or data.get("schema") != 1
            or not isinstance(data.get("source_iso"), dict)
            or not re.fullmatch(r"[0-9a-f]{64}", iso_sha256)
            or data.get("source_iso", {}).get("sha256") != iso_sha256):
        raise ValueError("启动许可索引与构建源 ISO 不一致")
    entries = data.get("notices", [])
    required = {"casper", "cifs-utils", "grub2", "grub2-signed", "shim-signed", "shim"}
    if (not isinstance(entries, list) or len(entries) != len(required)
            or any(not isinstance(item, dict) for item in entries)
            or any(not isinstance(item.get("source_package"), str) for item in entries)
            or {item.get("source_package") for item in entries} != required):
        raise ValueError("启动组件许可集合不完整")
    names = []
    for item in entries:
        name = item.get("file", "")
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name)
                or ".." in name or name in names):
            raise ValueError("启动许可文件名不安全或重复")
        path = source / name
        if path.is_symlink() or not path.is_file() or not 20 <= path.stat().st_size <= 4 * 1024 * 1024:
            raise ValueError("启动许可原文缺失或不安全：" + name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != item.get("sha256"):
            raise ValueError("启动许可原文摘要不符：" + name)
        names.append(name)
    return copy_notices(source, destination, ["boot-components.json", *names])


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
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--required", nargs="+")
    mode.add_argument("--boot-iso-sha256")
    parser.add_argument("--optional", nargs="*", default=[])
    args = parser.parse_args()
    try:
        if args.boot_iso_sha256:
            count = copy_boot_notices(args.source, args.destination, args.boot_iso_sha256)
        else:
            count = copy_notices(args.source, args.destination, args.required, args.optional)
    except (ValueError, OSError) as exc:
        parser.exit(1, "许可打包失败：" + str(exc) + "\n")
    print(f"已保留 {count} 份上游许可原文；仍须核对其他组件许可与源码义务")
