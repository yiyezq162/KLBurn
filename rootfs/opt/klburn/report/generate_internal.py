#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KLBurn 内部工程报告生成器

产出 <run-dir>/raw/INTERNAL_<机器名>.html —— **内部留档，不交付**。

和客户报告的分工，改代码前先记牢：

    报告名.html   随机器交付给客户。只回答"这台机器合不合格"，
                  措辞假设读者是采购/运维。通电时间、厂商管理工具、
                  git commit 这些一律不出现。规范见 docs/report-policy.md。

    本报告        只给我们自己看，比那份详细得多。回答的是另外两个问题：
                  「这台机器到底什么成色」和「我们这一轮测得干不干净」。

为什么放在 raw/ 里：客户要的是那个和目录同名的 .html，raw/ 整个目录本来就不外发；
文件名再加 INTERNAL_ 前缀，页面顶部再压一条红色横幅 —— 三道保险，防的是手滑。

它是**只读**的：只读 run-dir 里已经落好的数据，不采集、不判定整机结论。
整机结论永远以 results.jsonl 为准，这里只做"人看的时候会想知道"的二次解读。

================================================================
用词规范（1.7.0 起）—— 规范全文见 docs/report-policy.md 第七节
================================================================

这份报告的定位是**「我们自己复盘用的、更详细的那份数据」**，不是「问题清单」。
它一般不外发，但要按「万一发出去了也站得住」的标准写。

具体到措辞，只有一条规矩：
**描述「某项数据本轮没有」时，主语是那项数据或它的性质，不是我们。**

    ❌ 盘内没有 storcli64              ❌ 我们这一轮环境的缺口
    ❌ 本测试盘未包含 / 精简版          ❌ 某某项没测

    ✅ 阵列卡的固件版本与逻辑盘状态需由厂商管理工具（storcli64）读取，本轮未加载该工具
    ✅ 本轮采集范围说明

**但不许因此丢信息。** 原因要具体到"哪一类工具、哪一项数据因此没有"，
工程人员看完要知道下次怎么补齐 —— 「未加载该工具」比「盘内没有 storcli64」
信息量并没有变少，只是主语换了。TOOL_PROVIDES 那张表就是干这个的。

用法:
    generate_internal.py --run-dir <run-dir> [--out <html>]
    generate_internal.py --classify <raw 下的相对路径>     # 查这个文件属于哪一类
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
    kv_block, profile_text, read_json, read_text, scope_cn, scope_of,
    svg_line_chart, table,
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


# ============================================================ 工具 -> 它提供哪项数据
#
# 「本轮采集范围说明」那一节全靠这张表：只说"某个命令没跑成"对读报告的人没用，
# 他要知道的是**哪一项数据因此没有、以及那项数据本来该由什么来提供**。
#
# 每项： 命令名 -> (这项数据是什么, 它由什么提供)

TOOL_PROVIDES = {
    "storcli64":  ("阵列卡的固件版本与逻辑盘状态", "Broadcom / LSI MegaRAID 系列的厂商管理工具"),
    "perccli64":  ("阵列卡的固件版本与逻辑盘状态", "Dell PERC 系列的厂商管理工具"),
    "arcconf":    ("阵列卡的固件版本与逻辑盘状态", "Microchip / Adaptec 系列的厂商管理工具"),
    "ssacli":     ("阵列卡的固件版本与逻辑盘状态", "HPE Smart Array 系列的厂商管理工具"),
    "sas3ircu":   ("HBA（IT 模式）的控制器与物理盘状态", "LSI / Broadcom HBA 的厂商管理工具"),
    "nvidia-smi": ("显卡型号、显存与驱动版本，以及满载期间的温度/功耗读数",
                   "NVIDIA 驱动自带的管理程序"),
    "ipmitool":   ("BMC 传感器读数与事件日志", "IPMI 客户端"),
    "smartctl":   ("硬盘的 SMART 健康状态与属性表", "smartmontools"),
    "nvme":       ("NVMe 控制器参数与厂商扩展 SMART 页", "nvme-cli"),
    "lshw":       ("整机硬件树的留档快照", "lshw"),
    "sensors":    ("主板与 CPU 的温度传感器读数", "lm-sensors"),
    "ethtool":    ("网口的协商速率、驱动固件版本与光模块参数", "ethtool"),
    "dmidecode":  ("主板 / BIOS / CPU / 内存条的 DMI 信息", "dmidecode"),
    "ras-mc-ctl": ("逐条 DIMM 的 ECC 可纠正 / 不可纠正错误计数", "rasdaemon"),
    "edac-util":  ("内存控制器的 EDAC 错误计数", "edac-utils"),
    "mstflint":   ("迈络思网卡的固件版本与 PSID", "mstflint"),
    "lldpctl":    ("网口对端交换机与端口的 LLDP 邻居信息", "lldpd"),
    "fwupdmgr":   ("整机可升级部件的固件版本清单", "fwupd"),
    "turbostat":  ("逐核的频率 / 温度 / 功耗采样", "linux-tools 的 turbostat"),
    "sg_ses":     ("机框 / 背板（SES）的槽位与风扇状态", "sg3-utils"),
    "cpuid":      ("CPU 的特性位与步进信息", "cpuid"),
    "rdmsr":      ("CPU 的功耗 / 温度 / 降频寄存器读数", "msr-tools"),
    # 性能基准（1.9.0 新增）。这几个都不在 Ubuntu 源里、也不能重新分发，
    # 走 vendor/bench/ 放进去才带上；没放时对应的判定是 SKIP，不影响整机结论。
    "bandwidthTest": ("主机与显存之间、以及显存内部的数据传输带宽实测值",
                      "NVIDIA cuda-samples 里的 bandwidthTest（需放进构建期的 vendor/bench/）"),
    "p2pBandwidthLatencyTest":
                     ("显卡两两之间的双向互联带宽矩阵",
                      "NVIDIA cuda-samples 里的 p2pBandwidthLatencyTest（需放进构建期的 vendor/bench/）"),
    "xlinpack_xeon64": ("CPU 全核浮点算力（GFlops）",
                        "Intel Optimized LINPACK Benchmark（需放进构建期的 vendor/bench/）"),
    "mlc":        ("内存峰值读带宽（MB/s）",
                   "Intel Memory Latency Checker（需放进构建期的 vendor/bench/）"),
    "mlc_avx512": ("内存峰值读带宽（MB/s）",
                   "Intel Memory Latency Checker 的 AVX-512 版本（需放进构建期的 vendor/bench/）"),
    "fio":        ("硬盘的顺序 / 随机读写带宽与 IOPS", "fio"),
    "fwts":       ("固件（BIOS / UEFI / ACPI）自身的合规性检查结果",
                   "Firmware Test Suite（fwts，Ubuntu universe 里的包）"),
}


def tool_note(cmd):
    """-> (这项数据是什么, 由什么提供)；表里没有就照实说不知道，不编。"""
    base = os.path.basename((cmd or "").split()[0]) if cmd else ""
    if base in TOOL_PROVIDES:
        return TOOL_PROVIDES[base]
    return ("该命令的原始输出", base or "外部命令")


# ============================================================ raw/ 文件索引表
#
# 看报告的是**工程人员，不是开发人员**：`lspci-vv.txt` 这种名字他们不一定知道
# 是什么、什么时候该点开。所以索引不是一堆链接，是一张
# 「这是什么 / 什么时候该看它 / 怎么看」的表。
#
# ⚠️ **加了新采集就要在这里加一条。** 漏了会被
# tests/test-internal-report.sh 抓住 —— 那条测试把 rootfs 里所有 capture()
# 的目标文件名捞出来，逐个丢给 --classify，有一个落到 UNKNOWN 就跑红。
# 这是为了防"采了数据却没人知道它是什么"，那和没采一样。
#
# 每项： (正则, 分组, 这是什么, 什么时候该看它, 怎么看)
# 顺序有意义：从上往下第一个匹配上的算数，所以特例写在通例前面。

