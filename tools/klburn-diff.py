#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""两台机器逐项对比：同一批次里，这台和那台差在哪。

    python3 tools/klburn-diff.py <run-dir A> <run-dir B>

⚠️⚠️ **这是"跨机器一致性"唯一诚实的做法，请不要把它变成别的东西。**

我们始终拒绝"预期值文件"（1.9.0 那一整套阈值就是这么删掉的）：这张盘插上就跑、
无人值守，现场没有人、也没有地方去填"这台机器该是什么样"，凭空写一个值进来
等于我们替客户定了一个他没定过的标准。

但"同一批次的机器应当一模一样"是**客观事实**，不需要任何人去定义 ——
参照物是**同批次的另一台真机**，不是我们编的数字。第 37 台少了一根内存、
固件版本落后一版、少认一块盘，这样才查得出来。

所以这个工具：
  - 只**报差异**，不判合格，也不产出任何 PASS/FAIL
  - 不碰性能数字（同型号机器之间跑分本来就有正常波动，拿它比只会制造噪音）
  - 输出是给人看的，不进任何一份报告

⚠️ 仓库侧工具，不进盘。
"""
import argparse
import json
import os
import re
import sys

# 参与对比的字段。挑的是"同批次应当一模一样"的那些：数量、型号、固件版本。
# **故意不含**序列号（本来就每台不同）、温度功耗（环境相关）、
# 任何性能数字（正常波动）、任何时间戳。


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


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def dmi_values(run_dir, typename, field):
    """dmidecode.txt 里某一类块的某个字段，逐块一个值。"""
    txt = read_text(os.path.join(run_dir, "raw", "dmidecode.txt"))
    out, cur, expect = [], None, False
    for raw in txt.splitlines():
        if raw.startswith("Handle "):
            cur, expect = None, True
            continue
        if expect:
            cur = raw.strip() or None
            expect = False
            continue
        if cur == typename and raw.startswith(("\t", "    ")) and ":" in raw:
            k, _, v = raw.strip().partition(":")
            if k.strip() == field:
                out.append(v.strip())
    return out


def profile(run_dir):
    """一台机器"应当和同批次一致"的那些事实。"""
    meta = read_json(os.path.join(run_dir, "meta.json"))
    p = {}

    p["KLBurn 版本"] = meta.get("klburn_version") or ""
    p["BIOS 版本"] = "；".join(dmi_values(run_dir, "BIOS Information", "Version"))
    p["整机型号"] = "；".join(dmi_values(run_dir, "System Information", "Product Name"))
    p["主板型号"] = "；".join(dmi_values(run_dir, "Base Board Information", "Product Name"))

    cpus = [v for v in dmi_values(run_dir, "Processor Information", "Version") if v]
    p["CPU 型号"] = "；".join(sorted(set(cpus)))
    p["CPU 颗数"] = str(len(cpus))

    sizes = [v for v in dmi_values(run_dir, "Memory Device", "Size")
             if v and "No Module" not in v]
    pns = [v for v in dmi_values(run_dir, "Memory Device", "Part Number") if v]
    p["内存条数"] = str(len(sizes))
    p["内存容量组合"] = "；".join(sorted(sizes))
    p["内存颗粒型号"] = "；".join(sorted(set(pns)))

    # 判定的**状态**（不是文案）：同批次机器该是同一套结论
    for r in read_jsonl(os.path.join(run_dir, "results.jsonl")):
        p["判定 " + str(r.get("id"))] = str(r.get("status"))

    # 固件版本：网卡 / 硬盘 / BMC。这三样最常出现"同批次不一致"
    for line in read_text(os.path.join(run_dir, "raw", "nic-summary.txt")).splitlines():
        m = re.match(r"^\s*(\S+)\s.*firmware-version:\s*(.+?)\s*$", line)
        if m:
            p["网卡固件 " + m.group(1)] = m.group(2)
    mc = read_text(os.path.join(run_dir, "raw", "ipmi-mcinfo.txt"))
    m = re.search(r"^\s*Firmware Revision\s*:\s*(.+)$", mc, re.M)
    if m:
        p["BMC 固件"] = m.group(1).strip()

    d = os.path.join(run_dir, "raw", "smart-pre")
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".norm.json"):
                continue
            j = read_json(os.path.join(d, fn))
            key = fn[:-len(".norm.json")]
            if j.get("model"):
                p["硬盘型号 " + key] = str(j.get("model"))
            if j.get("firmware"):
                p["硬盘固件 " + key] = str(j.get("firmware"))
    return p


def main():
    ap = argparse.ArgumentParser(description="两份 run-dir 逐项对比（同批次一致性）")
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--all", action="store_true", help="连相同的项也一起列出来")
    args = ap.parse_args()

    for d in (args.a, args.b):
        if not os.path.isfile(os.path.join(d, "meta.json")):
            print("不像是一个 run-dir（里面没有 meta.json）：%s" % d, file=sys.stderr)
            return 1

    pa, pb = profile(args.a), profile(args.b)
    keys = sorted(set(pa) | set(pb))

    same, diff = 0, []
    for k in keys:
        va, vb = pa.get(k, "（本机没有这一项）"), pb.get(k, "（本机没有这一项）")
        if va == vb:
            same += 1
            if args.all:
                print("  =  %-28s %s" % (k, va))
        else:
            diff.append((k, va, vb))

    print("A = %s" % os.path.basename(os.path.abspath(args.a)))
    print("B = %s" % os.path.basename(os.path.abspath(args.b)))
    print()
    if not diff:
        print("两台机器在参与对比的 %d 项上完全一致。" % same)
        return 0

    print("%d 项一致，%d 项不同：" % (same, len(diff)))
    for k, va, vb in diff:
        print("  ≠ %s" % k)
        print("      A: %s" % va)
        print("      B: %s" % vb)
    print()
    print("⚠️ 不同 ≠ 有问题。这个工具只报差异，不做任何判定 ——")
    print("   哪些差异可以接受，是拿订单的人说了算的。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
