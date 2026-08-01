#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KLBurn 内部工程报告生成器

产出 <run-dir>/raw/INTERNAL_<机器名>.html —— **内部留档，不交付**。

和客户报告的分工，改代码前先记牢：

    报告名.html   随机器交付给客户。只回答"这台机器合不合格"，
                  措辞假设读者是采购/运维。通电时间、我们盘里少带哪个工具、
                  git commit 这些一律不出现。规范见 docs/report-policy.md。

    本报告        只给我们自己看。回答的是另外两个问题：
                  「这台机器到底什么成色」和「我们这一轮测得干不干净」。
                  什么都可以写：通电时间、通电次数、SSD 磨损率、异常掉电、
                  逐颗 CPU 温差、盘里有没有 storcli64、源码 commit……

为什么放在 raw/ 里：客户要的是那个和目录同名的 .html，raw/ 整个目录本来就不外发；
文件名再加 INTERNAL_ 前缀，页面顶部再压一条红色横幅 —— 三道保险，防的是手滑。

它是**只读**的：只读 run-dir 里已经落好的数据，不采集、不判定整机结论。
整机结论永远以 results.jsonl 为准，这里只做"人看的时候会想知道"的二次解读。

用法:
    generate_internal.py --run-dir <run-dir> [--out <html>]