RAW_INDEX = (
    # ---------------- 本次运行 ----------------
    (r"^config-review\.txt$", "本次运行",
     "开机后现场核对过的那一屏配置（纯文本存档）",
     "想知道现场当时看到的是什么配置时",
     "和下面的配置清单对照，不一致说明采集和显示之间有偏差"),
    (r"^clock-sync\.log$", "本次运行",
     "联网校时的完整过程日志",
     "报告时间戳看着不对时",
     "看有没有成功连上 NTP；没联网时时间来自主板 RTC"),

    # ---------------- 系统 ----------------
    (r"^dmidecode\.txt$", "系统",
     "完整的 DMI/SMBIOS 表（主板、BIOS、CPU、内存、插槽全在里面）",
     "任何「这台机器到底是什么配置」的问题",
     "按 Handle 0x 分块看，每块开头是 DMI type 名"),
    (r"^dmidecode-system\.txt$", "系统",
     "厂商 / 整机型号 / 序列号 / BIOS 版本与日期",
     "核对整机身份、查 BIOS 该不该升级时",
     "直接看 System Information 和 BIOS Information 两块"),
    (r"^dmidecode-psu\.txt$", "系统",
     "电源模块的位置与在位状态（DMI type 39）",
     "电源判定出现 WARN/FAIL 时",
     "看每个模块的 Status；判 FAIL 还要结合 BMC 的 Vin 读数"),
    (r"^lshw\.(json|txt)$", "系统",
     "整机硬件树的留档快照",
     "想一眼扫完整机有哪些设备时",
     "留档用，判定逻辑一行都不读它；超时截断了也不影响别的项"),
    (r"^uname\.txt$", "系统", "本次运行的内核版本",
     "怀疑某个驱动是内核版本问题时", "对照 meta.json 里的介质构建日期"),
    (r"^lsusb\.txt$", "系统", "USB 设备清单",
     "查 BMC 虚拟媒体、外接设备时", "启动 U 盘本身也会出现在这里"),
    (r"^lspci\.txt$", "系统", "PCI 设备一行一个的清单（含厂商:设备 ID）",
     "查这台机器装了什么卡时", "网卡型号、阵列卡型号都是从这里按总线地址反查的"),
    (r"^lspci-vv\.txt$", "系统", "PCI 设备的完整配置空间信息",
     "卡的型号或链路速率对不上时", "搜 LnkSta 看实际协商速率，和同一设备的 LnkCap 比"),
    (r"^raid-bmc-note\.txt$", "存储",
     "「PCI 上没有阵列卡，而 BMC 为阵列卡预留的传感器也全无读数」这件事的留档",
     "报告写着「未安装阵列卡」、但你知道这台机器应该有卡时",
     "它分不开「本来没装」和「卡坏到 PCI 都枚举不到」，所以只留档、"
     "不进客户报告也不改结论 —— 看到它就去现场摸一把卡和 riser"),
    (r"^pcie-link\.txt$", "系统",
     "每个 PCIe 端点的额定链路、空闲快照、全程最好读数，以及它是**板载**还是插在**插槽**上",
     "想知道某个设备为什么没进（或进了）PCIe 链路那条判定时",
     "第二列 slot/onboard 就是判定范围：只有 slot 的降速才会报 WARN，"
     "onboard 的走线宽度是主板设计，只在这里留档。"
     "判定看的是 best 那两列（全程最好的一次），不是 idle 那两列；"
     "n= 是这台机器上这个设备采到了几条读数，n=0 时本项对它不作结论"),
    (r"^pcie-link-samples\.txt$", "系统",
     "整轮测试期间每 5 秒复读一次的 PCIe 链路读数，一行一条「设备 速率 宽度」",
     "怀疑某张卡的链路在测试过程中掉过档、或者想看它是什么时候回满的时候",
     "空闲时 N 卡会自己掉到 2.5GT/s 省电，一加载就回满 —— "
     "这个文件就是为了不再拿一次空闲快照当判据而加的（见 lib/collect.sh）"),
    (r"^deep/dmidecode-slots\.txt$", "系统", "所有 PCIe / 内存插槽的定义与在用状态",
     "查「这台机器还有几个空槽」、卡插在第几槽时", "看 In Use / Current Usage"),
    (r"^deep/dmidecode-(cache|array|oem)\.txt$", "系统",
     "CPU 缓存 / 内存阵列拓扑 / OEM 自定义字符串",
     "核对缓存容量、内存最大支持容量时", "留档为主"),
    (r"^deep/(cmdline|modules|mtrr|efibootmgr)\.txt$", "系统",
     "内核启动参数 / 已加载模块 / MTRR / EFI 启动项",
     "怀疑某个模块没加载、或者引导方式不对时",
     "cmdline 里能看到 nouveau 是不是被 blacklist 了"),
    (r"^deep/fwupd-devices\.(txt|json)$", "系统",
     "全机可升级部件的固件版本清单（BIOS、BMC、网卡、硬盘、背板……）",
     "核对一批机器的固件版本齐不齐、或者要查某个部件该不该升级时",
     "离线也能读到本机现有版本；只有「有没有新版」需要联网"),
    (r"^deep/journal-boot\.txt$", "系统",
     "本次开机的完整 systemd 日志",
     "上面几份都看不出问题、要从头翻的时候",
     "很长，先搜 error / fail / timeout 再回头看上下文"),

    # ---------------- CPU 与内存 ----------------
    (r"^(lscpu\.(txt|json)|cpuinfo\.txt|deep/lscpu-extended\.txt|deep/cpuid-microcode\.txt)$",
     "CPU 与内存",
     "CPU 型号、路数、核心/线程、微码版本、逐核拓扑",
     "核对配置、以及怀疑微码没打上时",
     "microcode 那一行和厂商发布的版本对一下"),
    (r"^numactl\.txt$", "CPU 与内存", "NUMA 节点划分与节点间距离",
     "多路机器上性能不对称时", "看每个 node 分到的内存是不是均等"),
    (r"^dmidecode-memory\.txt$", "CPU 与内存",
     "逐条内存的容量 / 厂商 / 颗粒型号 / 频率 / 插槽位置",
     "装机容量和系统识别容量对不上时，或者要查混插时",
     "按 Locator 对到具体插槽；Size 为 No Module Installed 的是空槽"),
    (r"^meminfo\.txt$", "CPU 与内存", "系统识别到的内存总量与可用量",
     "内存容量核对判 WARN 时", "MemTotal 是内核看到的，会比装机容量少一点"),
    # ↓ 内存专用盘（memtest.sh）读的 SPD 原片。DMI 那份是主板转述的，
    #   这份是从内存条自己的芯片上读下来的，多出生产地点、颗粒厂商、
    #   以及厂商专属数据区（标签上那串长追溯号如果有电子记录，就在那里面）。
    (r"^spd-decode\.txt$", "CPU 与内存",
     "内存条自身芯片（SPD）中记录的完整出厂信息，人可读版本",
     "查内存来源与真伪时，或者要看生产日期 / 颗粒厂商时",
     "和 dmidecode-memory 的那几格对一遍，对不上就是被改写过"),
    (r"^spd/.*\.bin$", "CPU 与内存",
     "内存条自身芯片（SPD）的原始二进制，一条一片",
     "怀疑内存条出厂信息被改写、或者要逐字节比对两条内存时",
     "两条内存的这份文件**不可能完全相同**，相同就是整片克隆"),
    # ↓ 1.10.1：上面两份读不到时，**这一份说明为什么读不到**。
    #   现场问过两次"能不能读到条子标签上那串十几位的长号"，而
    #   `decode-dimms` 对三种完全不同的原因都只回一句 No EEPROM found。
    (r"^spd-probe\.txt$", "CPU 与内存",
     "读 SPD 之前的环境诊断：驱动装上了没有、i2c 总线出来了没有、总线上挂了什么",
     "SPD 那两份没读到、要判断是我们的盘缺东西还是这台机器不开放这条通道时",
     "模块「没有」= 盘里缺驱动，能修；模块有、i2c 总线一条都没有 = SMBus 被 BIOS "
     "锁了或归 BMC 管；总线有、设备里没 eeprom = SPD 挂在 mux 后面或这一代要 spd5118"
     "（内核 6.10 才有，本盘 6.8，DDR5 属于这一类）"),
    # ↓ 内存专用盘（memtest.sh）单独采的一份。整机盘把 CPU 的 DMI 记录混在
    #   dmidecode.txt 里，那张盘不采整份，只单独取 type 4。
    (r"^dmidecode-cpu\.txt$", "CPU 与内存",
     "逐颗 CPU 的 DMI 记录（型号 / 插槽 / 核数）",
     "只想确认这台机器是什么平台、几路 CPU 时",
     "一个 Processor Information 段就是一路；Version 那行是型号"),
    (r"^(sensors\.(txt|json)|sensors-post\.txt|deep/sensors-raw\.txt)$", "CPU 与内存",
     "主板与 CPU 的温度 / 风扇 / 电压传感器读数（post 是压测后的）",
     "温度判定出现 WARN/FAIL、或者读不到温度时",
     "sensors-raw 是机器可读格式，好做前后对比"),
    (r"^deep/(interrupts|vmstat|zoneinfo)\.txt$", "CPU 与内存",
     "中断分布 / 虚拟内存统计 / 内存 zone 水位",
     "怀疑中断没打散、或者内存压测被 OOM 时",
     "interrupts 看各 CPU 列是不是均衡"),
    (r"^counters-(pre|post)\.txt$", "CPU 与内存",
     "压测前后的计数器快照：逐条 DIMM 的 ECC、逐核热节流、逐设备 PCIe AER",
     "内存 ECC / CPU 热节流 / PCIe 错误这三项判定出现 WARN 或 FAIL 时",
     "判的是 post 减 pre 的**差值**，不是绝对值；一台用过的机器带历史计数是正常的"),
    (r"^counters/ras-(mc-ctl|summary)-(pre|post)\.txt$", "CPU 与内存",
     "rasdaemon 给的人可读版 ECC 计数（按 DIMM 标签归位）",
     "ECC 判定报了某条内存，想看它到底在哪个插槽时",
     "判定不读这份，它只是给人看的；标签对应主板丝印的插槽名"),
    (r"^counters/edac-util-(pre|post)\.txt$", "CPU 与内存",
     "EDAC 的另一条路给出的内存错误计数",
     "ras-mc-ctl 那份读不到、想换个来源核对时",
     "不同平台上两者可用性不一样，互为备份"),
    (r"^deep/cpuid\.txt$", "CPU 与内存", "CPU 的特性位、步进与勘误相关标志",
     "怀疑某个指令集/特性没开、或者查勘误时", "lscpu 给不全的那些在这里"),
    (r"^deep/msr-.*\.txt$", "CPU 与内存",
     "直接读的 MSR 寄存器：封装能量、Tjmax、功耗墙",
     "怀疑 BIOS 限了功耗墙、或者想核对 Tjmax 时",
     "是十六进制原始值；AMD 平台 MSR 号不同，读不到很正常"),
    (r"^deep/powercap-tree\.txt$", "CPU 与内存",
     "内核 RAPL 功耗域（powercap）的目录清单",
     "怀疑报告里那条 CPU 封装功耗曲线不对时",
     "同一个 package 域在这棵树下有两条路径，1.8.3 之前两条都算了一遍、功耗翻倍"),
    (r"^stress/turbostat.*$", "CPU 与内存",
     "压测期间**逐核**的实际频率、C-state 占比、封装功耗与温度",
     "想知道满载时是不是所有核都跑满了、哪几个核在拖后腿",
     "只留档不参与判定 —— 它在不同平台上可用性差别很大"),

    # ---------------- 存储 ----------------
    (r"^smart-pre/.*\.norm\.json$", "存储",
     "压测前 SMART 的归一化字段（SATA/SAS/NVMe 统一成同一组键）",
     "要程序化对比前后差值时",
     "第六节那张「压测前 -> 压测后」的表就是拿它算的"),
    (r"^smart-post/.*\.norm\.json$", "存储",
     "压测后 SMART 的归一化字段",
     "同上", "和 smart-pre 逐字段比，任何一格变大都是硬伤"),
    (r"^smart-(pre|post)/.*\.dtype$", "存储",
     "这块盘是靠哪种设备类型（smartctl 的 -d）读通的，空文件表示自动识别",
     "某块盘的 SMART 或自检结果读不出来、想知道换哪个 -d 再试时",
     "发起自检、读自检结果都复用它 —— 三处各自再试一遍的话，判据迟早不一致"),
    (r"^smart-pre/.*\.(txt|json)$", "存储",
     "每块盘压测前的完整 SMART 输出",
     "要看某块盘出厂时的健康度、通电时间、寿命时",
     "重点看 Reallocated_Sector / Current_Pending_Sector / 介质错误"),
    (r"^smart-post/.*\.(txt|json)$", "存储",
     "每块盘压测后的完整 SMART 输出",
     "判定说「新增坏道」时核对",
     "和 smart-pre 逐属性对比，只看**新增**的那部分"),
    (r"^deep/smart-x-.*\.txt$", "存储",
     "扩展 SMART（完整属性表 + 自检日志 + 错误日志）",
     "普通 SMART 看不出名堂、要往深里查时",
     "阵列卡后面的物理盘也在这里，key 带 -pdN 后缀"),
    (r"^deep/nvme-(id-ctrl|smart-log|error-log)-.*\.txt$", "存储",
     "NVMe 控制器参数 / 厂商 SMART 日志 / 错误日志",
     "NVMe 盘出现介质错误或温度异常时",
     "id-ctrl 里有厂商 OUI 和支持的日志页"),
    (r"^(nvme-list\.(json|txt))$", "存储", "NVMe 盘清单",
     "核对装了几块 NVMe、命名空间怎么分的", "和 lsblk 对照"),
    (r"^(lsblk\.(txt|json)|deep/lsblk-all\.txt)$", "存储",
     "块设备树：容量 / 介质类型 / 挂载点 / 分区表",
     "查哪块盘被排除了、为什么没参与压测时",
     "有挂载点的盘不参与破坏性写入，这是设计如此"),
    # 背板那条要排在通用的 storcli-*.txt 前面，否则会被它先吃掉
    (r"^(storcli|raid/[a-z0-9]+)-enclosure\.txt$", "存储",
     "阵列卡自报的机框（背板）：每个背板几个盘位、在位几块盘、厂商型号",
     "回档查「这台机器当初是 12 盘位还是 4 盘位×3」时",
     "看 Number of Slots；这一项只进内部报告，交付报告不列"),
    (r"^storcli-.*\.txt$", "存储",
     "Broadcom / LSI MegaRAID 阵列卡的控制器、物理盘、逻辑盘与事件",
     "带阵列卡的机器上核对固件版本和盘位状态时",
     "先看 -show 里的 Product Name 和 FW Package Build"),
    (r"^raid/.*\.txt$", "存储",
     "其它厂商阵列卡 / HBA 的管理工具输出（PERC / Adaptec / HPE / IT 模式 HBA）",
     "同上，非 Broadcom 的卡看这里",
     "文件名前缀就是命中的那个工具"),
    (r"^deep/nvme-[a-z]+-smart-.*\.txt$", "存储",
     "NVMe 厂商扩展 SMART 页（各家自己的健康度 / 寿命 / 温度门限字段）",
     "标准 SMART 看不出名堂、要问厂商专有计数时",
     "认不了这块盘的插件会直接报错，那一行就是这个意思，不是盘有问题"),
    (r"^deep/sg_ses-cf-.*\.txt$", "存储",
     "SES 背板的配置页：这个背板**有几个盘位**、厂商与型号",
     "回档查机箱背板规格时（3.7 那一节的盘位数就是从这里出的）",
     "盘位只认 Array device slot 那一类元件的 number of possible elements，"
     "风扇/电源/温度传感器的数量不能混进来当盘位"),
    (r"^deep/sg_ses-.*\.txt$", "存储",
     "机框 / 背板（SES）的槽位、风扇、温度与电源状态",
     "存储机上盘位报错、或者怀疑背板有问题时",
     "看每个 Element 的状态位；空槽和故障槽在这里分得开"),
    (r"^fio-(seq|rand)\.json$", "存储",
     "硬盘压测的带宽 / IOPS / 延迟原始结果",
     "要看实测性能、或者判定说有 I/O 错误时",
     "每个 job 都有 error 字段，非 0 才是真出错"),

    # ---------------- 网络 ----------------
    (r"^nic-summary\.txt$", "网络", "各网口的 MAC / 链路状态 / 协商速率汇总",
     "核对装了几个口、哪几个接了线时", "一屏看完，细节再翻 nic/ 下的"),
    (r"^nic-test\.txt$", "网络", "全部网口连通性测试的汇总结果",
     "网卡连通性判定出现 WARN 时", "现场没接网线时这里本来就是空的，不是故障"),
    (r"^nic/.*-ethtool\.txt$", "网络", "单个网口的协商速率与支持的速率列表",
     "协商速率判定出现 WARN 时", "比 Speed 和 Supported link modes 的最大值"),
    (r"^nic/.*-driver\.txt$", "网络", "单个网口的驱动名、固件版本、PCI 地址与商用型号",
     "查网卡型号、或者怀疑固件太旧时", "model 那一行是从 lspci 按总线地址反查来的"),
    (r"^nic/.*-(ping|test)\.txt$", "网络", "单个网口的 DHCP 与 ping 连通性测试过程",
     "连通性判定出现 WARN 时", "现场没接网线时这里本来就是空的，不是故障"),
    (r"^deep/nic-.*-module\.txt$", "网络", "光模块（SFP/QSFP）的厂商、型号、收发光功率",
     "光口机器链路不稳时 —— 这份数据最值钱", "收光功率偏低多半是光纤或模块的问题"),
    (r"^deep/nic-.*-(stats|ring|pause)\.txt$", "网络", "网口的收发计数器 / 环形缓冲 / 流控设置",
     "怀疑丢包或性能不对时", "看 rx_errors / rx_dropped 这类计数"),
    (r"^deep/ip-link-detail\.txt$", "网络", "所有网络接口的详细状态与统计",
     "接口起不来时", "看 state 和 qdisc"),
    (r"^deep/lldp-neighbors\.(txt|json)$", "网络",
     "每个网口的对端：接在**哪台交换机的哪个口**",
     "现场怀疑网线插错、或者要核对布线表时",
     "采集用的是接收模式，我们不往对端发任何通告；没接线或对端没开 LLDP 就是空的"),
    (r"^deep/mstflint-.*\.txt$", "网络",
     "迈络思网卡的固件版本、PSID 与 PXE 版本",
     "迈络思卡固件版本要核对、或者怀疑该升级时",
     "PSID 决定了能刷哪个厂商的固件，比型号还关键"),

    # ---------------- GPU ----------------
    (r"^gpu-lspci\.txt$", "GPU", "PCI 总线上看到的 NVIDIA 显卡",
     "驱动认不到卡、要确认卡在不在总线上时",
     "这里有、nvidia-smi 里没有 = 驱动问题或卡的问题"),
    (r"^gpu-smi-(query|full)\.txt$", "GPU", "nvidia-smi 的概览与逐卡完整属性",
     "核对显卡型号 / 显存 / 驱动版本时", "full 里有 ECC、时钟、功耗上限"),
    (r"^gpu-driver-modinfo\.txt$", "GPU", "显卡内核模块的版本与 license",
     "nvidia-smi 起不来、但想知道装的是哪版驱动时",
     "license 是 Dual MIT/GPL 说明是 open 内核模块"),
    (r"^gpu-(modprobe-error|driver-mismatch)\.txt$", "GPU",
     "内核里 NVRM 打的原话（含「这张卡我不支持」那几行）",
     "GPU 判定出现 SKIP「驱动与显卡不匹配」时",
     "搜 not supported by；这是「驱动旧了」而不是「卡坏了」的直接证据"),
    (r"^deep/nvidia-inventory\.csv$", "GPU",
     "逐卡清单：序列号 / VBIOS / 显存 / PCIe 额定与实际代数宽度",
     "核对显卡台账、或者怀疑卡没插到底时",
     "PCIe 那几列是压测后读的才准（空闲时 N 卡会主动降到 Gen1）"),
    (r"^deep/nvidia-ecc\.txt$", "GPU", "显存 ECC 的可纠正 / 不可纠正错误计数",
     "多卡机器复盘时", "少量可纠错误在数据中心卡上常见，持续增长才是坏显存"),
    (r"^deep/nvidia-(topo|clocks|power|perf)\.txt$", "GPU",
     "卡间互联拓扑 / 时钟 / 功耗上限 / 性能状态",
     "多卡通信性能不对、或者怀疑功耗被限时", "topo 看 NVLink 有没有连上"),

    # ---------------- BMC ----------------
    (r"^ipmi-mcinfo\.txt$", "BMC", "BMC 自身的固件版本与支持的功能",
     "确认 BMC 在不在线、固件该不该升时", "读不到就是这台机器没有 BMC 或没启用 IPMI"),
    (r"^ipmi-sensors(-post)?\.txt$", "BMC", "BMC 全部传感器读数（post 是压测后的）",
     "电源判定、温度交叉核对时", "PSU*_Vin 是判断某一路有没有进电的依据"),
    (r"^ipmi-sensor-breach\.txt$", "BMC",
     "**压测后越过主板自身上下限的那几条传感器**（每行 级别|名称|读数|单位|说明）",
     "「部件传感器复查」判 WARN/FAIL 时，这就是逐条明细",
     "级别 crit=越临界线（判 FAIL）、warn=越告警线、zero=读数为 0（装没装分不开，只判 WARN）；"
     "阈值取自 ipmi-sensors-post.txt 后六列，是**主板厂商写进 BMC 的**，不是我们定的"),
    (r"^ipmi-sdr\.txt$", "BMC", "BMC 传感器定义表（装没装卡都会有定义）",
     "查主板设计上有哪些传感器时", "有定义但全无读数 = 该位置现在没有东西在响应"),
    (r"^ipmi-sel-pre\.txt$", "BMC", "压测前的 BMC 事件日志（机器的历史）",
     "想知道这台机器过去出过什么事时", "看时间戳，很多是很久以前的"),
    (r"^ipmi-sel-post\.txt$", "BMC", "压测后的 BMC 事件日志全量",
     "要自己比对前后差异时", "一般直接看下面那份 new 就够了"),
    (r"^ipmi-sel-new\.txt$", "BMC", "**压测期间新增**的 BMC 事件",
     "这是 BMC 里最该看的一份", "时间戳落在压测区间的告警级事件会让整机判 FAIL"),
    (r"^ipmi-sel-psu\.txt$", "BMC", "历史事件里和电源相关的那些",
     "电源判定出现 WARN/FAIL 时", "和 dmidecode-psu 的 Status 对照"),
    (r"^ipmi-fru\.txt$", "BMC", "FRU 信息（主板 / 背板 / 电源的厂商与序列号）",
     "做设备台账、查部件序列号时", "部分机型这里比 DMI 还全"),
    (r"^deep/ipmi-(chassis|lan|mc-getsysinfo)\.txt$", "BMC",
     "机箱状态 / BMC 网口配置 / 系统信息",
     "查 BMC 的 IP、或者前面板告警灯状态时", "chassis 里有 Front Panel Light"),

    # ---------------- 内核日志 ----------------
    (r"^dmesg-pre\.txt$", "内核日志", "开机到压测前的完整内核日志",
     "怀疑某个硬件没被识别、或者驱动没加载时",
     "搜 error / fail / timeout；固件加载失败也在这里"),
    (r"^dmesg-post\.txt$", "内核日志", "压测结束后的完整内核日志",
     "判定里出现 I/O error / MCE / AER 时", "和 pre 对比，**只看新增的**"),
    (r"^dmesg-delta\.txt$", "内核日志", "压测期间新增的那部分内核日志",
     "上面那条「只看新增的」，这份是已经帮你减好的", "直接从头看到尾"),
    (r"^dmesg-errors-boot\.txt$", "内核日志", "开机阶段筛出来的硬件错误行",
     "开机内核日志判 FAIL 时", "每一行都对应一条真实的硬件错误关键字"),
    (r"^dmesg-errors\.txt$", "内核日志", "压测期间筛出来的硬件错误行",
     "内核日志复查判 FAIL 时", "这几行就是判 FAIL 的全部依据"),
    # ↓ 内存专用盘（memtest.sh）筛的两份。和上面两条的区别是**筛的范围**：
    #   那两份收全部硬件错误族，这两份**只收明确指向内存的**（EDAC / 坏页 /
    #   说了是内存的 MCE）。那张盘上坏网卡、坏阵列卡不许算到内存头上。
    (r"^dmesg-mem-boot\.txt$", "内核日志", "压测**开始之前**就有的内存错误行",
     "内存盘的「开机日志内存错误」判 FAIL 时",
     "有内容就说明这台机器空闲时就在报内存错误，问题不是压出来的"),
    (r"^dmesg-mem-new\.txt$", "内核日志", "压测期间**新增**的内存错误行",
     "内存盘的「压测期间内核日志」判 FAIL 时",
     "每一行都带着是哪个通道哪条 DIMM，直接对到明细表的槽位"),

    # ---------------- 压测日志 ----------------
    (r"^stress/cpu-.*\.log$", "压测日志", "CPU 压测（stress-ng）的完整输出",
     "CPU 压测判 FAIL 时", "看 failed: 后面那个**数字**，别按关键字搜——正常日志里也有 failed"),
    (r"^stress/mem-.*\.log$", "压测日志", "内存压测（stressapptest / stress-ng）的完整输出",
     "内存压测判 FAIL 或 WARN 时",
     "看 hardware incidents 和 errors 后面的数字；退出码 137 是被 OOM 收了，不是内存坏"),
    (r"^stress/gpu-.*\.log$", "压测日志", "显卡压测（gpu_burn）的完整输出",
     "GPU 压测判 FAIL 时",
     "多卡的错误数写在同一行、用空格加减号分隔，要全部相加；结尾 GPU N: OK/FAULTY"),
    (r"^stress/fio-.*\.(log|job)$", "压测日志", "硬盘压测的运行日志与 fio 作业文件",
     "想知道 fio 到底按什么参数跑的时候", "job 文件里是完整的参数"),
    (r"^stress/.*$", "压测日志", "压测过程的其它日志",
     "上面几类都不是的时候", "按文件名对应到具体的压测项"),

    # ---------------- 配置一致性核对（1.9.0 新增）----------------
    (r"^gpu-uniform\.txt$", "GPU", "逐卡一行的「型号, 显示 BIOS 版本」",
     "显卡一致性判 WARN 时", "两列各自去重，多于一种就是不一致"),
    (r"^gpu-ecc\.csv$", "GPU",
     "逐卡的显存 ECC 计数（本次上电以来 / 出厂累计，各含可纠正与不可纠正）",
     "显存 ECC 判 WARN/FAIL 时",
     "列是 index,volatile_ce,volatile_ue,aggregate_ce,aggregate_ue；"
     "`[N/A]` 表示该型号不支持 ECC，**不是 0**"),
    (r"^gpu-remapped-rows\.csv$", "GPU",
     "逐卡的显存行重映射状态（一行一张卡，无卡号列）",
     "显存行重映射判 WARN/FAIL 时",
     "列是 correctable,uncorrectable,pending,failure；"
     "failure=Yes 是备用行用尽（按 NVIDIA 口径要返修）；pending=Yes 只是需要重启。"
     "整个文件只有一行 `Field \"xxx\" is not a valid field to query.` "
     "= 查询字段名和这版驱动对不上（1.9.3 栽过），那一项会静悄悄判 SKIP"),
    (r"^disk-uniform-scope\.txt$", "存储",
     "硬盘型号一致性这一项**比了哪几块盘**（每行一个设备名）",
     "有人问「为什么只比了两块盘」「我们那根 U 盘算不算进去了」时",
     "取自 scan_disks 的 DISK_SMART[]，U 盘和虚拟设备本来就不在里面；"
     "空文件 = 这台机器一块本机硬盘都没有，那一项判 SKIP"),
    (r"^net-pci-addresses\.txt$", "网络",
     "系统里当前存在的网口对应的 PCI 总线地址",
     "核对板载网口是不是在 BIOS 里被禁用了时",
     "和 deep/dmidecode-onboard.txt 里的 Bus Address 对照，能对上就说明这个口是活的"),
    (r"^nic-drivers\.txt$", "网络", "每个网口用的是哪个驱动（口名|驱动名）",
     "虚拟设备核对判 WARN 时", "virtio_net / vmxnet3 / hv_netvsc 这几个是虚拟网卡"),
    (r"^deep/fwts\.log$", "系统",
     "固件（BIOS / UEFI / ACPI）自检的完整输出",
     "同一批板子怀疑有共性 BIOS 问题时，或者客户问「你们查过固件吗」时",
     "看结尾那张 Total 汇总表的 Fail / Warn 两列；**这一项只留档、不参与整机结论**，"
     "而且不进客户报告 —— 完全正常的服务器上 ACPI 告警也很常见，"
     "印给客户等于白白让人去找机器的毛病"),
    (r"^smart-selftest/.*$", "存储",
     "每块盘**自己跑**的短自检结果（smartctl -l selftest 原文）",
     "「硬盘自检」判 FAIL 时，或者想知道某块盘为什么没取到结论时",
     "看 Status 那一列：Completed without error 才算过；"
     "in progress / Interrupted 是本轮没跑完（我们的时间问题，判 SKIP）"),
    (r"^smart-selftest-start\.txt$", "存储",
     "发起短自检时 smartctl 的回话（含预计耗时）",
     "自检一条结论都没取到、想知道是不是压根没发起成功时",
     "正常会写 \"Testing has begun\" 和预计完成时间"),
    (r"^nic/.*-selftest\.txt$", "网络",
     "每个网口**自己跑**的自检结果（ethtool -t 原文）",
     "「网卡自检」判 FAIL 时，或者想知道哪几项子测试没过时",
     "看 \"The test result is\" 那一行；驱动不实现自检时这里是 "
     "\"Operation not supported\"，那是驱动的能力问题，判 SKIP"),
    (r"^deep/dmidecode-onboard\.txt$", "网络",
     "主板上焊死的板载设备清单及其 PCI 地址（DMI type 41）",
     "核对板载网口 / 板载阵列卡是否被禁用时",
     "Type: Ethernet 的那几块就是板载网口；Bus Address 拿去和上面那份对照"),
    (r"^dmesg-boot-for-profile\.txt$", "内核日志",
     "为读平台设置临时补采的一份开机内核日志",
     "平台关键设置那一项判 SKIP、想知道为什么读不到时",
     "搜 x2apic / DMAR / AMD-Vi —— 内核会明说这几项是开是关"),

    # ---------------- 性能基准（1.9.0 新增）----------------
    (r"^bench/gpu-bandwidth.*\.log$", "性能基准",
     "显卡与主机之间、以及显存内部的数据传输带宽实测输出",
     "显卡数据传输带宽判 FAIL 时",
     "三段各取自己的表头单位（有的版本是 MB/s、有的是 GB/s），别直接比数字"),
    (r"^bench/gpu-p2p\.log$", "性能基准", "显卡两两之间的双向互联带宽矩阵",
     "显卡间互联带宽判 FAIL 时",
     "看 Bidirectional P2P=Enabled 那张矩阵，对角线是卡自己不算"),
    (r"^bench/cpu-linpack\.log$", "性能基准", "CPU 浮点算力测试的完整输出",
     "CPU 浮点算力判 FAIL 时",
     "**看 Performance Summary 那张表的 Average 列**；上面那张表第 4 列是秒不是算力"),
    (r"^bench/linpack-input\.txt$", "性能基准", "本次算力测试用的问题规模等参数",
     "想复现或调整算力测试时", "问题规模是按内存容量自动推算的，可在配置里写死"),
    (r"^bench/mem-bandwidth\.log$", "性能基准", "内存峰值读带宽的实测输出",
     "内存读取带宽判 FAIL 时", "看 ALL Reads 那一行，单位 MB/s"),
    (r"^bench/fio-.*\.json$", "性能基准",
     "逐盘 128KB 顺序读 / 顺序写的带宽结果（客户验收单的口径）",
     "硬盘读写带宽判 FAIL 时",
     "job 名就是验收单上的写法（libaio_read_128k_32_1），bw 字段单位是 KiB/s"),
    (r"^bench/.*$", "性能基准", "性能基准的其它日志与作业文件",
     "上面几类都不是的时候", "按文件名对应到具体的基准项"),
)

