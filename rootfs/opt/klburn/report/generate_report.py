#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KLBurn 报告生成器

读取 factory-test.sh 落在 run-dir 里的原始数据，产出一个自包含的 report.html
（CSS 内嵌、图表用手写 SVG、不依赖任何外网资源，Windows 上双击就能看）。

用法:
    generate_report.py --run-dir /mnt/klburn-data/KLBurn-Reports/SN123_20260729-181500
"""
import argparse
import base64
import csv
import html
import json
import os
import re
import sys
from collections import OrderedDict, defaultdict

# ============================================================ 小工具

def read_text(path, default=""):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return default


def read_json(path, default=None):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default if default is not None else {}


def read_jsonl(path):
    out = []
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def E(s):
    """HTML 转义。None 一律显示成 —"""
    if s is None or s == "":
        return "—"
    return html.escape(str(s))


# 判定文案里用 **这样** 标重点，是给写代码的人看的记号（源码里一眼看得到
# 哪句是关键）。以前它一路原样进 HTML —— 客户看到的是
#     这是测试环境的容量限制，**不是内存故障** ——
# 字面的星号。那句话恰恰是最该让人看清的一句，结果被两串星号糟蹋了。
#
# 在**转义之后**做替换：html.escape 不碰星号，所以先转义再换标签是安全的，
# 反过来（先换标签再转义）会把 <b> 自己也转义掉。
_EMPH = re.compile(r"\*\*(.+?)\*\*", re.S)


def E_rich(s):
    """给判定文案用的转义：和 E() 一样安全，另外把 **重点** 渲染成粗体。"""
    return _EMPH.sub(r"<b>\1</b>", E(s))


BOGUS = {
    "to be filled by o.e.m.", "not specified", "default string", "none",
    "unknown", "n/a", "no dimm", "not present", "empty", "o.e.m.",
    "system manufacturer", "system product name", "0123456789",
}


def clean(v):
    """dmidecode 里大量占位垃圾值，统一过滤掉"""
    if v is None:
        return None
    s = str(v).strip()
    if not s or s.lower() in BOGUS:
        return None
    return s


def human_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "—"
    if n <= 0:
        return "—"
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if n < 1024 or unit == "PB":
            return "%.1f %s" % (n, unit) if unit not in ("B", "KB") else "%d %s" % (n, unit)
        n /= 1024.0
    return "—"


# 时长档位的中文名。报告里显示中文，meta.json 里存的仍是英文 key
# （屏幕上是英文，两边靠这张表对上）。认不出来的档位原样显示，不吞掉。
PROFILE_TEXT = {
    "QUICK":     "快速",
    "STANDARD":  "标准",
    "EXTENDED":  "加长",
    "LONG":      "长测",
    "SOAK":      "深度",
    "ENDURANCE": "耐久",
}


def profile_text(p):
    if not p:
        return None
    return PROFILE_TEXT.get(str(p).upper(), p)


def fmt_dur(sec):
    try:
        sec = int(sec)
    except (TypeError, ValueError):
        return "—"
    h, m, s = sec // 3600, sec % 3600 // 60, sec % 60
    if h:
        return "%d小时%d分%d秒" % (h, m, s)
    if m:
        return "%d分%d秒" % (m, s)
    return "%d秒" % s


# ============================================================ dmidecode 解析

def parse_dmidecode(text):
    """返回 [{'type': 'Memory Device', 'props': {...}}, ...]"""
    blocks = []
    cur = None
    expect_type = False
    for raw in text.splitlines():
        if raw.startswith("Handle "):
            cur = {"type": None, "props": OrderedDict()}
            blocks.append(cur)
            expect_type = True
            continue
        if cur is None:
            continue
        if expect_type:
            if raw.strip():
                cur["type"] = raw.strip()
                expect_type = False
            continue
        if raw.startswith(("\t", "    ")) and ":" in raw:
            k, _, v = raw.strip().partition(":")
            cur["props"][k.strip()] = v.strip()
    return blocks


def dmi_blocks(blocks, typename):
    return [b for b in blocks if b["type"] == typename]


def dmi_first(blocks, typename):
    got = dmi_blocks(blocks, typename)
    return got[0]["props"] if got else {}


# ============================================================ SVG 折线图

PALETTE = ["#2f6fd0", "#d9534f", "#5cb85c", "#f0ad4e", "#8e5bd0",
           "#00a2b3", "#e0669a", "#7a8b99"]


def svg_line_chart(series, y_label="", y_suffix="", width=880, height=280,
                   y_min=None, y_max=None):
    """
    series: [(label, [数值, ...]), ...]  —— x 轴按采样序号等距
    返回一段 <svg>，纯手写，不依赖任何图表库。
    """
    series = [(lab, [v for v in vals if v is not None]) for lab, vals in series]
    series = [(lab, vals) for lab, vals in series if len(vals) >= 2]
    if not series:
        return '<p class="muted">（无采样数据）</p>'

    pad_l, pad_r, pad_t, pad_b = 58, 16, 16, 34
    plot_w = width - pad_l - pad_r
    plot_h = height - pad_t - pad_b

    all_vals = [v for _, vals in series for v in vals]
    lo = min(all_vals) if y_min is None else y_min
    hi = max(all_vals) if y_max is None else y_max
    if hi - lo < 1e-6:
        hi = lo + 1
    span = hi - lo
    lo -= span * 0.08
    hi += span * 0.08
    if lo < 0 and min(all_vals) >= 0:
        lo = 0

    n_max = max(len(v) for _, v in series)

    def px(i, n):
        return pad_l + (plot_w * i / max(1, n - 1))

    def py(v):
        return pad_t + plot_h - (plot_h * (v - lo) / (hi - lo))

    parts = ['<svg class="chart" viewBox="0 0 %d %d" '
             'preserveAspectRatio="xMidYMid meet" role="img">' % (width, height)]

    # 网格 + Y 轴刻度
    for i in range(5):
        v = lo + (hi - lo) * i / 4.0
        y = py(v)
        parts.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" class="grid"/>'
                     % (pad_l, y, width - pad_r, y))
        parts.append('<text x="%.1f" y="%.1f" class="axis" text-anchor="end">%s%s</text>'
                     % (pad_l - 8, y + 4, ("%.0f" % v) if abs(v) >= 10 else ("%.1f" % v), y_suffix))

    # X 轴标注（起止）
    parts.append('<text x="%.1f" y="%.1f" class="axis">采样开始</text>' % (pad_l, height - 10))
    parts.append('<text x="%.1f" y="%.1f" class="axis" text-anchor="end">采样结束</text>'
                 % (width - pad_r, height - 10))
    if y_label:
        parts.append('<text x="6" y="12" class="axis">%s</text>' % E(y_label))

    for idx, (label, vals) in enumerate(series):
        color = PALETTE[idx % len(PALETTE)]
        pts = " ".join("%.1f,%.1f" % (px(i, len(vals)), py(v)) for i, v in enumerate(vals))
        parts.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="2" '
                     'stroke-linejoin="round"/>' % (pts, color))

    # 图例
    lx = pad_l
    for idx, (label, vals) in enumerate(series):
        color = PALETTE[idx % len(PALETTE)]
        peak = max(vals)
        txt = "%s (峰值 %.0f%s)" % (label, peak, y_suffix)
        parts.append('<rect x="%.1f" y="%.1f" width="10" height="10" fill="%s"/>'
                     % (lx, pad_t - 2, color))
        parts.append('<text x="%.1f" y="%.1f" class="legend">%s</text>'
                     % (lx + 14, pad_t + 7, E(txt)))
        lx += 14 + max(90, len(txt) * 7.2)
        if lx > width - 120:
            lx = pad_l
            pad_t += 14

    parts.append("</svg>")
    return "".join(parts)


# ============================================================ 采集数据装配

class Data(object):
    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.raw = os.path.join(run_dir, "raw")
        self.meta = read_json(os.path.join(run_dir, "meta.json"))
        self.results = read_jsonl(os.path.join(run_dir, "results.jsonl"))
        self.metrics = read_jsonl(os.path.join(run_dir, "metrics.jsonl"))
        self.dmi = parse_dmidecode(read_text(os.path.join(self.raw, "dmidecode.txt")))
        self._sensors = None

    def rawpath(self, *p):
        return os.path.join(self.raw, *p)

    # ---------- IPMI 传感器 ----------
    def ipmi_sensors(self):
        """`ipmitool sensor list` 的输出 -> {传感器名(小写): 读数}"""
        if self._sensors is None:
            d = {}
            for line in read_text(self.rawpath("ipmi-sensors.txt")).splitlines():
                parts = [p.strip() for p in line.split("|")]
                if len(parts) >= 2 and parts[0]:
                    d.setdefault(parts[0].lower(), parts[1])
            self._sensors = d
        return self._sensors

    # ---------- 整机 ----------
    def system(self):
        sysinfo = dmi_first(self.dmi, "System Information")
        board = dmi_first(self.dmi, "Base Board Information")
        bios = dmi_first(self.dmi, "BIOS Information")
        chassis = dmi_first(self.dmi, "Chassis Information")
        return OrderedDict([
            ("整机厂商", clean(sysinfo.get("Manufacturer"))),
            ("整机型号", clean(sysinfo.get("Product Name"))),
            ("整机序列号", clean(sysinfo.get("Serial Number")) or self.meta.get("serial")),
            ("主板厂商", clean(board.get("Manufacturer"))),
            ("主板型号", clean(board.get("Product Name"))),
            ("主板序列号", clean(board.get("Serial Number"))),
            ("机箱类型", clean(chassis.get("Type"))),
            ("BIOS 厂商", clean(bios.get("Vendor"))),
            ("BIOS 版本", clean(bios.get("Version"))),
            ("BIOS 日期", clean(bios.get("Release Date"))),
        ])

    # ---------- CPU ----------
    def cpus(self):
        out = []
        for b in dmi_blocks(self.dmi, "Processor Information"):
            p = b["props"]
            status = p.get("Status", "")
            if "Unpopulated" in status or not clean(p.get("Version")):
                continue
            out.append(OrderedDict([
                ("插槽", clean(p.get("Socket Designation"))),
                ("型号", clean(p.get("Version"))),
                ("厂商", clean(p.get("Manufacturer"))),
                ("物理核心", clean(p.get("Core Count"))),
                ("线程数", clean(p.get("Thread Count"))),
                ("最大频率", clean(p.get("Max Speed"))),
                ("当前频率", clean(p.get("Current Speed"))),
                ("状态", clean(status)),
            ]))
        return out

    def cpu_summary(self):
        lscpu = read_json(self.rawpath("lscpu.json"))
        d = {}
        for item in (lscpu.get("lscpu") or []):
            f = item.get("field", "").rstrip(":")
            d[f] = item.get("data")
        return d

    # ---------- 内存 ----------
    def dimms(self):
        out = []
        for b in dmi_blocks(self.dmi, "Memory Device"):
            p = b["props"]
            size = p.get("Size", "")
            if not size or "No Module" in size or size.lower() == "unknown":
                continue
            out.append(OrderedDict([
                ("插槽位置", clean(p.get("Locator"))),
                ("容量", clean(size)),
                ("类型", clean(p.get("Type"))),
                ("频率", clean(p.get("Configured Memory Speed")) or clean(p.get("Speed"))),
                ("厂商", clean(p.get("Manufacturer"))),
                ("颗粒/型号", clean(p.get("Part Number"))),
                ("序列号", clean(p.get("Serial Number"))),
                ("Rank", clean(p.get("Rank"))),
            ]))
        return out

    def dimm_slots_total(self):
        return len(dmi_blocks(self.dmi, "Memory Device"))

    def mem_capacity(self):
        """(装机容量MB, 系统识别MB)。取不到的那一项给 0。

        装机容量只累加 DMI 内存设备的 Size 字段。注意不能顺手把 DDR5 多打的
        "Volatile Size" 也加进来，否则容量翻倍。
        """
        installed = 0
        for b in dmi_blocks(self.dmi, "Memory Device"):
            size = (b["props"].get("Size") or "").strip()
            m = re.match(r"^(\d+)\s*(GB|MB|TB)$", size, re.I)
            if not m:
                continue
            n, unit = int(m.group(1)), m.group(2).upper()
            installed += n * {"MB": 1, "GB": 1024, "TB": 1048576}[unit]

        visible = 0
        m = re.search(r"^MemTotal:\s+(\d+)\s*kB", read_text(self.rawpath("meminfo.txt")), re.M)
        if m:
            visible = int(m.group(1)) // 1024
        return installed, visible

    # ---------- 电源 ----------
    def psu_ac_state(self, idx):
        """BMC 的输入电压/功率传感器 -> 这一路有没有进电。

        比 DMI 的 Status 可信：DMI 的 "Present, Critical" 既可能是没插电源线，
        也可能是模块真坏了，光看它分不出来。
        """
        pat = re.compile(r"^(psu|ps)_?%s[\s_-]*(vin|ac[_ ]?in|input[_ ]?volt|pin)" % re.escape(str(idx)))
        for name, val in self.ipmi_sensors().items():
            if not pat.match(name):
                continue
            try:
                return "正常" if float(val) > 1 else "未接入"
            except ValueError:
                return "未接入"      # na / no reading = 这个模块没在工作
        return None

    def psus(self):
        out = []
        for i, b in enumerate(dmi_blocks(self.dmi, "System Power Supply"), 1):
            p = b["props"]
            loc = clean(p.get("Location")) or clean(p.get("Name")) or ("PSU%d" % i)
            m = re.search(r"\d+", loc)
            out.append(OrderedDict([
                ("位置", loc),
                ("厂商", clean(p.get("Manufacturer"))),
                ("型号", clean(p.get("Model Part Number"))),
                ("序列号", clean(p.get("Serial Number"))),
                ("额定功率", clean(p.get("Max Power Capacity"))),
                ("交流输入", self.psu_ac_state(m.group(0) if m else i)),
                ("状态", clean(p.get("Status"))),
            ]))
        return out

    # ---------- 硬盘 ----------
    def raid_pd_keys(self):
        """阵列卡后端物理盘的 SMART key -> [(逻辑盘名, 设备号), ...]

        阵列卡跑 RAID 模式时物理盘没有 /dev 节点，它们的 SMART 是通过阵列卡
        透传读的（`smartctl -d megaraid,N`），落盘文件名形如 sda-pd8.norm.json。
        """
        d = self.rawpath("smart-pre")
        out = []
        if not os.path.isdir(d):
            return out
        for f in sorted(os.listdir(d)):
            m = re.match(r"^(.+)-pd(\d+)\.norm\.json$", f)
            if m:
                out.append((m.group(1), m.group(2)))
        return out

    def disks(self):
        lsblk = read_json(self.rawpath("lsblk.json"), {"blockdevices": []})

        # "本次压测" 只有在现场真的确认了破坏性写入之后才算数。
        # 0.3.0 及以前的 meta.json 会把"候选盘"也写进 disk_tested（哪怕最后跳过了），
        # 于是跳过压测的报告里这一列还是显示"是"，和下面 stress_disk 的 SKIP 打架。
        # 这里再用 disk_confirmed 卡一道，老的 run-dir 重新生成也能纠正过来。
        confirmed = str(self.meta.get("disk_confirmed")).strip().lower() in ("1", "true", "yes")
        tested = (self.meta.get("disk_tested") or "").split() if confirmed else []

        # KLBurn U 盘自己不算被测机器的硬件，不进清单。
        # 光看 lsblk 的 rm 标志不够——实测有些 USB 控制器下 rm 报的是 false，
        # 所以再用 tran==usb 和"数据分区所在的盘"两条线兜底。
        usb_parent = ""
        dp = self.meta.get("data_partition") or ""
        m = re.match(r"^/dev/(.+?)p?\d+$", dp)
        if m:
            usb_parent = m.group(1)

        out = []
        for d in lsblk.get("blockdevices", []):
            if d.get("type") != "disk":
                continue
            name = d.get("name")
            path = d.get("path") or ("/dev/" + str(name))
            if d.get("rm") is True or d.get("hotplug") is True:
                continue
            if (d.get("tran") or "").lower() == "usb":
                continue
            if usb_parent and name == usb_parent:
                continue
            sm = read_json(self.rawpath("smart-pre", "%s.norm.json" % name), {})
            smp = read_json(self.rawpath("smart-post", "%s.norm.json" % name), {})
            # 这张表只列参与判定的字段。寿命类（通电时间/通电次数/累计读写量）
            # 不参与判定，完整数值在工程数据和内部报告里。
            # 盘好不好，看的是 SMART 健康状态和坏道计数压测前后有没有变化。
            out.append(OrderedDict([
                ("设备", path),
                ("型号", clean(sm.get("model")) or clean(d.get("model"))),
                ("序列号", clean(sm.get("serial")) or clean(d.get("serial"))),
                ("固件", clean(sm.get("firmware"))),
                ("容量", human_bytes(d.get("size") or sm.get("capacity_bytes"))),
                ("接口", (d.get("tran") or "—")),
                ("介质", "机械盘" if d.get("rota") else "固态盘"),
                ("当前温度", ("%s°C" % smp.get("temperature_c"))
                    if smp.get("temperature_c") is not None else
                    (("%s°C" % sm.get("temperature_c")) if sm.get("temperature_c") is not None else None)),
                ("SMART健康", "正常" if sm.get("smart_passed") is True
                    else ("异常" if sm.get("smart_passed") is False else None)),
                ("本次压测", "是" if path in tested else "否"),
            ]))

        # 阵列卡后端的物理盘。它们没有自己的 /dev 节点，所以上面按 lsblk 那一圈
        # 扫不到 —— 但客户买的正是这些盘，报告里必须有。
        for vd, n in self.raid_pd_keys():
            sm = read_json(self.rawpath("smart-pre", "%s-pd%s.norm.json" % (vd, n)), {})
            smp = read_json(self.rawpath("smart-post", "%s-pd%s.norm.json" % (vd, n)), {})
            if not sm:
                continue
            rota = sm.get("rotation_rate")
            out.append(OrderedDict([
                ("设备", "阵列卡 PD%s" % n),
                ("型号", clean(sm.get("model"))),
                ("序列号", clean(sm.get("serial"))),
                ("固件", clean(sm.get("firmware"))),
                ("容量", human_bytes(sm.get("capacity_bytes"))),
                ("接口", "阵列卡"),
                ("介质", "固态盘" if rota in (0, None) else "机械盘"),
                ("当前温度", ("%s°C" % smp.get("temperature_c"))
                    if smp.get("temperature_c") is not None else
                    (("%s°C" % sm.get("temperature_c")) if sm.get("temperature_c") is not None else None)),
                ("SMART健康", "正常" if sm.get("smart_passed") is True
                    else ("异常" if sm.get("smart_passed") is False else None)),
                ("本次压测", "—"),
            ]))
        return out

    # ---------- 网卡 ----------
    # lib/network.sh 写的单口测试结论 -> 报告里的中文。两边的关键字必须对齐。
    NIC_RESULT_TEXT = {
        "OK":         "已连通",
        "NO_LINK":    "未连接链路（未接网线）",
        "NO_DHCP":    "链路已连接，但未获取到 DHCP 地址",
        "NO_GATEWAY": "已获取地址，但 DHCP 未下发网关",
        "PING_FAIL":  "已获取地址，但 ping 网关不通",
        "NO_CLIENT":  "未测试（当前测试环境不具备该项检测条件）",
    }

    def nics(self):
        out = []
        nicdir = self.rawpath("nic")
        if not os.path.isdir(nicdir):
            return out
        # 一个口有 -driver / -ethtool / -test / -ping / -dhcp 好几个文件，去重取口名
        names = sorted({f.rsplit("-", 1)[0] for f in os.listdir(nicdir)})
        for n in names:
            drv = read_text(os.path.join(nicdir, "%s-driver.txt" % n))
            eth = read_text(os.path.join(nicdir, "%s-ethtool.txt" % n))
            tst = read_text(os.path.join(nicdir, "%s-test.txt" % n))

            def grab(txt, key):
                m = re.search(r"^\s*%s\s*:\s*(.+)$" % re.escape(key), txt, re.M)
                v = m.group(1).strip() if m else None
                # 没插网线时 ethtool 打的是 "Unknown!" / "Unknown! (255)"，
                # 原样搬进客户报告像是采集出错，一律当没有这个值处理。
                if v is None or v.startswith("Unknown!") or v in ("-", "n/a"):
                    return None
                return v

            res = grab(tst, "Result")
            ping = grab(tst, "Ping")
            link = grab(eth, "Link detected")
            conn = None
            if res is not None:
                conn = self.NIC_RESULT_TEXT.get(res, res)
                if ping:
                    conn = "%s（%s）" % (conn, ping)
            out.append(OrderedDict([
                ("接口名", n),
                ("型号", grab(drv, "model")),
                ("驱动", grab(drv, "driver")),
                ("固件版本", grab(drv, "firmware-version")),
                ("总线地址", grab(drv, "bus-info")),
                ("协商速率", grab(eth, "Speed")),
                ("双工", grab(eth, "Duplex")),
                ("链路状态", "已连接" if link == "yes"
                    else ("未连接" if link == "no" else None)),
                ("IP 地址", grab(tst, "IPv4")),
                ("默认网关", grab(tst, "Gateway")),
                ("连通性测试", conn),
            ]))
        return out

    # ---------- 阵列卡 ----------
    def raid(self):
        txt = read_text(self.rawpath("storcli-show.txt"))
        cards = []
        if txt:
            # 按 "Controller = N" 切块后逐字段取。
            # 不能用一条跨字段的大正则：storcli 输出里 Serial Number 出现在
            # Product Name 之前，顺序一变就整条匹配不上。
            seen = set()
            for block in re.split(r"\n(?=Controller\s*=\s*\d+\s*$)", txt, flags=re.M):
                mc = re.search(r"^Controller\s*=\s*(\d+)\s*$", block, re.M)
                if not mc:
                    continue

                def g(key, b=block):
                    m = re.search(r"^\s*%s\s*=\s*(.+?)\s*$" % re.escape(key), b, re.M)
                    return clean(m.group(1)) if m else None

                model = g("Product Name") or g("Model")
                if not model:
                    continue
                key = (mc.group(1), model)
                if key in seen:
                    continue
                seen.add(key)
                cards.append(OrderedDict([
                    ("控制器", "Controller %s" % mc.group(1)),
                    ("型号", model),
                    ("序列号", g("Serial Number")),
                    ("固件版本", g("FW Package Build") or g("FW Version")),
                ]))
        if not cards:
            lspci = read_text(self.rawpath("lspci.txt"))
            for line in lspci.splitlines():
                if re.search(r"RAID bus controller|Serial Attached SCSI|MegaRAID", line, re.I):
                    cards.append(OrderedDict([
                        ("控制器", "PCI"),
                        ("型号", line.split(":", 2)[-1].strip()),
                        ("序列号", None),
                        ("固件版本", None),
                    ]))
        return cards

    # ---------- GPU ----------
    def gpus(self):
        out = []
        smi = read_text(self.rawpath("gpu-smi-full.txt"))
        if smi.strip():
            # nvidia-smi -q 的分卡段落
            chunks = re.split(r"\nGPU 00000000", smi)
            drv = re.search(r"Driver Version\s*:\s*(.+)", smi)
            drv = drv.group(1).strip() if drv else None
            for ch in chunks[1:]:
                def grab(key, b=ch):
                    m = re.search(r"^\s*%s\s*:\s*(.+)$" % re.escape(key), b, re.M)
                    v = m.group(1).strip() if m else None
                    return None if v in ("N/A", "Unknown Error") else v

                def grab_under(section, key, b=ch):
                    """nvidia-smi -q 里 Total / Max 这类键名重复出现在多个小节下，
                    必须限定在指定小节内取，否则会拿到别处的值。"""
                    m = re.search(r"^\s*%s\s*\n(?:.*\n)*?\s*%s\s*:\s*(.+)$"
                                  % (re.escape(section), re.escape(key)), b, re.M)
                    return m.group(1).strip() if m else None

                out.append(OrderedDict([
                    ("型号", grab("Product Name")),
                    ("显存", grab_under("FB Memory Usage", "Total")),
                    ("序列号", grab("Serial Number")),
                    ("BIOS版本", grab("VBIOS Version")),
                    ("驱动版本", drv),
                    ("PCIe最大代数", grab_under("PCIe Generation", "Max")),
                ]))
        if not out:
            for line in read_text(self.rawpath("gpu-lspci.txt")).splitlines():
                if line.strip():
                    out.append(OrderedDict([
                        ("型号", line.split(":", 2)[-1].strip()),
                        ("显存", None), ("序列号", None),
                        ("BIOS版本", None), ("驱动版本", None), ("PCIe链路", None),
                    ]))
        return out

    # ---------- 采样曲线 ----------
    def sys_series(self):
        """CPU 温度 / 频率 / 封装功耗三条曲线。

        cpu_power_w 是 0.6.0 才加的列（读 RAPL 算的），老的 run-dir 里没有这一列，
        DictReader 取不到就当没有——报告里那张图直接不画，不能因此崩掉。
        RAPL 读不到的机器（部分 AMD、虚拟机）也是同样处理。
        """
        path = os.path.join(self.run_dir, "sys_metrics.csv")
        temps, freqs, powers = [], [], []
        if not os.path.exists(path):
            return temps, freqs, powers
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                for key, bucket in (("cpu_temp_c", temps),
                                    ("cpu_freq_mhz", freqs),
                                    ("cpu_power_w", powers)):
                    try:
                        bucket.append(float(row[key]))
                    except (ValueError, KeyError, TypeError):
                        pass
        return temps, freqs, powers

    def gpu_series(self):
        """返回 {gpu_index: {'temp': [...], 'power': [...], 'name': str}}"""
        path = os.path.join(self.run_dir, "gpu_metrics.csv")
        data = defaultdict(lambda: {"temp": [], "power": [], "name": ""})
        if not os.path.exists(path):
            return {}
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                idx = row.get("index")
                if idx is None or idx == "":
                    continue
                d = data[idx]
                d["name"] = row.get("name") or d["name"]
                for k, col in (("temp", "temp_c"), ("power", "power_w")):
                    try:
                        d[k].append(float(row[col]))
                    except (ValueError, KeyError, TypeError):
                        pass
        return dict(data)

    # ---------- fio ----------
    def fio_results(self):
        out = []
        for tag, fname in (("顺序写 1M", "fio-seq.json"), ("4K随机读写", "fio-rand.json")):
            j = read_json(self.rawpath(fname))
            for job in (j.get("jobs") or []):
                rd, wr = job.get("read", {}), job.get("write", {})
                out.append(OrderedDict([
                    ("测试项", tag),
                    ("目标", job.get("jobname")),
                    ("读带宽", "%.1f MB/s" % (rd.get("bw", 0) / 1024.0)),
                    ("读IOPS", "%.0f" % rd.get("iops", 0)),
                    ("写带宽", "%.1f MB/s" % (wr.get("bw", 0) / 1024.0)),
                    ("写IOPS", "%.0f" % wr.get("iops", 0)),
                    ("错误数", job.get("error", 0)),
                ]))
        return out


# ============================================================ HTML 渲染

CSS = """
:root{--fg:#1a1d21;--muted:#6b7280;--line:#e2e5ea;--bg:#fff;--panel:#f7f8fa;
--pass:#1a7f37;--fail:#c1121f;--warn:#b45309;--skip:#6b7280;--accent:#2f6fd0}
*{box-sizing:border-box}
body{margin:0;padding:0 0 60px;background:var(--bg);color:var(--fg);
font-family:"Microsoft YaHei","PingFang SC","Hiragino Sans GB",-apple-system,"Segoe UI",sans-serif;
font-size:14px;line-height:1.6}
.wrap{max-width:1080px;margin:0 auto;padding:0 20px}
header{border-bottom:3px solid var(--accent);padding:26px 0 18px;margin-bottom:8px}
.company{font-size:20px;font-weight:700;letter-spacing:.5px}
.logo{max-height:52px;margin-bottom:10px}
h1{font-size:26px;margin:6px 0 2px}
h2{font-size:19px;margin:34px 0 12px;padding-left:11px;border-left:5px solid var(--accent)}
h3{font-size:15px;margin:20px 0 8px;color:#333}
.sub{color:var(--muted);font-size:13px}
.kv{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:2px 26px;margin:10px 0}
.kv div{display:flex;gap:8px;padding:5px 0;border-bottom:1px dotted var(--line)}
.kv b{min-width:104px;color:var(--muted);font-weight:400}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:13px}
th,td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}
th{background:var(--panel);font-weight:600;white-space:nowrap}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.tablewrap{overflow-x:auto}
.verdict{display:inline-block;padding:12px 34px;border-radius:8px;font-size:34px;
font-weight:800;letter-spacing:4px;color:#fff}
.v-PASS{background:var(--pass)}.v-FAIL{background:var(--fail)}
.badge{display:inline-block;min-width:52px;text-align:center;padding:2px 10px;
border-radius:4px;color:#fff;font-weight:700;font-size:12px;letter-spacing:1px}
.b-PASS{background:var(--pass)}.b-FAIL{background:var(--fail)}
.b-WARN{background:var(--warn)}.b-SKIP{background:var(--skip)}
.result-row{display:flex;gap:14px;align-items:flex-start;padding:11px 13px;
border:1px solid var(--line);border-left-width:5px;border-radius:5px;margin-bottom:8px;background:var(--panel)}
.r-PASS{border-left-color:var(--pass)}.r-FAIL{border-left-color:var(--fail)}
.r-WARN{border-left-color:var(--warn)}.r-SKIP{border-left-color:var(--skip)}
.result-row .rn{font-weight:700;min-width:150px}
.result-row .rd{flex:1;color:#333}
.muted{color:var(--muted)}
.chart{width:100%;height:auto;background:#fff;border:1px solid var(--line);border-radius:5px;margin:10px 0}
.grid{stroke:#eef0f3;stroke-width:1}
.axis{font-size:11px;fill:#8a9099;font-family:sans-serif}
.legend{font-size:11px;fill:#333;font-family:sans-serif}
details{margin:8px 0;border:1px solid var(--line);border-radius:5px;background:var(--panel)}
summary{cursor:pointer;padding:8px 12px;font-weight:600;user-select:none;font-size:13px}
details>div{padding:0 12px 12px}
pre{background:#1e2227;color:#d6dae0;padding:12px;border-radius:5px;overflow-x:auto;
font-size:11.5px;line-height:1.45;max-height:460px;font-family:Consolas,Monaco,monospace}
.notice{padding:11px 14px;border-radius:5px;margin:12px 0;border:1px solid}
.notice-warn{background:#fff8e6;border-color:#f0c96b;color:#7a5200}
.notice-info{background:#eef4fd;border-color:#b9d0f0;color:#1f4d8f}
footer{margin-top:44px;padding-top:14px;border-top:1px solid var(--line);
color:var(--muted);font-size:12px}
@media print{body{font-size:11pt}details{break-inside:avoid}details[open] pre{max-height:none}
h2{break-after:avoid}.result-row{break-inside:avoid}}
"""


def table(rows, empty_note="未安装"):
    """rows: [OrderedDict, ...] -> HTML 表格。空则给一句说明。"""
    if not rows:
        return '<p class="muted">%s</p>' % E(empty_note)
    cols = list(rows[0].keys())
    out = ['<div class="tablewrap"><table><thead><tr>']
    out += ["<th>%s</th>" % E(c) for c in cols]
    out.append("</tr></thead><tbody>")
    for r in rows:
        out.append("<tr>")
        for c in cols:
            out.append("<td>%s</td>" % E(r.get(c)))
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def kv_block(d):
    items = ['<div><b>%s</b><span>%s</span></div>' % (E(k), E(v)) for k, v in d.items()]
    return '<div class="kv">%s</div>' % "".join(items)


def collapsible(title, content, is_pre=True):
    body = "<pre>%s</pre>" % E(content) if is_pre else content
    return "<details><summary>%s</summary><div>%s</div></details>" % (E(title), body)


# 采集失败时 capture() 会往文件里写这两种标记。它们是**我们这边环境**的记录
# （某个工具没带、某条命令超时），对客户没有任何意义，而且直接暴露了内部工具名 ——
# 比如 storcli-show.txt 里可能只有一行 "(command not found: storcli64)"。
# 这类行一律从交付的报告里剔掉；完整原文仍然留在 raw/ 和内部工程报告里。
CAPTURE_NOISE = re.compile(r"^\s*\((?:command not found:|TIMEOUT after)[^)]*\)\s*$", re.M)


def raw_file_block(data, title, relpath, limit=200000):
    p = data.rawpath(relpath)
    if not os.path.exists(p):
        return ""
    txt = CAPTURE_NOISE.sub("", read_text(p))
    if not txt.strip():
        # 整个文件只有采集失败的标记 —— 这一块整个不出现，
        # 而不是给客户看一个空的、或者写着某某工具没找到的折叠块。
        return ""
    if len(txt) > limit:
        txt = txt[:limit] + "\n...（内容过长已截断，完整数据见报告目录）"
    # ⚠️ 标题里不要带 raw/ 下的文件名。文件名里常常就是工具名
    # （storcli-show.txt / gpu-smi-full.txt），等于把内部实现直接印给客户看。
    # 上面那句"完整文件保存在报告目录的 raw/ 子目录下"已经说清去哪儿找了。
    return collapsible(title, txt)


def build_html(data):
    meta = data.meta
    results = data.results

    statuses = [r.get("status") for r in results]
    # 一条判定都没有 != 全都通过。
    #
    # results.jsonl 为空或读不出来（采集阶段就崩了、U 盘写满了、进程被收掉），
    # 以前会走进 else 分支打出绿色大字 PASS —— 一台什么都没测过的机器，报告上
    # 看起来是合格的。判不出来就得说判不出来，绝不能默认成合格。
    #
    # 注意这不是说机器坏了：下面的提示语写的是"本次测试无效、需重新测试"，
    # 不往硬件头上扣帽子（见 docs/report-policy.md）。
    no_results = not statuses
    overall = "FAIL" if ("FAIL" in statuses or no_results) else "PASS"

    n_pass = statuses.count("PASS")
    n_fail = statuses.count("FAIL")
    n_warn = statuses.count("WARN")
    n_skip = statuses.count("SKIP")

    sysinfo = data.system()
    serial = sysinfo.get("整机序列号") or meta.get("serial") or "UNKNOWN"

    H = []
    A = H.append

    # ---------------- 抬头 ----------------
    logo_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logo.png")
    logo_html = ""
    if os.path.exists(logo_path):
        try:
            with open(logo_path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
            logo_html = '<img class="logo" src="data:image/png;base64,%s" alt="logo">' % b64
        except OSError:
            pass

    A('<div class="wrap"><header>')
    A(logo_html)
    A('<div class="company">%s</div>' % E(meta.get("company_name")))
    # 抬头和标题都取自 meta.json（构建时钉进盘里的），不写死在代码里 ——
    # 换一家公司出盘时只改 build/config.sh，这里一行都不用动。
    A("<h1>%s</h1>" % E(meta.get("report_title") or "服务器出厂老化测试报告"))
    A('<div class="sub">整机序列号 <b>%s</b> ｜ 测试时间 %s ~ %s ｜ '
      "测试模式 %s ｜ 实际耗时 %s</div>"
      % (E(serial), E(meta.get("start_time")), E(meta.get("end_time")),
         E(profile_text(meta.get("profile"))), E(fmt_dur(meta.get("elapsed_secs")))))
    A('<div class="sub">测试工具 %s v%s（%s，构建于 %s）</div>'
      % (E(meta.get("product_name") or "KLBurn"), E(meta.get("klburn_version")),
         E(meta.get("base_os")), E(meta.get("build_date"))))
    A("</header>")

    # ---------------- 总结论 ----------------
    A('<div style="margin:18px 0 8px"><span class="verdict v-%s">%s</span>' % (overall, overall))
    A('<span style="margin-left:18px" class="sub">通过 %d 项 ｜ 失败 %d 项 ｜ 告警 %d 项 ｜ 跳过 %d 项</span></div>'
      % (n_pass, n_fail, n_warn, n_skip))
    if no_results:
        # 措辞只说"这次测试没跑成"，不说机器有问题——两码事
        A('<div class="notice notice-warn"><b>本次测试未产生任何判定结果，'
          "本报告无效。</b>测试过程未能正常完成，请重新测试后以新报告为准。</div>")
    elif overall == "FAIL":
        A('<div class="notice notice-warn"><b>本机存在未通过项，不建议出货。</b>'
          "请查看下方标红的测试项详情。</div>")

    # 告警项不影响总结论，但必须在抬头就点出来，不能只埋在下面的列表里等人翻。
    # 缺一条内存、少接一路电源线这种事，恰恰是最容易被漏看又最该在出厂拦住的。
    warn_items = [r for r in results if r.get("status") == "WARN"]
    if warn_items:
        A('<div class="notice notice-warn"><b>以下 %d 项为告警，不影响总体结论，'
          "但建议出货前确认：</b><ul style=\"margin:6px 0 0;padding-left:22px\">" % len(warn_items))
        for r in warn_items:
            A("<li>%s：%s</li>" % (E(r.get("name")), E_rich(r.get("detail"))))
        A("</ul></div>")

    if str(meta.get("clock_suspect")) == "1":
        # 开机后会尝试联网校时（见 lib/network.sh），这条通知只在校时没成功、
        # 时间戳仍然看着不对时才出现——文案要如实反映"试过但没成"，
        # 不能再写"现场无网络"，那已经不是这个分支的真实原因了。
        if str(meta.get("clock_synced")) == "1":
            A('<div class="notice notice-info">已通过网络自动校时，但测试时间戳看起来仍有异常，'
              "以下时间仅供参考，测试内容与结论不受影响。</div>")
        else:
            A('<div class="notice notice-info">本机未能通过网络自动校时'
              "（现场无网络连接，或连接不到时间服务器），"
              "测试时间沿用主板 RTC 原有设置，可能不准。测试内容与结论不受影响。</div>")

    if meta.get("data_partition") in (None, "", "none"):
        A('<div class="notice notice-warn">本次测试未找到 U 盘数据分区，'
          "报告曾写入 /tmp（关机即丢失）。</div>")

    # ================================================================
    A("<h2>一、硬件清单</h2>")

    A("<h3>1.1 整机</h3>")
    A(kv_block(sysinfo))

    A("<h3>1.2 CPU</h3>")
    cpus = data.cpus()
    A(table(cpus, "未检测到 CPU 信息"))
    cs = data.cpu_summary()
    if cs:
        A(kv_block(OrderedDict([
            ("逻辑处理器", cs.get("CPU(s)")),
            ("每核线程", cs.get("Thread(s) per core")),
            ("每路核心", cs.get("Core(s) per socket")),
            ("物理插槽", cs.get("Socket(s)")),
            ("NUMA 节点", cs.get("NUMA node(s)")),
            ("架构", cs.get("Architecture")),
            ("L3 缓存", cs.get("L3 cache")),
            ("虚拟化", cs.get("Virtualization")),
        ])))

    A("<h3>1.3 内存</h3>")
    dimms = data.dimms()
    installed_mb, visible_mb = data.mem_capacity()
    if dimms:
        A('<p class="sub">已装 %d 条，主板共 %d 个内存插槽。'
          "每条的厂商 / 颗粒型号 / 序列号如下，可逐条核对品牌与规格是否一致。</p>"
          % (len(dimms), data.dimm_slots_total()))
    if installed_mb and visible_mb:
        A(kv_block(OrderedDict([
            ("装机容量", "%d GB（%d 条）" % (installed_mb // 1024, len(dimms))),
            ("系统识别容量", "%d GB" % (visible_mb // 1024)),
        ])))
    A(table(dimms, "未检测到内存条信息"))

    A("<h3>1.4 硬盘</h3>")
    disks = data.disks()
    if disks:
        A('<p class="sub">下表为本机硬盘的型号 / 序列号 / 固件 / 容量与 SMART 健康状态。'
          "坏道类计数在压测前后的变化见下方「硬盘 SMART 复查」。</p>")
        if data.raid_pd_keys():
            A('<p class="sub">标注为「阵列卡 PD<i>n</i>」的是接在阵列卡后面的物理盘 —— '
              "它们在操作系统里看不到独立的盘符，这里的信息是通过阵列卡逐块读取的。</p>")
    A(table(disks, "未检测到本机硬盘"))

    A("<h3>1.5 阵列卡</h3>")
    A(table(data.raid(), "未安装阵列卡"))

    A("<h3>1.6 网卡</h3>")
    nics = data.nics()
    if nics:
        A('<p class="sub">每个网口都会拉起链路、用 DHCP 取地址并 ping 默认网关；'
          "未接网线的口显示「未连接链路」，不计为故障。</p>")
    A(table(nics, "未检测到物理网卡"))

    A("<h3>1.7 GPU 显卡</h3>")
    gpus = data.gpus()
    if gpus:
        A(table(gpus))
    else:
        A('<p class="muted">未安装独立显卡</p>')

    A("<h3>1.8 电源</h3>")
    A(table(data.psus(), "BIOS 未提供电源信息（部分机型不上报，可从 BMC 查看）"))

    # ================================================================
    A("<h2>二、压力测试结果</h2>")

    budget = meta.get("budget") or {}
    A(kv_block(OrderedDict([
        ("测试模式", profile_text(meta.get("profile"))),
        ("计划总时长", fmt_dur(meta.get("planned_secs"))),
        ("实际总耗时", fmt_dur(meta.get("elapsed_secs"))),
        ("CPU 压测时长", fmt_dur(budget.get("cpu_secs"))),
        ("内存压测时长", fmt_dur(budget.get("mem_secs"))),
        ("硬盘压测时长", fmt_dur(budget.get("disk_secs"))),
        ("GPU 压测时长", fmt_dur(budget.get("gpu_secs"))),
    ])))
    A('<p class="sub">CPU / 内存 / GPU 三项并发压测（互不占用彼此的时间，选多长测多长）；'
      "硬盘单独测试，不与前三项同时进行，所以以上时长不能直接相加算总耗时。</p>")

    # 二级编号动态生成：硬盘、GPU 没测的时候它们的小节整个不出现，
    # 写死编号就会出现 2.2 后面直接跳到 2.5 这种断号。
    sub_no = [0]

    def SUB(title):
        sub_no[0] += 1
        return "<h3>2.%d %s</h3>" % (sub_no[0], title)

    A(SUB("各项结论"))
    for r in results:
        st = r.get("status", "SKIP")
        A('<div class="result-row r-%s">' % st)
        A('<span class="badge b-%s">%s</span>' % (st, st))
        A('<span class="rn">%s</span>' % E(r.get("name")))
        A('<span class="rd">%s</span>' % E_rich(r.get("detail")))
        A("</div>")

    # 判定阈值从 meta.json 取实际生效的值——现场可以在 klburn.conf 里覆盖，
    # 报告里写死一份就会和实际判定对不上。老的 run-dir 没有这一段，用默认值兜底。
    def thr(key, default):
        try:
            v = (meta.get("thresholds") or {}).get(key)
            return int(float(v))
        except (TypeError, ValueError):
            return default

    # ---------------- CPU 曲线 ----------------
    CPU_TEMP_WARN, CPU_TEMP_FAIL = thr("cpu_temp_warn", 95), thr("cpu_temp_fail", 100)
    GPU_TEMP_WARN, GPU_TEMP_FAIL = thr("gpu_temp_warn", 83), thr("gpu_temp_fail", 90)
    temps, freqs, powers = data.sys_series()
    if temps or freqs or powers:
        A(SUB("CPU 温度 / 频率 / 功耗曲线"))
        if temps:
            A('<p class="sub">温度峰值 %d°C（告警线 %s°C，判故障线 %s°C）</p>'
              % (max(temps), CPU_TEMP_WARN, CPU_TEMP_FAIL))
            A(svg_line_chart([("CPU 温度", temps)], y_label="°C", y_suffix="°C"))
        if freqs:
            A(svg_line_chart([("CPU 平均频率", freqs)], y_label="MHz", y_suffix="MHz"))
        if powers:
            A('<p class="sub">封装功耗峰值 %d W（读自 RAPL 能量计数器，多路 CPU 已求和）</p>'
              % max(powers))
            A(svg_line_chart([("CPU 封装功耗", powers)], y_label="W", y_suffix="W"))
        A('<p class="sub">采样间隔 5 秒，覆盖 CPU / 内存 / 硬盘全部压测阶段。'
          "读不到的项目（部分平台不提供 RAPL 或 CPU 温度驱动）不画图，不影响判定。</p>")

    # ---------------- GPU 曲线 ----------------
    gs = data.gpu_series()
    if gs:
        A(SUB("GPU 温度 / 功耗曲线"))
        temp_series, power_series = [], []
        peak_t, peak_p = [], []
        for idx in sorted(gs.keys(), key=lambda x: int(x) if str(x).isdigit() else 0):
            label = "GPU%s %s" % (idx, gs[idx]["name"])
            temp_series.append((label, gs[idx]["temp"]))
            power_series.append((label, gs[idx]["power"]))
            if gs[idx]["temp"]:
                peak_t.append("GPU%s %d°C" % (idx, max(gs[idx]["temp"])))
            if gs[idx]["power"]:
                peak_p.append("GPU%s %dW" % (idx, max(gs[idx]["power"])))
        if peak_t:
            A('<p class="sub">逐卡温度峰值：%s（告警线 %s°C，判故障线 %s°C）</p>'
              % (E("、".join(peak_t)), GPU_TEMP_WARN, GPU_TEMP_FAIL))
        A(svg_line_chart(temp_series, y_label="°C", y_suffix="°C"))
        if peak_p:
            A('<p class="sub">逐卡功耗峰值：%s</p>' % E("、".join(peak_p)))
        A(svg_line_chart(power_series, y_label="W", y_suffix="W"))
        A('<p class="sub">采样间隔 5 秒，数据来自 nvidia-smi，覆盖 GPU 满载压测全程。</p>')

    # ---------------- fio ----------------
    fio = data.fio_results()
    if fio:
        A(SUB("硬盘性能数据"))
        A(table(fio))

    # ---------------- 指标 ----------------
    if data.metrics:
        A(SUB("其他实测指标"))
        groups = OrderedDict()
        for m in data.metrics:
            groups.setdefault(m.get("group"), []).append(m)
        rows = []
        for g, items in groups.items():
            for it in items:
                rows.append(OrderedDict([
                    ("分组", g), ("指标", it.get("key")), ("数值", it.get("value")),
                ]))
        A(table(rows))

    # ================================================================
    A("<h2>三、原始日志</h2>")
    A('<p class="sub">以下为采集到的原始输出，完整文件保存在报告目录的 raw/ 子目录下。</p>')

    # 这里不嵌 smartctl 的原始输出（raw/smart-pre|post/ 里完整保留）：
    # 一块盘几百行属性，绝大部分和判定无关，嵌进来只会把报告撑成一堆看不懂的数字。
    # 硬盘的结论看 1.4 表格和 SMART 复查那一项。
    for title, rel in [
        ("dmidecode 全量输出", "dmidecode.txt"),
        ("CPU 详细信息", "lscpu.txt"),
        ("内存条明细", "dmidecode-memory.txt"),
        ("PCI 设备列表", "lspci.txt"),
        ("块设备列表", "lsblk.txt"),
        ("网卡信息", "nic-summary.txt"),
        ("网卡连通性测试", "nic-test.txt"),
        ("电源信息", "dmidecode-psu.txt"),
        ("IPMI 传感器读数", "ipmi-sensors.txt"),
        ("BMC 电源相关事件", "ipmi-sel-psu.txt"),
        ("IPMI 事件日志（测前）", "ipmi-sel-pre.txt"),
        ("IPMI 事件日志（测后）", "ipmi-sel-post.txt"),
        ("阵列卡信息", "storcli-show.txt"),
        ("GPU 详细信息", "gpu-smi-full.txt"),
        ("温度传感器（测后）", "sensors-post.txt"),
        ("CPU 压测日志", "stress/cpu-stress-ng.log"),
        ("内存压测日志", "stress/mem-stressapptest.log"),
        ("硬盘压测日志（随机）", "stress/fio-rand.log"),
        ("GPU 压测日志", "stress/gpu-burn.log"),
        ("内核日志中的硬件错误", "dmesg-errors.txt"),
        ("内核日志（压测期间新增）", "dmesg-delta.txt"),
    ]:
        A(raw_file_block(data, title, rel))

    A("<footer>")
    A("本报告由 %s v%s 自动生成，所有数据来自被测机器实测采集，未经人工修改。<br>"
      % (E(meta.get("product_name") or "KLBurn"), E(meta.get("klburn_version"))))
    # ⚠️ 这份 HTML 是**交付给客户**的，页脚绝不能出现 git commit hash、
    # 源码版本、构建目录这类只有我们内部才用得上的东西。
    # 版本可追溯性靠 meta.json 里的 git_commit —— 那个文件留在内部的工程目录里，
    # 不随报告交付（0.3.0 出过"盘自称的版本和仓库对不上"的悬案，靠它定位）。
    A("报告编号：%s" % E(os.path.basename(data.run_dir)))
    A("</footer></div>")

    return ('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>出厂测试报告 %s</title><style>%s</style></head><body>%s</body></html>"
            % (html.escape(str(serial)), CSS, "".join(H)))


# ============================================================ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    if not os.path.isdir(a.run_dir):
        print("run-dir 不存在: %s" % a.run_dir, file=sys.stderr)
        return 1

    data = Data(a.run_dir)
    out = a.out or os.path.join(a.run_dir, "report.html")

    try:
        doc = build_html(data)
    except Exception as e:  # 报告生成失败绝不能吞掉原始数据
        import traceback
        print("报告生成失败: %s" % e, file=sys.stderr)
        traceback.print_exc()
        return 1

    with open(out, "w", encoding="utf-8") as f:
        f.write(doc)

    print("报告已生成: %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
