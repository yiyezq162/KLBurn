#!/usr/bin/env python3
"""Validate declarative branding and emit shell-quoted build constants."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import unicodedata


def load_brand(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    fields = {"schema", "display_name", "console_name", "report_title",
              "mem_report_title", "tagline", "custom", "logo", "logo_sha256"}
    if (not isinstance(data, dict) or set(data) != fields
            or type(data["schema"]) is not int or data["schema"] != 1
            or type(data["custom"]) is not bool):
        raise ValueError("品牌配置字段或版本无效")
    for key in fields - {"schema", "custom"}:
        value = data[key]
        if not isinstance(value, str) or len(value) > 120:
            raise ValueError("品牌字段必须为不超过 120 字符的文本：" + key)
        if any(unicodedata.category(c).startswith("C") for c in value):
            raise ValueError("品牌字段不能包含控制字符：" + key)
        if key not in ("logo", "logo_sha256") and not value.strip():
            raise ValueError("品牌字段不能为空：" + key)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}", data["console_name"]):
        raise ValueError("控制台名称须为 1–40 位 ASCII 字母、数字、空格或 ._-，首位须字母或数字")
    if not re.fullmatch(r"[A-Za-z0-9 .,:()/_-]{1,70}", data["tagline"]):
        raise ValueError("控制台说明须为安全的 ASCII 文本（最多 70 字符）")
    if data["logo"] not in ("", "custom-logo.png"):
        raise ValueError("logo 只能为空或 custom-logo.png；不接受任意路径")
    if data["logo"]:
        if not re.fullmatch(r"[a-f0-9]{64}", data["logo_sha256"]):
            raise ValueError("自定义 logo 必须记录 SHA256")
    elif data["logo_sha256"]:
        raise ValueError("无 logo 时 logo_sha256 必须为空")
    return data


def constants(data, edition):
    """All strings remain data, including quotes, $, backticks and HTML."""
    canonical = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return {
        "COMPANY_NAME": data["display_name"] + ("（定制构建）" if data["custom"] else ""),
        "REPORT_TITLE": data["mem_report_title" if edition == "mem" else "report_title"],
        "PRODUCT_NAME": data["console_name"] + ("-MEM" if edition == "mem" else ""),
        "BRAND_TAGLINE": data["tagline"],
        "COMPANY_LOGO_FILE": data["logo"],
        "BRAND_CUSTOM": "1" if data["custom"] else "0",
        "BRAND_SHA256": hashlib.sha256(canonical.encode()).hexdigest(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path(__file__).with_name("branding.json"))
    parser.add_argument("--edition", choices=("full", "mem"), required=True)
    args = parser.parse_args()
    try:
        data = load_brand(args.config)
        if data["logo"]:
            logo = args.config.parent / data["logo"]
            if logo.is_symlink() or hashlib.sha256(logo.read_bytes()).hexdigest() != data["logo_sha256"]:
                raise ValueError("logo 文件与已追溯的 SHA256 不一致")
        # Overrides would not be committed or hashed: fail visibly instead.
        if any(k in os.environ for k in ("KLBURN_COMPANY_NAME", "KLBURN_PRODUCT_NAME", "KLBURN_REPORT_TITLE", "KLBURN_LOGO_FILE")):
            raise ValueError("请在独立工作区修改并提交 branding.json；不再接受未追溯的品牌环境变量")
        for key, value in constants(data, args.edition).items():
            print(key + "=" + shlex.quote(value))
    except (ValueError, OSError) as exc:
        parser.exit(2, "品牌配置无效：" + str(exc) + "\n")


if __name__ == "__main__":
    main()
