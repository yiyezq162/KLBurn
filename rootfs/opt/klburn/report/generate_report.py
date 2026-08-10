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
    "unknown", "n/a", "na", "no dimm", "not present", "empty", "o.e.m.",
    "system manufacturer", "system product name", "system serial number",
    "0123456789",
    # dmidecode 自己打出来的两个"这条读不出来"标记，不是厂商填的内容：
    #   <BAD INDEX>   字符串下标指到了字符串表外面（BIOS 填错了索引）
    #   <OUT OF SPEC> 枚举值不在 SMBIOS 规范里
    # Supermicro X11DPG-QT 的两路电源，厂商/型号/序列号四个字段全是 <BAD INDEX>，
    # 照抄进客户报告就是四格乱码。读不出来就写"读不出来"（表格里的 —）。
    "<bad index>", "<out of spec>",
    # smartctl 对读不到的字段给的就是一个横杠
    "-", "--",
}


# "To be filled by O.E.M." 各家的大小写和尾巴都不一样：有的没有结尾的点、
# 有的写成 "To Be Filled By O.E.M. (dmi)"。BOGUS 是精确匹配，兜不住这些变体，
# 所以再加一道前缀。
#
# ⚠️ 这条前缀 lib/core.sh 的 _serial_is_bogus() 从一开始就有，Python 这边没有 ——
#    而两处的注释都写着"这份名单要和另一边保持一致"。后果和海光那台 `N/A`
#    是同一个方向、只是反过来：BIOS 写成 "To Be Filled By O.E.M"（没有结尾的点）
#    时 shell 认、Python 不认，于是这一格原样印进客户报告。
#    三份名单的一致性现在由 tests/test-hw-checks.sh 逐个值实测，不靠人记。
_BOGUS_PREFIX = "to be filled"


def clean(v):
    if v is None:
        return None
    s = str(v).strip()
    if not s or s.lower() in BOGUS or s.lower().startswith(_BOGUS_PREFIX):
        return None
    return s


# DMI 的状态字段是英文的（`Present, OK` / `Populated, Enabled`），照抄进一份
# 中文报告里，客户还得自己猜。逗号分隔逐段翻，翻不出来的段原样留着 ——
# 见过一个词就整格退回英文，比夹着一个英文词更难读。
DMI_STATUS_CN = {
    "present": "在位",
    "not present": "未在位",
    "populated": "已安装",
    "unpopulated": "未安装",
    "enabled": "已启用",
    "disabled": "已禁用",
    "idle": "空闲",
    "ok": "正常",
    "non-critical": "轻度异常",
    "critical": "严重异常",
    "non-recoverable": "不可恢复故障",
    "failed": "故障",
    "unknown": "未知",
}


def dmi_status_cn(v):
    s = clean(v)
    if not s:
        return None
    parts = [x.strip() for x in s.split(",") if x.strip()]
    return "，".join(DMI_STATUS_CN.get(x.lower(), x) for x in parts) or None


# 「其他实测指标」那张表的分组列。metric_add 的第一个参数是**内部分组键**
# （cpu / mem / gpu / disk / nic / pcie，还有逐卡的 gpu0、gpu1……），
# 它是给 metrics.jsonl 和内部报告做归类用的，不是写给客户看的词。
# 一份中文报告里夹着一列 `mem` `pcie`，和 1.8.3 修掉的 `PCI`、`Present, OK`
# 是同一类：照抄内部写法。
METRIC_GROUP_CN = {
    "cpu": "处理器", "mem": "内存", "gpu": "显卡", "disk": "硬盘",
    "nic": "网卡", "pcie": "PCIe", "psu": "电源", "sys": "整机",
    # 1.9.0 起这三组在报告里有各自的小节（配置核对 / 平台设置 / 性能基准），
    # 一般不再混进「其他实测指标」那张大表。留在这里是为了两件事：
    # 认得出老 run-dir 的数据；以及**那一节没画出来的时候**（比如有 bench 指标
    # 却一条 bench 判定都没有），它们要退回这张大表而不是凭空消失 ——
    # 退回来的时候就要用得上这个中文名。
    # （内部报告用不着它：那份按内部分组键原样列，读者认得 conform / bench。）
    "conform": "配置核对", "platform": "平台设置", "bench": "性能基准",
}


def metric_group_cn(g):
    """内部分组键 -> 中文。认不出来的原样留着，绝不丢信息。"""
    s = (str(g) if g is not None else "").strip()
    if not s:
        return s
    base = METRIC_GROUP_CN.get(s.lower())
    if base:
        return base
    # 逐卡/逐路的分组带序号：gpu0 -> 显卡0、cpu1 -> 处理器1
    m = re.match(r"^([a-z]+)(\d+)$", s.lower())
    if m and m.group(1) in METRIC_GROUP_CN:
        return "%s%s" % (METRIC_GROUP_CN[m.group(1)], m.group(2))
    return s


# 指标名绝大多数本来就是中文（metric_add 的第二个参数），这里只收拾
# 混进英文的那几个。同样：认不出来的原样留着。
METRIC_KEY_CN = {
    "FAULTY卡数": "状态异常卡数",
}


def metric_key_cn(k):
    s = str(k) if k is not None else ""
    return METRIC_KEY_CN.get(s.strip(), s)


def nic_firmware_display(v):
    """`ethtool -i` 的 firmware-version -> 能放进「固件版本」那一格的写法。

    多数网卡给的是版本号（I350：`1.63, 0x800009fb, 1.791.0`），
    但一部分驱动给的是它**加载的固件文件名**，带着目录：
        r8169  ->  rtl_nic/rtl8168d-2.fw
    整串印进「固件版本」那一格，看着像我们把一条路径漏出去了。
    去掉目录只留文件名 —— 信息一点没少（这一格本来就是"这块卡在跑哪个固件"，
    出厂核对固件是否加载正是要看它），也不再像路径。

    只在"整串就是一个路径"时才动：含空格或逗号的多段版本号（I350 那种）
    一律原样留着，别拿一个 `/` 就去切人家的版本串。
    """
    s = clean(v)
    if s and re.match(r"^[^\s,]+/[^\s,]+$", s):
        return s.rsplit("/", 1)[-1]
    return s


