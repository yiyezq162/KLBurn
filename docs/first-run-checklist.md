# 开工首台真机检查清单

> 这份是**内部**的，不随报告交付。
>
> 用途：拿到第一台真服务器时，照着它一条条过。等真机到手再现想要看什么，
> 一定会漏 —— 而机器通常只借得到半天。

离线能做的验证已经做到头了：[`tests/run-all.sh`](../tests/run-all.sh) 361 项、
[`tests/mutate.sh`](../tests/mutate.sh) 8 条变异、
[`tests/e2e-qemu.sh`](../tests/e2e-qemu.sh) 把盘在 QEMU 里真开机跑完。
**下面这些是 QEMU 结构上盖不到的**，只能上真机。

---

## 零、先看这条

**[`lib/collect.sh`](../rootfs/opt/klburn/lib/collect.sh) 里阵列卡后端物理盘那条路
（v1.2.0 的主功能）一次真机都没验过。** QEMU 里没有 MegaRAID，
单元测试喂的是构造出来的 sysfs 和 smartctl 输出。

它恰恰是最重要的一条：**这条路悄悄失效的表现是「报告写着 PASS，实际一块物理盘
都没查过」**，而带阵列卡的存储机又是最常见的机型。所以第一台能借到的
**带阵列卡的机器**，优先级高于一切。

---

## 一、QEMU 盖不到的，按优先级

| # | 项 | 为什么盖不到 | 看什么才算过 |
|---|---|---|---|
| 1 | **阵列卡后端物理盘 SMART** | 没有 MegaRAID 可模拟 | `raw/smart-pre/` 下要有 `sdX-pdN.txt`，且**内容是物理盘**（有型号/序列号/温度），不是空的逻辑盘。报告硬件清单里逐块列出来 |
| 2 | **压测前后 SMART 真的增长** | 虚拟盘不会长坏道 | 至少确认 `smart-pre` 和 `smart-post` 两边的键**逐项对齐**（同一批 key）。真增长可遇不可求，但对齐是必须的 |
| 3 | **IPMI / BMC** | QEMU 无 BMC | `collect_ipmi` 不再是 SKIP；`raw/ipmi-sdr.txt` 有读数；SEL 能读到 |
| 4 | **电源判定** | 要 BMC 的 Vin 交叉核对 | 双路都插电时 PASS；**故意拔掉一路**，应判 WARN 而不是 FAIL |
| 5 | **真显卡 + gpu_burn** | 无 GPU 直通 | `gpu_detect` PASS、`stress_gpu` 跑满、`gpu_metrics.csv` 有逐卡温度/功耗曲线 |
| 6 | **CPU 温度来源** | QEMU 无 coretemp | `sys_metrics.csv` 的 `cpu_temp_c` 非空；空了不算故障，但要知道这台机器的驱动是哪个 |
| 7 | **PCIe 链路降级** | 虚拟设备无 LnkCap/LnkSta | 有降级的机器上要**只报端点、不报桥**（§11-5） |
| 8 | **网卡协商速率** | 虚拟网卡无 ethtool 速率 | 万兆口跑满时 PASS；**故意插千兆线**应判 WARN |

---

## 二、破坏性写盘：必须在真机上过一次

`stress_disk`（fio 裸盘读写）在 QEMU 完整档里**始终是 SKIP** ——
自动化里绝不能确认破坏性写入。所以这条路真机上一次都没走过。

找一台**盘里没有任何要留的数据**的机器，专门跑一次：

1. 硬盘压测确认那一步，如实打 `yes` 回车
2. 最终警告面板列出的盘 —— **逐块核对**，尤其确认**启动 U 盘不在里面**
3. 按 `y` 开始
4. 跑完拔盘，插 Windows 电脑：**U 盘里的历史报告必须还在，分区必须还能读**

> 这一步是整个项目最危险的一条路径（[§8.2](architecture.md#82-裸盘写入的排除规则storagesh)）。
> `tests/test-disk-exclusion.sh` 用 loop + dm-linear 搭了同构设备链，
> 但那终究是构造出来的。**真机上过一次之前，别把这个功能当成验证过了。**

---

## 三、引导方式

QEMU 里 **BIOS 和 UEFI 两条都验过了**（`--firmware bios|uefi`），
所以真机上主要是补环境相关的：

- [ ] BIOS 启动菜单里能不能看到这根盘（有些机器要关 Secure Boot）
- [ ] **Ventoy 方案**（见 [`usb-rufus.md`](usb-rufus.md) 末尾）——
      走的是四层回退里的**第 0 层**（dm 设备），和 Rufus 完全不同的路径。
      QEMU 里没法真装 Ventoy，只能真机验
- [ ] 报告落盘位置那一行是**绿色**的（`Data partition: /dev/sdb2 -> ...`）。
      黄色大框 = 没认出数据分区，报告只在 /tmp，关机就没了

> 「U 盘上没有可用 exFAT 分区」这个场景 QEMU 里验过了
> （`--no-data-partition`）：报告不会被写到不认识的分区上，流程也不卡死。

---

## 四、每台都要顺手记的

不管测什么机型，跑完把这几样收进内部留档，日后排查全靠它：

- `raw/INTERNAL_*.html`（内部工程报告，**别发出去**）
- `meta.json` 里的 `klburn_version` + `git_commit`
- 屏幕上有没有出现**黄色大框警告**（= 没找到 U 盘数据分区，报告只在 /tmp）
- 有没有哪一项是 SKIP 但**你觉得本来该有**的 —— 那通常意味着采集没覆盖到

---

## 五、发现问题时

**先分清是"能力缺失"还是"硬件故障"。** 判 FAIL 之前问一句：
这台机器真的坏了，还是我们的盘缺个工具 / 驱动太旧 / 现场没接线？

后者一律 SKIP，文案写「此项不影响整机结论」。
**把好机器拦在出货前，比漏判更糟** —— 见
[`report-policy.md`](report-policy.md) 和 [§2](architecture.md#二四条核心原则)。

真发现判定 bug：

1. 把 `raw/` 整个目录留下来（那是唯一的证据）
2. 把触发它的原始日志做成 fixture 加进 `tests/`
3. 修完在 [`tests/mutate.sh`](../tests/mutate.sh) 里加一条变异，确认新守卫真的会红
4. bump 版本 + 写 [`CHANGELOG.md`](../CHANGELOG.md)
