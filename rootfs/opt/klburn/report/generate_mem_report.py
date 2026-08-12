#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# KLBurn 内存专用盘的报告生成器（KLBURN_EDITION=mem）
#
# 读 memtest.sh 落在 run-dir 里的原始数据，产出一个自包含的 HTML
# （CSS 内嵌、无外链、Windows 上双击就能看）。
#
# ================================================================
# 和整机盘那份 generate_report.py 的关系：**故意分开写，不共用。**
#
# 那份是 2600 行，因为它要渲染硬盘/网卡/显卡/电源/BMC/曲线图/原始日志。
# 这份要渲染的只有两块：平台认个大概、逐条内存的明细。把那份加一个
# "内存模式"开关的话，二十几处 if 会散在整个文件里，改哪边都得两边都验 ——
# 而这两种盘的报告以后只会越走越远。
#
# 共用的是**规矩**，不是代码：四态语义、措辞红线（不出现内部工具名、
# 不出现源码版本、能力缺失不判故障）、"一条判定都没有不算通过"。
# ================================================================
#
# 用法:
#     generate_mem_report.py --run-dir <run-dir> --out <报告.html>

import argparse
import base64
import html
import json
import os
import re
import sys
from collections import OrderedDict


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
    # HTML 转义。空值一律显示成一个破折号，而不是留白 ——
    # 留白看着像我们漏了一格，破折号说的是"这一格 BIOS 没填"。
    if s is None or s == "":
        return "—"
    return html.escape(str(s))


# 判定文案里用星号标重点，那是给写代码的人看的记号。原样进 HTML 的话，
# 客户看到的是字面的星号 —— 那句话恰恰是最该看清的一句。
# 在转义**之后**替换：html.escape 不碰星号，先转义再换标签是安全的。
_EMPH = re.compile(r"\*\*(.+?)\*\*", re.S)


def E_rich(s):
    return _EMPH.sub(r"<b>\1</b>", E(s))


# BIOS 没填时的各种写法。这份名单必须和 lib/core.sh 的 _serial_is_bogus、
# 整机盘报告生成器的 BOGUS 保持一致 —— 三处不一致的后果是现成的：
# 一边认、另一边不认，于是 "N/A" 被当成真的序列号印进报告。
# 一致性由 tests/test-mem-edition.sh 逐个值实测，不靠人记。
BOGUS = {
    "to be filled by o.e.m.", "not specified", "default string", "none",
    "unknown", "n/a", "na", "no dimm", "not present", "empty", "o.e.m.",
    "system manufacturer", "system product name", "system serial number",
    "0123456789", "<bad index>", "<out of spec>", "-", "--",
}
_BOGUS_PREFIX = "to be filled"


def clean(v):
    if v is None:
        return None
    s = str(v).strip()
    if not s or s.lower() in BOGUS or s.lower().startswith(_BOGUS_PREFIX):
        return None
    return s