_RAW_INDEX_RE = tuple((re.compile(p), g, w, wh, h) for p, g, w, wh, h in RAW_INDEX)


def classify_raw(rel):
    """rel（raw/ 下的相对路径）-> (分组, 这是什么, 什么时候看, 怎么看)；认不出来给 None。"""
    rel = (rel or "").replace(os.sep, "/").lstrip("./")
    for rx, group, what, when, how in _RAW_INDEX_RE:
        if rx.match(rel):
            return (group, what, when, how)
    return None


RAW_GROUP_ORDER = ("本次运行", "系统", "CPU 与内存", "存储", "网络", "GPU",
                   "BMC", "内核日志", "性能基准", "压测日志", "未分类")


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
        return self._csv_multi("sys_metrics.csv", "cpu_pkg_temps")

    def _csv_multi(self, fname, col):
        """读一列"分号分隔的多个数值"，拆成 {序号: [值...]}。"""
        path = os.path.join(self.run_dir, fname)
        out = {}
        if not os.path.exists(path):
            return out
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                raw = (row.get(col) or "").strip()
                if not raw:
                    continue
                for i, part in enumerate(raw.split(";")):
                    v = num(part)
                    if v is None:
                        continue
                    out.setdefault(i, []).append(float(v))
        return out

    def sys_extra_series(self):
        """负载和内存占用两条曲线，外加内存总量（客户报告不画，内部看压测强度用）。

        总量要一起给：光画"已用 12000 MB"看不出压测吃得狠不狠 ——
        16GB 机器上那是快满了，512GB 机器上那是几乎没动。
        -> (负载[], 已用MB[], 总量MB 或 None)
        """
        path = os.path.join(self.run_dir, "sys_metrics.csv")
        load, memused, total = [], [], None
        if not os.path.exists(path):
            return load, memused, total
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                for key, bucket in (("load1", load), ("mem_used_mb", memused)):
                    v = num(row.get(key))
                    if v is not None:
                        bucket.append(float(v))
                t = num(row.get("mem_total_mb"))
                if t is not None and (total is None or t > total):
                    total = float(t)
        return load, memused, total

    def ecc_series(self):
        """压测期间的 ECC 计数曲线 -> (可纠正[], 不可纠正[])。

        为什么值得单独画一条：只有压测前后两个快照的话，只知道"涨了多少"，
        不知道**什么时候开始涨**。而这两件事的含义完全不同 ——
        一上来就涨，多半是这条内存本身；烤热十分钟之后才开始涨，
        更像是散热或供电压不住。判定只看差值，这条曲线是给人看的。

        老 run-dir（1.7.0 之前）没有这两列，返回两个空列表，报告里整块不画。
        读不到 EDAC 的机器上写进 CSV 的是 "--"，num() 解析不了，同样不计点 ——
        绝不会被当成 0。
        """
        path = os.path.join(self.run_dir, "sys_metrics.csv")
        ce, ue = [], []
        if not os.path.exists(path):
            return ce, ue
        with open(path, newline="", encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f):
                for key, bucket in (("ecc_ce", ce), ("ecc_ue", ue)):
                    v = num(row.get(key))
                    if v is not None:
                        bucket.append(float(v))
        return ce, ue

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

    # ---------- 计数器快照（1.7.0 新增）----------
    def _counters(self, phase):
        """raw/counters-<phase>.txt -> {(类型, 键): [数值...]}；没有就返回 None。

        None 和 {} 是两回事：None = 这台机器/这一轮压根没有这份快照（判定判 SKIP），
        {} = 有快照但一条都没解析出来。报告里两者显示的东西不一样。
        """
        p = self.rawpath("counters-%s.txt" % phase)
        if not os.path.exists(p):
            return None
        out = {}
        for line in read_text(p).splitlines():
            parts = line.split()
            if len(parts) < 3 or parts[0].startswith("#"):
                continue
            vals = []
            for v in parts[2:]:
                n = num(v)
                vals.append(int(n) if n is not None else None)
            out[(parts[0], parts[1])] = vals
        return out

    COUNTER_LABELS = {
        ("ECC", 0): "内存 ECC 可纠正",
        ("ECC", 1): "内存 ECC 不可纠正",
        ("THROTTLE", 0): "CPU 核心热节流",
        ("THROTTLE", 1): "CPU 封装热节流",
        ("AER", 0): "PCIe 可纠正错误",
        ("AER", 1): "PCIe 不可纠正（致命）",
        ("AER", 2): "PCIe 不可纠正（非致命）",
    }

    def counter_deltas(self):
        """-> [OrderedDict...]；只列**增量大于 0** 的。

        没有快照返回 None（报告里整块不画）；有快照但没有增长返回 []。
        """
        pre, post = self._counters("pre"), self._counters("post")
        if pre is None or post is None:
            return None
        rows = []
        for key, after in sorted(post.items()):
            before = pre.get(key) or []
            for i, a in enumerate(after):
                if a is None:
                    continue
                b = before[i] if i < len(before) and before[i] is not None else 0
                if a - b <= 0:
                    continue
                rows.append(OrderedDict([
                    ("类型", self.COUNTER_LABELS.get((key[0], i), "%s[%d]" % (key[0], i))),
                    ("位置", key[1]),
                    ("压测前", b),
                    ("压测后", a),
                    ("新增", a - b),
                ]))
        return rows

    def ecc_table(self):
        """逐条 DIMM 的 ECC，前后各一列。没有 EDAC 就是空表。"""
        pre, post = self._counters("pre"), self._counters("post")
        if pre is None and post is None:
            return []
        pre, post = pre or {}, post or {}
        labels = sorted({k[1] for k in list(pre) + list(post) if k[0] == "ECC"})
        rows = []
        for lb in labels:
            a = pre.get(("ECC", lb)) or [None, None]
            b = post.get(("ECC", lb)) or [None, None]
            def cell(x, y):
                if x is None and y is None:
                    return None
                if x == y:
                    return str(y)
                return "%s → %s ⚠" % (x, y)
            rows.append(OrderedDict([
                ("内存位置", lb),
                ("可纠正（前→后）", cell(a[0] if len(a) > 0 else None,
                                        b[0] if len(b) > 0 else None)),
                ("不可纠正（前→后）", cell(a[1] if len(a) > 1 else None,
                                          b[1] if len(b) > 1 else None)),
            ]))
        return rows

    # ---------- BMC 部件传感器 ----------
    def bmc_sensors(self):
        """`ipmitool sensor list` -> 数值型传感器逐条一行，带主板自己的上下限。

        ⚠️ **这里只做展示，绝不重新判一遍。**判定在 lib/verify.sh 的
        `ipmi_sensor_scan` 里，越线的那几条另外落在 `raw/ipmi-sensor-breach.txt`。
        Python 这边再写一份阈值比较，就是第二套判据 —— 两边迟早会不一致，
        而且不一致的时候没人看得出来是哪边错了（占位符名单那三份的教训）。

        十列：名称|读数|单位|状态|lnr|lcr|lnc|unc|ucr|unr
        离散量（读数是 `0x80` 那种事件位）整条跳过：它没有上下限可言，
        一百多行十六进制堆在表里只会把真正有读数的那几十行淹掉。
        """
        txt = read_text(self.rawpath("ipmi-sensors-post.txt"))
        phase = "压测后"
        if not txt.strip():
            txt = read_text(self.rawpath("ipmi-sensors.txt"))
            phase = "压测前"
        rows = []
        for line in txt.splitlines():
            c = [x.strip() for x in line.split("|")]
            if len(c) < 10:
                continue
            if not re.match(r"^-?\d+(\.\d+)?$", c[1] or ""):
                continue

            def n(v):
                return v if re.match(r"^-?\d+(\.\d+)?$", v or "") else None

            if not any(n(c[i]) for i in (4, 5, 6, 7, 8, 9)):
                continue
            rows.append(OrderedDict([
                ("传感器", c[0]), ("%s读数" % phase, c[1]), ("单位", c[2]),
                ("下限·不可恢复", n(c[4])), ("下限·临界", n(c[5])), ("下限·告警", n(c[6])),
                ("上限·告警", n(c[7])), ("上限·临界", n(c[8])), ("上限·不可恢复", n(c[9])),
            ]))
        return rows

    def bmc_sensor_breach(self):
        """raw/ipmi-sensor-breach.txt -> 越线的那几条。判定那边写的，这里只渲染。"""
        cn = {"crit": "越临界线", "warn": "越告警线", "zero": "读数为 0"}
        rows = []
        for line in read_text(self.rawpath("ipmi-sensor-breach.txt")).splitlines():
            p = line.split("|")
            if len(p) < 5:
                continue
            rows.append(OrderedDict([
                ("级别", cn.get(p[0], p[0])), ("传感器", p[1]),
                ("读数", "%s %s" % (p[2], p[3])), ("说明", p[4]),
            ]))
        return rows

    # ---------- 固件版本清单 ----------
    def fwupd_devices(self):
        """fwupdmgr get-devices 的文本输出 -> [(设备, 当前版本)]。

        故意解析文本而不是 json：json 那份在不同 fwupd 版本之间结构变过好几次，
        而文本里 "Current version:" 这一行十年没变。解析失败就是空表，不影响别的。
        """
        txt = read_text(self.rawpath("deep", "fwupd-devices.txt"))
        if not txt.strip():
            return []
        rows, name = [], None
        for line in txt.splitlines():
            s = line.strip()
            if not s:
                continue
            # 设备名是不带 "key: value" 形状、且缩进较浅的那一行
            if ":" not in s and not line.startswith("    "):
                name = s.strip("│├└─ ").strip()
                continue
            m = re.match(r"^[│├└─\s]*(Current version|DeviceId|Vendor|GUID)\s*:\s*(.+)$", s)
            if m and m.group(1) == "Current version" and name:
                rows.append(OrderedDict([("部件", name), ("当前固件版本", m.group(2).strip())]))
        return rows

    # ---------- LLDP 邻居 ----------
    def lldp_neighbors(self):
        """lldpctl 的输出 -> [(本端口, 对端设备, 对端端口, 对端描述)]。"""
        txt = read_text(self.rawpath("deep", "lldp-neighbors.txt"))
        if not txt.strip() or "command not found" in txt:
            return []
        rows, cur = [], None
        for line in txt.splitlines():
            m = re.match(r"^Interface:\s*([^,]+)", line.strip())
            if m:
                if cur:
                    rows.append(cur)
                cur = OrderedDict([("本端网口", m.group(1).strip()),
                                   ("对端设备", None), ("对端端口", None), ("对端描述", None)])
                continue
            if cur is None:
                continue
            for key, col in (("SysName", "对端设备"), ("PortID", "对端端口"),
                             ("PortDescr", "对端端口"), ("SysDescr", "对端描述")):
                m = re.match(r"^\s*%s:\s*(.+)$" % key, line)
                if m and not cur.get(col):
                    cur[col] = m.group(1).strip()[:120]
        if cur:
            rows.append(cur)
        return [r for r in rows if r.get("对端设备") or r.get("对端端口")]

    # ---------- 本轮采集范围 ----------
    def scope_notes(self):
        """本轮哪些数据没有、各自的客观原因。

        措辞规范见文件顶部：主语是**那项数据**，不是我们。
        但原因必须具体到"哪一类工具、哪一项数据" —— 中性不等于含糊。

        -> [(性质, 涉及的数据, 由什么提供, 证据文件, 补充说明)]
        """
        notes = []

        # ---- 先说本轮介质随带了哪些专用组件 ----
        # 这几项在 meta.json 里是构建期就定下来的，和现场跑得怎么样无关，
        # 所以不等采集文件里出现 "command not found" 才说 —— 那种情况只有
        # 真去跑过才会留下记录，而"根本没这个组件"应该一上来就写清楚。
        meta = self.meta
        for flag, cmd, extra in (
            ("storcli_present", "storcli64",
             "把对应厂商的管理工具放进构建期的 vendor/ 目录，下一版盘即可读到。"
             "本机若装的不是 Broadcom / LSI 的卡，需要的是对应品牌的那一个。"),
            ("gpu_burn_present", "gpu_burn",
             "显卡的型号、显存与驱动版本照常采集；缺的是满载期间的温度/功耗曲线。"),
        ):
            if str(meta.get(flag)) == "0":
                if cmd == "gpu_burn":
                    what, by = ("显卡满载期间的温度与功耗曲线", "显卡满载测试程序（gpu_burn）")
                else:
                    what, by = tool_note(cmd)
                notes.append(("该项由专用工具提供", what, by, "meta.json",
                              "该数据需由%s读取，本轮未加载该工具（%s）。%s" % (by, cmd, extra)))
        if str(meta.get("include_nvidia")) != "1":
            what, by = tool_note("nvidia-smi")
            notes.append(("该项由专用工具提供", what, by, "meta.json",
                          "该数据需由%s读取，本轮介质未随带显卡驱动。"
                          "无独立显卡的机型不受影响。" % by))

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
                    what, by = tool_note(m.group(2))
                    notes.append(("采集超时", what, by, rel,
                                  "%s 在 %s 秒内未返回，本轮取到的是截断的结果。"
                                  "下一轮可放宽该项超时，或在目标机器空闲时重采。"
                                  % (m.group(2).split()[0], m.group(1))))
                for m in re.finditer(r"\(command not found: ([^)]+)\)", txt):
                    what, by = tool_note(m.group(1))
                    notes.append(("该项由专用工具提供", what, by, rel,
                                  "该数据需由%s读取，本轮未加载该工具（%s）。"
                                  "把对应工具放进构建期的 vendor/ 目录即可在下一版盘里取到。"
                                  % (by, m.group(1))))

        # 同一项数据可能既在 meta 里标了没有、又在采集文件里留了一条记录，
        # 去重按「性质 + 是哪项数据 + 由什么提供」，证据文件取第一次出现的那个。
        seen, uniq = set(), []
        for n in notes:
            key = (n[0], n[1], n[2])
            if key in seen:
                continue
            seen.add(key)
            uniq.append(n)
        return uniq

    # ---------- raw/ 文件索引 ----------
    def raw_files(self, skip_prefix="INTERNAL_"):
        rows = []
        for root, _dirs, files in os.walk(self.raw):
            for fn in sorted(files):
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, self.raw).replace(os.sep, "/")
                if rel.startswith(skip_prefix):
                    continue
                try:
                    size = os.path.getsize(p)
                except OSError:
                    size = 0
                rows.append((rel, size))
        rows.sort(key=lambda r: r[0])
        return rows

    def raw_index_grouped(self):
        """-> OrderedDict{分组: [(说明四元组, [(相对路径, 大小)...])]}

        同一类的文件合并成一行（"每块盘一份 SMART" 没必要重复十遍说明），
        看的人要的是"这一类是什么、什么时候该点开"。
        """
        buckets = OrderedDict()
        for rel, size in self.raw_files():
            info = classify_raw(rel)
            if info is None:
                info = ("未分类", "（这一类还没有写说明）",
                        "——", "在 generate_internal.py 的 RAW_INDEX 里补一条")
            group = info[0]
            buckets.setdefault(group, OrderedDict()).setdefault(info, []).append((rel, size))
        out = OrderedDict()
        for g in RAW_GROUP_ORDER:
            if g in buckets:
                out[g] = list(buckets[g].items())
        for g, v in buckets.items():        # 万一将来加了新分组没登记进顺序表
            if g not in out:
                out[g] = list(v.items())
        return out


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
        f.append(finding(INFO, "测试范围", "硬盘破坏性读写压测不在本轮范围内",
                         "现场默认跳过（需要两道人工确认）。硬盘的型号、SMART 与温度"
                         "照常采集并参与判定，只是没有 fio 的带宽与 IOPS 数据。", "meta.json"))
    if str(meta.get("clock_synced")) != "1":
        f.append(finding(INFO, "测试范围", "本轮时间戳取自主板 RTC",
                         "现场无网络时联网校时不可用，属正常情况；"
                         "报告里的时间可能与真实时间有偏差。", "raw/clock-sync.log"))

    notes = d.scope_notes()
    if notes:
        kinds = OrderedDict()
        for kind, what, _by, _rel, _more in notes:
            kinds.setdefault(kind, set()).add(what)
        desc = "；".join("%s：%s" % (k, "、".join(sorted(v))) for k, v in kinds.items())
        f.append(finding(WATCH, "测试范围", "本轮有 %d 项数据未取到" % len(notes),
                         desc + "。这些项与被测机器的状态无关，客户报告里对应的项记 SKIP；"
                                "逐条的客观原因和补齐办法见「本轮采集范围说明」。",
                         "见第八节"))

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
        f.append(finding(INFO, "CPU 散热", "本机不上报 CPU 温度",
                         "这台机器的温度驱动不是 coretemp/k10temp，属于正常情况，"
                         "温度类判定已自动让开。", "raw/sensors.txt"))

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
        f.append(finding(INFO, "硬盘", "本机未检测到可读取 SMART 的硬盘", "",
                         "raw/smart-pre/"))
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
                             "有 %d 张卡不在本轮驱动版本的支持范围内" % (present - usable),
                             "判据是内核里 NVRM 自己打的原话。这是**驱动版本与卡的代际不匹配**，"
                             "与卡本身的好坏无关 —— 客户报告里判的是 SKIP。"
                             "要覆盖这几张卡，需要换一个支持该代际的驱动分支重新出盘。"
                             "原话见证据文件。",
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
        f.append(finding(INFO, "网卡", "本轮现场未接网线",
                         "共 %d 个物理口，型号与固件照常采集；连通性一项记 SKIP。"
                         % len(speeds), "raw/nic-summary.txt"))

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
#
# 视觉语言和客户报告保持一致（复用它的 CSS），但信息密度更高：
# 表格更紧凑、顶部有锚点导航、原始数据全部收在可折叠块里。
# **单文件、内嵌 CSS、不引任何外部资源** —— 现场无网络，报告要能离线打开。
# 打印也要能看：工程人员会打出来夹进机器箱。