def disk_serial_key(v):
    """硬盘序列号归一化，用来判断"这两行说的是不是同一块盘"。

    同一块盘从两条路读出来的序列号写法会有差别：lsblk / smartctl 直读的是
    `K48060R002933`，而阵列卡透传那条常常带补齐空格或大小写不同。
    只留字母数字并统一成大写，比较才稳。

    返回 None 表示这个序列号不可用于比对（空值、或 dmidecode 那类占位垃圾），
    **绝不能拿 None 去撞另一个 None**，否则两块都没有序列号的盘会被并成一块。
    """
    s = clean(v)
    if not s:
        return None
    key = re.sub(r"[^0-9A-Za-z]", "", s).upper()
    # 太短的不敢当唯一标识（见过阵列卡把序列号截成 "0"）
    return key if len(key) >= 4 else None


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

    # pad_l 是留给 Y 轴刻度文字的宽度。刻度用 text-anchor="end" 贴着 pad_l-8 画，
    # 所以它必须容得下最长的一条刻度（"28935MB" / "3000MHz" 这种 7 个字符）。
    # 58 太紧，1.8.0 转 PDF 时最左边一列被切掉了半个字。
    pad_l, pad_r, pad_t, pad_b = 70, 16, 16, 34
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

    # ⚠️ 颜色和字号必须写成 SVG 的**呈现属性**，不能只靠外部 CSS 的 .grid/.axis。
    #
    # 浏览器会把外部样式表级联进内联 SVG，所以只写 CSS 时 HTML 看着是好的；
    # 但 PDF 渲染器（WeasyPrint）不会 —— 它直接丢掉 `fill:`/`stroke:` 这类规则
    # （转换时会打 "Ignored fill:#8a9099"），于是刻度文字退回默认字号 16px，
    # 一下子撑爆 pad_l 预留的宽度，最左边被裁掉半个字。
    # 写成属性，两边都对；CSS 里那几条留着不冲突（属性优先级更低，但值一样）。
    GRID = 'stroke="#eef0f3" stroke-width="1"'
    AXIS = 'font-size="11" fill="#8a9099" font-family="sans-serif"'

    # 网格 + Y 轴刻度
    for i in range(5):
        v = lo + (hi - lo) * i / 4.0
        y = py(v)
        parts.append('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" class="grid" %s/>'
                     % (pad_l, y, width - pad_r, y, GRID))
        parts.append('<text x="%.1f" y="%.1f" class="axis" %s text-anchor="end">%s%s</text>'
                     % (pad_l - 8, y + 4, AXIS,
                        ("%.0f" % v) if abs(v) >= 10 else ("%.1f" % v), y_suffix))

    # X 轴标注（起止）
    parts.append('<text x="%.1f" y="%.1f" class="axis" %s>采样开始</text>'
                 % (pad_l, height - 10, AXIS))
    parts.append('<text x="%.1f" y="%.1f" class="axis" %s text-anchor="end">采样结束</text>'
                 % (width - pad_r, height - 10, AXIS))
    if y_label:
        parts.append('<text x="6" y="12" class="axis" %s>%s</text>' % (AXIS, E(y_label)))

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
        parts.append('<text x="%.1f" y="%.1f" class="legend" '
                     'font-size="11" fill="#333" font-family="sans-serif">%s</text>'
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
    # BMC 传感器表的输出 -> {传感器名(小写): 读数}
    # （说明写成 # 注释而不是 docstring：那条"文案里不许出现工具名"的守卫
    #  用 "[^"]*" 抠字符串，会把三引号 docstring 整块当成一个字符串扫，
    #  里面同时有中文和工具名就误报。见 test-hw-checks.sh 里的说明。）
    def ipmi_sensors(self):
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
                ("状态", dmi_status_cn(status)),
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

    def psu_ac_state_sdr(self, idx):
        """第二个来源：BMC 的**离散量**电源状态传感器（`ipmi-sdr.txt`）。

        不是所有 BMC 都有 `PSU1_Vin` 这种数值传感器。Supermicro X11DPG-QT
        只有离散量，1.8.2 的报告里「交流输入」那一列因此整列是破折号 ——
        而 sdr 里其实一直写着答案：

            PSU1_Status | BFh | ok | 10.8  | Presence detected, Failure detected, Power Supply AC lost
            PS1 Status  | C4h | ok | 10.92 | Presence detected
            PSU3_Status | 57h | ns | 10.24 | No Reading

        最后一栏是 IPMI Power Supply（传感器类型 08h）已置位的事件位。
        判读规则和 lib/collect.sh 的 psu_ac_state_sdr **必须一致**，
        那边的注释写了为什么是这个顺序（简单说：先看 "lost"，
        别拿 out-of-range 当判据 —— offset 5 明写着 "but present"；
        整串子串匹配，别按逗号切 —— offset 5 的名字自带逗号）。
        """
        pat = re.compile(r"^(psu|ps)_?\s*%s[\s_-]*status\b" % re.escape(str(idx)), re.I)
        for line in read_text(self.rawpath("ipmi-sdr.txt")).splitlines():
            cols = line.split("|")
            if len(cols) < 2 or not pat.match(cols[0].strip()):
                continue
            st = cols[-1].strip().lower()
            if "lost" in st:
                return "未接入"
            if "presence detected" in st:
                return "正常"
            return None                      # No Reading / Disabled = 读不到
        return None

    def psu_ac_state_any(self, idx):
        """数值传感器优先（那是直接量出来的），读不到才退到离散量。"""
        v = self.psu_ac_state(idx)
        return v if v is not None else self.psu_ac_state_sdr(idx)

    # 空的电源位，BIOS 照样报 `Present, OK` —— 6530 那台的 PSU4 就是：
    # 厂商/型号/序列号全是 "To Be Filled By O.E.M."、额定功率 0 W，状态却写着在位。
    # 列进表里客户一数电源就发现对不上（判定那边 lib/collect.sh 的
    # dmi_psu_list 用的是同一条规则，两边口径必须一致）。
    #
    # 三个条件**同时**成立才算幽灵，缺一不可（每条都对着一种会误杀真电源的写法）：
    #   1. Max Power Capacity 那行**显式存在**且值为 0
    #      —— 有些 BIOS 对真电源也不填额定功率，字段缺失不能当 0
    #   2. 身份字段（厂商/型号/序列号）**至少存在一个**
    #      —— 最小 DMI 只有 Location + Status，那是 BIOS 懒，不是空槽位
    #   3. 存在的身份字段**全是占位符**
    #      —— 同一台的 PSU3 厂商是占位符，但序列号和 2700W 都是真的
    #
    # ⚠️⚠️ **外加一条一票否决：BMC 说这一路进了电，就一定是真电源。**（1.9.4）
    #    上面三条只看得到 DMI。1.9.3 那台 6530 的 PSU4 三条全中，
    #    可 `ipmitool sdr` 上白纸黑字写着 `PSU4_Vin 220 Volts / PSU4_Pout 130 Watts`
    #    —— 那是一路正在给整机供电的真电源，只是 BIOS 没填它那一格。
    #    误杀的后果是三处口径全错：报告 1.8 电源表少一行、判定文案写「共 3 个在位」、
    #    而现场配置核对屏打的是「PSU 4/4 present」。
    #    判据和 report-policy 二-6 一致：**"读不出身份" ≠ "这个部件不存在"**。
    #    lib/collect.sh 的 psu_is_real 是同一条规则，两边必须一致。
    ID_KEYS = ("Manufacturer", "Name", "Model Part Number", "Serial Number")

    @staticmethod
    def psu_capacity(v):
        """DMI type 39 的 Max Power Capacity -> 能给客户看的额定功率，读不到就 None。

        这一格是 SMBIOS 里的一个 16 位整数。规范定义 `0x8000` 表示"未知"，
        dmidecode 遇到它会直接打 `Unknown`（走 clean() 就过滤掉了）。
        **但填 `0xFFFF` 的 BIOS 不在少数** —— Supermicro X11DPG-QT 就是，
        dmidecode 照实打成 `65535 W`，报告上于是写着「额定功率 65535 W」。
        那不是电源有 65 千瓦，那是 BIOS 这一格没填。

        判据不写死 65535，而是卡一个物理上说得通的区间：服务器电源额定
        几十瓦到几千瓦，一台机器上不会有 0 W 也不会有 10 kW 的模块。
        区间外的一律当"没读到"，宁可这一格空着，也不能让客户拿着一个
        荒唐的数字回来问。
        """
        s = clean(v)
        if not s:
            return None
        m = re.match(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*W\s*$", s, re.I)
        if not m:
            return s                      # 不是"数字 + W"的写法，原样留着
        return s if 0 < float(m.group(1)) < 10000 else None

    @classmethod
    def _psu_is_phantom(cls, p):
        cap = p.get("Max Power Capacity")
        if cap is None:
            return False
        try:
            if float(re.sub(r"[^0-9.]", "", cap) or 0) > 0:
                return False
        except ValueError:
            return False
        present = [k for k in cls.ID_KEYS if k in p]
        if not present:
            return False
        return not any(clean(p.get(k)) for k in present)

    def psus(self):
        out = []
        for i, b in enumerate(dmi_blocks(self.dmi, "System Power Supply"), 1):
            p = b["props"]
            loc = clean(p.get("Location")) or clean(p.get("Name")) or ("PSU%d" % i)
            m = re.search(r"\d+", loc)
            # 幽灵槽位不列 —— 但 BMC 读到这一路进电时它就不是幽灵（见 ID_KEYS 上面）
            if (self._psu_is_phantom(p)
                    and self.psu_ac_state_any(m.group(0) if m else i) != "正常"):
                continue
            out.append(OrderedDict([
                ("位置", loc),
                ("厂商", clean(p.get("Manufacturer"))),
                ("型号", clean(p.get("Model Part Number"))),
                ("序列号", clean(p.get("Serial Number"))),
                ("额定功率", self.psu_capacity(p.get("Max Power Capacity"))),
                ("交流输入", self.psu_ac_state_any(m.group(0) if m else i)),
                ("状态", dmi_status_cn(p.get("Status"))),
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

    def disk_stress_ran(self):
        """现场这一轮到底跑没跑硬盘压测。

        99% 的情况下现场是跳过的（客户不让往盘里写破坏性数据），跳过时
        `stress_disk` / `verify_smart` 这两项以及所有和"硬盘压测"沾边的字段
        整个不进客户报告 —— 一行「SKIP 硬盘压力测试 现场选择跳过」只会让客户
        以为我们偷工减料，而跳过恰恰是客户自己的选择。

        判据取 results.jsonl 里 stress_disk 的真实状态，**不看 meta 的 budget**：
        老的 run-dir 里 disk_secs 可能是"候选时长"，跳过了也非零。
        """
        for r in self.results:
            if r.get("id") == "stress_disk":
                return r.get("status") != "SKIP"
        return False

    def disks(self, show_stress_col=True):
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
        # 操作系统看得见的盘，按序列号记一份索引。
        #
        # 阵列卡跑 JBOD / 直通模式时，同一块物理盘**既有 /dev 节点、又能被阵列卡
        # 逐块读到**，于是下面那一圈会把它当成"阵列卡后面另一块盘"再列一次 ——
        # 1.7.8 现场就是这样：一块 FORESEE 128GB SSD（序列号 K48060R002933）
        # 在报告里出现了两行，客户看到的是"这台机器有两块盘"。
        #
        # RAID 模式下不会重复，那是因为操作系统看到的是**虚拟盘**（型号
        # AVAGO MR9361-16i，序列号是阵列卡自己编的），和后端物理盘本来就是
        # 两个不同的东西，两行都该在。所以判据只能是序列号，不能是"有没有阵列卡"。
        os_serial_row = {}
        # 后面挂着阵列卡物理盘的那些块设备名（smart 文件名形如 sda-pd0.norm.json）
        vd_names = set(vd for vd, _n in self.raid_pd_keys())
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
            # 这块"盘"其实是阵列卡做出来的逻辑盘（RAID 模式下操作系统看到的就是它）。
            #
            # 判据要两个条件同时成立，缺一不可：
            #   1) 它后面挂着阵列卡的物理盘
            #   2) 它自己读不出 SMART
            # 只看第 1 条会把 JBOD/直通的真盘也误判成逻辑盘 —— 直通时物理盘同样
            # 有 pd 文件，但它自己的 SMART 是读得出来的。
            is_vd = (name in vd_names) and (sm.get("smart_passed") is None)

            # 逻辑盘没有"转不转"，也没有自己的温度。
            # lsblk 对 MegaRAID 逻辑盘默认报 rota=1，照抄就会在报告上写"机械盘"——
            # 而它背后可能全是 SSD。温度那格同理，读出来的 0°C 是个假数。
            if is_vd:
                media = "阵列卡逻辑盘"
                temp = None
            else:
                media = "机械盘" if d.get("rota") else "固态盘"
                temp = (("%s°C" % smp.get("temperature_c"))
                        if smp.get("temperature_c") is not None else
                        (("%s°C" % sm.get("temperature_c"))
                         if sm.get("temperature_c") is not None else None))

            out.append(OrderedDict([
                ("设备", path),
                ("型号", clean(sm.get("model")) or clean(d.get("model"))),
                ("序列号", clean(sm.get("serial")) or clean(d.get("serial"))),
                ("固件", clean(sm.get("firmware"))),
                ("容量", human_bytes(d.get("size") or sm.get("capacity_bytes"))),
                ("接口", ("阵列卡" if is_vd else (d.get("tran") or "—"))),
                ("介质", media),
                ("当前温度", temp),
                ("SMART健康", "正常" if sm.get("smart_passed") is True
                    else ("异常" if sm.get("smart_passed") is False else None)),
            ]))
            # 没跑硬盘压测就整列不出现 —— 一列全是"否"等于在报告上写
            # "我们没测"，而那是客户自己选的，不该让他反过来怀疑我们
            if show_stress_col:
                out[-1]["本次压测"] = "是" if path in tested else "否"

            sn = disk_serial_key(out[-1]["序列号"])
            if sn:
                os_serial_row[sn] = out[-1]

        # 阵列卡后端的物理盘。它们没有自己的 /dev 节点，所以上面按 lsblk 那一圈
        # 扫不到 —— 但客户买的正是这些盘，报告里必须有。
        for vd, n in self.raid_pd_keys():
            sm = read_json(self.rawpath("smart-pre", "%s-pd%s.norm.json" % (vd, n)), {})
            smp = read_json(self.rawpath("smart-post", "%s-pd%s.norm.json" % (vd, n)), {})
            if not sm:
                continue
            # 直通/JBOD：这块盘上面已经作为 /dev/sdX 列过了，不能再列一行。
            # 把已有那行的"接口"补成阵列卡直通即可 —— 客户既知道盘只有一块，
            # 也知道它是挂在阵列卡后面的。
            sn = disk_serial_key(clean(sm.get("serial")))
            if sn and sn in os_serial_row:
                os_serial_row[sn]["接口"] = "阵列卡直通"
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
            ]))
            if show_stress_col:
                out[-1]["本次压测"] = "—"
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
                ("固件版本", nic_firmware_display(grab(drv, "firmware-version"))),
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
    RAID_PCI_RE = re.compile(r"RAID bus controller|Serial Attached SCSI|MegaRAID", re.I)

    def raid_pci_models(self):
        """lspci 里认到的阵列卡 / HBA -> [(BDF, 型号名), ...]，按 lspci 的顺序。

        **型号这一列必须有值。** 现场按报告备件、换卡，型号空着就可能装错。
        只要卡还在 PCI 总线上，这条路就一定拿得到名字 —— 不依赖任何厂商工具。
        """
        out = []
        for line in read_text(self.rawpath("lspci.txt")).splitlines():
            if not self.RAID_PCI_RE.search(line):
                continue
            m = re.match(r"^([0-9a-f]{2,4}:?[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f])\s", line, re.I)
            bdf = (m.group(1).lower() if m else "")
            name = line.split(":", 2)[-1].strip()
            # 去掉尾巴上的 [1000:005d] (rev 02)：那串 ID 对客户没意义
            name = re.sub(r"\s*\[[0-9a-f]{4}:[0-9a-f]{4}\].*$", "", name, flags=re.I).strip()
            if name:
                out.append((bdf, name))
        return out

    # 厂商工具给的 `PCI Address = 00:28:00:00` -> lspci 的 `28:00.0`
    #
    # 四段是 域:总线:设备:功能，**总线那段是十六进制**（同一份输出里
    # `Bus Number = 40` 是十进制的 0x28，两边对得上）。多卡机器上靠它把
    # 控制器和 lspci 的条目一一对上，比按出现顺序配对可靠 ——
    # 顺序配对在「lspci 认到 2 张卡、工具只认得其中 1 张」时会串行。
    @staticmethod
    def _storcli_bdf(addr):
        if not addr:
            return ""
        p = [x.strip() for x in str(addr).split(":")]
        if len(p) != 4:
            return ""
        try:
            return "%s:%s.%d" % (p[1].lower(), p[2].lower(), int(p[3], 16))
        except ValueError:
            return ""

    # 某个控制器上配了几个逻辑盘。
    #
    # 「没配逻辑盘」和「读不到」是两回事，必须分开：前者是这台机器的事实
    # （卡跑直通/JBOD、盘直连就是这样），后者是我们没数据。
    # 读不到回 None，那一列留空 —— 别把"没查到"写成"没有"。
    #
    # ⚠️ 这段说明写成 # 注释而不是 docstring 是有原因的：
    #    tests/test-hw-checks.sh 的客户文案守卫用 `grep -oE '"[^"]*"'` 取引号串，
    #    三引号 docstring 会被当成一个巨大的字符串整块取出来，里面只要同时有
    #    中文和厂商工具名就会误报。docstring 进不了报告，但守卫看不出来。
    def raid_vd_of(self, cnum):
        txt = read_text(self.rawpath("storcli-vd.txt"))
        if not txt.strip():
            return None
        for block in re.split(r"\n(?=Controller\s*=\s*\d+\s*$)", txt, flags=re.M):
            m = re.search(r"^Controller\s*=\s*(\d+)\s*$", block, re.M)
            if not m or m.group(1) != cnum:
                continue
            if re.search(r"No VD'?s have been configured", block, re.I):
                return "未配置"
            n = len(re.findall(r"^\s*\d+/\d+\s+\S+", block, re.M))
            return ("%d 个" % n) if n else None
        return None

    # ---------- 硬盘背板（机框） ----------
    #
    # 只进内部报告，**不进交付报告**。
    # 理由是现场提的：这个数拿不准的时候宁可不写 —— 客户看到"4 盘位"
    # 而机器实际是 8 盘位（背板不上报、或者只挂了一半），会当成缺件。
    # 内部留档另说，回档查"这台当初什么背板"时这一条最值钱。
    #
    # 两条独立来源，都拿不到就是拿不到，绝不猜：
    #   1) 阵列卡自己报的机框：storcli /cX/eall show all -> Number of Slots
    #   2) SES 背板：sg_ses -p cf -> "number of possible elements"
    #      （元件类型是 "Array device slot" 那一项才是盘位）
    # 纯直连背板（没有 expander、也不带 SES 芯片）两条都问不出来，
    # 这种情况下返回空，报告那边写"未检测到"。
    def backplanes(self):
        out = []

        # ---- 来源 1：阵列卡机框 ----
        for fn in ("storcli-enclosure.txt", "raid/perccli64-enclosure.txt"):
            txt = read_text(self.rawpath(*fn.split("/")))
            if not txt.strip():
                continue
            # 按 "Enclosure /cX/eY :" 切块
            for block in re.split(r"\n(?=Enclosure\s+/c\d+/e\d+\s*:)", txt):
                mh = re.search(r"Enclosure\s+(/c(\d+)/e(\d+))\s*:", block)
                if not mh:
                    continue
                slots = re.search(r"^\s*Number of Slots\s*=\s*(\d+)", block, re.M)
                if not slots:
                    continue
                etype = re.search(r"^\s*Enclosure Type\s*=\s*(.+?)\s*$", block, re.M)
                vend = re.search(r"^\s*Vendor Identification\s*=\s*(.+?)\s*$", block, re.M)
                prod = re.search(r"^\s*Product Identification\s*=\s*(.+?)\s*$", block, re.M)
                pd = re.search(r"^\s*Number of PDs\s*=\s*(\d+)", block, re.M)
                out.append(OrderedDict([
                    ("背板", "控制器 %s / 机框 %s" % (mh.group(2), mh.group(3))),
                    ("盘位数", slots.group(1)),
                    ("在位硬盘", pd.group(1) if pd else None),
                    ("类型", clean(etype.group(1)) if etype else None),
                    ("厂商", clean(vend.group(1)) if vend else None),
                    ("型号", clean(prod.group(1)) if prod else None),
                    ("来源", "阵列卡"),
                ]))

        # ---- 来源 2：SES 背板 ----
        d = self.rawpath("deep")
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if not f.startswith("sg_ses-cf-"):
                    continue
                txt = read_text(os.path.join(d, f))
                if not txt.strip():
                    continue
                # sg_ses -p cf 的元件行形如：
                #   Element type: Array device slot, subenclosure id: 0,
                #     number of possible elements: 12
                # 盘位只认 "Array device slot" / "Device slot" 两种类型，
                # 风扇、电源、温度传感器的数量不能混进来当盘位。
                slots = 0
                for m in re.finditer(
                        r"Element type:\s*(Array device slot|Device slot)\b"
                        r".*?number of possible elements:\s*(\d+)",
                        txt, re.S | re.I):
                    slots += int(m.group(2))
                if slots <= 0:
                    continue
                vend = re.search(r"vendor:\s*(.+?)\s*(?:product:|$)", txt, re.I | re.M)
                prod = re.search(r"product:\s*(.+?)\s*(?:rev:|$)", txt, re.I | re.M)
                out.append(OrderedDict([
                    ("背板", f[len("sg_ses-cf-"):].replace(".txt", "")),
                    ("盘位数", str(slots)),
                    ("在位硬盘", None),
                    ("类型", "SES"),
                    ("厂商", clean(vend.group(1)) if vend else None),
                    ("型号", clean(prod.group(1)) if prod else None),
                    ("来源", "SES"),
                ]))
        return out

    def backplane_summary(self):
        """把背板列表压成一句话：'12 盘位 x1'、'4 盘位 x3'。拿不到返回 None。"""
        bps = self.backplanes()
        if not bps:
            return None
        counts = OrderedDict()
        for b in bps:
            s = b.get("盘位数")
            if not s:
                continue
            counts[s] = counts.get(s, 0) + 1
        if not counts:
            return None
        return "、".join("%s 盘位 x%d" % (s, n) for s, n in counts.items())

    def raid(self):
        txt = read_text(self.rawpath("storcli-show.txt"))
        pci_models = self.raid_pci_models()
        pci_by_bdf = dict(pci_models)
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

                # 卡自己报的名字。Product Name 是正规商品名（OEM 卡上最准，
                # 比如 Dell 的 "PERC H730P Mini"）；有些固件只填 Model，
                # 而且填的是**人格/工作模式**而不是型号 —— 6530 那张 3108 自报的
                # 就是 "AVAGO JBOD"。所以它不能当唯一的型号来源。
                selfname = g("Product Name") or g("Model")
                serial = g("Serial Number")
                if not selfname and not serial:
                    continue          # storcli 输出顶部那个只有 Status 的块
                cnum = mc.group(1)
                key = (cnum, selfname or serial)
                if key in seen:
                    continue
                seen.add(key)

                # 固件版本：storcli 各版本键名不一样，长短两种都要认。
                # `/call show all` 的 Version 段用长键名（Firmware Package Build /
                # Firmware Version），`/cx show` 的紧凑输出用短键名（FW Package Build）。
                # 1.7.6 只认了短的，于是**真装了 storcli 的机器固件版本反而是空的** ——
                # raw/storcli-show.txt 里明明写着 24.21.0-0067，报告上是个破折号。
                fw = (g("Firmware Package Build") or g("FW Package Build")
                      or g("Firmware Version") or g("FW Version"))

                # 型号优先用 PCI 名（认得出、不会因为固件填了个模式名就变成 JBOD），
                # 拿不到才退回卡自报的。两个都留着，谁也不丢。
                bdf = self._storcli_bdf(g("PCI Address"))
                pci_name = pci_by_bdf.get(bdf)
                if not pci_name and len(cards) < len(pci_models):
                    pci_name = pci_models[len(cards)][1]   # 对不上地址时退回按顺序
                cards.append(OrderedDict([
                    ("控制器", "Controller %s" % cnum),
                    ("型号", pci_name or selfname),
                    ("控制器自报", selfname if selfname and selfname != pci_name else None),
                    ("序列号", serial),
                    ("固件版本", fw),
                    ("逻辑盘", self.raid_vd_of(cnum)),
                ]))
        if not cards:
            # 没有厂商工具、或者工具认不了这张卡（含卡本身是死的）—— 型号照样要有，
            # 走 PCI 那条路。「控制器」那格留空：这时候根本没有控制器编号可言，
            # 原先往里填的字面量 "PCI" 在客户眼里就是一格看不懂的英文，
            # 下面那圈会把整列去掉。
            for _bdf, name in pci_models:
                cards.append(OrderedDict([
                    ("控制器", None),
                    ("型号", name),
                    ("控制器自报", None),
                    ("序列号", None),
                    ("固件版本", None),
                    ("逻辑盘", None),
                ]))

        # 「控制器」「控制器自报」「逻辑盘」是补充信息，一整列都空的时候整列去掉 ——
        # 一列破折号只会让人以为漏采了。核心三列（型号/序列号/固件版本）
        # 无论如何都留着：空着本身就是信息（"查过了，没有"）。
        for col in ("控制器", "控制器自报", "逻辑盘"):
            if cards and all(not c.get(col) for c in cards):
                for c in cards:
                    c.pop(col, None)
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

                # 消费级 GeForce 卡没有序列号，nvidia-smi 给的是一个字面的 `0`
                # （只有数据中心卡才烧了真序列号）。印成「序列号 0」比空着更糟：
                # 客户会拿这个 0 去对货。全零一律当没读到。
                sn = grab("Serial Number")
                if sn is not None and not sn.strip("0 "):
                    sn = None

                out.append(OrderedDict([
                    ("型号", grab("Product Name")),
                    ("显存", grab_under("FB Memory Usage", "Total")),
                    ("序列号", sn),
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

    # ---------- 性能基准：逐盘顺序读写带宽 ----------
    def bench_disk_rows(self):
        """raw/bench/fio-<盘>-<read|write>.json -> 每块盘一行。

        文件名里带着盘符和方向，job 名带着测试口径（libaio_read_128k_32_1）——
        **job 名按业界通行的写法保留**（引擎_方向_块大小_队列深度_线程数），
        客户拿自己那份验收表来对照时省得再翻译一遍。
        """
        d = self.rawpath("bench")
        if not os.path.isdir(d):
            return []
        rows = OrderedDict()
        jobs_of = {}
        for fn in sorted(os.listdir(d)):
            m = re.match(r"^fio-(.+)-(read|write)\.json$", fn)
            if not m:
                continue
            dev, rw = m.group(1), m.group(2)
            for job in (read_json(os.path.join(d, fn), {}).get("jobs") or []):
                bw = (job.get(rw) or {}).get("bw")
                if not bw:
                    continue
                row = rows.setdefault(dev, OrderedDict([
                    ("硬盘", "/dev/%s" % dev), ("测试口径", None),
                    ("顺序读带宽", None), ("顺序写带宽", None),
                ]))
                # ⚠️ 「测试口径」是**逐个方向各一个** job 名
                # （libaio_read_128k_32_1 / libaio_write_128k_32_1），
                # 差别就在中间那个方向词上。写成 `row[...] = jobname` 的话，
                # 读写都跑了的那一行会被排在后面的写覆盖掉，于是「顺序读带宽」
                # 那一格的数字顶着一个 `_write_` 的口径 —— 客户拿它去和自己
                # 验收单上的 job 名对照时，对到的是另一个方向。
                jn = job.get("jobname")
                if jn and jn not in jobs_of.setdefault(dev, []):
                    jobs_of[dev].append(jn)
                row["测试口径"] = " / ".join(jobs_of[dev])
                row["顺序读带宽" if rw == "read" else "顺序写带宽"] = \
                    "%.1f MB/s" % (bw / 1024.0)
        out = list(rows.values())
        # 现场没确认破坏性写入时根本没跑写带宽，整列都是空的。
        # 留一列破折号等于在报告上写"我们没测"，而那是客户自己选的
        # （和 §11-26 硬盘压测那几项整个不进报告是同一把尺子）。
        if out and not any(r.get("顺序写带宽") for r in out):
            for r in out:
                r.pop("顺序写带宽", None)
        return out

    # ---------- 固件版本清单 ----------
    def firmware_rows(self):
        """一张表把这台机器上所有能读到的固件版本汇总起来。

        "同批次机器固件版本要一致"是很多出厂验收都有的一条，而它是**批次之间**
        比对的项，单台机器判不了。所以这里不判定，只把散在各处（BIOS 在 1.1、
        网卡在 1.6、硬盘在 1.4、显卡在 1.7）的版本号汇到一处 —— 拿两份报告
        并排一看就能对完，不用在报告里翻五个小节。
        """
        rows = []

        def add(part, where, ver):
            v = clean(ver)
            if v:
                rows.append(OrderedDict([("部件", part), ("位置 / 型号", clean(where) or "—"),
                                         ("版本", v)]))

        sysinfo = self.system()
        add("主板 BIOS", sysinfo.get("主板型号") or sysinfo.get("整机型号"),
            sysinfo.get("BIOS 版本"))

        # BMC 固件版本只有 `ipmitool mc info` 那一份，前面没有任何地方解析过
        mc = read_text(self.rawpath("ipmi-mcinfo.txt"))
        m = re.search(r"^\s*Firmware Revision\s*:\s*(.+)$", mc, re.M)
        if m:
            add("管理控制器（BMC）", "板载", m.group(1))

        for c in self.raid():
            add("阵列卡 / HBA", c.get("型号"), c.get("固件版本"))
        for n in self.nics():
            add("网卡", "%s（%s）" % (n.get("型号") or "—", n.get("接口名")),
                n.get("固件版本"))
        for dk in self.disks(show_stress_col=False):
            add("硬盘", "%s %s" % (dk.get("设备") or "", dk.get("型号") or ""),
                dk.get("固件"))
        # ⚠️ 只列显卡自己的显示 BIOS，**不列驱动版本**：驱动是我们这套测试环境
        #    带的，不是这台机器上的东西，混进"这台机器的固件清单"里会误导批次比对。
        for i, g in enumerate(self.gpus()):
            add("显卡显示 BIOS", "显卡%d %s" % (i, g.get("型号") or ""), g.get("BIOS版本"))
        return rows


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
/* ================= 打印 / 转 PDF =================
   注意：CSS 注释是会跟着 <style> 一起进 HTML 的，所以这里不能用
   「星号星号」那种强调写法 —— test-report-render 有一条守卫在查
   「客户报告里不许出现字面的星号」，写进来就会跑红（写这段时刚踩过）。

   PDF 是「拿这份 HTML 渲染出来的」，不是另画一份 —— 所以改了报告内容，
   PDF 自动跟着变，不存在"改了个东西 PDF 那边没覆盖到"。
   下面这些只在出 PDF 时生效，屏幕上看 HTML 完全不受影响。

   1.8.0 之前少了这几条，一份真实报告转出来是 179 页，
   而其中只有 8 页是报告本身，剩下 171 页全是原始日志 —— 而且有三处是坏的。
   这三处都是"HTML 上一切正常、只有转成 PDF 才露出来"的，
   断言抓不到，只能把 PDF 渲成图去看（见 architecture.md §11-33）。 */
@page{size:A4;margin:14mm 12mm}
@media print{
  body{font-size:11pt}
  thead{display:table-header-group}
  tr,.chart,.result-row,details{break-inside:avoid;page-break-inside:avoid}
  h2,h3{break-after:avoid;page-break-after:avoid}

  /* (1) 判定行不能用 flex。
        PDF 渲染器对 flex 只支持一半，详情一长就换行错位 ——
        实测那台坏卡的报告里，FAIL 徽章、"内核日志复查"、和详情三样
        叠印在同一个位置，糊成一团完全没法读。
        退回块级布局：徽章和名称一行，详情另起一行。 */
  .result-row{display:block}
  .result-row .rn{display:inline-block;min-width:0;margin-right:8px}
  .result-row .rd{display:block;margin-top:5px}
  .badge{margin-right:8px}
  .kv div{display:block}
  .kv b{display:inline-block}

  /* (2) 折叠块在 PDF 里保持折叠。
        HTML 里这 20 块原始日志默认是收起来的（点开才看），
        而 PDF 渲染器不管 open 属性、一律全展开 —— 于是 171 页日志。
        光 GPU 压测日志就 40 页进度百分比，内核日志 38 页同一句话。
        PDF 应该长得像你打开 HTML 时看到的样子，所以这里让它保持收起，
        并在标题后注明去哪看全文（.html 就在同一个目录里，什么都没丢）。 */
  details:not([open]) > *:not(summary){display:none !important}
  details:not([open]) > summary::after{
    content:"　（完整原文见同目录的 .html）";font-weight:400;
    color:var(--muted);font-size:12px}

  /* (3) 长行必须换行。
        pre 用的是 overflow-x:auto —— 浏览器里给你一根横向滚动条，
        而纸上没有滚动条：超出的部分直接冲出代码块背景、
        跑到页面外面去，右边一大截被切掉，看着像叠在一起。 */
  pre{white-space:pre-wrap;word-break:break-all;overflow:visible;max-height:none}
  .tablewrap{overflow:visible}
}
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
    # ⚠️ 整机结论永远看**全部**判定，不看下面过滤后的那份。过滤只影响"给客户看什么"，
    # 绝不能影响"这台机器合不合格"。
    overall = "FAIL" if ("FAIL" in statuses or no_results) else "PASS"

    # ---------------- 硬盘压测没跑时，把它那几项整个藏起来 ----------------
    #
    # 现场 99% 会跳过硬盘压测（客户不让往盘里写破坏性数据）。跳过时报告上留着
    # 一行「SKIP 硬盘压力测试 现场选择跳过（直接回车）」，客户看到的是
    # "他们少测了一项"，而那恰恰是客户自己的选择 —— 白白惹一次解释。
    # `verify_smart`（硬盘 SMART 复查）跟着一起藏：没跑压测的话它比的是
    # "空转前后"，单独留着反而更像凑数。
    #
    # ⚠️⚠️ **只藏 PASS / SKIP。WARN 和 FAIL 一律照常显示，一条都不许藏。**
    # 这是这个改动唯一不能犯的错：verify_smart 判 FAIL 的意思是这一轮盘上
    # 新增了坏道 —— 那和跑没跑硬盘压测无关（CPU/内存压测照样跑了十几分钟），
    # 是实打实的硬件问题，客户必须看到。藏掉它就等于把坏盘放出厂。
    # tests/test-report-render.sh 里有成对断言，mutate.sh 里有 disk-hide-fail 守着。
    DISK_STRESS_ROWS = ("stress_disk", "verify_smart")
    disk_ran = data.disk_stress_ran()
    if disk_ran:
        shown = results
    else:
        shown = [r for r in results
                 if not (r.get("id") in DISK_STRESS_ROWS
                         and r.get("status") in ("PASS", "SKIP"))]

    # ---------------- 判的是我们、不是机器的那些项 ----------------
    # 判断标准就一句：**这一项要是失败了，客户会在意吗？**
    #   collect_deep（扩展信息留档）失败 = 我们自己的存档薄了一点，
    #     客户拿到的报告一个字都不少 -> 不进客户报告
    #   collect_system（硬件信息采集）失败 = 报告里整块硬件清单都没了
    #     -> 客户当然在意，留着
    # 它的文案本身也是内部口径（"供日后追溯"），按 report-policy 二-1 就不该外发。
    #
    # 和上面硬盘那组不同，这条**无条件**藏：它任何状态下都不回答
    # "这台机器合不合格"。results.jsonl 和内部报告照常完整。
    #
    # `collect_fwts`（固件自检留档，1.9.2 加）同一把尺子，而且更极端一点：
    # ACPI 表上的告警在**完全正常**的服务器上极其常见（几乎每台都有若干条）。
    # 印给客户的结果是每台机器都刷一片黄，而且刷的是他看不懂、也无从处理的
    # 东西 —— 白白让人去找机器的毛病。它对**我们**有价值（同一批板子的 BIOS
    # 有没有共性问题），所以留在 results.jsonl 和内部报告里，不外发。
    #
    # `check_sn_consistency`（序列号一致性，1.9.4 加进来）同一把尺子。它查的是
    # **文书**对不对得上（主板 BIOS / BMC / 机身标签三处），不是硬件有没有毛病，
    # 而整机结论只回答后者。组装机上 BIOS 那一格本来就没人填，也没地方填 ——
    # 报告于是每台都挂一条黄的「主板 BIOS 未填写整机序列号，建议出货前补写」，
    # 客户读到的是"这台机器有问题"，而它连硬件都不是。
    # 整机序列号本身照常印在报告抬头和 1.1 整机那张表里，一个字没少；
    # 三处对不对得上留在内部报告里，那才是我们自己要盯的事。
    INTERNAL_ONLY_ROWS = ("collect_deep", "collect_fwts", "check_sn_consistency")
    shown = [r for r in shown if r.get("id") not in INTERNAL_ONLY_ROWS]

    # ---------------- 「我们没测到」的那些 SKIP ----------------
    #
    # `origin=self` 是产生结论的那一处自己打的标（lib/core.sh 的 result_add）：
    # **这条 SKIP 的原因在我们这边，不在被测机器上** —— 盘里没带那个基准/诊断
    # 程序，或者程序跑了没给出有效结果。
    #
    # 客户报告里印一行
    #     SKIP  显卡专项诊断  当前测试环境未包含显卡厂商诊断程序，本项未做核对
    # 他读到的不是"这台机器没问题"，是"这家供应商的工具箱是破的"。
    # 这一行对他做"收还是不收"的决定没有任何帮助，属于二-5「判的是我们、
    # 不是机器」那一类。1.9.3 印出去过，客户当面骂了一次。
    #
    # ⚠️ 三条边界，改之前先读：
    #   1. **只藏 SKIP。**origin 对别的状态没有意义，也不该有 —— 部件自己
    #      给的 FAIL（`validate_*` 判出"这颗 CPU 会算错"）是真故障，
    #      一条都不许藏（二-5-2 最后那段）。
    #   2. **判据是 origin，不是文案。**别改成"看看句子里有没有'未包含'" ——
    #      措辞一改那条判据就静悄悄失效，而失效的方向是漏出去。
    #   3. **"这台机器上没有可测的东西"不是 self。**「本机只安装了 1 张显卡，
    #      没有卡间互联可测」「未发现可测试的本机硬盘」讲的是被测机器的事实，
    #      客户有权知道哪些没测，照常印。那些地方不传 origin。
    shown = [r for r in shown
             if not (r.get("status") == "SKIP" and r.get("origin") == "self")]

    # ---------------- 判定按"读者关心的三件事"分组 ----------------
    #
    # 出厂验收表大多是分段写的：配置检查一段、性能数值一段、老化一段。
    # 以前报告把二十几条判定平铺成一张长列表，客户要自己在里面找哪条对应
    # 他单子上的哪一行。分成三段之后，报告的结构就和他手里那张表对得上。
    #
    # ⚠️ **分组只影响"印在哪一节"，不影响任何判定。**整机结论仍然只看
    # 全部判定里有没有 FAIL（上面那行 overall 已经算完了，在分组之前）。
    # 认不出来的 id 一律落到"压测与复查"那一段 —— 新加判定忘了登记的话，
    # 后果是它出现在一个不太贴切的小节里，而**不是从报告里消失**。
    #
    # `check_sn_consistency` 留在这张表里是**故意**的：它已经被
    # INTERNAL_ONLY_ROWS 滤掉了，这里登记的是"万一以后又放出来，它该印在哪一节"。
    # 从表里删掉的话，将来一放出来它就落到"压测与复查"那一段去了。
    #
    # `validate_*`（部件专项验证）没登记，所以落到"压测与复查"那一段 ——
    # 它们查的是"部件自己怎么说"（这颗 CPU 会不会算错、厂商诊断过不过），
    # 和压测同属"扛不扛得住 / 有没有毛病"，落在那一节是对的。
    CONFORM_IDS = (
        "check_dimm_uniform", "check_nic_uniform", "check_disk_uniform",
        "check_gpu_uniform", "check_gpu_ecc", "check_gpu_remap",
        "check_bios_profile", "check_virtual_dev", "check_sn_consistency",
        "check_mem_cap", "check_pcie_link", "check_nic_speed",
    )
    conform_rows = [r for r in shown if r.get("id") in CONFORM_IDS]
    bench_rows = [r for r in shown if str(r.get("id", "")).startswith("bench_")]
    other_rows = [r for r in shown
                  if r.get("id") not in CONFORM_IDS
                  and not str(r.get("id", "")).startswith("bench_")]

    # 计数按**客户实际看得到的那些**算，否则抬头写着"跳过 4 项"、
    # 下面只列得出 2 条，客户第一眼就会问剩下两条哪儿去了。
    # 「SMART 复查」这一项到底还在不在报告里 —— 上面 1.4 那句"详见下方…"
    # 得跟着它走，不能跟着 disk_ran 走：压测没跑但 SMART 复查判了 FAIL 时，
    # 那一项是留着的，指路的话就不该被删掉。
    smart_shown = any(r.get("id") == "verify_smart" for r in shown)
    shown_statuses = [r.get("status") for r in shown]
    n_pass = shown_statuses.count("PASS")
    n_fail = shown_statuses.count("FAIL")
    n_warn = shown_statuses.count("WARN")
    n_skip = shown_statuses.count("SKIP")

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
    warn_items = [r for r in shown if r.get("status") == "WARN"]
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
            # lscpu 给的是 `55 MiB (2 instances)` —— 一份中文报告里挂个
            # 英文尾巴，客户还得猜 instances 是什么。数字（总量和组数）不动。
            ("L3 缓存", re.sub(r"\s*\(\s*(\d+)\s+instances?\s*\)", r"（共 \1 组）",
                               cs.get("L3 cache") or "") or None),
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
    disks = data.disks(show_stress_col=disk_ran)
    if disks:
        # 后半句指的是下面那一项判定。它被藏掉时这句话就是指向一个
        # 报告里根本不存在的小节，所以跟着 smart_shown 走。
        A('<p class="sub">下表为本机硬盘的型号 / 序列号 / 固件 / 容量与 SMART 健康状态。%s</p>'
          % ("坏道类计数在压测前后的变化见下方「硬盘 SMART 复查」。" if smart_shown else ""))
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
    psus = data.psus()
    A(table(psus, "BIOS 未提供电源信息（部分机型不上报，可从 BMC 查看）"))
    # 有些主板（实测 Supermicro X11DPG-QT）DMI type 39 里除了位置和状态之外
    # 一格都没填 —— 厂商/型号/序列号是 dmidecode 的 <BAD INDEX>，额定功率是
    # 0xFFFF。我们把这些原样印出去过，客户拿到的是四格乱码和「65535 W」，
    # 每台机器都得口头解释一遍。现在改成显示破折号，并且把"为什么是破折号"
    # 直接写在表下面 —— 少一次解释，也少一次被当成漏采。
    if any(not any(p.get(k) for k in ("厂商", "型号", "序列号", "额定功率"))
           for p in psus):
        A('<p class="sub">本机 BIOS 未填写部分电源模块的厂商 / 型号 / 序列号 / 额定功率，'
          "表中显示为「—」。这几项由主板 BIOS 提供，读不到不代表电源有问题 —— "
          "电源是否在位、是否进电，以第二节「电源」那一项的结论为准。</p>")

    # 判定行的渲染，三个小节共用一份
    def result_list(rows):
        for r in rows:
            st = r.get("status", "SKIP")
            A('<div class="result-row r-%s">' % st)
            A('<span class="badge b-%s">%s</span>' % (st, st))
            A('<span class="rn">%s</span>' % E(r.get("name")))
            A('<span class="rd">%s</span>' % E_rich(r.get("detail")))
            A("</div>")

    def metrics_of(group):
        return [m for m in data.metrics if m.get("group") == group]

    def metric_kv(group):
        return kv_block(OrderedDict(
            (metric_key_cn(m.get("key")), m.get("value")) for m in metrics_of(group)))

    def metric_table(group, col="项目"):
        """把一组零散数值排成两列表格。

        值长的时候（内存两种颗粒型号并排、网卡型号加一长串固件版本）
        kv_block 那个网格会折得很难看 —— 表格反而稳。
        """
        return table([OrderedDict([(col, metric_key_cn(m.get("key"))),
                                   ("实测值", m.get("value"))])
                      for m in metrics_of(group)])

    # 这里以前还有一个 metric_value(key)：按 key 去 bench 组里捞一个数。
    # 它唯一的调用点是那张"实测数值汇总"表，表删掉之后函数留在了原地 ——
    # 一个谁也不调的函数看着像"这个数还有别的地方在用"，下次改 bench 组的
    # key 名时会有人特意去维护它。删掉重构后没人走的死路，和删那张表是一件事。

    # ⚠️ **性能基准这一节里没有"参考值 / 是否达标"这种东西，也不要再加回来。**
    #    这张盘是插上就跑、无人值守的，没有任何地方能拿到"这台机器应该达到多少"——
    #    凭空印一个数上去，等于我们替客户定了一个他没定过的标准，再拿它去说
    #    这台机器行不行。**报告里只有实测值**，谁做验收谁拿自己那份要求来对。
    #    tests/test-report-render.sh 里有一组断言钉着这一点。

    # ================================================================
    A("<h2>二、配置核对</h2>")
    A('<p class="sub">这一节回答的是「这台机器装的东西对不对、齐不齐、一不一致」。'
      "同规格的部件在同一台机器里应当型号一致、固件版本一致；"
      "整机序列号在主板与管理控制器两处应当对得上。</p>")

    conf_no = [0]

    def CSUB(title):
        conf_no[0] += 1
        return "<h3>2.%d %s</h3>" % (conf_no[0], title)

    A(CSUB("核对结论"))
    if conform_rows:
        result_list(conform_rows)
    else:
        A('<p class="muted">本次未产生配置核对结论。</p>')

    plat = metrics_of("platform")
    if plat:
        A(CSUB("平台关键设置"))
        A('<p class="sub">以下为操作系统读到的实际状态，可与订单要求逐项比对。'
          "这些是主板设置项，与硬件好坏无关。</p>")
        A(metric_kv("platform"))

    conf_m = metrics_of("conform")
    if conf_m:
        A(CSUB("核对依据的实测值"))
        A('<p class="sub">上面每一条结论所依据的原始读数，逐项列在这里。</p>')
        A(metric_table("conform"))

    fwrows = data.firmware_rows()
    if fwrows:
        A(CSUB("固件版本清单"))
        A('<p class="sub">同一批次的机器，这张表应当逐行一致。'
          "本表只汇总本机实测到的版本号，不做批次间比对。</p>")
        A(table(fwrows))

    # ================================================================
    # 性能基准：整段只在真的测了才出现。
    # 一台不做性能验收的机器，报告里多出一节全是 SKIP 的"基准"只会招来提问。
    #
    # ⚠️ 判据只能是**这一节真的画得出东西**（有判定行、或有逐盘带宽表），
    #    不能把 metrics_of("bench") 也算进来。bench 组的指标在这一节里
    #    **一格都不单独印** —— 每个数字都已经写在对应那条结论的句子里
    #    （见下面那段"不要再加实测数值汇总表"）。拿它当判据的话，
    #    出现"有 bench 指标、但一条 bench 判定都没有"的 run-dir 时，
    #    画出来的是一个只有标题和导语、底下什么都没有的空章节。
    bench_disk = data.bench_disk_rows()
    bench_shown = bool(bench_rows or bench_disk)
    if bench_shown:
        A("<h2>三、性能基准</h2>")
        A('<p class="sub">以下数值在机器空闲时测得（不与老化压测同时进行，'
          "否则数值会被互相干扰）。<b>本节只如实报出实测数值，不做合格与否的判断，"
          "也不影响整机结论</b> —— 不同用途对性能的要求各不相同，"
          "请对照贵方的验收要求核对这些数值。</p>")
        bench_no = [0]

        def BSUB(title):
            bench_no[0] += 1
            return "<h3>3.%d %s</h3>" % (bench_no[0], title)

        if bench_rows:
            A(BSUB("各项结论"))
            result_list(bench_rows)

        # ⚠️ **这一节不要再加"实测数值汇总"表或"测试条件"那一行。**
        # 1.9.0 两样都加过，然后都删了 —— 上面每条结论里已经写着那个数字、
        # 也写着它是怎么测的（问题规模多少阶、内存跑多少 MT/s 几个通道），
        # 底下再印一遍就是同一页上同一个数出现两次。那不是排版，是堆砌。
        #
        # 逐盘带宽是**另一组数**（结论那一行给不出逐盘明细），所以下面那张表留着。
        if bench_disk:
            # 标题和导语跟着**这张表里真有的方向**走。现场没确认破坏性写入时
            # 只测得到读，写那一列整个不画（见 bench_disk_rows）——
            # 标题却还写着"读写"，就是说得比测得多（report-policy 六-4）。
            #
            # ⚠️ 两个标题都写成**字面量**，不要拿 "硬盘%s带宽" 拼。
            #    lib/bench.sh 的判定文案里有一句「逐盘数值见下方「X」」指着它，
            #    tests/test-hw-checks.sh 靠"这两个字面量在两个文件里都得有"
            #    来对账；拼出来的字符串 grep 不到，那条对账就成了摆设。
            if any("顺序写带宽" in r for r in bench_disk):
                title, way = "硬盘顺序读写带宽", "顺序读写"
                safety = ""
            else:
                title, way = "硬盘顺序读带宽", "顺序读"
                # 只测了读的时候把"没写盘"这件事就地说清楚。客户看到「硬盘带宽」
                # 四个字，第一个念头就是"你们是不是把我盘上的数据冲了" ——
                # 等他打电话来问就晚了（lib/bench.sh 那条结论里也写了同一句）。
                safety = "本项全程只从硬盘读取、未向硬盘写入任何数据，盘上原有数据不受影响。"
            A(BSUB(title))
            A('<p class="sub">128KB 大块%s，逐块单独测量。%s'
              "「测试口径」一列是本次实际使用的参数，格式为"
              "「引擎_方向_块大小_队列深度_线程数」。</p>" % (way, safety))
            A(table(bench_disk))
        stress_h2 = "四、压力测试结果"
        raw_h2 = "五、原始日志"
        sub_prefix = 4
    else:
        stress_h2 = "三、压力测试结果"
        raw_h2 = "四、原始日志"
        sub_prefix = 3

    # ================================================================
    A("<h2>%s</h2>" % stress_h2)

    budget = meta.get("budget") or {}
    dur = OrderedDict([
        ("测试模式", profile_text(meta.get("profile"))),
        ("计划总时长", fmt_dur(meta.get("planned_secs"))),
        ("实际总耗时", fmt_dur(meta.get("elapsed_secs"))),
        ("CPU 压测时长", fmt_dur(budget.get("cpu_secs"))),
        ("内存压测时长", fmt_dur(budget.get("mem_secs"))),
    ])
    # 「硬盘压测时长 0秒」和那行 SKIP 是一回事，藏就一起藏干净
    if disk_ran:
        dur["硬盘压测时长"] = fmt_dur(budget.get("disk_secs"))
    dur["GPU 压测时长"] = fmt_dur(budget.get("gpu_secs"))
    # 性能基准跑在压测之前，占的是"实际总耗时"里的一段。不写出来的话，
    # 各项压测时长加起来对不上总耗时，客户会以为报告算错了。
    try:
        if int(budget.get("bench_secs") or 0) > 0:
            dur["性能基准耗时"] = fmt_dur(budget.get("bench_secs"))
    except (TypeError, ValueError):
        pass
    A(kv_block(dur))
    A('<p class="sub">CPU / 内存 / GPU 三项并发压测（互不占用彼此的时间，选多长测多长）。%s</p>'
      % ("硬盘单独测试，不与前三项同时进行，所以以上时长不能直接相加算总耗时。"
         if disk_ran else ""))

    # 二级编号动态生成：硬盘、GPU 没测的时候它们的小节整个不出现，
    # 写死编号就会出现 2.2 后面直接跳到 2.5 这种断号。
    # 一级编号也是动的（没跑性能基准时这一节是"三"不是"四"），所以用 sub_prefix。
    sub_no = [0]

    def SUB(title):
        sub_no[0] += 1
        return "<h3>%d.%d %s</h3>" % (sub_prefix, sub_no[0], title)

    A(SUB("各项结论"))
    result_list(other_rows)

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
    GPU_TEMP_WARN, GPU_TEMP_FAIL = thr("gpu_temp_warn", 90), thr("gpu_temp_fail", 95)
    # 显卡那两条线正常情况下是**卡自己报的**降频/关机温度（见 lib/gpu.sh）。
    # 报告里出现一条线，看的人第一个问题就是"这条线哪来的"，所以要说清楚。
    gpu_thr_src = ""
    try:
        if int((meta.get("thresholds") or {}).get("gpu_temp_from_card") or 0) == 1:
            gpu_thr_src = "，两条线均取自显卡自身上报的限值"
    except (TypeError, ValueError):
        gpu_thr_src = ""
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
        # 1.7.6 把「/ 硬盘」做成可选之后，这句拼出来是「覆盖CPU / 内存全部压测阶段」——
        # 中文和 ASCII 之间少了空格。文案是给客户看的，别留这种毛刺。
        A('<p class="sub">采样间隔 5 秒，覆盖 %s 全部压测阶段。'
          "读不到的项目（部分平台不提供 RAPL 或 CPU 温度驱动）不画图，不影响判定。</p>"
          % ("CPU / 内存 / 硬盘" if disk_ran else "CPU / 内存"))

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
            A('<p class="sub">逐卡温度峰值：%s（告警线 %s°C，判故障线 %s°C%s）</p>'
              % (E("、".join(peak_t)), GPU_TEMP_WARN, GPU_TEMP_FAIL, gpu_thr_src))
        A(svg_line_chart(temp_series, y_label="°C", y_suffix="°C"))
        if peak_p:
            A('<p class="sub">逐卡功耗峰值：%s</p>' % E("、".join(peak_p)))
        A(svg_line_chart(power_series, y_label="W", y_suffix="W"))
        A('<p class="sub">采样间隔 5 秒，数据取自显卡驱动的实时读数，'
          "覆盖 GPU 满载压测全程。</p>")

    # ---------------- fio ----------------
    fio = data.fio_results()
    if fio:
        A(SUB("硬盘性能数据"))
        A(table(fio))

    # ---------------- 指标 ----------------
    # 判的是我们、不是机器的指标，和 INTERNAL_ONLY_ROWS 同一把尺子：
    # 「失败压测项」是 stress-ng 内部子测试的失败计数，客户看到一个 0
    # 既不知道分母是多少，也不知道它和上面那条 PASS 有什么区别 ——
    # 有区别时上面那条就不会是 PASS。工程数据和内部报告里一个字段都没少。
    # 「mem / 测试工具」是内存压测程序的名字。客户不需要知道盘里带的是
    # stressapptest 还是 stress-ng —— 那是内部实现（§2-1「盘里带了什么工具」），
    # 而且这一格失败与否也不由它决定。metrics.jsonl 和内部报告里一个字段都没少。
    #
    # 显存那三格（1.9.0 新增）同一把尺子，但理由再深一层：
    #   「显存重映射不可纠正行」讲的是**这台机器出厂以来**被永久屏蔽过几行显存，
    #   和硬盘的通电时间/累计读写量是同一类 —— 它回答不了"这台机器合不合格"，
    #   客户看到一个孤零零的 5 只会问"那是什么，严重吗"。
    #   「显存 ECC 可纠正 / 不可纠正」则是那条结论的原始读数，
    #   而结论那句话（"累计出现 3 次可纠正的显存 ECC 错误，已被硬件自动纠正"）
    #   已经把数字连同它的含义一起说清楚了，表里再印一个裸数字就是同一个数
    #   在一页上出现两遍（report-policy 二-10）。
    #
    # ⚠️ 藏的只是**这张表里的裸数字**：check_gpu_ecc / check_gpu_remap 两条判定
    #    连同 WARN/FAIL 的全文照常出现在第二节，metrics.jsonl 和内部报告
    #    一个字段都没少。**任何 WARN/FAIL 一条都不许藏**那条红线没有被碰。
    INTERNAL_ONLY_METRICS = {
        ("cpu", "失败压测项"), ("mem", "测试工具"),
        ("gpu", "显存ECC可纠正"), ("gpu", "显存ECC不可纠正"),
        ("gpu", "显存重映射不可纠正行"),
    }
    # 逐卡的满载运行读数（1.9.0 新增）。这几个**不是**历史类数据，就是这一轮
    # 测出来的 —— 藏它们的理由只有一条：`check_gpu_load` 那条结论已经把同样的
    # 五个数**连同单位和上下文**写成了一句话
    #     「GPU0 平均频率 2520MHz（最低 2490MHz），平均功耗 430W，
    #       风扇最高 62%，距显卡自报的温度上限最少还有 8°C」
    # 表里再印一遍就是同一个数在一页上出现两遍（report-policy 二-10）。
    # 而且拆进表格之后单位就没了：一格「距温度上限最小余量 8」，客户既不知道
    # 是 8 度还是 8%，也不知道 8 是多是少 —— 那句话里写着「还有 8°C」。
    #
    # 卡号是变的（gpu0 / gpu1 / …），所以按**键名**过滤，不按 (组, 键)。
    #
    # ⚠️ 1.9.3 把这个键从「距降频阈值最小余量」改名成「距温度上限最小余量」
    #    （tlimit 归零的点是厂家标的最高工作温度，降频还要再高几度）。
    #    **旧名字留着**：拿一份 1.9.2 的 run-dir 重新出报告时，这一格
    #    还是要被挡在客户报告外面。
    INTERNAL_ONLY_GPU_LOAD_KEYS = {
        "满载最低频率MHz", "满载平均频率MHz", "满载平均功耗W",
        "峰值风扇转速%", "距温度上限最小余量", "距降频阈值最小余量",
    }

    def _internal_only(m):
        g, k = m.get("group"), m.get("key")
        if (g, k) in INTERNAL_ONLY_METRICS:
            return True
        return bool(re.match(r"^gpu\d+$", str(g or ""))) and k in INTERNAL_ONLY_GPU_LOAD_KEYS
    # 这几组在上面已经有各自的小节了，再进这张大表就是同一个数字印两遍。
    # **这是"挪位置"，不是"藏"**：platform / conform 各有一张表，
    # bench 的每个数字都写在对应那条结论的句子里。
    #
    # ⚠️ bench 只在那一节**真的画出来了**的时候才排除。整节没画时（没有任何
    #    bench 判定、也没有逐盘带宽表）还硬排除的话，那几个指标就两头不落 ——
    #    从报告里凭空消失。分组只该决定"印在哪一节"，不该决定"印不印"。
    OWN_SECTION_GROUPS = {"platform", "conform"} | ({"bench"} if bench_shown else set())
    shown_metrics = [m for m in data.metrics
                     if not _internal_only(m)
                     and m.get("group") not in OWN_SECTION_GROUPS]
    if shown_metrics:
        A(SUB("其他实测指标"))
        groups = OrderedDict()
        for m in shown_metrics:
            groups.setdefault(m.get("group"), []).append(m)
        rows = []
        for g, items in groups.items():
            for it in items:
                rows.append(OrderedDict([
                    ("分组", metric_group_cn(g)),
                    ("指标", metric_key_cn(it.get("key"))),
                    ("数值", it.get("value")),
                ]))
        A(table(rows))

    # ================================================================
    A("<h2>%s</h2>" % raw_h2)
    A('<p class="sub">以下为采集到的原始输出，完整文件保存在报告目录的 raw/ 子目录下。</p>')

    # 这里不嵌 smartctl 的原始输出（raw/smart-pre|post/ 里完整保留）：
    # 一块盘几百行属性，绝大部分和判定无关，嵌进来只会把报告撑成一堆看不懂的数字。
    # 硬盘的结论看 1.4 表格和 SMART 复查那一项。
    for title, rel in [
        ("主板与整机信息（BIOS 记录）", "dmidecode.txt"),
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
        ("显卡数据传输带宽测试", "bench/gpu-bandwidth.log"),
        ("显卡间互联带宽测试", "bench/gpu-p2p.log"),
        ("CPU 浮点算力测试", "bench/cpu-linpack.log"),
        ("内存带宽测试", "bench/mem-bandwidth.log"),
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
        print("run-dir does not exist: %s" % a.run_dir, file=sys.stderr)
        return 1

    data = Data(a.run_dir)
    out = a.out or os.path.join(a.run_dir, "report.html")

    try:
        doc = build_html(data)
    except Exception as e:  # 报告生成失败绝不能吞掉原始数据
        import traceback
        print("Report generator failed: %s" % e, file=sys.stderr)
        traceback.print_exc()
        return 1

    with open(out, "w", encoding="utf-8") as f:
        f.write(doc)

    print("Report written: %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
