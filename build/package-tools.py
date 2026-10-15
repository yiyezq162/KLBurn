#!/usr/bin/env python3
"""Produce deterministic, allowlisted tool ZIPs from a clean committed tree. Never upload."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile


LAUNCHERS = {"Windows": "KLBurn-Windows.cmd", "macOS": "KLBurn-macOS.command", "Linux": "KLBurn-Linux.sh"}
COMMON = {
    "klburn-builder.py": "tools/customize/klburn-builder.py",
    "dependencies.json": "tools/customize/dependencies.json",
    "使用说明.md": "docs/custom-build.md",
    "LICENSE": "LICENSE",
}


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def package(root, destination):
    root = Path(root).resolve(strict=True)
    destination = Path(destination).resolve()
    if git(root, "status", "--porcelain").strip():
        raise ValueError("工具发布必须使用干净且已提交的源码")
    commit = git(root, "rev-parse", "HEAD").decode().strip()
    config = git(root, "show", "HEAD:build/config.sh").decode()
    match = re.search(r'^KLBURN_VERSION="([0-9]+\.[0-9]+\.[0-9]+(?:-custom\.[a-f0-9]+)?)"$', config, re.M)
    if not match:
        raise ValueError("源码版本格式无效")
    version = match[1]
    filenames = [f"KLBurn-Builder-{platform}-{version}.zip" for platform in LAUNCHERS]
    reserved = filenames + [name + ".sha256" for name in filenames] + ["tools-manifest.json"]
    if any((destination / name).exists() for name in reserved):
        raise ValueError("输出已存在；不覆盖已生成的工具发布资产")
    # Read exact committed blobs, not vendor, working-tree symlinks or customer inputs.
    payloads = {}
    for platform, launcher in LAUNCHERS.items():
        members = dict(COMMON)
        members[launcher] = "tools/customize/" + launcher
        payloads[platform] = {name: git(root, "show", "HEAD:" + path) for name, path in members.items()}
    destination.mkdir(parents=True, exist_ok=True)
    artifacts = {}
    for platform, name in zip(LAUNCHERS, filenames):
        members = payloads[platform]
        provenance = {"schema": 1, "version": version, "commit": commit, "platform": platform,
                      "publication": "manual", "bundled_third_party_binaries": False,
                      "files": {key: hashlib.sha256(value).hexdigest() for key, value in members.items()}}
        members["SOURCE.json"] = (json.dumps(provenance, ensure_ascii=False, indent=2) + "\n").encode()
        path = destination / name
        with zipfile.ZipFile(path, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for member in sorted(members):
                info = zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                mode = 0o100755 if member == LAUNCHERS[platform] and platform != "Windows" else 0o100644
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(info, members[member], compresslevel=9)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        with (destination / (name + ".sha256")).open("x", encoding="ascii") as stream:
            stream.write(digest + "  " + name + "\n")
        artifacts[platform] = {"file": name, "bytes": path.stat().st_size, "sha256": digest}
    receipt = {"schema": 1, "version": version, "commit": commit, "artifacts": artifacts}
    with (destination / "tools-manifest.json").open("x", encoding="utf-8") as stream:
        json.dump(receipt, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(package(args.source, args.output), ensure_ascii=False, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, "工具打包停止：" + str(exc) + "\n")


if __name__ == "__main__":
    main()
