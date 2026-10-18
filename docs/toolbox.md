# 盘里封了哪些工具

full 的两道破坏性硬盘确认使用 Ubuntu `fbterm` 包在帧缓冲上显示 UTF-8 双语，
复用报告已有的 `fonts-wqy-microhei` 字体，不增加桌面环境或输入法。
仅确认期间启动，其他界面仍用原控制台；mem 不安装 fbterm。

本表默认说明整机版 full。1.10.6 起内存专用版 mem 使用 `PKGS_MEM` 精简清单，
只带内存/SPD、压测/ECC、中文 PDF、USB 落盘与联网校时工具，不带
NVIDIA/CUDA、GPU/CPU 性能基准、硬盘/阵列卡/BMC 检测程序。
CPU 微码、显示/网络/USB/启动存储内核驱动及固件仍保留。

> 这份回答一个问题：**这张盘拿到一台陌生服务器面前，靠什么把它查清楚。**
>
> 读者有两种，都照顾到了：
> - **用的人** —— 想知道某一项判定是靠什么读出来的、为什么在我的机器上判了 SKIP
> - **改代码的人** —— 想加一项检查，需要知道现在有什么可用、缺什么要自己放
>
> ⚠️ **这些工具名一个都不许出现在交付报告里**（[`report-policy.md`](report-policy.md) 二-6-2）。
> 客户要的是"这台机器怎么样"，不是"你们用什么查的"。这份文档是内部的。

