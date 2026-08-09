#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一批机器一张表：走一遍 out/，每台机器出一行 CSV。

    python3 tools/klburn-summary.py <out 目录> [-o 汇总.csv]

为什么要有它：一次出厂跑一百台，现在的产物是一百个文件夹、两百份 HTML。
"这批里有几台 FAIL""哪几台报了内存混插""固件版本有没有不一致的"——
这些问题现在只能一个个点开报告去看。

**它只是把 results.jsonl 摊平，不做任何新判定。**
整机结论仍然只看有没有 FAIL，和盘里、和报告里同一个口径（architecture.md §11-25）。

⚠️ 这是**仓库侧**的工具，不进盘：现场不需要它，而且它读的是拷回来之后的
   一整批 run-dir。盘里那个 factory-test.sh 一次只认识一台机器。
"""
import argparse
import csv
import json
import os
import sys

# 汇总表里带上哪几条判定的状态。挑的是"出了问题最需要一眼看到是哪台"的那些，
# 不是全部 —— 全列出来就是四十列，翻起来还不如点开报告。
KEY_CHECKS = [
    ("collect_system",     "硬件采集"),
    ("check_mem_cap",      "内存容量"),
    ("check_dimm_uniform", "内存一致性"),
    ("verify_ecc",         "内存ECC"),
    ("verify_smart",       "SMART复查"),
    ("verify_disk_selftest", "硬盘自检"),
    ("verify_bmc_sensors", "部件传感器"),
    ("check_nic_selftest", "网卡自检"),
    ("stress_cpu",         "CPU压测"),
    ("stress_mem",         "内存压测"),
    ("stress_gpu",         "GPU压测"),
    ("verify_dmesg",       "内核日志"),
    ("verify_sel",         "BMC事件"),
]


def read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        pass
    return out


def read_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def find_run_dirs(root):
    """一个 run-dir 的判据只有一个：里面有 meta.json。

    不按目录名的形状去猜 —— 目录名是 `日期_时间_CPU_内存` 加上人手工补的备注，
    形状随时会变（test_out 里就有一堆带中文备注的）。
    """
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        if "meta.json" in filenames:
            hits.append(dirpath)
            dirnames[:] = []          # run-dir 里面不会再套 run-dir
    return sorted(hits)


def summarize(run_dir):
    meta = read_json(os.path.join(run_dir, "meta.json"))
    results = read_jsonl(os.path.join(run_dir, "results.jsonl"))
    by_id = {r.get("id"): r for r in results}
    st = [r.get("status") for r in results]

    # ⚠️ 和盘里、和两份报告**同一个口径**：只看有没有 FAIL；
    #    一条判定都没有不算通过（那说明这轮压根没跑成）。
    if not st:
        overall = "INVALID"
    elif "FAIL" in st:
        overall = "FAIL"
    else:
        overall = "PASS"

    row = {
        "目录": os.path.basename(run_dir),
        "整机结论": overall,
        "整机序列号": meta.get("serial") or "",
        "版本": meta.get("klburn_version") or "",
        "档位": meta.get("profile") or "",
        "开始时间": meta.get("start_time") or "",
        "实际耗时秒": meta.get("elapsed_secs") or "",
        "PASS": st.count("PASS"),
        "FAIL": st.count("FAIL"),
        "WARN": st.count("WARN"),
        "SKIP": st.count("SKIP"),
    }
    for cid, label in KEY_CHECKS:
        row[label] = (by_id.get(cid) or {}).get("status", "")
    # FAIL / WARN 的项目名单：不带 detail（太长），要细节就点开那台的报告
    row["FAIL 项"] = "、".join(r.get("name", r.get("id", "?"))
                              for r in results if r.get("status") == "FAIL")
    row["WARN 项"] = "、".join(r.get("name", r.get("id", "?"))
                              for r in results if r.get("status") == "WARN")
    return row


def main():
    ap = argparse.ArgumentParser(description="把一批 run-dir 汇总成一张 CSV")
    ap.add_argument("root", help="out/ 目录（或任何装着若干 run-dir 的目录）")
    ap.add_argument("-o", "--out", default=None, help="输出 CSV，默认写到 <root>/summary.csv")
    a = ap.parse_args()

    if not os.path.isdir(a.root):
        print("目录不存在：%s" % a.root, file=sys.stderr)
        return 1

    dirs = find_run_dirs(a.root)
    if not dirs:
        print("在 %s 下没有找到任何 run-dir（判据是里面有 meta.json）" % a.root,
              file=sys.stderr)
        return 1

    rows = [summarize(d) for d in dirs]
    cols = (["目录", "整机结论", "整机序列号", "版本", "档位", "开始时间", "实际耗时秒",
             "PASS", "FAIL", "WARN", "SKIP"]
            + [label for _, label in KEY_CHECKS]
            + ["FAIL 项", "WARN 项"])

    out = a.out or os.path.join(a.root, "summary.csv")
    # utf-8-sig：Windows 上双击用 Excel 打开时不会把中文显示成乱码
    with open(out, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for r in rows:
            w.writerow(r)

    n_fail = len([r for r in rows if r["整机结论"] == "FAIL"])
    n_inv = len([r for r in rows if r["整机结论"] == "INVALID"])
    print("%d 台，其中 FAIL %d 台、无效 %d 台 -> %s" % (len(rows), n_fail, n_inv, out))
    for r in rows:
        if r["整机结论"] != "PASS":
            print("  %-10s %s  %s" % (r["整机结论"], r["目录"],
                                      r["FAIL 项"] or r["WARN 项"] or ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
