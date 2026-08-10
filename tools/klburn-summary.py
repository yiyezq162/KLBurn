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
# 测试范围（meta.json 的 scope）。和 lib/core.sh 的 scope_tag()、
# report/generate_report.py 的 SCOPE_CN 是同一套键。
SCOPE_CN = {
    "full": "全量老化测试",
    "cpu":  "CPU 专项测试",
    "mem":  "内存专项测试",
    "gpu":  "显卡专项测试",
    "disk": "硬盘专项测试",
    "info": "仅导出硬件信息",
}

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

    # ⚠️⚠️ **单项专测的 PASS 绝不能和全量的 PASS 挤在同一个词里。**
    #
    # 一台只跑了 CPU 专测的机器，results.jsonl 里当然没有 FAIL —— 上面那段
    # 会老老实实给它一个 PASS。可是它的内存、硬盘、显卡**根本没测过**。
    # 汇总表是拿来做"这一批能不能出货"这个决定的：一列全是 PASS 的表格里
    # 混进这么一台，没有任何人会发现。
    #
    # 所以非全量的那几轮在结论列里自带范围后缀（PASS(CPU)），
    # 而且下面还单独有一列写明范围。**排序/筛选时它和 PASS 不是同一个值**，
    # 这正是要的效果。
    scope = str(meta.get("scope") or "full").lower()
    if scope not in SCOPE_CN:
        scope = "full"
    if overall == "PASS" and scope != "full":
        overall = "PASS(%s)" % scope.upper()

    row = {
        "目录": os.path.basename(run_dir),
        "整机结论": overall,
        "测试范围": SCOPE_CN[scope],
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
    cols = (["目录", "整机结论", "测试范围", "整机序列号", "版本", "档位",
             "开始时间", "实际耗时秒",
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
    # 非全量的那几台单独数出来。屏幕上这一行是**唯一**会被人快速扫一眼的输出，
    # 「这批里有几台其实只测了一个部件」必须出现在这里，而不是等人去翻 CSV。
    n_part = len([r for r in rows if str(r["整机结论"]).startswith("PASS(")])
    print("%d 台，其中 FAIL %d 台、无效 %d 台、非全量 %d 台 -> %s"
          % (len(rows), n_fail, n_inv, n_part, out))
    for r in rows:
        if r["整机结论"] != "PASS":
            print("  %-12s %-16s %s  %s" % (r["整机结论"], r["测试范围"], r["目录"],
                                            r["FAIL 项"] or r["WARN 项"] or ""))
    if n_part:
        print("  ⚠ 上面带 PASS(...) 的是**单项专测**：范围以外的部件这一轮没测过，")
        print("    不能和全量测试的 PASS 一起算作「已通过出厂测试」。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
