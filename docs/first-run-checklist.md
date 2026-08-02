# 开工首台真机检查清单

> 这份是**内部**的，不随报告交付。
>
> 用途：拿到第一台真服务器时，照着它一条条过。等真机到手再现想要看什么，
> 一定会漏 —— 而机器通常只借得到半天。

离线能做的验证已经做到头了：[`tests/run-all.sh`](../tests/run-all.sh) 400+ 项、
[`tests/mutate.sh`](../tests/mutate.sh) 11 条变异、
[`tests/e2e-qemu.sh`](../tests/e2e-qemu.sh) 把盘在 QEMU 里真开机跑完
（`--disk-stress` 还会真让 fio 写一次盘）、
[`tests/check-firmware.sh`](../tests/check-firmware.sh) 对账盘里的网卡固件。
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
| 9 | **非 Broadcom 阵列卡的管理工具** | `perccli64`/`arcconf`/`ssacli`/`sas3ircu` 这几个闭源二进制我们手上没有，测试里全是桩 | 放好对应工具后，`raw/raid/` 下要有**真的输出**（型号、固件版本、逻辑盘状态），不是一行报错。没放工具时那一项必须是 SKIP，**绝不能是 FAIL** |
| 10 | **需要固件才能起来的网卡** | QEMU 里只有 virtio | 插 `bnx2x`（Broadcom 10G）或 `ice`（Intel E810）的机器上，`ip link` 要看得到物理口，`dmesg` 里不许有 `Direct firmware load ... failed`。1.5.0 之前这些卡在盘里根本起不来 |

### 1.7.0 新增的，一样只能上真机验

| # | 项 | 为什么盖不到 | 看什么才算过 |
|---|---|---|---|
| 11 | **`gpu_burn` 在真显卡上跑得起来** | 无 GPU 直通 | **这条优先级仅次于阵列卡。** 1.6.0 及以前的盘里 `gpu_burn` 只带了 sm_120 一代的 cubin（`nvprune --arch` 重复写不叠加），H200 / 4090 / A100 / 3060 上 cuBLAS 会找不到可用核、非零退出，然后被判成「显卡故障」。1.7.0 改成 `-gencode` 并补了 sm_75。**修法在构建期有自检，但"真卡上真能跑"一次都没验过** —— 第一张能借到的 N 卡上要看到 `stress_gpu` PASS、`gpu-burn.log` 里 `GPU N: OK` |
| 12 | **内存 ECC 计数（`verify_ecc`）** | QEMU 无 EDAC | 有 EDAC 的机器上 `raw/counters-pre.txt` 要有 `ECC` 行、且**标签是插槽名**（`CPU0_DIMM_A1` 这种，能对到主板丝印）。读不到就该是 SKIP，**绝不能是 FAIL** |
| 13 | **CPU 热节流计数（`verify_throttle`）** | QEMU 无 `thermal_throttle` | `counters-pre.txt` 有 `THROTTLE` 行。想主动验一次：把风扇调到最低跑 QUICK，应判 WARN 而不是 FAIL |
| 14 | **PCIe AER 计数（`verify_aer`）** | QEMU 不开 AER | `counters-pre.txt` 有 `AER` 行。固件没开 AER 的机器上该是 SKIP |
| 15 | **LLDP 邻居** | QEMU 无交换机 | 接了交换机的口上 `raw/deep/lldp-neighbors.txt` 要有对端设备名和端口号。**同时确认交换机侧看不到我们发的通告**（我们只用接收模式） |
| 16 | **`fwupdmgr` / `turbostat` / `sg_ses` / `mstflint` / NVMe 厂商插件** | 都要真硬件 | 各自的 `raw/deep/*.txt` 里是真输出而不是一行报错。**这几样都只留档、不参与判定**，读不到不影响任何结论 |
| 17 | **新界面在真 BMC KVM 上** | QEMU 的显示不等于 BMC 的 KVM | 配置核对面板和压测仪表盘的框线要是整齐的 ASCII，不能有乱码或错位；80 列的串口/KVM 下也不许折行 |
| 18 | **HWE 内核（如果启用了 `KLBURN_KERNEL=hwe`）** | 引导链和驱动集全变了 | 默认是 `generic`。要切之前，先在真机上确认：认得到所有硬盘和网卡、`nvidia-smi` 正常、BMC 和阵列卡照常。**这一项没在任何真机上跑过** |

---

## 二、破坏性写盘：QEMU 里过了，真机上还得再过一次

1.5.0 起 QEMU 里能真跑这条了：

```bash
sudo ./tests/e2e-qemu.sh --stage full --disk-stress
```

它会真让 fio 往两块虚拟盘上写满，然后验三件事：空白盘确实被写了、
**开跑前预埋在「U 盘」里的上一轮报告一个字节没变**、`stress_disk` 判 PASS。

**但 QEMU 里的 U 盘是一块 usb-storage 虚拟设备**，真机上是一根插在 xHCI 上的
真 U 盘，中间隔着完全不同的枚举路径。所以真机还得再过一次：

找一台**盘里没有任何要留的数据**的机器，专门跑一次：

1. 硬盘压测确认那一步，如实打 `yes` 回车
2. 最终警告面板列出的盘 —— **逐块核对**，尤其确认**启动 U 盘不在里面**
3. 按 `y` 开始
4. 跑完拔盘，插 Windows 电脑：**U 盘里的历史报告必须还在，分区必须还能读**

> 这一步是整个项目最危险的一条路径（[§8.2](architecture.md#82-裸盘写入的排除规则storagesh)）。
> **Ventoy 盘尤其要单独过一次**：排除有三层，而 Ventoy 场景下前两层
> （`rm=1` / 有分区挂载）**同时**落空，只剩 `live_media_disks` 那一层。

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