def fmt_dur(sec):
    try:
        sec = int(sec)
    except (TypeError, ValueError):
        return None
    if sec < 60:
        return "%d 秒" % sec
    if sec < 3600:
        return "%d 分 %d 秒" % (sec // 60, sec % 60)
    return "%d 小时 %d 分" % (sec // 3600, sec % 3600 // 60)


# ============================================================ DMI 解析

def parse_dmi(text):
    # -> [{'type': 'Memory Device', 'props': OrderedDict}, ...]
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
            # 同一段里有重名字段时**只认第一个**：DDR5 的每条内存除了
            # "Size" 还会多打一行 "Volatile Size"，两者名字不同不冲突；
            # 但 "Speed" 之类在某些 BIOS 上会重复出现，后面那次往往是空的。
            if k.strip() not in cur["props"]:
                cur["props"][k.strip()] = v.strip()
    return blocks


def dmi_first(blocks, typename):
    for b in blocks:
        if b["type"] == typename:
            return b["props"]
    return {}


def dmi_all(blocks, typename):
    return [b["props"] for b in blocks if b["type"] == typename]


# 制造日期。**它不在专门的字段里** —— AMI 系 BIOS 把它塞在 Asset Tag 后面
# 的括号里，形如：
#     Asset Tag: P1-DIMMA1_AssetTag (date:22/51)
# 也就是 2022 年第 51 周。这一格是 SPD 里的模组生产日期，
# 查翻新条时很有用：一批一起买的正品，生产周次会挨得很近；
# 而拼凑来的翻新条日期往往乱七八糟，甚至出现晚于购入时间的日期。
#
# ⚠️ 只认 `date:YY/WW` 这个形状，认不出就当没有 —— 各家 BIOS 的 Asset Tag
#    格式不一样，硬猜的话会把别的内容当成日期印进报告。
#    Asset Tag 本身（`P1-DIMMA1_AssetTag`）是没有信息量的占位串，不渲染。
_DATE_RE = re.compile(r"date:\s*(\d{2})\s*/\s*(\d{2})")


def dimm_made_date(asset_tag):
    if not asset_tag:
        return None
    m = _DATE_RE.search(str(asset_tag))
    if not m:
        return None
    yy, ww = int(m.group(1)), int(m.group(2))
    # 周次 1~53 之外的一律不认（那说明这不是日期，或者 BIOS 填错了）
    if not (1 <= ww <= 53):
        return None
    return "20%02d 年第 %d 周" % (yy, ww)


# 总位宽 / 数据位宽 -> 有没有 ECC。
# 72/64 = 多出 8 位校验位，是 ECC 内存；64/64 = 没有 ECC。
# 服务器内存标称 ECC 却报 64/64，是很值得追一句的事，所以单独列一格。
def ecc_text(total_width, data_width):
    def bits(v):
        if not v:
            return None
        m = re.match(r"(\d+)", str(v))
        return int(m.group(1)) if m else None
    t, d = bits(total_width), bits(data_width)
    if t is None or d is None:
        return None
    if t > d:
        return "有（%d/%d 位）" % (t, d)
    return "无（%d 位）" % d


# ================================================================
# 序列号有两种长度，而且**和 DDR4/DDR5 无关**
# ================================================================
#
# 现场 2026-08-12 问：为什么有的机器报 `1BA3172A`（8 位），有的报
# `80AD01233537A7DDDD`（18 位）？是主板 BIOS 有问题吗？
#
# 不是。翻了仓库里七个版本的现场数据（`test_out/`），结论很清楚：
#
#   8 位   1BA3172A / 175B36BA / 2182C77A          Jintide C5218R、Xeon 6133、海光
#   18 位  80AD01233537A7DDDD / 80AD01220695DED917  EPYC 7542、Xeon Gold 6530
#
# **7542 是 DDR4，报的却是 18 位** —— 所以和内存代次没关系，是 BIOS 抄了
# 多少字节的差别：
#
#   SPD 里模组序列号那一格 JEDEC 只给了 **4 字节**（打出来 8 位十六进制）。
#   但 JEDEC 同时定义了一个 **9 字节的"模组唯一标识"**：
#       厂商 ID(2) + 生产地点(1) + 生产日期(2, BCD) + 序列号(4)
#   有的 BIOS 只抄后面那 4 字节，有的把整个 9 字节抄出来。
#
# 拿 7542 那台实测对过，三处完全自洽：
#   80 AD -> Bank 1 / 0xAD = SK Hynix，和同一块里的
#            `Module Manufacturer ID: Bank 1, Hex 0xAD` 一致
#   01    -> 生产地点
#   23 35 -> 2023 年第 35 周，和 `Asset Tag ... (date:23/35)` 一致
#   37A7DDDD -> 真正的 4 字节序列号
#
# 所以 18 位那种**信息更全**，不是出错。这里把它拆开：生产日期能直接从序列号
# 里拿到（不用再依赖 Asset Tag 那个 AMI 私有写法），厂商也能交叉核对一遍。
#
# ⚠️ **拆归拆，报告里显示的仍然是 BIOS 报出来的原串。** 那才是这台机器的
#    记录，也是拿去和别的工具、和厂商对账时唯一对得上的东西。
_UID_RE = re.compile(r"^[0-9A-Fa-f]{18}$")


def decode_module_uid(sn):
    """18 位那种序列号 -> {厂商, 产地, 日期, 4 字节序列号}；不是那种就返回 None。"""
    if not sn or not _UID_RE.match(str(sn).strip()):
        return None
    b = bytes.fromhex(str(sn).strip())
    y, w = _bcd(b[3]), _bcd(b[4])
    made = None
    # 周次 1~53 之外的说明这不是日期 —— 那这 18 位多半只是个长序列号，
    # 别硬把它当成 9 字节标识拆开（宁可不给，也不给一个编出来的日期）。
    if 1 <= w <= 53 and 0 <= y <= 99:
        made = "20%02d 年第 %d 周" % (y, w)
    else:
        return None
    return {
        "mfr": _jep106(b[0], b[1]),
        "loc": b[2],
        "made": made,
        "serial4": "".join("%02X" % x for x in b[5:9]),
    }


def size_to_mb(v):
    # "16 GB" / "16384 MB" / "No Module Installed" -> MB（认不出返回 0）
    if not v:
        return 0
    parts = str(v).split()
    if len(parts) < 2 or not parts[0].isdigit():
        return 0
    n = int(parts[0])
    unit = parts[1].upper()
    if unit == "GB":
        return n * 1024
    if unit == "MB":
        return n
    if unit == "TB":
        return n * 1024 * 1024
    return 0


# ============================================================ SPD 原片
#
# `dmidecode -t 17` 给的是主板读出 SPD 之后转述的那几格。这里读的是**条子
# 自己的芯片整片**，多出来的是：模组厂商 ID、生产地点、生产年/周、颗粒厂商、
# 以及一片 **厂商专属数据区**（JEDEC 不管里面放什么，各家自己用）。
#
# ⚠️ 现场问的"能不能读到标签上那串十几位的长号"，答案就落在这片专属区上：
#    标准序列号字段 JEDEC 只给了 **4 个字节**（所以 dmidecode 打出来是 8 位
#    十六进制，那不是截断，那就是全部）。长号如果有电子记录，只可能在专属区里。
#    **有没有取决于厂商** —— 这里的做法是把那片字节如实读出来摆着：
#    是可读文本就按文本显示，不是就按十六进制显示，绝不猜、绝不编。

# 各代 SPD 里这几格在哪。key -> (偏移, 长度)
_SPD_MAP = {
    0x0B: {  # DDR3
        "mfr": (117, 2), "loc": (119, 1), "year": (120, 1), "week": (121, 1),
        "serial": (122, 4), "part": (128, 18), "rev": (146, 2),
        "dram_mfr": (148, 2), "vendor": (150, 26),
    },
    0x0C: {  # DDR4
        "mfr": (320, 2), "loc": (322, 1), "year": (323, 1), "week": (324, 1),
        "serial": (325, 4), "part": (329, 20), "rev": (349, 1),
        "dram_mfr": (350, 2), "vendor": (353, 29),
    },
    0x12: {  # DDR5
        "mfr": (512, 2), "loc": (514, 1), "year": (515, 1), "week": (516, 1),
        "serial": (517, 4), "part": (521, 30), "rev": (551, 1),
        "dram_mfr": (552, 2), "vendor": (555, 30),
    },
}
_SPD_KIND = {0x0B: "DDR3", 0x0C: "DDR4", 0x12: "DDR5"}

# JEP106 厂商代码。只放服务器上真见得到的那些，认不出就原样报代码 ——
# 编一个名字出来比报代码糟糕得多。
_JEP106 = {
    (1, 0x2C): "Micron", (1, 0xAD): "SK Hynix", (1, 0xCE): "Samsung",
    (1, 0x4F): "Transcend", (1, 0x89): "Intel", (1, 0x98): "Kingston",
    (1, 0x94): "Smart Modular", (1, 0xB3): "IDT", (1, 0xC1): "Infineon",
    (2, 0xFE): "Elpida", (2, 0x9E): "Corsair", (3, 0x0B): "Nanya",
    (3, 0x25): "Kingmax", (4, 0xB0): "OCZ", (5, 0xCD): "G.Skill",
    (6, 0x04): "Netlist", (7, 0x9E): "Ramaxel", (9, 0xC8): "Innodisk",
}


def _bcd(b):
    return (b >> 4) * 10 + (b & 0x0F)


def _jep106(lo, hi):
    # 低字节是"跳过几个 bank"，高字节是 bank 内的厂商代码。
    #
    # ⚠️ **两个字节的第 7 位都是奇校验位，但处理方式不一样：**
    #    低字节要把校验位抠掉才是"跳过几个 bank"（0x80 -> 0 个 -> bank 1）；
    #    高字节**保持原样不要抠** —— JEP106 的厂商代码本来就是连校验位一起写的
    #    （三星 = bank 1 / 0xCE，抠掉就成了 0x4E，对不上任何一家）。
    #    dmidecode 打的也是原始字节（"Module Manufacturer ID: Bank 1, Hex 0xCE"），
    #    这里跟它保持一致，两边的值能直接对上。
    bank = (lo & 0x7F) + 1
    name = _JEP106.get((bank, hi))
    if name:
        return name
    # 认不出就原样报代码。编一个名字出来比报代码糟糕得多。
    return "Bank %d / 0x%02X" % (bank, hi)


def _ascii_field(raw):
    # SPD 里的文本字段用空格或 0x00 补齐，两种都要剥掉。
    s = "".join(chr(b) if 32 <= b < 127 else " " for b in raw)
    return s.strip() or None


def _vendor_blob(raw):
    # 厂商专属区。全 0x00 / 全 0xFF 就是"这家没往里写东西"，
    # 那种情况明说没有，而不是印一行 0000000000。
    if not raw or all(b == 0 for b in raw) or all(b == 0xFF for b in raw):
        return None, None
    text = _ascii_field(raw)
    # 至少连着 6 个可打印字符才当成文本 —— 否则是二进制，按十六进制给。
    printable = max((len(x) for x in re.findall(r"[!-~]{2,}", text or "")), default=0)
    hexs = " ".join("%02X" % b for b in raw)
    return (text if printable >= 6 else None), hexs


def parse_spd(blob):
    # blob: bytes。认不出返回 None（读了半片、平台给的是别的 eeprom，都可能）。
    if len(blob) < 128:
        return None
    kind_byte = blob[2]
    m = _SPD_MAP.get(kind_byte)
    if not m:
        return None

    def get(key):
        off, ln = m[key]
        if off + ln > len(blob):
            return None
        return blob[off:off + ln]

    ser = get("serial")
    if ser is None:
        return None
    year, week = get("year"), get("week")
    made = None
    if year and week:
        y, w = _bcd(year[0]), _bcd(week[0])
        if 0 < w <= 53 and 0 <= y <= 99:
            made = "20%02d 年第 %d 周" % (y, w)

    mfr, dram = get("mfr"), get("dram_mfr")
    vtext, vhex = _vendor_blob(get("vendor"))

    return {
        "kind": _SPD_KIND.get(kind_byte),
        # 和 dmidecode 一样按大端十六进制打，这样两边能直接对上
        "serial": "".join("%02X" % b for b in ser),
        "part": _ascii_field(get("part") or b""),
        "made": made,
        "mfr": _jep106(mfr[0], mfr[1]) if mfr and len(mfr) == 2 else None,
        "dram_mfr": _jep106(dram[0], dram[1]) if dram and len(dram) == 2 else None,
        "vendor_text": vtext,
        "vendor_hex": vhex,
    }


# ============================================================ 数据

class Data(object):
    def __init__(self, run_dir):
        self.run_dir = run_dir
        self.raw = os.path.join(run_dir, "raw")
        self.meta = read_json(os.path.join(run_dir, "meta.json"))
        self.results = read_jsonl(os.path.join(run_dir, "results.jsonl"))
        self.metrics = read_jsonl(os.path.join(run_dir, "metrics.jsonl"))
        self.dmi_mem = parse_dmi(read_text(os.path.join(self.raw, "dmidecode-memory.txt")))
        self.dmi_sys = parse_dmi(read_text(os.path.join(self.raw, "dmidecode-system.txt")))
        self.dmi_cpu = parse_dmi(read_text(os.path.join(self.raw, "dmidecode-cpu.txt")))

    # ---------- SPD 原片 ----------
    #
    # 读到几片、每片解出什么。**按 SPD 序列号和上面那张 DMI 表对齐** ——
    # i2c 地址和内存槽位没有可靠的对应关系（不同平台的映射不一样），
    # 而序列号两边是同一个来源（DMI 那格就是 BIOS 从 SPD 读的），
    # 拿它当连接键既准又不用猜。
    def spd_modules(self):
        out = []
        d = os.path.join(self.raw, "spd")
        if not os.path.isdir(d):
            return out
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".bin"):
                continue
            try:
                with open(os.path.join(d, fn), "rb") as f:
                    blob = f.read()
            except OSError:
                continue
            info = parse_spd(blob)
            if info:
                info["addr"] = fn[:-4]
                out.append(info)
        return out

    def metric(self, group, key):
        for m in self.metrics:
            if m.get("group") == group and m.get("key") == key:
                return m.get("value")
        return None

    # ---------- 平台：认个大概就够 ----------
    #
    # 用户要的是"知道是什么平台就行"。所以只有六格，一格都不多：
    # 整机型号 / 主板 / BIOS 版本 / 处理器型号 / 处理器路数 / 内存总量。
    # 机箱类型、BIOS 日期、内核版本、微码版本这些和"这条内存好不好"无关，
    # 不进这份报告。
    def platform(self):
        sysinfo = dmi_first(self.dmi_sys, "System Information")
        board = dmi_first(self.dmi_sys, "Base Board Information")
        bios = dmi_first(self.dmi_sys, "BIOS Information")
        cpus = [p for p in dmi_all(self.dmi_cpu, "Processor Information")
                if clean(p.get("Version"))]
        cpu_model = clean(cpus[0].get("Version")) if cpus else None
        if cpu_model:
            for junk in ("(R)", "(TM)", "(tm)"):
                cpu_model = cpu_model.replace(junk, "")
            cpu_model = re.sub(r"\s+", " ", cpu_model).strip()

        vendor = clean(sysinfo.get("Manufacturer")) or clean(board.get("Manufacturer"))
        model = clean(sysinfo.get("Product Name"))
        board_model = clean(board.get("Product Name"))

        return OrderedDict([
            ("整机厂商", vendor),
            ("整机型号", model),
            ("主板型号", board_model),
            ("BIOS 版本", clean(bios.get("Version"))),
            ("处理器", ("%d x %s" % (len(cpus), cpu_model)) if (cpus and cpu_model) else cpu_model),
            ("内存总容量", self.installed_gb_text()),
        ])

    # ---------- 逐条内存 ----------
    #
    # 这张表就是这份报告存在的理由：**按序列号能把某一条内存点出来**。
    # 空槽位不列（列出来只是把表撑长，没有任何信息）。
    def dimms(self):
        rows = []
        for p in dmi_all(self.dmi_mem, "Memory Device"):
            size = p.get("Size", "")
            if not size or "No Module Installed" in size:
                continue
            speed_cfg = clean(p.get("Configured Memory Speed")) or clean(p.get("Configured Clock Speed"))
            # 列的顺序按"拿它干什么"排：先是认条子的（槽位/容量/厂商/型号/
            # 序列号/生产日期），再是规格（Rank/ECC/频率）。
            # 查假条子的人从左往右读，前六列就够他做判断。
            sn = clean(p.get("Serial Number"))
            # 生产日期两条来路，都拿不到就留空：
            #   ① Asset Tag 括号里的 date:YY/WW（AMI 系 BIOS 的私有写法）
            #   ② 18 位序列号里自带的那两个字节（JEDEC 的 9 字节模组唯一标识）
            # 两处都有时优先 ①，因为那是 BIOS 明确标成日期的那一格。
            uid = decode_module_uid(sn)
            made = dimm_made_date(p.get("Asset Tag")) or (uid or {}).get("made")
            rows.append(OrderedDict([
                ("槽位", clean(p.get("Locator")) or clean(p.get("Bank Locator"))),
                ("容量", clean(size)),
                ("类型", clean(p.get("Type"))),
                ("厂商", clean(p.get("Manufacturer"))),
                ("型号", clean(p.get("Part Number"))),
                ("序列号", sn),
                ("生产日期", made),
                ("Rank", clean(p.get("Rank"))),
                ("ECC", ecc_text(p.get("Total Width"), p.get("Data Width"))),
                ("运行频率", speed_cfg),
                ("标称频率", clean(p.get("Speed"))),
            ]))
        return rows

    # 这台机器的 BIOS 报的是不是那种 18 位的"模组唯一标识"。
    # 是的话报告里要多说一句 —— 否则现场看到同一批内存在两台机器上
    # 序列号长度不一样，会以为哪台的 BIOS 坏了（真发生过）。
    def uid_breakdown(self):
        out = []
        for r in self.dimms():
            uid = decode_module_uid(r.get("序列号"))
            if uid:
                out.append(OrderedDict([
                    ("槽位", r.get("槽位")),
                    ("完整序列号", r.get("序列号")),
                    ("其中：厂商", uid["mfr"]),
                    ("生产地点", uid["loc"]),
                    ("生产日期", uid["made"]),
                    ("模组序号", uid["serial4"]),
                ]))
        return out

    # 哪几个序列号在这台机器上出现了不止一次。
    #
    # 判定本身在 lib/memcheck.sh 的 check_dimm_serial 里做（那一条判 FAIL）；
    # 这里重新算一遍**只是为了在表格里把那几行标出来** —— 一张十几行的表，
    # 光看数字很难发现"第 3 行和第 9 行的序列号是一样的"，
    # 而这恰恰是这份报告最该让人一眼看到的东西。
    def dup_serials(self):
        seen = {}
        for r in self.dimms():
            sn = r.get("序列号")
            if sn:
                seen[sn] = seen.get(sn, 0) + 1
        return set(sn for sn, n in seen.items() if n > 1)

    # ---------- 这一轮到底压没压、压了什么、压了多久 ----------
    #
    # 现场要的第一个问题就是"有没有真的做压力测试"。把它埋在判定行的
    # 一句话里不够 —— 那句话是给"出没出错"用的，不是给"做没做、做了多少"用的。
    # 所以单独一节，用**这一轮真的落下来的数字**填，一个都不硬编码：
    # 数字全部来自压测函数自己记的 metrics，报告这边只负责摆出来。
    #
    # ⚠️ `测试工具` 那一项**故意不渲染**：盘里用的是哪个程序属于内部实现，
    #    印给客户就是措辞红线里那条（工具名不进交付报告）。它照常留在
    #    metrics 里，内部要查随时查得到。
    def stress(self):
        row = next((r for r in self.results if r.get("id") == "stress_mem"), None)
        if row is None:
            return None, OrderedDict([
                ("是否执行", "否 —— 本轮未进行内存压力测试"),
            ])

        cap = self.metric("mem", "测试容量MB")
        pct = self.metric("mem", "占识别容量")
        cap_text = None
        try:
            gb = int(cap) / 1024.0
            cap_text = "%.1f GB（%s MB）" % (gb, cap)
            if pct:
                cap_text += "，占系统识别内存的 %s" % pct
        except (TypeError, ValueError):
            cap_text = cap

        # 计划时长和实际时长分开写：被 OOM 收掉的那一轮两者对不上，
        # 而那正是需要看得见的（那种情况判 WARN，不是内存故障）。
        planned = fmt_dur(self.meta.get("planned_secs"))
        actual = fmt_dur(self.meta.get("elapsed_secs"))

        d = OrderedDict()
        d["是否执行"] = "是"
        d["测试项目"] = "内存读写校验（对下方容量逐字节写入特定数据后回读比对）"
        d["覆盖容量"] = cap_text
        d["计划时长"] = planned
        d["实际时长"] = actual
        d["压测时段"] = "%s ~ %s" % (self.meta.get("start_time") or "—",
                                     self.meta.get("end_time") or "—")
        d["数据校验错误"] = self.metric("mem", "校验错误数")
        d["硬件异常"] = self.metric("mem", "硬件异常数")

        ce = self.metric("mem", "新增ECC可纠正条目")
        ue = self.metric("mem", "新增ECC不可纠正条目")
        if ce is not None or ue is not None:
            d["压测新增 ECC 错误"] = "可纠正 %s 条，不可纠正 %s 条" % (
                ce if ce is not None else "—", ue if ue is not None else "—")

        # 没跑满的那一轮必须写出来，别让"计划 150 秒"看着像真跑了 150 秒。
        full = self.metric("mem", "本次是否跑满")
        if full:
            d["是否跑满"] = full

        return row, d

    def installed_mb(self):
        total = 0
        for p in dmi_all(self.dmi_mem, "Memory Device"):
            total += size_to_mb(p.get("Size"))
        return total

    def installed_gb_text(self):
        mb = self.installed_mb()
        return ("%d GB" % (mb // 1024)) if mb else None

    def visible_gb_text(self):
        v = self.metric("mem", "系统识别MB")
        try:
            return "%d GB" % (int(v) // 1024)
        except (TypeError, ValueError):
            return None


# ============================================================ 渲染

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
h3{font-size:15px;margin:22px 0 8px;color:#333}
.sub{color:var(--muted);font-size:13px}
.kv{display:grid;grid-template-columns:repeat(auto-fill,minmax(310px,1fr));gap:2px 26px;margin:10px 0}
.kv div{display:flex;gap:8px;padding:5px 0;border-bottom:1px dotted var(--line)}
.kv b{min-width:96px;color:var(--muted);font-weight:400}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:13px}
th,td{border:1px solid var(--line);padding:7px 10px;text-align:left;vertical-align:top}
th{background:var(--panel);font-weight:600;white-space:nowrap}
.tablewrap{overflow-x:auto}
.sn{font-family:Consolas,Monaco,monospace;font-size:12.5px}
tr.dup td{background:#fdeaea}
td.dupcell{color:var(--fail);font-weight:700}
.duptag{display:inline-block;margin-left:8px;padding:1px 7px;border-radius:3px;
background:var(--fail);color:#fff;font-size:11px;font-weight:700;
font-family:"Microsoft YaHei","PingFang SC",sans-serif;letter-spacing:.5px}
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
.notice{padding:11px 14px;border-radius:5px;margin:12px 0;border:1px solid}
.notice-warn{background:#fff8e6;border-color:#f0c96b;color:#7a5200}
.notice-info{background:#eef4fd;border-color:#b9d0f0;color:#1f4d8f}
footer{margin-top:44px;padding-top:14px;border-top:1px solid var(--line);
color:var(--muted);font-size:12px}
@page{size:A4;margin:14mm 12mm}
@media print{
  body{font-size:11pt}
  thead{display:table-header-group}
  tr,.result-row{break-inside:avoid;page-break-inside:avoid}
  h2{break-after:avoid;page-break-after:avoid}
  .result-row{display:block}
  .result-row .rn{display:inline-block;min-width:0;margin-right:8px}
  .result-row .rd{display:block;margin-top:5px}
  .badge{margin-right:8px}
  .kv div{display:block}
  .kv b{display:inline-block}
  .tablewrap{overflow:visible}
}
"""


def table(rows, empty_note, dup_serials=frozenset()):
    if not rows:
        return '<p class="muted">%s</p>' % E(empty_note)
    cols = list(rows[0].keys())
    out = ['<div class="tablewrap"><table><thead><tr>']
    out += ["<th>%s</th>" % E(c) for c in cols]
    out.append("</tr></thead><tbody>")
    for r in rows:
        # 序列号重复的那几行整行标红。这是这份报告最该让人一眼看到的东西：
        # 序列号是厂商唯一分配的，两条正品撞不到一起。
        dup = r.get("序列号") in dup_serials
        out.append('<tr class="dup">' if dup else "<tr>")
        for c in cols:
            # 序列号和型号用等宽字体：这两列是拿来逐字核对的，
            # 比例字体下 O 和 0、I 和 1 分不清。
            cls = "sn" if c in ("序列号", "型号") else ""
            val = E(r.get(c))
            if dup and c == "序列号":
                cls = (cls + " dupcell").strip()
                val += '<span class="duptag">与其它内存条重复</span>'
            out.append("<td%s>%s</td>" % ((' class="%s"' % cls) if cls else "", val))
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def kv_block(d):
    return '<div class="kv">%s</div>' % "".join(
        '<div><b>%s</b><span>%s</span></div>' % (E(k), E(v)) for k, v in d.items())


def build_html(data):
    meta = data.meta
    results = data.results
    dimms = data.dimms()

    statuses = [r.get("status") for r in results]
    n_pass = statuses.count("PASS")
    n_fail = statuses.count("FAIL")
    n_warn = statuses.count("WARN")
    n_skip = statuses.count("SKIP")

    # 一条判定都没有 != 全都通过。整机盘上是同一条规矩：
    # 判不出来就得说判不出来，绝不打绿色大字。
    no_results = len(results) == 0
    overall = "FAIL" if (no_results or n_fail > 0) else "PASS"
    # 「本轮作废」和「这条内存坏了」是两回事，措辞完全不同，所以要分开认。
    run_invalid = no_results or any(r.get("id") == "mem_no_data" for r in results)

    serial = meta.get("serial") or "UNKNOWN"

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
    # 抬头和标题都取自构建时钉进这张介质的配置，不写死在代码里。
    A("<h1>%s</h1>" % E(meta.get("report_title") or "内存专用测试报告"))
    head_bits = ["整机序列号 <b>%s</b>" % E(serial),
                 "测试时间 %s ~ %s" % (E(meta.get("start_time")), E(meta.get("end_time")))]
    d = fmt_dur(meta.get("elapsed_secs"))
    if d:
        head_bits.append("本轮耗时 %s" % E(d))
    A('<div class="sub">%s</div>' % " ｜ ".join(head_bits))
    A("</header>")

    # ---------------- 总结论 ----------------
    A('<div style="margin:18px 0 8px"><span class="verdict v-%s">%s</span>' % (overall, overall))
    A('<span style="margin-left:18px" class="sub">'
      "通过 %d 项 ｜ 失败 %d 项 ｜ 告警 %d 项 ｜ 跳过 %d 项</span></div>"
      % (n_pass, n_fail, n_warn, n_skip))

    # ⚠️⚠️ 这一句**必须紧贴结论，不许挪到下面任何一节里**。
    #
    # 这份报告只测了内存。一个孤零零的绿色 PASS，读报告的人会当成
    # "这台机器整机验收通过" —— 而处理器、硬盘、网卡这些本轮一项都没测。
    # 把"没测"包装成"通过"，比不做这个功能还糟。
    # tests/test-mem-edition.sh 有一条断言钉着这句话必须在。
    A('<div class="notice notice-info"><b>本报告仅针对内存。</b>'
      "本轮对本机安装的每一条内存做了信息登记与压力测试，并核对了压测前后的"
      "内存错误计数。<b>本机的处理器、硬盘、网卡、显卡等其它部件本轮均未测试，"
      "本报告不能作为整机验收依据。</b></div>")

    if run_invalid:
        # 措辞只说"这次没跑成"，不说机器有问题 —— 两码事。
        A('<div class="notice notice-warn"><b>本次测试未能正常完成，本报告无效。</b>'
          "<b>这不是内存故障</b> —— 请重新测试后以新报告为准。</div>")
    elif overall == "FAIL":
        A('<div class="notice notice-warn"><b>本机内存存在未通过项，不建议出货。</b>'
          "请查看下方标红的测试项详情，并按序列号定位到具体的内存条。</div>")

    # ---------------- 一、平台信息 ----------------
    A("<h2>一、平台信息</h2>")
    A('<p class="sub">仅用于说明这份内存清单来自哪一台机器，本轮未对以下部件做任何测试。</p>')
    A(kv_block(data.platform()))

    # ---------------- 二、内存明细 ----------------
    A("<h2>二、内存明细</h2>")
    installed = data.installed_gb_text()
    visible = data.visible_gb_text()
    summary = ["本机共装有 <b>%d</b> 条内存" % len(dimms)]
    if installed:
        summary.append("合计 <b>%s</b>" % E(installed))
    if visible:
        summary.append("系统实际识别 <b>%s</b>" % E(visible))
    A("<p>%s。</p>" % "，".join(summary))
    dups = data.dup_serials()
    # ⚠️ 这一句要在表格**前面**：读者是先看到警告再看表，不是先看完一屏
    #    数字再回过头来找哪里不对。
    if dups:
        A('<div class="notice notice-warn"><b>下表中标红的内存条，序列号互相重复。</b>'
          "内存条的序列号写在条子自身的存储芯片里，由厂商唯一分配，"
          "<b>两条正品内存不可能出现相同的序列号</b>。"
          "出现重复说明这些内存条的出厂信息被改写过，属于翻新或假冒产品。</div>")
    A(table(dimms, "未能从主板 BIOS 读取到任何一条内存的明细信息。", dups))
    # 序列号读不到的那几条，同样要在表旁边说一句 —— 光看一格 — 看不出轻重，
    # 而这一项是有单独结论的（见下方测试结果那一节）。
    n_nosn = sum(1 for r in dimms if not r.get("序列号"))
    if n_nosn:
        A('<div class="notice notice-warn">下表中有 <b>%d</b> 条内存读不出序列号。'
          "内存条的序列号写在条子自身的存储芯片里，正常情况下都能读到；"
          "<b>读不出来说明这几条内存的出厂信息不完整或已被清除</b>，"
          "无法据此核对来源与真伪。</div>" % n_nosn)
    A('<p class="sub">表中显示为 — 的字段，表示主板未记录该项内容；'
      "其中序列号一项另有单独结论，见下方「测试结果」。"
      "运行频率是这条内存在本机实际运行的速率，标称频率是它自身支持的最高速率，"
      "两者不同通常是被同机的其它内存条或主板设置拉低的。</p>")

    # ---- 18 位序列号的拆解 ----
    #
    # 现场问过：为什么有的机器序列号是 8 位、有的是 18 位，是不是 BIOS 坏了。
    # 不是 —— 18 位那种是行业标准定义的「模组唯一标识」，把厂商、生产地点、
    # 生产日期和序列号连在一起写，**信息更全**。这里拆开摆出来，
    # 顺便把这件事在报告里说清楚，免得下次又被当成故障。
    uids = data.uid_breakdown()
    if uids:
        A("<h3>序列号里包含的出厂信息</h3>")
        A('<p class="sub">本机主板记录的内存序列号采用行业标准的「模组唯一标识」'
          "格式，即把厂商代码、生产地点、生产日期和模组序号连写在一起。"
          "拆开后如下（部分主板只记录其中的模组序号部分，因此在不同机器上"
          "看到的序列号长度可能不同，<b>两种都是正常的</b>）。</p>")
        A(table(uids, "—"))

    # ---------------- 二之二、内存条芯片记录 ----------------
    #
    # 上面那张表来自主板 BIOS 的转述；这一块来自**内存条自己的芯片**。
    # 多出来的是生产地点、颗粒厂商、以及厂商专属数据区 ——
    # 标签上那串十几位的长号如果有电子记录，只可能在专属区里。
    #
    # ⚠️ 读不到是常态（很多服务器平台不把这条通道开给操作系统），
    #    所以这一块**读到了才出现**，读不到时整块不印 —— 印一个空表格
    #    只会让人以为我们漏了什么。那条 SKIP 判定会在下面的测试结果里说明。
    spds = data.spd_modules()
    if spds:
        A("<h3>内存条芯片中的出厂记录</h3>")
        A('<p class="sub">以下内容直接读自每条内存自身的存储芯片，'
          "比主板转述的信息更完整，可用于核对来源与真伪。</p>")
        srows = []
        for s in spds:
            srows.append(OrderedDict([
                ("序列号", s.get("serial")),
                ("型号", s.get("part")),
                ("规格", s.get("kind")),
                ("模组厂商", s.get("mfr")),
                ("颗粒厂商", s.get("dram_mfr")),
                ("生产日期", s.get("made")),
                ("厂商追溯记录", s.get("vendor_text") or
                 (("（非文本内容）" + s["vendor_hex"][:47] + "…") if s.get("vendor_hex") else None)),
            ]))
        A(table(srows, "—"))
        # 这一句是给现场看的：为什么这里的序列号还是 8 位，而标签上是十几位。
        A('<p class="sub">说明：内存条电子记录中的序列号字段由行业标准规定为 '
          "4 字节（即 8 位十六进制），上表中显示的已是该字段的完整内容，没有截断。"
          "内存条标签上印刷的更长的编号是厂商自用的生产追溯号，"
          "是否写入芯片由厂商自行决定 —— 若已写入，会出现在上表的"
          "「厂商追溯记录」一列。</p>")

    # ---------------- 三、压力测试 ----------------
    #
    # 单独一节，回答"有没有真的压、压了什么、压了多久、压了多少容量"。
    # 数字全部来自压测函数自己记的 metrics，这里一个都不硬编码。
    A("<h2>三、压力测试</h2>")
    burn_row, burn_kv = data.stress()
    A(kv_block(burn_kv))
    if burn_row is None:
        A('<div class="notice notice-warn">本轮<b>没有</b>对内存做压力测试，'
          "上方的内存明细仅为信息登记。<b>本报告不能用于判断这些内存能否正常工作。</b></div>")
    else:
        A('<p class="sub">压力测试只能覆盖操作系统识别到的这部分内存；'
          "被固件保留的那一小部分不在覆盖范围内。</p>")

    # ---------------- 四、测试结果 ----------------
    A("<h2>四、测试结果</h2>")
    if not results:
        A('<p class="muted">本次运行没有产生任何判定结果。</p>')
    for r in results:
        st = r.get("status", "SKIP")
        A('<div class="result-row r-%s"><span class="badge b-%s">%s</span>'
          '<span class="rn">%s</span><span class="rd">%s</span></div>'
          % (st, st, E(st), E(r.get("name")), E_rich(r.get("detail"))))

    A('<p class="sub">判定说明：PASS 通过；FAIL 未通过；'
      "WARN 有需要确认的地方，但不影响使用；SKIP 本机不具备该项检测条件，"
      "不影响结论。</p>")

    # ---------------- 页脚 ----------------
    #
    # ⚠️ 页脚只写"这份报告是谁、什么时候、用哪一版介质出的"。
    #    源码版本、构建目录、盘里带了哪些程序一律不出现（那是内部实现）。
    A("<footer>")
    A("%s ｜ %s v%s ｜ 报告生成于 %s"
      % (E(meta.get("company_name")), E(meta.get("product_name") or "KLBurn-MEM"),
         E(meta.get("klburn_version")), E(meta.get("end_time"))))
    if meta.get("clock_suspect"):
        A("<br>注意：本机主板时钟可能不准确，报告中的时间仅供参考。")
    A("</footer></div>")

    title = "%s %s" % (meta.get("company_name") or "", meta.get("report_title") or "内存专用测试报告")
    return ("<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<title>%s</title><style>%s</style></head><body>%s</body></html>"
            % (E(title.strip()), CSS, "".join(H)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if not os.path.isdir(args.run_dir):
        sys.stderr.write("run-dir 不存在: %s\n" % args.run_dir)
        return 1

    data = Data(args.run_dir)
    htm = build_html(data)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(htm)
    sys.stderr.write("报告已生成: %s (%d 字节)\n" % (args.out, len(htm.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
