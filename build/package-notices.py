#!/usr/bin/env python3
"""Restore exact base-package notices and reject missing installed-package notices.

This checks copyright text presence, not license applicability or redistribution rights.
Symlinks are resolved within the target root, never against the build host.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat


def normalize(parts):
    result = []
    for part in parts:
        if part in ("", "."):
            continue
        if part == "..":
            if not result:
                raise ValueError("链接越过目标根目录")
            result.pop()
        else:
            result.append(part)
    return result


def rooted(root, name):
    """Resolve even absolute links using chroot semantics, with a link limit."""
    pending = normalize(name.split("/"))
    done = []
    links = 0
    while pending:
        done.append(pending.pop(0))
        path = root.joinpath(*done)
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            links += 1
            if links > 40:
                raise ValueError("版权路径存在循环链接")
            target = str(path.readlink())
            prefix = [] if target.startswith("/") else done[:-1]
            pending = normalize(prefix + target.split("/") + pending)
            done = []
        elif pending and not stat.S_ISDIR(mode):
            raise ValueError("版权路径父项不是目录")
    return root.joinpath(*done)


def notice(root, package):
    path = rooted(root, "usr/share/doc/" + package + "/copyright")
    relative = path.relative_to(root).as_posix()
    if not relative.startswith(("usr/share/doc/", "usr/share/common-licenses/")):
        raise ValueError("版权文本链接不在允许的文档目录：" + package)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or not 1 <= info.st_size <= 4 * 1024**2:
        raise ValueError("版权文本为空、过大或不是普通文件：" + package)
    data = path.read_bytes()
    if not data.strip() or b"\x00" in data:
        raise ValueError("版权文本为空或含二进制数据：" + package)
    return {"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def installed(root):
    path = rooted(root, "var/lib/dpkg/status")
    if path.relative_to(root).as_posix() != "var/lib/dpkg/status" or not path.is_file():
        raise ValueError("dpkg 状态文件不是目标根目录内的普通文件")
    packages = {}
    for paragraph in path.read_text(encoding="utf-8").split("\n\n"):
        fields = {}
        key = None
        for line in paragraph.splitlines():
            if line.startswith((" ", "\t")) and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, _, value = line.partition(":")
                fields[key] = value.strip()
        if fields.get("Status") != "install ok installed":
            continue
        name = fields.get("Package", "")
        if not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", name) or name in packages or not fields.get("Version"):
            raise ValueError("dpkg 包名、版本缺失或重复")
        packages[name] = fields["Version"]
    if not packages:
        raise ValueError("没有已安装包，不能将空清单判为通过")
    return packages


def catalogue(source, iso_sha256):
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError("基础包版权集合目录不安全")
    index_path = source / "base-packages.json"
    if index_path.is_symlink() or not index_path.is_file() or index_path.stat().st_size > 65536:
        raise ValueError("基础包版权索引缺失或不安全")
    data = json.loads(index_path.read_text(encoding="utf-8"))
    if (not isinstance(data, dict) or data.get("schema") != 1
            or not re.fullmatch(r"[0-9a-f]{64}", iso_sha256)
            or not isinstance(data.get("source_iso"), dict)
            or data["source_iso"].get("sha256") != iso_sha256):
        raise ValueError("基础包版权集合与源 ISO 摘要不一致")
    rows = data.get("notices")
    if not isinstance(rows, list) or not 1 <= len(rows) <= 64:
        raise ValueError("基础包版权索引为空或过大")
    result = {}
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("基础包版权条目格式错误")
        name = row.get("binary_package", "")
        if (not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", name)
                or name in result or row.get("file") != name + ".COPYRIGHT"
                or not isinstance(row.get("binary_version"), str) or not row["binary_version"]):
            raise ValueError("基础包版权名称、版本或文件名不合法")
        path = source / row["file"]
        if path.is_symlink() or not path.is_file() or not 20 <= path.stat().st_size <= 4 * 1024**2:
            raise ValueError("基础包版权原文缺失或不安全：" + name)
        content = path.read_bytes()
        if hashlib.sha256(content).hexdigest() != row.get("sha256") or b"\x00" in content:
            raise ValueError("基础包版权原文摘要不符：" + name)
        result[name] = (row, content)
    return result


def plain_directory(root, relative, create=False):
    """Writes never traverse any existing directory symlink."""
    current = root
    for part in relative.split("/"):
        current /= part
        if current.is_symlink() or (current.exists() and not current.is_dir()):
            raise ValueError("版权写入目录存在链接或特殊文件")
        if create:
            current.mkdir(exist_ok=True)
    return current


def restore(root, source, iso_sha256):
    root = Path(root)
    if root.is_symlink() or not root.is_dir() or root.resolve() == Path("/"):
        raise ValueError("需要独立、非宿主根目录的构建根文件系统")
    root = root.resolve()
    texts = catalogue(source, iso_sha256)
    packages = installed(root)
    repairs = []
    # Validate every missing package and every write boundary before writing.
    for name, version in sorted(packages.items()):
        try:
            notice(root, name)
        except FileNotFoundError:
            if name not in texts or texts[name][0]["binary_version"] != version:
                raise ValueError("缺少适用精确版本的版权原文：" + name)
            plain_directory(root, "usr/share/doc/" + name)
            target = root / "usr/share/doc" / name / "copyright"
            if target.exists() and not target.is_symlink():
                raise ValueError("不能覆盖现有版权文本：" + name)
            repairs.append(name)
    saved = plain_directory(root, "usr/share/doc/klburn/licenses/base-packages")
    for filename in ["base-packages.json", *[row[0]["file"] for row in texts.values()], "presence.json"]:
        target = saved / filename
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError("版权留存目标不安全")
    for name in repairs:
        directory = plain_directory(root, "usr/share/doc/" + name, create=True)
        target = directory / "copyright"
        if target.is_symlink():
            target.unlink()  # Only the already-validated broken leaf link, not notice bytes.
        target.write_bytes(texts[name][1])
        target.chmod(0o644)
    rows = [{"package": name, "version": version, **notice(root, name)} for name, version in sorted(packages.items())]
    saved = plain_directory(root, "usr/share/doc/klburn/licenses/base-packages", create=True)
    for filename in ["base-packages.json", *[row[0]["file"] for row in texts.values()]]:
        (saved / filename).write_bytes((Path(source) / filename).read_bytes())
        (saved / filename).chmod(0o644)
    receipt = {"schema": 1, "source_iso_sha256": iso_sha256, "installed_packages": len(rows),
               "readable_notices": len(rows), "restored_packages": repairs, "packages": rows,
               "scope": "Installed dpkg copyright presence only; not redistribution rights, all embedded notices or corresponding-source compliance"}
    (saved / "presence.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (saved / "presence.json").chmod(0o644)
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("source", type=Path)
    parser.add_argument("--boot-iso-sha256", required=True)
    args = parser.parse_args()
    try:
        receipt = restore(args.rootfs, args.source, args.boot_iso_sha256)
    except (OSError, ValueError) as exc:
        parser.exit(1, "包版权保留检查失败：" + str(exc) + "\n")
    print("已核对 %d 个已安装包版权文本，恢复 %d 个标准路径；不构成许可放行" %
          (receipt["readable_notices"], len(receipt["restored_packages"])))