EXTRA_CSS = """
.internal-banner{background:#7f1d1d;color:#fff;padding:12px 18px;border-radius:6px;
margin:0 0 18px;font-weight:700;letter-spacing:.5px}
.internal-banner span{display:block;font-weight:400;font-size:12.5px;opacity:.92;margin-top:4px}
.toc{position:sticky;top:0;z-index:9;background:var(--bg);border-bottom:1px solid var(--line);
padding:9px 0;margin:14px 0 4px;display:flex;flex-wrap:wrap;gap:6px 14px;font-size:12.5px}
.toc a{color:var(--accent);text-decoration:none;white-space:nowrap}
.toc a:hover{text-decoration:underline}
h2{scroll-margin-top:52px}
.lead{color:var(--muted);font-size:12.5px;margin:2px 0 12px;padding-left:11px;
border-left:2px solid var(--line)}
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
.dense table{font-size:12px}
.dense th,.dense td{padding:4px 8px}
.idx td{vertical-align:top}
.idx td.f a{display:block;font-family:Consolas,Monaco,monospace;font-size:11.5px;
white-space:nowrap;color:var(--accent);text-decoration:none}
.idx td.f a:hover{text-decoration:underline}
.idx td.how{color:var(--muted);font-size:12px}
.delta{color:#c1121f;font-weight:700}
.same{color:var(--muted)}
@media print{
  .toc{display:none}
  .internal-banner{background:#fff;color:#7f1d1d;border:2px solid #7f1d1d}
  .fnd{break-inside:avoid}
  details{break-inside:avoid}
  details[open] pre{max-height:none}
}
"""

