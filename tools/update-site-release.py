#!/usr/bin/env python3
"""Build static public download data from local hashes AND server release metadata. No upload."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import quote

BASE = "https://github.com/yiyezq162/KLBurn/releases/"
KINDS = {"full", "mem", "Windows", "macOS", "Linux"}


def validate(data):
    if (not isinstance(data, dict) or data.get("schema") != 1
            or data.get("publication_ready") is not True
            or not isinstance(data.get("releases"), list) or not data["releases"]):
        raise ValueError("公开元数据尚未准备好，禁止发布网站")
    seen = set()
    for release in data["releases"]:
        if not isinstance(release, dict):
            raise ValueError("版本数据必须是对象")
        version = release.get("version", "")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or version in seen:
            raise ValueError("版本格式无效或重复")
        seen.add(version)
        if type(release.get("prerelease")) is not bool or not re.fullmatch(r"[a-f0-9]{40}", release.get("commit", "")):
            raise ValueError("版本类型或源码 commit 无效")
        datetime.date.fromisoformat(release["date"])
        if release.get("url") != BASE + "tag/v" + version or set(release.get("assets", {})) != KINDS:
            raise ValueError("发布链接或双版/三平台资产集合无效")
        for kind, item in release["assets"].items():
            name = item.get("file", "")
            if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name in (".", ".."):
                raise ValueError("资产文件名不安全")
            if kind in ("full", "mem"):
                prefix = "KLBurn-" if kind == "full" else "KLBurn-MEM-"
                valid_name = re.fullmatch(re.escape(prefix + version) + r"-[0-9]{8}\.iso", name)
            else:
                valid_name = name == "KLBurn-Builder-" + kind + "-" + version + ".zip"
            if not valid_name:
                raise ValueError("资产类型与版本文件名不匹配")
            if (item.get("url") != BASE + "download/v" + version + "/" + quote(name)
                    or type(item.get("bytes")) is not int or item["bytes"] <= 0
                    or not re.fullmatch(r"[a-f0-9]{64}", item.get("sha256", ""))):
                raise ValueError("资产大小、哈希或官方链接无效")


def export_release(iso_receipt, tool_receipt, remote, iso_dir, tool_dir):
    version, commit = iso_receipt["version"], iso_receipt["commit"]
    if tool_receipt.get("version") != version or tool_receipt.get("commit") != commit:
        raise ValueError("ISO 与工具必须来自同一版本、同一 commit")
    if remote.get("tag_name") != "v" + version or remote.get("draft") is not False:
        raise ValueError("GitHub Release tag 不匹配或仍是草稿")
    date = datetime.datetime.fromisoformat(remote["published_at"].replace("Z", "+00:00")).date().isoformat()
    release = {"version": version, "commit": commit, "date": date,
               "prerelease": remote["prerelease"], "url": remote["html_url"], "assets": {}}
    by_name = {}
    for asset in remote["assets"]:
        if asset["name"] in by_name:
            raise ValueError("远端发布资产重名")
        by_name[asset["name"]] = asset
    for receipt, kinds, folder in ((iso_receipt, ("full", "mem"), iso_dir),
                                   (tool_receipt, ("Windows", "macOS", "Linux"), tool_dir)):
        for kind in kinds:
            item = receipt["artifacts"][kind]
            name = item["file"]
            if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name in (".", ".."):
                raise ValueError("收据中的文件名不安全")
            path = Path(folder) / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("本地产物缺失或为链接")
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != item["sha256"] or path.stat().st_size != item["bytes"]:
                raise ValueError("本地产物与收据不一致")
            server = by_name.get(name, {})
            if (server.get("state") != "uploaded" or server.get("size") != item["bytes"]
                    or server.get("digest") != "sha256:" + item["sha256"]):
                raise ValueError("远端资产缺失、未完成上传或哈希/大小不一致")
            # Explicit allowlist: never copy internal manifests, logs or operational fields.
            release["assets"][kind] = {"file": name, "bytes": item["bytes"],
                                       "sha256": item["sha256"], "url": server["browser_download_url"]}
    validate({"schema": 1, "publication_ready": True, "releases": [release]})
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", type=Path)
    parser.add_argument("--iso-receipt", type=Path)
    parser.add_argument("--tools-receipt", type=Path)
    parser.add_argument("--release-json", type=Path, help="gh api repos/yiyezq162/KLBurn/releases/tags/vVERSION 输出")
    parser.add_argument("--iso-dir", type=Path)
    parser.add_argument("--tools-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--previous", type=Path, help="保留已验证的历史索引，不覆盖同版本记录")
    args = parser.parse_args()
    try:
        if args.check:
            validate(json.loads(args.check.read_text(encoding="utf-8")))
            print("静态公开版本元数据格式检查通过；不替代发布授权或在线访问验收")
            return
        if not all((args.iso_receipt, args.tools_receipt, args.release_json, args.iso_dir, args.tools_dir, args.output)):
            parser.error("必须提供两份收据、远端 Release JSON、两个产物目录与全新输出文件")
        receipts = [json.loads(p.read_text(encoding="utf-8")) for p in (args.iso_receipt, args.tools_receipt, args.release_json)]
        release = export_release(*receipts, args.iso_dir, args.tools_dir)
        history = []
        if args.previous:
            previous = json.loads(args.previous.read_text(encoding="utf-8"))
            if previous != {"schema": 1, "publication_ready": False, "releases": []}:
                validate(previous)
                history = previous["releases"]
            if any(item["version"] == release["version"] for item in history):
                raise ValueError("历史索引已有此版本，不能覆盖已有记录")
        catalog = {"schema": 1, "publication_ready": True, "releases": [release] + history}
        validate(catalog)
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(catalog, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        print("已生成可审阅的公开元数据；未上传、未修改网站、未改变仓库可见性")
    except (ValueError, OSError, KeyError, TypeError) as exc:
        parser.exit(1, "元数据导出停止：" + str(exc) + "\n")


if __name__ == "__main__":
    main()