相关：[`vendor/README.md`](../vendor/README.md)（可选件怎么放进来）、
[`architecture.md` §6](architecture.md#六判定规则总表)（每一项判定的口径）。

---

## 一、一句话总览

盘里的工具分三类，**能不能拿到、缺了会怎样，三类完全不同**：

| 类 | 从哪来 | 缺了会怎样 |
|---|---|---|
| **基础采集与压测** | Ubuntu 源，`build/config.sh` 的 `PKGS_*` | **缺不了** —— 构建时装不上就直接构建失败 |
| **平台增强** | 同上 | 那一格读不出来，对应判定干净地 SKIP |
| **可选件** | 手工放进 `vendor/`，不能重分发 | 对应判定 SKIP，**绝不判 FAIL** |

最后一条是这个项目的一号红线：**能力缺失 ≠ 硬件故障**。
盘里少带一个工具是**我们**的能力缺口，跟被测机器好不好毫无关系
（[`architecture.md` §2-2](architecture.md#2-能力缺失--硬件故障)）。

---

## 二、采集：把这台机器读出来

装机清单在 `build/config.sh` 的 `PKGS_COLLECT`。按"被调用多少次"排，
括号里是运行时代码里实际出现的次数——**不是清单上有就等于在用**。

| 工具 | 读什么 | 喂给哪些判定 | 读不到时 |
|---|---|---|---|
| `dmidecode` (65) | 主板 BIOS 记的一切：整机/主板序列号、CPU、内存条逐条、电源、插槽 | 几乎所有硬件清单、`check_mem_cap`、`check_dimm_uniform`、`check_psu`、`check_sn_consistency` | 整块硬件清单没了 → `collect_system` 判 FAIL（这是唯一一个"读不到就判 FAIL"的采集项） |
| `dmesg` (61) | 内核日志 | `verify_dmesg_boot`、`verify_dmesg`、AER / MCE / 掉盘掉卡 | 判 SKIP |
| `lspci` (49) | PCI 设备树、链路宽度与速率 | `check_pcie_link`、网卡/阵列卡型号反查 | 型号退回驱动名 |
| `lsblk` (30) | 块设备树 | `scan_disks`（**决定哪几块盘会被 fio 写**）、硬盘清单 | 没有可测盘 → 硬盘压测 SKIP |
| `ethtool` (28) | 网口速率、固件版本、**网卡自检** | `check_nic_speed`、`check_nic_uniform`、`check_nic_selftest` | 那几项 SKIP |
| `sensors` (26) | hwmon 温度 | 温度曲线、`collect_sensors` | 曲线不画 |
| `smartctl` (22) | 硬盘 SMART：健康状态、坏道计数、温度、自检 | `verify_smart`、`verify_disk_temp`、`verify_disk_selftest`、1.4 硬盘表 | 那几项 SKIP |
| `nvme` (21) | NVMe 专有信息 | 硬盘清单补充 | 退回 smartctl |
| `ipmitool` (21) | BMC：传感器、SEL 事件、FRU | `verify_sel`、`verify_bmc_sensors`、`check_psu` 交叉验证、`check_sn_consistency` | 无 BMC 的机器判 SKIP（很常见，不是故障） |
| `jq` (19) | 解析 JSON | **整机结论就是它算的**（`results.jsonl`） | 构建时必须在，缺了整个流程无从判定 |
| `lshw` (9) | 整机硬件树留档 | `collect_deep`（只留档不判定） | 少一份存档 |
| `numactl` `lsusb` `lsscsi` `efibootmgr` `hdparm` `sdparm` `sg_ses` | 拓扑 / USB / SCSI / 引导项 / 背板 | `collect_deep`、背板盘位 | 少一份存档 |
| `fwupdmgr` | 固件版本清单 | 2.4 固件版本清单 | 那张表少几行 |

## 三、平台增强：读得更深的那几个

`PKGS_DIAG`。**这几个缺了不影响流程，只是对应的那一格没有数**——
而"没有数"和"正常"必须分得开，所以一律 SKIP 并写明原因。

| 工具 | 读什么 | 缺了会怎样 |
|---|---|---|
| `rasdaemon` / `edac-utils` | 逐 DIMM 的 ECC 计数（`ras-mc-ctl --error-count`） | `verify_ecc` 退回内核 EDAC sysfs 的整机计数，**定位不到是哪一条内存** |
| `mstflint` | Mellanox 网卡固件 | 那几张卡的固件版本读不到 |
| `cpuid` / `msr-tools` | CPU 特性位、MSR（含功耗上限） | 内部报告少几行 |
| `lldpd` | LLDP 邻居（这个口接在哪台交换机的哪个口） | 内部报告里没有拓扑，现场排线错误只能靠人查 |
| `fwts` | BIOS / UEFI / ACPI 合规自检 | `collect_fwts` SKIP。⚠️ 它的结论**无条件不进交付报告**——好机器上 ACPI 告警极常见，印出去每台都刷一片黄 |
| `thermald` | 温控守护 | 无 |
| `intel-microcode` / `amd64-microcode` | CPU 微码 | 报告里的微码版本是"没打补丁"的那个 |

## 四、压测与基准：把机器压满、量出数

| 工具 | 干什么 | 属于 | 缺了会怎样 |
|---|---|---|---|
| `stress-ng` (17) | CPU 全核满载，`--cpu-method all` | `PKGS_STRESS` | 构建失败（缺不了） |
| `stressapptest` (10) | 内存满载 + 数据校验 | 同上 | 同上 |
| `fio` (30) | 硬盘裸盘读写压测**和**顺序带宽基准 | 同上 | 同上 |
| `sysbench` | 备用 | 同上 | — |
| `turbostat` (9) | 逐核频率 / C-state / 封装功耗采样 | `util-linux` 系 | 只留档不判定，起不来就当没有（老平台、虚拟机常见） |
| `libopenblas0-pthread` | **`klburn_flops` 的运行库** | `PKGS_STRESS` | ⚠️ **CPU 浮点算力这一项永远 SKIP**，而且现场看不出原因（程序在，一跑就是找不到动态库） |
| `memtest86+` | GRUB 里挂一个可引导菜单项 | `PKGS_MISC` | 少一个菜单项。⚠️ 它**不是**无人值守流程的一部分：跑完只在屏幕上显示、不落结果文件，进不了报告 |

## 五、可选件：手工放进 `vendor/` 的

**放了就带上，不放就干净地 SKIP，永远不判 FAIL。** 放法见
[`vendor/README.md`](../vendor/README.md)。

| 放什么 | 谁在用 | 不放会怎样 |
|---|---|---|
| `nvidia/*.run` | 显卡识别与压测的前提 | 出一张不含显卡驱动的盘；有卡的机器 GPU 各项 SKIP |
| `gpu_burn/` | `stress_gpu` 满载烤卡 | 显卡型号/显存/驱动版本照常进报告，但没有满载压测，也就没有温度功耗曲线 |
| `bench/cpuflops/klburn_flops` | `bench_cpu_flops`，非 Intel 平台首选；源码 `build/src/klburn-flops.c` 随仓库 | 非 Intel 平台可能无法运行 Intel 专用兜底程序，届时 SKIP |
| `bench/linpack/xlinpack_xeon64` | Intel 平台首选，缺少时退回自研 OpenBLAS 程序 | 两个都不放才 SKIP |
| `bench/mlc/mlc` | `bench_mem_bw` 内存峰值读带宽 | 那一项 SKIP |
| `bench/cuda-samples/` | `bench_gpu_bw_*`（显卡传输/显存带宽）、`bench_gpu_p2p`（卡间互联） | 那几项 SKIP |
| `bench/opendcdiag/` | `validate_cpu_sdc` —— **算完了但算错了**（静默数据损坏 SDC） | 那一项 SKIP，而且是 `origin=self` 的 SKIP：**不进交付报告** |
| `dcgm/dcgmi` | `validate_gpu_diag` 显卡厂商诊断 | 同上；所选版本的再分发条件尚未核实，当前不随盘提供 |
| `storcli64` / `perccli64` / `ssacli` / `sas3ircu` | 阵列卡型号、固件、逻辑盘状态 | 阵列卡只能报 PCI 反查到的型号。**卡后面物理盘的 SMART 不依赖它** |
| 品牌配置中的可选 PNG | 报告抬头 | 默认显示中性的 KLBurn 文字标识 |

1.11.1 的 gpu-burn 构建保留逐架构检查，最终链接未经裁剪的 CUDA 原始静态库，
并附带对应 EULA 与程序许可证。不能把这些第三方组件统称为 MIT；分发条件另见
[第三方说明](third-party.md)。

> **为什么 `origin=self` 的 SKIP 不进交付报告**：客户读到
> 「SKIP 显卡专项诊断 当前测试环境未包含显卡厂商诊断程序」，
> 得到的信息不是"这台机器没问题"，是"这家供应商的工具箱是破的"。
> 那一行对他做"收还是不收"的决定没有任何帮助。1.9.4 之前印出去过，被当面骂了一次。
>
> 反过来一样要守住：**"本机只有一张卡，没有卡间互联可测"照常印**——
> 那讲的是被测机器的事实，客户有权知道哪些没测。

---

## 六、怎么确认一张盘里到底带了什么

不要猜，也不要翻清单——**问那张已经构建出来的盘**：

```bash
./tests/check-firmware.sh --rootfs /home/li/klburn-build/rootfs
```

它现在查三件事：

1. **关键驱动要的固件一个都不能少**（`modinfo -F firmware` 问驱动自己要什么）
2. **有且只有一个内核**、CPU 微码在不在、`pci.ids` 新不新
3. **`tools/bench/` 下每个程序的依赖库都在盘里**（1.9.5 加）

第 3 条守的是最难查的一种失效：程序在盘里、权限也对，一跑就是
`error while loading shared libraries`，而那行报错落进日志里，
判定只看到"这一项没测出结果"——**现场表现是"这一项莫名其妙 SKIP"，
没有人查得出为什么**。`klburn_flops` 依赖 `libopenblas` 就是这么一条线。

构建期还有一道：`chroot-setup.sh` 装完 `vendor/bench/` 之后用 `readelf -d`
逐个自检依赖库在不在，缺了打 WARN（不中断构建——基准程序是可选件）。