# 九节的标题与"这节是干什么的"。顺序就是读的人想知道的顺序：
# 先结论，再身份，再配置，再逐项依据，再过程，再复查，最后才是原始数据。
SECTIONS = (
    ("s1", "一、结论摘要", "整机结论、本轮参数，以及所有 FAIL / WARN 的逐条清单。先看这一节。"),
    ("s2", "二、机器身份", "这台机器是谁：厂商、型号、序列号、BIOS 与 BMC 版本、资产标签。"),
    ("s3", "三、配置清单", "这台机器装了什么：CPU、逐条内存、存储、网络、显卡、阵列卡、电源。"),
    ("s4", "四、逐项判定", "每一条判定的状态、依据，以及它引用了哪个原始文件。按 id 能直接定位到代码。"),
    ("s5", "五、压测过程", "压测期间的曲线与峰值：温度、频率、功耗、负载、显卡读数、硬盘带宽。"),
    ("s6", "六、测后复查", "压测把什么逼出来了：SMART 前后逐属性差值、内核日志、BMC 新增事件。"),
    ("s7", "七、深度硬件数据", "不参与判定、但复盘时最值钱的那些：光模块、显卡逐卡清单、固件版本。"),
    ("s8", "八、本轮采集范围说明", "本轮哪些数据没有、各自的客观原因，以及下一轮怎么补齐。"),
    ("s9", "九、原始文件索引", "每一份原始数据是什么、什么时候该看它、怎么看。"),
)


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