"""
import argparse
import csv
import html
import os
import re
import sys
from collections import OrderedDict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# 客户报告生成器里那些纯工具函数直接复用，不重写第二份。
# 注意只借工具，不借它的版式 —— 两份报告的读者完全不同。
from generate_report import (  # noqa: E402
    CSS, Data, E, clean, collapsible, dmi_blocks, fmt_dur, human_bytes,
    kv_block, profile_text, read_json, read_text, svg_line_chart, table,
)

# ============================================================ 评估等级

GOOD, WATCH, RISK, INFO = "good", "watch", "risk", "info"

LEVEL_TEXT = {GOOD: "良好", WATCH: "关注", RISK: "风险", INFO: "记录"}
LEVEL_ORDER = {RISK: 0, WATCH: 1, GOOD: 2, INFO: 3}


def finding(level, area, title, detail="", evidence=""):
    return {"level": level, "area": area, "title": title,
            "detail": detail, "evidence": evidence}


def num(v, default=None):
    """尽量把一个值解释成数字，解释不了给 default。

    SMART/ethtool/nvidia-smi 的字段经常带单位（"24576 MiB"、"1000Mb/s"），
    统一在这里剥掉，免得每个判定都写一遍。
    """
    if v is None:
        return default
    if isinstance(v, (int, float)):
        return v
    m = re.search(r"-?\d+(?:\.\d+)?", str(v))
    if not m:
        return default
    try:
        f = float(m.group(0))
    except ValueError:
        return default
    return int(f) if f == int(f) else f


# ============================================================ 数据层

class Internal(Data):
    """在客户报告那份 Data 的基础上，补上"只有内部才看"的读取。"""

    # ---------- 采集到 SMART 的盘（以真实落盘的文件为准，不猜）----------
    def smart_devices(self):
        d = self.rawpath("smart-pre")
        if not os.path.isdir(d):
            return []
        names = [f[:-len(".norm.json")] for f in os.listdir(d)
                 if f.endswith(".norm.json")]
        return sorted(names)

    def smart_pair(self, base):
        return (read_json(self.rawpath("smart-pre", "%s.norm.json" % base), {}),
                read_json(self.rawpath("smart-post", "%s.norm.json" % base), {}))

    def lsblk_by_name(self):
        out = {}
        j = read_json(self.rawpath("lsblk.json"), {"blockdevices": []})
        for d in j.get("blockdevices", []):
            if d.get("name"):
                out[d["name"]] = d
        return out

    # ---------- 逐颗 CPU 封装温度（0.9.0 起才有这一列）----------
    def cpu_pkg_series(self):
        """-> {0: [温度...], 1: [...]}；老 run-dir 没这列就返回 {}"""
        path = os.path.join(self.run_dir, "sys_metrics.csv")
        out = {}
        if not os.path.exists(path):
            return out
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                raw = (row.get("cpu_pkg_temps") or "").strip()
                if not raw:
                    continue
                for i, part in enumerate(raw.split(";")):
                    v = num(part)
                    if v is None:
                        continue
                    out.setdefault(i, []).append(float(v))
        return out

    def sys_extra_series(self):
        """负载和内存占用两条曲线（客户报告不画，内部看压测强度用）。"""
        path = os.path.join(self.run_dir, "sys_metrics.csv")
        load, memused = [], []
        if not os.path.exists(path):
            return load, memused
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                for key, bucket in (("load1", load), ("mem_used_mb", memused)):
                    v = num(row.get(key))
                    if v is not None:
                        bucket.append(float(v))
        return load, memused

    def gpu_full_series(self):
        """逐卡的频率/利用率/显存，客户报告只画温度和功耗。"""
        path = os.path.join(self.run_dir, "gpu_metrics.csv")
        out = {}
        if not os.path.exists(path):
            return out
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                idx = row.get("index")
                if not idx:
                    continue
                d = out.setdefault(idx, {"name": "", "clock": [], "util": [], "mem": []})
                d["name"] = row.get("name") or d["name"]
                for k, col in (("clock", "clock_sm_mhz"), ("util", "util_pct"),
                               ("mem", "mem_used_mb")):
                    v = num(row.get(col))
                    if v is not None:
                        d[k].append(float(v))
        return out

    # ---------- nvidia-smi 的逐卡清单（deep/ 里那份 csv）----------
    def gpu_inventory(self):
        rows = []
        txt = read_text(self.rawpath("deep", "nvidia-inventory.csv"))
        lines = [l for l in txt.splitlines() if l.strip()]
        if len(lines) < 2:
            return rows
        hdr = [h.strip() for h in lines[0].split(",")]
        for line in lines[1:]:
            cells = [c.strip() for c in line.split(",")]
            if len(cells) != len(hdr):
                continue
            rows.append(dict(zip(hdr, cells)))
        return rows

    # ---------- 网口 ethtool 的额定/实际速率 ----------
    def nic_speeds(self):
        """-> [(接口名, 实际Mb/s或None, 额定Mb/s或None, 是否已接网线)]"""
        out = []
        nicdir = self.rawpath("nic")
        if not os.path.isdir(nicdir):
            return out
        names = sorted({f.rsplit("-", 1)[0] for f in os.listdir(nicdir)})
        for n in names:
            eth = read_text(os.path.join(nicdir, "%s-ethtool.txt" % n))
            if not eth:
                continue
            linked = bool(re.search(r"^\s*Link detected:\s*yes", eth, re.M))
            cur = None
            m = re.search(r"^\s*Speed:\s*(\d+)\s*Mb/s", eth, re.M)
            if m:
                cur = int(m.group(1))
            # "Supported link modes" 可能跨多行，吃到下一个字段名为止
            mx = 0
            block = re.search(r"Supported link modes:(.*?)(?:\n\s*[A-Za-z][\w \-/()]*:)",
                              eth, re.S)
            if block:
                for v in re.findall(r"(\d+)base", block.group(1)):
                    mx = max(mx, int(v))
            out.append((n, cur, mx or None, linked))
        return out

    def nic_optics(self):
        """插了光模块的口 -> 厂商/型号/收发光功率，没有就不出现。"""
        out = []
        deep = self.rawpath("deep")
        if not os.path.isdir(deep):
            return out
        for f in sorted(os.listdir(deep)):
            m = re.match(r"^nic-(.+)-module\.txt$", f)
            if not m:
                continue
            txt = read_text(os.path.join(deep, f))
            if not txt.strip() or "Cannot get module" in txt or "command not found" in txt:
                continue

            def g(key, t=txt):
                mm = re.search(r"^\s*%s\s*:\s*(.+)$" % re.escape(key), t, re.M)
                return mm.group(1).strip() if mm else None

            vendor = g("Vendor name")
            if not vendor and not g("Identifier"):
                continue
            out.append(OrderedDict([
                ("接口名", m.group(1)),
                ("模块厂商", vendor),
                ("模块型号", g("Vendor PN")),
                ("模块序列号", g("Vendor SN")),
                ("类型", g("Transceiver type") or g("Identifier")),
                ("温度", g("Module temperature")),
                ("发光功率", g("Laser output power")),
                ("收光功率", g("Rcvr signal avg optical power")),
            ]))
        return out

    # ---------- 本次测试环境自己的缺口 ----------
    def env_gaps(self):
        """采集期间超时/缺工具的命令。这类东西只该出现在内部报告里。"""
        gaps = []
        for root, _dirs, files in os.walk(self.raw):
            for fn in sorted(files):
                if not fn.endswith((".txt", ".json", ".csv", ".log")):
                    continue
                p = os.path.join(root, fn)
                try:
                    if os.path.getsize(p) > 4 * 1024 * 1024:
                        continue
                except OSError:
                    continue
                txt = read_text(p)
                rel = os.path.relpath(p, self.raw).replace(os.sep, "/")
                for m in re.finditer(r"\(TIMEOUT after (\d+)s: ([^)]+)\)", txt):
                    gaps.append(("超时", rel, "%s（%ss）" % (m.group(2), m.group(1))))
                for m in re.finditer(r"\(command not found: ([^)]+)\)", txt):
                    gaps.append(("缺工具", rel, m.group(1)))
        return gaps

    # ---------- raw/ 文件索引 ----------
    def raw_index(self, skip=()):
        rows = []
        for root, _dirs, files in os.walk(self.raw):
            for fn in sorted(files):
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, self.raw).replace(os.sep, "/")
                if rel in skip:
                    continue
                try:
                    size = os.path.getsize(p)
                except OSError:
                    size = 0
                rows.append((rel, size))
        rows.sort(key=lambda r: r[0])
        return rows


# ============================================================ 评估规则
#
# 这里的每一条都**不影响整机结论** —— 结论只看 results.jsonl 里有没有 FAIL。
# 这些是"人拿到这台机器会想知道、但不该写进交付文件"的二次解读：
# 哪里成色好、哪里将来可能出问题、这一轮测得干不干净。

def assess(d):
    f = []
    meta = d.meta
    thr = meta.get("thresholds") or {}

    # ---------------- 整机结论与判定分布 ----------------
    st = [r.get("status") for r in d.results]
    n_fail, n_warn = st.count("FAIL"), st.count("WARN")
    if not st:
        # 一条判定都没有：这不是"全都通过"，是这一轮压根没跑成。
        # 排在 n_fail 前面 —— 没有结果的时候 n_fail 也是 0，会走进"无 FAIL 项"那支。
        f.append(finding(RISK, "整机", "results.jsonl 里一条判定都没有",
                         "本次运行没有产生任何结论，报告无效，需要重测。"
                         "先看 klburn.log 最后几行，确认是采集阶段崩了、盘写满了，"
                         "还是进程被收掉了。", "results.jsonl"))
    elif n_fail:
        names = "、".join(r.get("name", "?") for r in d.results if r.get("status") == "FAIL")
        f.append(finding(RISK, "整机", "有 %d 项判定为 FAIL：%s" % (n_fail, names),
                         "整机结论为 FAIL，不能出货。", "results.jsonl"))
    else:
        f.append(finding(GOOD, "整机", "无 FAIL 项，整机结论 PASS",
                         "告警 %d 项、跳过 %d 项，均不拉低结论。"
                         % (n_warn, st.count("SKIP")), "results.jsonl"))

    # ---------------- 本轮测试本身干不干净 ----------------
    planned = num(meta.get("planned_secs"), 0) or 0
    elapsed = num(meta.get("elapsed_secs"), 0) or 0
    if planned and elapsed and elapsed < planned * 0.9:
        f.append(finding(WATCH, "测试完整性",
                         "实际耗时明显短于计划（%s / %s）" % (fmt_dur(elapsed), fmt_dur(planned)),
                         "压测可能提前退出，看一下各项压测的退出码再下结论。", "meta.json"))
    if str(meta.get("disk_confirmed")) not in ("1", "True", "true"):
        f.append(finding(INFO, "测试完整性", "本次未做硬盘破坏性读写压测",
                         "现场默认跳过。硬盘的型号/SMART/温度照常采集，"
                         "但没有 fio 的带宽与 IOPS 数据。", "meta.json"))
    if str(meta.get("clock_synced")) != "1":
        f.append(finding(INFO, "测试完整性", "本次未能联网校时",
                         "报告时间戳沿用主板 RTC，可能不准。", "raw/clock-sync.log"))

    gaps = d.env_gaps()
    if gaps:
        kinds = OrderedDict()
        for kind, _rel, what in gaps:
            kinds.setdefault(kind, set()).add(what.split("（")[0])
        desc = "；".join("%s：%s" % (k, "、".join(sorted(v))) for k, v in kinds.items())
        f.append(finding(WATCH, "测试完整性", "采集过程有 %d 处不完整" % len(gaps),
                         desc + "。这些是我们环境的问题，不是机器的问题，"
                                "但缺的数据会让日后追溯少一块。", "见下方「本次采集的缺口」"))

    # ---------------- CPU ----------------
    temps, freqs, powers = d.sys_series()
    warn_t = num(thr.get("cpu_temp_warn"), 95)
    fail_t = num(thr.get("cpu_temp_fail"), 100)
    if temps:
        peak = max(temps)
        margin = fail_t - peak
        if peak >= fail_t:
            lvl, txt = RISK, "已经到判故障线，散热不合格"
        elif peak >= warn_t:
            lvl, txt = WATCH, "已进入告警区间"
        elif margin >= 25:
            lvl, txt = GOOD, "余量充足"
        else:
            lvl, txt = GOOD, "余量正常"
        f.append(finding(lvl, "CPU 散热",
                         "满载峰值 %d°C，距判故障线还有 %d°C（%s）" % (peak, margin, txt),
                         "告警线 %s°C / 判故障线 %s°C。" % (warn_t, fail_t),
                         "sys_metrics.csv"))
    else:
        f.append(finding(INFO, "CPU 散热", "读不到 CPU 温度",
                         "这台机器的温度驱动不是 coretemp/k10temp，"
                         "属于正常情况，判定已自动让开。", "raw/sensors.txt"))

    # 逐颗温差：双路机上一颗凉一颗烫，基本就是散热器没装好或风道偏
    pkg = d.cpu_pkg_series()
    if len(pkg) >= 2:
        peaks = {i: max(v) for i, v in pkg.items() if v}
        if len(peaks) >= 2:
            hi_i = max(peaks, key=lambda k: peaks[k])
            lo_i = min(peaks, key=lambda k: peaks[k])
            spread = peaks[hi_i] - peaks[lo_i]
            detail = "、".join("CPU%d %d°C" % (i, peaks[i]) for i in sorted(peaks))
            if spread >= 15:
                f.append(finding(WATCH, "CPU 散热",
                                 "两颗 CPU 满载峰值相差 %d°C" % spread,
                                 detail + "。差这么多通常是散热器没压紧、硅脂没铺开，"
                                          "或者风道偏向一侧 —— 现在不算故障，"
                                          "但装到客户机房里最容易变成「那颗 CPU 老降频」。",
                                 "sys_metrics.csv"))
            else:
                f.append(finding(GOOD, "CPU 散热", "两颗 CPU 温度均衡（相差 %d°C）" % spread,
                                 detail, "sys_metrics.csv"))

    # 满载频率 vs DMI 标称基频
    base = None
    for b in dmi_blocks(d.dmi, "Processor Information"):
        v = num(b["props"].get("Current Speed"))
        if v:
            base = v
            break
    if freqs and base:
        avg = sum(freqs) / len(freqs)
        lo = min(freqs)
        if avg < base * 0.8:
            f.append(finding(WATCH, "CPU 频率",
                             "全核满载平均只有 %d MHz，标称基频 %d MHz" % (avg, base),
                             "掉到基频八成以下，多半是散热或供电压不住；"
                             "也可能 BIOS 里限了功耗墙。最低瞬时 %d MHz。" % lo,
                             "sys_metrics.csv"))
        else:
            f.append(finding(GOOD, "CPU 频率",
                             "全核满载平均 %d MHz（标称基频 %d MHz）" % (avg, base),
                             "满载能吃住基频，供电和散热都跟得上。最低瞬时 %d MHz。" % lo,
                             "sys_metrics.csv"))
    if powers:
        f.append(finding(INFO, "CPU 功耗", "封装功耗峰值 %d W" % max(powers),
                         "读自 RAPL，多路已求和。可用来核对这颗 U 是不是真按标称 TDP 在跑。",
                         "sys_metrics.csv"))

    # ---------------- 内存 ----------------
    dimms = d.dimms()
    installed, visible = d.mem_capacity()
    slots = d.dimm_slots_total()
    if dimms:
        if installed and visible:
            gap = installed - visible
            if gap > max(installed * 0.06, 2048):
                f.append(finding(RISK, "内存",
                                 "装机 %dGB，系统只认到 %dGB" % (installed // 1024, visible // 1024),
                                 "少认了约 %dGB。要么有条子没被 BIOS 认到（插槽/条子问题），"
                                 "要么 BIOS 开了内存镜像/备用。" % (gap // 1024),
                                 "raw/dmidecode-memory.txt"))
            else:
                f.append(finding(GOOD, "内存",
                                 "装机 %dGB，系统识别 %dGB，一致"
                                 % (installed // 1024, visible // 1024),
                                 "差值在固件保留的正常范围内。", "raw/dmidecode-memory.txt"))
        # 插槽利用率：插满一半以下时通道跑不满，性能会明显吃亏
        if slots:
            pct = len(dimms) * 100 // slots
            if pct <= 50:
                f.append(finding(WATCH, "内存",
                                 "%d 个插槽只装了 %d 条（%d%%）" % (slots, len(dimms), pct),
                                 "内存通道大概率没跑满，带宽比满配少一截。"
                                 "不是故障，但客户如果按满配的性能预期来验收会有落差。",
                                 "raw/dmidecode-memory.txt"))
            else:
                f.append(finding(GOOD, "内存", "%d 个插槽装了 %d 条" % (slots, len(dimms)), "",
                                 "raw/dmidecode-memory.txt"))
        # 混插：厂商 / 颗粒型号 / 频率任一不齐
        for key, label in (("厂商", "厂商"), ("颗粒/型号", "颗粒型号"), ("频率", "频率")):
            vals = {x.get(key) for x in dimms if x.get(key)}
            if len(vals) > 1:
                f.append(finding(WATCH, "内存", "内存条%s不一致（%d 种）" % (label, len(vals)),
                                 "、".join(sorted(str(v) for v in vals)) +
                                 "。混插能开机不代表稳，频率会被拉到最低的那条，"
                                 "长期跑还可能出兼容性问题。",
                                 "raw/dmidecode-memory.txt"))

    # ---------------- 硬盘 ----------------
    devs = d.smart_devices()
    if not devs:
        f.append(finding(INFO, "硬盘", "本机未采集到任何硬盘的 SMART", "", "raw/smart-pre/"))
    else:
        aged, worn, bad, hot, unsafe = [], [], [], [], []
        models = set()
        warn_dt = num(thr.get("disk_temp_warn"), 70)
        for base in devs:
            pre, post = d.smart_pair(base)
            cur = post or pre
            models.add(clean(pre.get("model")) or "?")
            hrs = num(cur.get("power_on_hours"))
            if hrs is not None and hrs >= 8760:
                aged.append("%s %d 小时（约 %.1f 年）" % (base, hrs, hrs / 8760.0))
            used = num(cur.get("percentage_used"))
            if used is not None and used >= 10:
                worn.append("%s 已用寿命 %d%%" % (base, used))
            for fld, name in (("realloc_sectors", "重分配扇区"),
                              ("pending_sectors", "待处理扇区"),
                              ("uncorrectable", "不可修正错误"),
                              ("crc_errors", "接口CRC错误"),
                              ("media_errors", "介质错误")):
                v = num(cur.get(fld))
                if v:
                    bad.append("%s %s=%d" % (base, name, v))
            us = num(cur.get("unsafe_shutdowns"))
            if us is not None and us >= 100:
                unsafe.append("%s 异常掉电 %d 次" % (base, us))
            t = num(cur.get("temperature_c"))
            if t is not None and warn_dt and t >= warn_dt - 10:
                hot.append("%s %d°C" % (base, t))

        if bad:
            f.append(finding(RISK, "硬盘", "有盘带着坏道/错误计数",
                             "；".join(bad) + "。压测前后没有增长的话不判 FAIL，"
                                             "但这些盘不该再往关键位置上装。", "raw/smart-post/"))
        if aged:
            f.append(finding(WATCH, "硬盘", "有 %d 块盘通电时间较长" % len(aged),
                             "；".join(aged) + "。寿命类字段不参与判定，"
                                             "这里列出来供设备台账和排产参考。", "raw/smart-pre/"))
        else:
            f.append(finding(GOOD, "硬盘", "所有盘通电时间都在 1 年以内", "", "raw/smart-pre/"))
        if worn:
            f.append(finding(WATCH, "硬盘", "有 SSD 已消耗一部分寿命",
                             "；".join(worn) + "。", "raw/smart-pre/"))
        if unsafe:
            f.append(finding(WATCH, "硬盘", "有盘异常掉电次数偏高",
                             "；".join(unsafe) + "。通常是此前直接断电留下的记录，"
                                               "本身不算故障，但值得留意。", "raw/smart-pre/"))
        if hot:
            f.append(finding(WATCH, "硬盘", "压测结束时温度偏高",
                             "；".join(hot) + "（告警线 %s°C）。盘位散热或风道要看一下。"
                             % warn_dt, "raw/smart-post/"))
        if len(models) > 1:
            f.append(finding(INFO, "硬盘", "本机混用了 %d 种型号的盘" % len(models),
                             "、".join(sorted(models)), "raw/lsblk.txt"))

    # ---------------- GPU ----------------
    present = num(meta.get("gpu_present"), 0) or 0
    usable = num(meta.get("gpu_usable"), 0) or 0
    if present:
        if str(meta.get("gpu_mismatch")) == "1":
            f.append(finding(WATCH, "显卡",
                             "驱动版本不支持其中 %d 张卡" % (present - usable),
                             "这是**我们盘里的驱动旧了**，不是客户的卡有问题 —— "
                             "客户报告里判的是 SKIP。要测这几张卡，"
                             "得换更新的驱动重新出盘。原话见证据文件。",
                             "raw/gpu-driver-mismatch.txt"))
        gpus = d.gpu_series()
        peaks = {i: max(v["temp"]) for i, v in gpus.items() if v.get("temp")}
        if len(peaks) >= 2:
            spread = max(peaks.values()) - min(peaks.values())
            detail = "、".join("GPU%s %d°C" % (i, peaks[i]) for i in sorted(peaks))
            lvl = WATCH if spread >= 12 else GOOD
            f.append(finding(lvl, "显卡",
                             "逐卡满载峰值温差 %d°C" % spread,
                             detail + ("。差得多的那张多半在风道下游或者被别的卡挡了，"
                                       "多卡机器最常见的问题。" if lvl == WATCH else "。"),
                             "gpu_metrics.csv"))
        # PCIe 实际链路（加载状态下读的才准）
        for row in d.gpu_inventory():
            idx = row.get("index", "?")
            gmax = num(row.get("pcie.link.gen.max"))
            gcur = num(row.get("pcie.link.gen.current"))
            wmax = num(row.get("pcie.link.width.max"))
            wcur = num(row.get("pcie.link.width.current"))
            why = []
            if gmax and gcur and gcur < gmax:
                why.append("代数 Gen%d（额定 Gen%d）" % (gcur, gmax))
            if wmax and wcur and wcur < wmax:
                why.append("宽度 x%d（额定 x%d）" % (wcur, wmax))
            if why:
                f.append(finding(WATCH, "显卡",
                                 "GPU%s 的 PCIe 链路没跑满：%s" % (idx, "、".join(why)),
                                 "空闲时 N 卡会自己降到 Gen1 省电，这份是压测后采的，"
                                 "仍然偏低才值得查：卡没插到底、槽位电气通道少、"
                                 "或者转接板信号质量不好。",
                                 "raw/deep/nvidia-inventory.csv"))
        ecc = read_text(d.rawpath("deep", "nvidia-ecc.txt"))
        if ecc.strip():
            tot = 0
            for m in re.finditer(r"^\s*Total\s*:\s*(\d+)\s*$", ecc, re.M):
                tot += int(m.group(1))
            if tot:
                f.append(finding(WATCH, "显卡", "ECC 计数合计 %d" % tot,
                                 "显存 ECC 有纠错记录。少量可纠错误在数据中心卡上常见，"
                                 "持续增长才是坏显存。", "raw/deep/nvidia-ecc.txt"))
    else:
        f.append(finding(INFO, "显卡", "本机未安装独立显卡", "", "raw/gpu-lspci.txt"))

    # ---------------- 网卡 ----------------
    speeds = d.nic_speeds()
    linked = [s for s in speeds if s[3]]
    slow = [s for s in linked if s[1] and s[2] and s[1] < s[2]]
    if slow:
        f.append(finding(WATCH, "网卡", "有 %d 个口没协商到额定速率" % len(slow),
                         "；".join("%s 实际 %dMb/s、额定 %dMb/s" % (n, c, m)
                                   for n, c, m, _ in slow) +
                         "。多半是这次接的线/对端口不够格，不一定是网卡的问题 —— "
                         "换根线再测一次就知道。", "raw/nic-summary.txt"))
    elif linked:
        f.append(finding(GOOD, "网卡", "%d 个已接线的口都协商到额定速率" % len(linked),
                         "共 %d 个物理口。" % len(speeds), "raw/nic-summary.txt"))
    else:
        f.append(finding(INFO, "网卡", "现场一个口都没接网线",
                         "共 %d 个物理口，型号/固件照常采集。" % len(speeds),
                         "raw/nic-summary.txt"))

    # ---------------- 电源 ----------------
    psus = d.psus()
    if psus:
        # 口径要和 check_psu 一致：只要有模块没进电，那一路就没被验证过，
        # 客户报告那边判的是 WARN，这里不能反而说"良好"。
        live = [p for p in psus if p.get("交流输入") == "正常"]
        if len(live) < len(psus):
            f.append(finding(WATCH, "电源", "%d 个电源模块只有 %d 路进电"
                             % (len(psus), len(live)),
                             "测试台上只接一半电源线是常态，不算故障；但没进电的那几路"
                             "这一轮等于没测到 —— 要验证冗余得把线都插上再跑一次。",
                             "raw/dmidecode-psu.txt"))
        else:
            f.append(finding(GOOD, "电源", "%d 个模块全部在位且有交流输入" % len(psus),
                             "冗余在本次测试中被完整验证过。", "raw/dmidecode-psu.txt"))

    # ---------------- PCIe / BMC / 内核日志 ----------------
    pcie = [m for m in d.metrics if m.get("group") == "pcie"]
    if pcie:
        f.append(finding(WATCH, "PCIe", "有 %d 个端点设备链路未达额定值" % len(pcie),
                         "；".join("%s %s" % (m.get("key"), m.get("value")) for m in pcie),
                         "raw/lspci-vv.txt"))

    sel_new = d.rawpath("ipmi-sel-new.txt")
    if os.path.exists(sel_new):
        n = len([l for l in read_text(sel_new).splitlines() if l.strip()])
        if n:
            f.append(finding(WATCH, "BMC", "压测期间 BMC 新增 %d 条事件" % n,
                             "逐条看一下是不是电源/温度类告警。", "raw/ipmi-sel-new.txt"))

    for fn, label in (("dmesg-errors-boot.txt", "开机阶段"),
                      ("dmesg-errors.txt", "压测期间")):
        p = d.rawpath(fn)
        if os.path.exists(p):
            n = len([l for l in read_text(p).splitlines() if l.strip()])
            if n:
                f.append(finding(RISK, "内核日志", "%s有 %d 条硬件错误" % (label, n),
                                 "这类日志基本都对应真实的硬件问题，逐条看。", "raw/" + fn))

    f.sort(key=lambda x: LEVEL_ORDER.get(x["level"], 9))
    return f


# ============================================================ 渲染

EXTRA_CSS = """
.internal-banner{background:#7f1d1d;color:#fff;padding:12px 18px;border-radius:6px;
margin:0 0 18px;font-weight:700;letter-spacing:.5px}
.internal-banner span{display:block;font-weight:400;font-size:12.5px;opacity:.92;margin-top:4px}
.pill{display:inline-block;min-width:44px;text-align:center;padding:1px 9px;border-radius:10px;
color:#fff;font-size:12px;font-weight:700;letter-spacing:1px}
.p-good{background:#1a7f37}.p-watch{background:#b45309}.p-risk{background:#c1121f}.p-info{background:#6b7280}
.fnd{display:flex;gap:12px;align-items:flex-start;padding:9px 12px;border:1px solid var(--line);
border-left-width:4px;border-radius:5px;margin-bottom:7px;background:var(--panel)}
.f-good{border-left-color:#1a7f37}.f-watch{border-left-color:#b45309}
.f-risk{border-left-color:#c1121f}.f-info{border-left-color:#6b7280}
.fnd .ft{font-weight:600}
.fnd .fa{min-width:74px;color:var(--muted);font-size:12.5px}
.fnd .fd{color:#444;font-size:13px;margin-top:2px}
.fnd .fe{color:var(--muted);font-size:11.5px;margin-top:3px;font-family:Consolas,monospace}
.idx{font-size:12px}
.idx td{padding:4px 8px}
"""


def findings_html(items):
    out = []
    for it in items:
        out.append('<div class="fnd f-%s">' % it["level"])
        out.append('<span class="pill p-%s">%s</span>' % (it["level"], LEVEL_TEXT[it["level"]]))
        out.append('<span class="fa">%s</span>' % E(it["area"]))
        out.append("<div style='flex:1'><div class='ft'>%s</div>" % E(it["title"]))
        if it["detail"]:
            out.append("<div class='fd'>%s</div>" % E(it["detail"]))
        if it["evidence"]:
            out.append("<div class='fe'>%s</div>" % E(it["evidence"]))
        out.append("</div></div>")
    return "".join(out)


def build_internal_html(d):
    meta = d.meta
    H = []
    A = H.append

    tag = meta.get("machine_tag") or os.path.basename(d.run_dir)
    serial = (d.system().get("整机序列号") or meta.get("serial") or "UNKNOWN")
    findings = assess(d)

    st = [r.get("status") for r in d.results]
    # 和 generate_report.py / factory-test.sh 同一条规矩：一条判定都没有 != 全都通过。
    # 三处必须一致，否则同一次运行的屏幕、交付报告、内部报告会给出三个结论。
    overall = "FAIL" if ("FAIL" in st or not st) else "PASS"

    A('<div class="wrap"><header>')
    A('<div class="internal-banner">内部工程报告 · 请勿外发'
      "<span>这份是工程数据，包含设备台账字段、本次测试环境的信息和源码版本，"
      "用于复盘和日后追溯。交付的是报告目录下与目录同名的那个 .html。</span></div>")
    A('<div class="company">%s</div>' % E(meta.get("company_name")))
    A("<h1>%s ｜ 工程数据</h1>" % E(meta.get("report_title") or "服务器出厂老化测试报告"))
    A('<div class="sub">机器标识 <b>%s</b></div>' % E(tag))
    A('<div class="sub">整机序列号 %s ｜ 测试 %s ~ %s ｜ %s ｜ 实际耗时 %s</div>'
      % (E(serial), E(meta.get("start_time")), E(meta.get("end_time")),
         E(profile_text(meta.get("profile"))), E(fmt_dur(meta.get("elapsed_secs")))))
    A("</header>")

    A('<div style="margin:16px 0 6px"><span class="verdict v-%s">%s</span>' % (overall, overall))
    A('<span style="margin-left:16px" class="sub">通过 %d ｜ 失败 %d ｜ 告警 %d ｜ 跳过 %d'
      "（整机结论只看有没有 FAIL）</span></div>"
      % (st.count("PASS"), st.count("FAIL"), st.count("WARN"), st.count("SKIP")))

    # ---------------- 一、内部评估 ----------------
    A("<h2>一、内部评估：这台机器什么成色</h2>")
    counts = OrderedDict()
    for lv in (RISK, WATCH, GOOD, INFO):
        n = len([x for x in findings if x["level"] == lv])
        if n:
            counts[LEVEL_TEXT[lv]] = "%d 条" % n
    A(kv_block(counts))
    A('<p class="sub">以下每一条都<b>不影响整机结论</b>（结论只看 results.jsonl 里有没有 FAIL）。'
      "它们回答的是另一个问题：这台机器哪里好、哪里将来可能出问题、这一轮测得干不干净。</p>")
    A(findings_html(findings))

    # ---------------- 二、本次测试环境 ----------------
    A("<h2>二、本次测试环境</h2>")
    thr = meta.get("thresholds") or {}
    A(kv_block(OrderedDict([
        ("KLBurn 版本", meta.get("klburn_version")),
        ("源码 commit", meta.get("git_commit")),
        ("构建日期", meta.get("build_date")),
        ("基础系统", meta.get("base_os")),
        ("运行内核", meta.get("kernel")),
        ("显卡驱动", ("已包含 %s" % meta.get("nvidia_version")
                      if str(meta.get("include_nvidia")) == "1" else "未包含")),
        ("阵列卡工具", "盘内有 storcli64" if str(meta.get("storcli_present")) == "1"
                       else "盘内没有 storcli64"),
        ("显卡压测程序", "盘内有 gpu_burn" if str(meta.get("gpu_burn_present")) == "1"
                         else "盘内没有 gpu_burn"),
        ("报告落盘设备", meta.get("data_partition")),
        ("联网校时", "成功" if str(meta.get("clock_synced")) == "1" else "未成功"),
        ("CPU 温度阈值", "告警 %s / 故障 %s °C"
         % (thr.get("cpu_temp_warn"), thr.get("cpu_temp_fail"))),
        ("GPU 温度阈值", "告警 %s / 故障 %s °C"
         % (thr.get("gpu_temp_warn"), thr.get("gpu_temp_fail"))),
        ("硬盘温度阈值", "告警 %s / 故障 %s °C"
         % (thr.get("disk_temp_warn"), thr.get("disk_temp_fail"))),
    ])))

    gaps = d.env_gaps()
    A("<h3>本次采集的缺口</h3>")
    if gaps:
        A('<p class="sub">下面这些是<b>我们环境</b>的问题，不是被测机器的问题。'
          "客户报告里对应的项一律记 SKIP。缺的数据会让日后追溯少一块，能补就补。</p>")
        A(table([OrderedDict([("类型", k), ("文件", rel), ("命令 / 工具", what)])
                 for k, rel, what in gaps]))
    else:
        A('<p class="muted">没有超时、也没有缺工具，本轮采集是完整的。</p>')

    # ---------------- 三、硬盘全量参数 ----------------
    A("<h2>三、硬盘全量参数</h2>")
    devs = d.smart_devices()
    if not devs:
        A('<p class="muted">未采集到任何硬盘的 SMART。</p>')
    else:
        lsb = d.lsblk_by_name()
        rows = []
        for base in devs:
            pre, post = d.smart_pair(base)
            cur = post or pre
            b = lsb.get(base, {})
            rows.append(OrderedDict([
                ("设备", base),
                ("型号", clean(pre.get("model")) or clean(b.get("model"))),
                ("序列号", clean(pre.get("serial"))),
                ("固件", clean(pre.get("firmware"))),
                ("容量", human_bytes(pre.get("capacity_bytes") or b.get("size"))),
                ("介质", "机械盘" if b.get("rota") else "固态盘"),
                ("通电时间", ("%s 小时" % pre.get("power_on_hours"))
                    if pre.get("power_on_hours") is not None else None),
                ("通电次数", pre.get("power_cycles")),
                ("已用寿命", ("%s%%" % pre.get("percentage_used"))
                    if pre.get("percentage_used") is not None else None),
                ("异常掉电", pre.get("unsafe_shutdowns")),
                ("测后温度", ("%s°C" % cur.get("temperature_c"))
                    if cur.get("temperature_c") is not None else None),
                ("SMART", "正常" if cur.get("smart_passed") is True
                    else ("异常" if cur.get("smart_passed") is False else None)),
            ]))
        A('<p class="sub">通电时间 / 通电次数 / 已用寿命 / 异常掉电这几列不参与判定，'
          "交付报告里不列；做设备台账、排产，以及日后回查时用的就是它们。</p>")
        A(table(rows))

        A("<h3>坏道类计数：压测前 → 压测后</h3>")
        A('<p class="sub">出厂测试真正的价值在这张表：压测本身跑完不代表没问题，'
          "要看压测把什么逼出来了。任何一格前后变大都是硬伤。</p>")
        fields = [("realloc_sectors", "重分配扇区"), ("pending_sectors", "待处理扇区"),
                  ("uncorrectable", "不可修正错误"), ("crc_errors", "接口CRC错误"),
                  ("media_errors", "NVMe介质错误"), ("critical_warning", "NVMe严重告警")]
        rows = []
        for base in devs:
            pre, post = d.smart_pair(base)
            row = OrderedDict([("设备", base)])
            for key, label in fields:
                a, b = pre.get(key), post.get(key)
                if a is None and b is None:
                    row[label] = None
                elif a == b:
                    row[label] = str(a)
                else:
                    row[label] = "%s → %s ⚠" % (a, b)
            rows.append(row)
        A(table(rows))

    # ---------------- 四、压测曲线 ----------------
    A("<h2>四、压测曲线（比客户报告多几条）</h2>")
    temps, freqs, powers = d.sys_series()
    pkg = d.cpu_pkg_series()
    if pkg:
        A("<h3>4.1 逐颗 CPU 封装温度</h3>")
        A('<p class="sub">客户报告只画一条整机最高温。逐颗分开画，才看得出'
          "是不是某一颗的散热器没装好 —— 这是双路机最常见的隐性问题。</p>")
        A(svg_line_chart([("CPU%d" % i, pkg[i]) for i in sorted(pkg)],
                         y_label="°C", y_suffix="°C"))
    if temps:
        A("<h3>4.2 整机最高 CPU 温度</h3>")
        A(svg_line_chart([("CPU 最高温", temps)], y_label="°C", y_suffix="°C"))
    if freqs:
        A("<h3>4.3 全核平均频率</h3>")
        A(svg_line_chart([("平均频率", freqs)], y_label="MHz", y_suffix="MHz"))
    if powers:
        A("<h3>4.4 CPU 封装功耗</h3>")
        A(svg_line_chart([("封装功耗", powers)], y_label="W", y_suffix="W"))
    load, memused = d.sys_extra_series()
    if load or memused:
        A("<h3>4.5 系统负载与内存占用</h3>")
        A('<p class="sub">用来核对压测强度：负载没上去 = 压测没真跑满；'
          "内存占用曲线能看出内存压测吃到了多少、离 OOM 还有多远。</p>")
        if load:
            A(svg_line_chart([("1 分钟负载", load)], y_label="load"))
        if memused:
            A(svg_line_chart([("已用内存", memused)], y_label="MB", y_suffix="MB"))

    gfull = d.gpu_full_series()
    if gfull:
        A("<h3>4.6 GPU 频率 / 利用率 / 显存占用</h3>")
        A('<p class="sub">利用率没到 100% 说明压测没喂满，出来的温度功耗数字要打折看。</p>')
        for key, label, suf in (("clock", "SM 频率", "MHz"), ("util", "利用率", "%"),
                                ("mem", "显存占用", "MB")):
            series = [("GPU%s %s" % (i, gfull[i]["name"]), gfull[i][key])
                      for i in sorted(gfull) if gfull[i][key]]
            if series:
                A("<p class='sub'>%s</p>" % E(label))
                A(svg_line_chart(series, y_label=suf, y_suffix=suf))

    # ---------------- 五、逐项判定明细 ----------------
    A("<h2>五、逐项判定明细（含内部 id 与证据文件）</h2>")
    A('<p class="sub">客户报告只显示名称和结论，这里连 id 和证据文件路径一起列出来 —— '
      "复盘时按 id 就能直接定位到代码里的判定分支。</p>")
    rows = []
    for r in d.results:
        rows.append(OrderedDict([
            ("状态", r.get("status")),
            ("id", r.get("id")),
            ("名称", r.get("name")),
            ("结论", r.get("detail")),
            ("证据", r.get("ref")),
            ("时间", r.get("time")),
        ]))
    A(table(rows, "没有任何判定记录"))

    if d.metrics:
        A("<h3>实测指标全量</h3>")
        A(table([OrderedDict([("分组", m.get("group")), ("指标", m.get("key")),
                              ("数值", m.get("value"))]) for m in d.metrics]))

    fio = d.fio_results()
    if fio:
        A("<h3>硬盘性能数据</h3>")
        A(table(fio))

    # ---------------- 六、更多硬件明细 ----------------
    A("<h2>六、更多硬件明细</h2>")
    optics = d.nic_optics()
    if optics:
        A("<h3>6.1 光模块</h3>")
        A('<p class="sub">只有插着模块时才读得到。光口机器出问题时，'
          "收发光功率是最值钱的一份数据 —— 客户报告里没有它。</p>")
        A(table(optics))

    inv = d.gpu_inventory()
    if inv:
        A("<h3>6.2 显卡逐卡清单（压测后读的 PCIe 链路）</h3>")
        A(table([OrderedDict((k, v) for k, v in row.items()) for row in inv]))

    A("<h3>6.3 内存条明细</h3>")
    A(table(d.dimms(), "未检测到内存条信息"))

    # ---------------- 七、raw/ 索引 ----------------
    # 本报告自己就在 raw/ 里，所以相对链接直接可用：在 U 盘上双击打开这份 HTML，
    # 点任何一行就能跳到对应的原始文件，不用再去翻目录。
    A("<h2>七、raw/ 文件索引</h2>")
    idx = [(rel, size) for rel, size in d.raw_index()
           if not rel.startswith("INTERNAL_")]
    A('<p class="sub">共 %d 个文件，下面的链接可以直接点开（在浏览器里打开本文件时有效）。</p>'
      % len(idx))
    # 链接要原样输出，不能被 E() 转义，所以这张表自己拼
    A('<div class="tablewrap"><table class="idx"><thead><tr><th>文件</th><th>大小</th>'
      "</tr></thead><tbody>")
    for rel, size in idx:
        A('<tr><td><a href="%s">%s</a></td><td>%s</td></tr>'
          % (html.escape(rel), html.escape(rel), E(human_bytes(size) if size else "0 B")))
    A("</tbody></table></div>")

    # ---------------- 八、关键原始输出 ----------------
    A("<h2>八、关键原始输出</h2>")
    A('<p class="sub">挑几份最常翻的内嵌进来，省得一个个开文件。'
      "单份超过 120KB 的会截断，完整内容点上面的索引。</p>")
    for title, rel in [
        ("驱动/显卡不匹配的内核原话", "gpu-driver-mismatch.txt"),
        ("显卡驱动信息", "gpu-driver-modinfo.txt"),
        ("内核日志中的硬件错误（开机）", "dmesg-errors-boot.txt"),
        ("内核日志中的硬件错误（压测）", "dmesg-errors.txt"),
        ("IPMI 传感器读数（测后）", "ipmi-sensors-post.txt"),
        ("BMC 新增事件", "ipmi-sel-new.txt"),
        ("联网校时日志", "clock-sync.log"),
        ("CPU 压测日志", "stress/cpu-stress-ng.log"),
        ("内存压测日志", "stress/mem-stressapptest.log"),
        ("GPU 压测日志", "stress/gpu-burn.log"),
        ("PCIe 链路详情", "lspci-vv.txt"),
        ("扩展 SMART（第一块盘）",
         "deep/smart-x-%s.txt" % (devs[0] if devs else "none")),
        ("本次开机完整日志", "deep/journal-boot.txt"),
    ]:
        p = d.rawpath(rel)
        if not os.path.exists(p):
            continue
        txt = read_text(p)
        if not txt.strip():
            continue
        if len(txt) > 120000:
            txt = txt[:120000] + "\n...（已截断，完整内容见 raw/%s）" % rel
        A(collapsible("%s  [raw/%s]" % (title, rel), txt))

    A("<footer>")
    A("KLBurn v%s ｜ 源码 %s ｜ 生成自 %s<br>"
      % (E(meta.get("klburn_version")), E(meta.get("git_commit")), E(d.run_dir)))
    A("<b>内部工程报告，不随机器交付。</b>")
    A("</footer></div>")

    return ('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>[内部] %s</title><style>%s%s</style></head><body>%s</body></html>"
            % (html.escape(str(tag)), CSS, EXTRA_CSS, "".join(H)))


# ============================================================ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    if not os.path.isdir(a.run_dir):
        print("run-dir 不存在: %s" % a.run_dir, file=sys.stderr)
        return 1

    d = Internal(a.run_dir)
    out = a.out
    if not out:
        tag = d.meta.get("machine_tag") or os.path.basename(os.path.abspath(a.run_dir))
        raw = os.path.join(a.run_dir, "raw")
        if not os.path.isdir(raw):
            os.makedirs(raw, exist_ok=True)
        out = os.path.join(raw, "INTERNAL_%s.html" % tag)

    try:
        doc = build_internal_html(d)
    except Exception as e:      # 内部报告失败绝不能影响已经生成好的客户报告
        import traceback
        print("内部工程报告生成失败: %s" % e, file=sys.stderr)
        traceback.print_exc()
        return 1

    with open(out, "w", encoding="utf-8") as f:
        f.write(doc)

    print("内部工程报告已生成: %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