def sub_numberer(sec):
    """<h3> 的二级编号器。**别再写死编号了。**

    五、七两节里的小节全是"有数据才画"的：没显卡就没有 GPU 那一段、
    没跑硬盘压测就没有硬盘那一段。编号写死的话，缺一段就断一个号 ——
    读的人第一反应是"报告是不是漏了一节"。
    交付报告那边早就是动态编号（见 generate_report.py 的 SUB），
    内部这份一直没跟上，1.9.0 补齐。
    """
    n = [0]

    def sub(title):
        n[0] += 1
        return "<h3>%d.%d %s</h3>" % (sec, n[0], title)

    return sub


def nav_html():
    return '<nav class="toc">%s</nav>' % "".join(
        '<a href="#%s">%s</a>' % (sid, E(title)) for sid, title, _lead in SECTIONS)


def build_internal_html(d):
    meta = d.meta
    H = []
    A = H.append

    tag = meta.get("machine_tag") or os.path.basename(d.run_dir)
    serial = (d.system().get("整机序列号") or meta.get("serial") or "UNKNOWN")
    findings = assess(d)
    devs = d.smart_devices()

    st = [r.get("status") for r in d.results]
    # 和 generate_report.py / factory-test.sh 同一条规矩：一条判定都没有 != 全都通过。
    # 三处必须一致，否则同一次运行的屏幕、交付报告、内部报告会给出三个结论。
    overall = "FAIL" if ("FAIL" in st or not st) else "PASS"

    def SEC(sid):
        for s, title, lead in SECTIONS:
            if s == sid:
                A('<h2 id="%s">%s</h2>' % (s, E(title)))
                A('<p class="lead">%s</p>' % E(lead))
                return
        raise KeyError(sid)

    # ================================================ 抬头
    A('<div class="wrap"><header>')
    A('<div class="internal-banner">内部工程报告 · 请勿外发'
      "<span>这份是工程数据，包含设备台账字段、本轮测试的环境信息和源码版本，"
      "用于复盘和日后追溯。交付给客户的是报告目录下与目录同名的那个 .html。</span></div>")
    A('<div class="company">%s</div>' % E(meta.get("company_name")))
    A("<h1>%s ｜ 工程数据</h1>" % E(meta.get("report_title") or "服务器出厂老化测试报告"))
    # 范围和机器标识并排：内部复盘时"这份是哪一轮"和"这份测了什么"是同一个问题。
    A('<div class="sub">机器标识 <b>%s</b> ｜ 本轮范围 <b>%s</b></div>'
      % (E(tag), E(scope_cn(meta))))
    A("</header>")
    A(nav_html())

    # ================================================ 一、结论摘要
    SEC("s1")
    A('<div style="margin:10px 0 6px"><span class="verdict v-%s">%s</span>' % (overall, overall))
    A('<span style="margin-left:16px" class="sub">通过 %d ｜ 失败 %d ｜ 告警 %d ｜ 跳过 %d'
      "（整机结论只看有没有 FAIL）</span></div>"
      % (st.count("PASS"), st.count("FAIL"), st.count("WARN"), st.count("SKIP")))

    A("<h3>1.1 本轮参数</h3>")
    thr = meta.get("thresholds") or {}
    A(kv_block(OrderedDict([
        ("整机序列号", serial),
        ("测试范围", "%s（scope=%s）" % (scope_cn(meta), scope_of(meta))),
        # 这一轮的算力是拿哪套程序量的。**只在内部报告里出现** ——
        # 客户报告不许出现工具名。留着它是为了日后有人拿新旧报告对比、
        # 发现算力数字对不上时能解释：1.9.5 起统一换成了自研的 OpenBLAS 版本，
        # 在 Intel 机器上比原来的 MKL 版本低一到两成，不是机器变慢了。
        ("算力测量方法", (meta.get("bench_params") or {}).get("flops_method") or "—"),
        ("测试档位", profile_text(meta.get("profile"))),
        ("计划时长", fmt_dur(meta.get("planned_secs"))),
        ("实际耗时", fmt_dur(meta.get("elapsed_secs"))),
        ("开始时间", meta.get("start_time")),
        ("结束时间", meta.get("end_time")),
        ("硬盘破坏性压测", "已执行" if str(meta.get("disk_confirmed")) == "1" else "不在本轮范围内"),
        ("CPU 温度阈值", "告警 %s / 故障 %s °C"
         % (thr.get("cpu_temp_warn"), thr.get("cpu_temp_fail"))),
        ("GPU 温度阈值", "告警 %s / 故障 %s °C"
         % (thr.get("gpu_temp_warn"), thr.get("gpu_temp_fail"))),
        ("硬盘温度阈值", "告警 %s / 故障 %s °C"
         % (thr.get("disk_temp_warn"), thr.get("disk_temp_fail"))),
    ])))

    # 校验清单（1.9.2 加）。它是在两份报告和 PDF 都出完之后才生成的，
    # 所以这份内部报告里**只能说它在哪、怎么用**，列不出内容 —— 列出来就成了
    # "报告里印着报告自己的哈希"那种自指的东西。
    sums = os.path.join(d.run_dir, "SHA256SUMS")
    if os.path.exists(sums):
        try:
            nfiles = sum(1 for x in open(sums, encoding="utf-8", errors="replace")
                         if x.strip())
        except OSError:
            nfiles = 0
        A('<p class="sub">本轮共 <b>%d</b> 个文件（含两份报告与 PDF）的 SHA256 '
          "已写进报告目录下的 <code>SHA256SUMS</code>。"
          "半年后客户拿一份报告回来问，靠它证明我们归档的和他手上的是不是同一份：<br>"
          "<code>cd &lt;报告目录&gt; &amp;&amp; sha256sum -c SHA256SUMS</code><br>"
          "<b>这份清单不进客户报告</b> —— 客户手上没有 raw/，拿到哈希也校验不了什么，"
          "印在交付报告上只会招来「你们是不是怕被改」的提问。</p>" % nfiles)

    bad_rows = [r for r in d.results if r.get("status") in ("FAIL", "WARN")]
    A("<h3>1.2 需要处理的项</h3>")
    if bad_rows:
        A(table([OrderedDict([("状态", r.get("status")), ("项目", r.get("name")),
                              ("结论", r.get("detail")), ("证据", r.get("ref"))])
                 for r in bad_rows]))
    else:
        A('<p class="muted">本轮没有 FAIL，也没有 WARN。</p>')

    A("<h3>1.3 工程评估</h3>")
    counts = OrderedDict()
    for lv in (RISK, WATCH, GOOD, INFO):
        n = len([x for x in findings if x["level"] == lv])
        if n:
            counts[LEVEL_TEXT[lv]] = "%d 条" % n
    A(kv_block(counts))
    A('<p class="sub">以下每一条都<b>不影响整机结论</b>（结论只看 results.jsonl 里有没有 FAIL）。'
      "它们回答的是另一个问题：这台机器哪里好、哪里将来可能出问题、这一轮测得干不干净。</p>")
    A(findings_html(findings))

    # ================================================ 二、机器身份
    SEC("s2")
    sysinfo = OrderedDict(d.system())
    sysinfo["KLBurn 版本"] = meta.get("klburn_version")
    sysinfo["源码 commit"] = meta.get("git_commit")
    sysinfo["介质构建日期"] = meta.get("build_date")
    sysinfo["基础系统"] = meta.get("base_os")
    sysinfo["运行内核"] = meta.get("kernel")
    sysinfo["报告落盘设备"] = meta.get("data_partition")
    # 有才写。没有的那些统一在第八节交代清楚是哪一项数据、由什么提供，
    # 不在这里写一行"没有 XXX"。
    if str(meta.get("include_nvidia")) == "1" and meta.get("nvidia_version"):
        sysinfo["显卡驱动版本"] = "NVIDIA %s" % meta.get("nvidia_version")
    A(kv_block(sysinfo))

    # ================================================ 三、配置清单
    SEC("s3")
    A("<h3>3.1 CPU</h3>")
    A('<div class="dense">%s</div>' % table(d.cpus(), "未读到 CPU 信息"))
    A("<h3>3.2 内存（逐条）</h3>")
    A('<div class="dense">%s</div>' % table(d.dimms(), "未检测到内存条信息"))
    A("<h3>3.3 存储</h3>")
    if not devs:
        A('<p class="muted">未检测到可读取 SMART 的硬盘。</p>')
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
        A('<div class="dense">%s</div>' % table(rows))
    A("<h3>3.4 网络</h3>")
    A('<div class="dense">%s</div>' % table(d.nics(), "未检测到物理网口"))
    A("<h3>3.5 显卡</h3>")
    A('<div class="dense">%s</div>' % table(d.gpus(), "未安装独立显卡"))
    A("<h3>3.6 阵列卡</h3>")
    A('<div class="dense">%s</div>' % table(d.raid(), "未安装阵列卡"))

    # 背板只在这份内部报告里出现，交付报告不列 —— 拿不准的数字给客户
    # 只会造成误解（"我买的是 8 盘位，报告怎么写 4 盘位"）。
    A("<h3>3.7 硬盘背板</h3>")
    summary = d.backplane_summary()
    if summary:
        A('<p class="sub">本机背板：<b>%s</b>。回档查"这台当初是什么机箱/背板"时看这里。</p>'
          % E(summary))
    A('<div class="dense">%s</div>' % table(
        d.backplanes(),
        "未检测到背板信息。直连背板（无 expander、不带 SES 芯片）本身不上报，"
        "属于正常情况，不代表机器缺件。"))
    A('<p class="sub">数据来自阵列卡自报的机框（Number of Slots）与 SES 配置页；'
      "两条路都问不到时这里为空，不做任何推测。</p>")

    A("<h3>3.8 电源</h3>")
    A('<div class="dense">%s</div>' % table(d.psus(), "BIOS 未上报电源信息"))

    # ================================================ 四、逐项判定
    SEC("s4")
    A('<p class="sub">客户报告只显示名称和结论，这里连 id 和证据文件路径一起列出来 —— '
      "复盘时按 id 就能直接定位到代码里的判定分支。</p>")
    A('<div class="dense">%s</div>' % table(
        [OrderedDict([("状态", r.get("status")), ("id", r.get("id")),
                      ("名称", r.get("name")), ("结论", r.get("detail")),
                      ("证据", r.get("ref")), ("时间", r.get("time"))])
         for r in d.results], "没有任何判定记录"))
    if d.metrics:
        A("<h3>4.1 实测指标全量</h3>")
        A('<div class="dense">%s</div>' % table(
            [OrderedDict([("分组", m.get("group")), ("指标", m.get("key")),
                          ("数值", m.get("value"))]) for m in d.metrics]))

    # ================================================ 五、压测过程
    SEC("s5")
    S5 = sub_numberer(5)
    temps, freqs, powers = d.sys_series()
    pkg = d.cpu_pkg_series()
    if pkg:
        A(S5("逐颗 CPU 封装温度"))
        A('<p class="sub">客户报告只画一条整机最高温。逐颗分开画，才看得出'
          "是不是某一颗的散热器没装好 —— 这是双路机最常见的隐性问题。</p>")
        A(svg_line_chart([("CPU%d" % i, pkg[i]) for i in sorted(pkg)],
                         y_label="°C", y_suffix="°C"))
    if temps:
        A(S5("整机最高 CPU 温度"))
        A(svg_line_chart([("CPU 最高温", temps)], y_label="°C", y_suffix="°C"))
    if freqs:
        A(S5("全核平均频率"))
        A(svg_line_chart([("平均频率", freqs)], y_label="MHz", y_suffix="MHz"))
    if powers:
        A(S5("CPU 封装功耗"))
        A(svg_line_chart([("封装功耗", powers)], y_label="W", y_suffix="W"))
    load, memused, memtotal = d.sys_extra_series()
    if load or memused:
        A(S5("系统负载与内存占用"))
        A('<p class="sub">用来核对压测强度：负载没上去 = 压测没真跑满；'
          "内存占用曲线能看出内存压测吃到了多少、离 OOM 还有多远。</p>")
        if load:
            A(svg_line_chart([("1 分钟负载", load)], y_label="load"))
        if memused:
            # 总量写进图例：光看"已用 12000 MB"分不出这是快满了还是几乎没动
            label = "已用内存"
            if memtotal:
                label = "已用内存（本机共 %.0f GB）" % (memtotal / 1024.0)
            A(svg_line_chart([(label, memused)], y_label="MB", y_suffix="MB"))

    ecc_ce, ecc_ue = d.ecc_series()
    if ecc_ce or ecc_ue:
        A(S5("内存 ECC 计数随时间的变化"))
        A('<p class="sub">第六节那张表给的是压测前后的<b>差值</b>，只能回答"涨了多少"。'
          "这条曲线回答的是<b>什么时候开始涨</b> —— 而这两件事的含义完全不同："
          "一上来就涨多半是这条内存本身，烤热十几分钟之后才开始涨则更像散热或供电压不住。"
          "判定只看差值，这条是给人看的。</p>")
        series = []
        if ecc_ce:
            series.append(("可纠正 CE", ecc_ce))
        if ecc_ue:
            series.append(("不可纠正 UE", ecc_ue))
        A(svg_line_chart(series, y_label="次"))

    gfull = d.gpu_full_series()
    if gfull:
        A(S5("GPU 频率 / 利用率 / 显存占用"))
        A('<p class="sub">利用率没到 100% 说明压测没喂满，出来的温度功耗数字要打折看。</p>')
        for key, label, suf in (("clock", "SM 频率", "MHz"), ("util", "利用率", "%"),
                                ("mem", "显存占用", "MB")):
            series = [("GPU%s %s" % (i, gfull[i]["name"]), gfull[i][key])
                      for i in sorted(gfull) if gfull[i][key]]
            if series:
                A("<p class='sub'>%s</p>" % E(label))
                A(svg_line_chart(series, y_label=suf, y_suffix=suf))

    fio = d.fio_results()
    if fio:
        A(S5("硬盘性能数据"))
        A('<div class="dense">%s</div>' % table(fio))

    A(S5("压测日志原文"))
    for title, rel in (("CPU 压测", "stress/cpu-stress-ng.log"),
                       ("内存压测", "stress/mem-stressapptest.log"),
                       ("内存压测（退到 stress-ng --vm）", "stress/mem-stress-ng.log"),
                       ("GPU 压测", "stress/gpu-burn.log")):
        p = d.rawpath(rel)
        if os.path.exists(p) and read_text(p).strip():
            A(collapsible("%s  [raw/%s]" % (title, rel), read_text(p)[:120000]))

    # ================================================ 六、测后复查
    SEC("s6")
    A("<h3>6.1 坏道类计数：压测前 → 压测后</h3>")
    if not devs:
        A('<p class="muted">未采集到任何硬盘的 SMART。</p>')
    else:
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
        A('<div class="dense">%s</div>' % table(rows))

    A("<h3>6.2 内核日志与 BMC 事件</h3>")
    got_any = False
    for title, rel in (("开机阶段筛出的硬件错误", "dmesg-errors-boot.txt"),
                       ("压测期间筛出的硬件错误", "dmesg-errors.txt"),
                       ("压测期间新增的内核日志", "dmesg-delta.txt"),
                       ("压测期间 BMC 新增事件", "ipmi-sel-new.txt"),
                       ("压测后的 BMC 传感器读数", "ipmi-sensors-post.txt")):
        p = d.rawpath(rel)
        if os.path.exists(p) and read_text(p).strip():
            got_any = True
            A(collapsible("%s  [raw/%s]" % (title, rel), read_text(p)[:120000]))
    if not got_any:
        A('<p class="muted">压测前后没有筛出任何硬件错误行，BMC 也没有新增事件。</p>')

    # ================================================ 七、深度硬件数据
    S7 = sub_numberer(7)
    SEC("s7")
    got_any = False

    # ---- 计数器差值：这一版新加的三样，最该先看 ----
    deltas = d.counter_deltas()
    if deltas is not None:
        got_any = True
        A(S7("计数器：压测前 → 压测后"))
        A('<p class="sub">这三样都是内核自带的计数器，判定看的是<b>差值</b>而不是绝对值 ——'
          "一台用过的机器带着历史计数是正常的，我们要回答的是「这一轮压测把什么逼出来了」。"
          "<b>热节流</b>那一行尤其值得看：散热不行但温度没到告警线的机器，"
          "只有它看得出来（CPU 自己在降频，温度曲线反而好看）。</p>")
        if deltas:
            A('<div class="dense">%s</div>' % table(deltas))
        else:
            A('<p class="muted">三类计数器压测前后都没有增长。</p>')

    ecc_rows = d.ecc_table()
    if ecc_rows:
        got_any = True
        A(S7("逐条 DIMM 的 ECC 计数"))
        A('<p class="sub">按 BIOS 给的插槽标签归位，可以直接对到主板丝印上。'
          "可纠正错误持续增长是内存条早期退化最直接的信号 ——"
          "机器现在照样能跑，但装到客户机房里会越来越频繁。</p>")
        A('<div class="dense">%s</div>' % table(ecc_rows))

    fw_rows = d.fwupd_devices()
    if fw_rows:
        got_any = True
        A(S7("全机固件版本一览"))
        A('<p class="sub">核对一批机器的固件版本齐不齐时用这张表。'
          "离线也读得到本机现有版本，只有「有没有新版」需要联网。</p>")
        A('<div class="dense">%s</div>' % table(fw_rows))

    lldp_rows = d.lldp_neighbors()
    if lldp_rows:
        got_any = True
        A(S7("网口对端（LLDP 邻居）"))
        A('<p class="sub">这个口接在哪台交换机的哪个口 —— 现场排线错误一眼就看出来。'
          "采集用的是<b>接收模式</b>，我们不往对端发任何通告。</p>")
        A('<div class="dense">%s</div>' % table(lldp_rows))

    optics = d.nic_optics()
    if optics:
        got_any = True
        A(S7("光模块"))
        A('<p class="sub">只有插着模块时才读得到。光口机器出问题时，'
          "收发光功率是最值钱的一份数据 —— 客户报告里没有它。</p>")
        A('<div class="dense">%s</div>' % table(optics))
    breach = d.bmc_sensor_breach()
    if breach:
        got_any = True
        A(S7("越过主板自身上下限的部件传感器"))
        A('<p class="sub">「部件传感器复查」那一条判 WARN / FAIL 的**逐条依据**。'
          "客户报告里只列前六条，这里是全部。</p>")
        A('<div class="dense">%s</div>' % table(breach))
    sensors = d.bmc_sensors()
    if sensors:
        got_any = True
        A(S7("BMC 部件传感器逐条（读数 vs 主板自己写的上下限）"))
        A('<p class="sub">后六列是<b>主板厂商烧进管理控制器的</b>上下限，不是我们定的 —— '
          "这也是全项目唯一一处拿阈值去判的地方（判定在 <code>lib/verify.sh</code>，"
          "这张表只做展示，不重新判一遍）。风扇转速、VRM 温度、各路电压都在这儿；"
          "客户报告里只有一句结论，逐条明细只在这份。"
          "离散量传感器（读数是事件位、没有上下限可言）不在表内，原文见原始文件索引。</p>")
        A('<div class="dense">%s</div>' % table(sensors))
    inv = d.gpu_inventory()
    if inv:
        got_any = True
        A(S7("显卡逐卡清单（压测后读的 PCIe 链路）"))
        A('<div class="dense">%s</div>' % table(
            [OrderedDict((k, v) for k, v in row.items()) for row in inv]))
    for title, rel in (("PCIe 链路详情", "lspci-vv.txt"),
                       ("显卡驱动信息", "gpu-driver-modinfo.txt"),
                       ("驱动与显卡不匹配的内核原话", "gpu-driver-mismatch.txt"),
                       ("扩展 SMART（第一块盘）",
                        "deep/smart-x-%s.txt" % (devs[0] if devs else "none")),
                       ("现场核对过的配置屏", "config-review.txt"),
                       ("联网校时日志", "clock-sync.log"),
                       ("本次开机完整日志", "deep/journal-boot.txt")):
        p = d.rawpath(rel)
        if not os.path.exists(p):
            continue
        txt = read_text(p)
        if not txt.strip():
            continue
        got_any = True
        if len(txt) > 120000:
            txt = txt[:120000] + "\n...（已截断，完整内容见 raw/%s）" % rel
        A(collapsible("%s  [raw/%s]" % (title, rel), txt))
    if not got_any:
        A('<p class="muted">本轮没有采到这一类数据。</p>')

    # ================================================ 八、本轮采集范围说明
    SEC("s8")
    notes = d.scope_notes()
    if notes:
        A('<p class="sub">下面这些项与<b>被测机器的状态无关</b>，是本轮采集条件的客观限制。'
          "客户报告里对应的项一律记 SKIP，不影响整机结论。"
          "「补齐办法」那一列写清楚了下一轮怎么把这份数据取到。</p>")
        A('<div class="dense">%s</div>' % table(
            [OrderedDict([("性质", k), ("本轮未取到的数据", what),
                          ("该数据由什么提供", by), ("证据文件", rel),
                          ("补齐办法", more)])
             for k, what, by, rel, more in notes]))
    else:
        A('<p class="muted">本轮采集是完整的：没有超时，也没有需要专用工具才能取到的项。</p>')

    # ================================================ 九、原始文件索引
    # 本报告自己就在 raw/ 里，所以相对链接直接可用：在 U 盘上双击打开这份 HTML，
    # 点任何一行就能跳到对应的原始文件，不用再去翻目录。
    SEC("s9")
    grouped = d.raw_index_grouped()
    total = sum(len(files) for entries in grouped.values() for _info, files in entries)
    A('<p class="sub">共 %d 个文件。看的人是工程人员不是开发人员，所以这张表除了链接，'
      "还写清楚每一类<b>是什么、什么时候该看它、怎么看</b>。"
      "链接在浏览器里打开本文件时可以直接点开。</p>" % total)
    for group, entries in grouped.items():
        A("<h3>%s</h3>" % E(group))
        # 链接要原样输出、不能被 E() 转义，所以这张表自己拼
        A('<div class="tablewrap dense"><table class="idx"><thead><tr>'
          "<th>文件</th><th>这是什么</th><th>什么时候该看它</th><th>怎么看</th>"
          "</tr></thead><tbody>")
        for info, files in entries:
            links = "".join(
                '<a href="%s">%s <span class="same">(%s)</span></a>'
                % (html.escape(rel), html.escape(rel), E(human_bytes(size) if size else "0 B"))
                for rel, size in files)
            A('<tr><td class="f">%s</td><td>%s</td><td>%s</td><td class="how">%s</td></tr>'
              % (links, E(info[1]), E(info[2]), E(info[3])))
        A("</tbody></table></div>")

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
    ap.add_argument("--run-dir")
    ap.add_argument("--out", default=None)
    # 给 tests/test-internal-report.sh 用：把 rootfs 里所有 capture() 的目标文件名
    # 逐个丢进来，有一个落到 UNKNOWN 就说明"采了数据却没写说明"。
    ap.add_argument("--classify", default=None,
                    help="查一个 raw/ 下的相对路径属于索引里的哪一类")
    a = ap.parse_args()

    if a.classify is not None:
        info = classify_raw(a.classify)
        if info is None:
            print("UNKNOWN\t%s" % a.classify)
            return 1
        print("%s\t%s" % (info[0], info[1]))
        return 0

    if not a.run_dir:
        print("need either --run-dir or --classify", file=sys.stderr)
        return 2
    if not os.path.isdir(a.run_dir):
        print("run-dir does not exist: %s" % a.run_dir, file=sys.stderr)
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
        print("Internal report generator failed: %s" % e, file=sys.stderr)
        traceback.print_exc()
        return 1

    with open(out, "w", encoding="utf-8") as f:
        f.write(doc)

    print("Internal engineering report written: %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
