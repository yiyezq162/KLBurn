# KLBurn 开发文档

> 这份是**给改代码的人看的**。只想拿来用（出盘、现场跑测试、看报告）请看
> [`../README.md`](../README.md)；报告文案的红线看
> [`report-policy.md`](report-policy.md)；出 U 盘的步骤看 [`usb-rufus.md`](usb-rufus.md)。

---

## 目录

- [一、这个项目到底在解决什么问题](#一这个项目到底在解决什么问题)
- [二、四条核心原则](#二四条核心原则)
- [三、一次运行的完整时序](#三一次运行的完整时序)
- [四、模块地图](#四模块地图)
- [五、数据流：一次运行产出什么](#五数据流一次运行产出什么)
- [六、判定规则总表](#六判定规则总表)
- [七、阈值与现场覆盖](#七阈值与现场覆盖)
- [八、两处最危险的代码](#八两处最危险的代码)
- [九、构建流水线](#九构建流水线)
- [十、扩展点：加一项新检查](#十扩展点加一项新检查)
- [十一、不变量清单（改代码前必读）](#十一不变量清单改代码前必读)
- [十二、测试地图](#十二测试地图)

---

## 一、这个项目到底在解决什么问题

服务器出厂前要做老化测试。现实中的做法通常是：插个 PE、开几个工具手动跑、
拿手机拍张屏幕当记录。问题有三个：

1. **测得不全。** 手动跑的人只会测他想得起来的项目。少一条内存、
   一路电源没进电、万兆口协商成了千兆、显卡插在 x8 槽上 —— 这些机器照样能开机、
   照样跑得动压测，但客户装到机房里迟早会发现。
2. **没有可信的记录。** 出货半年后客户说"这盘坏了"，我们拿不出当时的 SMART，
   也证明不了发货时是好的。
3. **会把好机器拦下来。** 用关键字匹配判日志、把测试环境自己的问题算成硬件故障，
   一台完全正常的机器被判 FAIL —— 这比漏判更糟，因为它会让人不再相信这套流程。

KLBurn 是一根 U 盘：插上、开机、选个时长，剩下的全自动。测完在 U 盘里留下
一份给客户的中文 HTML 报告，和一整套给我们自己留档的工程数据。

**一个盘通吃所有机型**：无显卡的通用服务器、带阵列卡的存储机、多卡 GPU 服务器。
没有的硬件自动跳过并在报告里标注，不会卡住也不会误判为故障。
**不需要网络也能完整跑完**；接了网线会顺手联网校时、测一下网口通不通，纯属加分项。

---

## 二、四条核心原则

改任何判定逻辑之前，先把这四条读一遍。项目里几乎每一个"看起来多余"的分支，
背后都是这四条之一。

### 1. 四态判定：**没有这个硬件（SKIP）** 和 **有但坏了（FAIL）** 必须分开

所有测试项的状态是 `PASS / FAIL / SKIP / WARN` 四态：

| 状态 | 含义 | 影响整机结论？ |
|---|---|---|
| PASS | 测了，正常 | — |
| FAIL | 测了，有问题 | **是，一条就整机 FAIL** |
| WARN | 有异常读数，但不足以判故障 | 否，但在报告抬头单独列一块 |
| SKIP | 没有这个硬件 / 现场选择跳过 / 我们环境不具备条件 | 否 |

**整机结论只看有没有 FAIL。** 没装阵列卡、没装显卡、没接网线都不影响结论。

**但"一条判定都没有"不算通过。** `results.jsonl` 为空 / 读不出来 / 解析不了
（采集阶段就崩了、U 盘写满了、进程被收掉），1.3.0 之前会走进"没有 FAIL"那一支，
屏幕和交付报告都打出绿色大字 —— 一台什么都没测过的机器看起来是合格的。
现在这种情况判 FAIL，并明确写「本次测试未产生任何判定结果，本报告无效」。
**措辞只说这轮没跑成，不往硬件头上扣帽子** —— 它不是"机器坏了"，是"这份报告作废、
需要重测"。屏幕、交付报告、内部报告三处同一条规矩，
`test-hw-checks.sh` / `test-report-render.sh` / `test-internal-report.sh` 各有断言锁着。

WARN 不拉低结论但要在抬头单独列出来 —— 少一条内存、少接一路电源线这类事，
最容易被漏看，又最该在出厂时拦住，不能只埋在下面的列表里等人翻。

### 2. 能力缺失 ≠ 硬件故障

我们的盘没带某个厂商的管理工具、驱动版本比客户的新卡旧、现场没接网线 ——
这些都是**我们这边环境**的限制，跟被测机器好不好毫无关系。一律判 SKIP，
文案里写明「此项不影响整机结论」。

同理，**测试环境自身的问题绝不能判成硬件故障**：内存压测被 OOM killer 打死
（退出码 137）是测试程序要的容量超过了当时系统能给的，不是内存条坏了。

> 这条是有代价换来的。0.7.0 现场一台完全正常的机器，因为内存压测被 OOM 打死、
> 退出码 137 被当成"测试进程异常退出"判了 FAIL，硬生生被拦在出货前。
> **把好机器拦在出货前，比漏判更糟。**

### 3. 测后复查才是出厂测试的价值所在

压测本身跑完不代表机器没问题 —— 要看压测**把什么逼出来了**：

- 对比测前 / 测后 SMART：有没有新增坏道、CRC 错误、NVMe 介质错误
- 扫 `dmesg`：MCE / EDAC / PCIe AER / I/O error
- 对比 BMC SEL：压测期间有没有新增告警事件
- 温度是否超阈值

只跑压测不做复查，等于花了半小时把机器烤热，然后什么都没测。

### 4. 两份报告，两个读者

同一份数据，两种视角：

| 产物 | 读者 | 只回答一个问题 |
|---|---|---|
| `报告名.html` | 客户的采购或运维 | 这台机器合不合格 |
| `raw/INTERNAL_*.html` | 我们自己 | 这台机器什么成色、这一轮测得干不干净 |

交付报告只放参与判定、或者支撑判定的内容 —— 一块盘几百行 SMART 属性，
绝大部分和"合不合格"无关，全塞进去只会把报告撑成一堆看不懂的数字。
其余参数完整留在工程数据里。

详细规范见 [`report-policy.md`](report-policy.md)，有**三处自动化守卫**盯着，
文案跑偏会直接跑红。

---

## 三、一次运行的完整时序

`klburn.service` 在 tty1 上把 `factory-test.sh` 拉起来，之后是：

```
STEP 1   定位报告存储位置        mount_data_partition()      四层回退，见 §8
         └─ 找不到就黄色大框警告，报告落 /tmp，流程继续

NETWORK  联网校时（best-effort）  try_sync_clock_via_network()
         └─ 必须在算 RUN_STAMP 之前：目录名和时间戳一旦写死就晚了

         建立 RUN_DIR / RAW_DIR，早期日志并入 klburn.log
         时钟可信度自检（年份 < 2024，或早于本介质构建日期 -> 标记存疑）

         select_duration()        30 秒倒计时，默认 STANDARD

PHASE 1  硬件采集                collect_all()
         collect_system → check_memory_capacity → check_pcie_link
         → collect_sensors → collect_smart pre
         → net_link_up_all → collect_nic → check_nic_speed → net_test
         → collect_ipmi → collect_raid → check_psu → gpu_detect
         → collect_deep（只留档，不判定）
         → collect_counters pre（ECC / 热节流 / PCIe AER 的基线）
         → dmesg-pre → verify_dmesg_boot（开机就有硬伤的话，现在就要知道）

REVIEW   config_review()          配置核对面板，60 秒倒计时，任意键继续
         └─ 全部读已经采好的 raw/，不重跑采集；超时自动往下，绝不卡住流程

         confirm_disk_write()     破坏性写入两道确认，默认跳过

PHASE 2  CPU / 内存 / GPU 并发压测   三个子 shell 同时跑满所选时长
         console_quiet_on()        先把内核消息从控制台上压下去
         progress_bar_concurrent() 每 2 秒整屏重绘一次仪表盘

PHASE 3  硬盘压测（单独跑，不并发） 只在两道确认都过了才有
         run_disk_with_dashboard() 同样是整屏重绘，换成逐盘带宽/IOPS/温度视角
         console_quiet_off()       压测全部结束后恢复

PHASE 4  测后复查                verify_all()
         collect_smart post → verify_smart → verify_disk_temp
         → collect_counters post → verify_ecc → verify_throttle → verify_aer
         → verify_dmesg → verify_sel

         写 meta.json
         generate_report.py    -> 报告名.html        （交付）
         generate_internal.py  -> raw/INTERNAL_*.html（内部）

         verdict_banner()  PASS/FAIL 大字 + 收尾菜单 r/p/s/t
```

**为什么顺序不能随便改**（`test-hw-checks.sh` 里有断言锁着）：

| 顺序 | 理由 |
|---|---|
| 校时在 `RUN_STAMP` 之前 | 目录名、meta.json 时间戳都是那时候定的 |
| `net_link_up_all` 在 `collect_nic` 之前 | 口是 down 的时候 ethtool 报的速率/链路状态是假的 |
| `collect_ipmi` 在 `check_psu`/`collect_raid` 之前 | 两者都要用 BMC 传感器交叉核对 |
| `collect_system` 在 `check_pcie_link` 之前 | PCIe 判定读的是它落下的 `lspci-vv.txt` |
| `collect_nic` 在 `check_nic_speed` 之前 | 速率判定读的是它落下的 ethtool 输出 |
| `dmesg-pre` 采集在 `verify_dmesg_boot` 之前 | 否则扫的是个空文件，每台机器都 SKIP |

---

## 四、模块地图

```
rootfs/opt/klburn/
├── factory-test.sh          主流程编排（上面那张时序图就是它）
├── lib/
│   ├── core.sh              日志、capture()、result_add()、温度/功耗读取、机器标识
│   ├── ui.sh                控制台界面：倒计时菜单、配置核对面板、压测仪表盘
│   │                        （框线纯 ASCII、文案全英文、整屏重绘，见 §11-14）
│   ├── storage.sh    ★★★   数据分区发现 + 裸盘排除（全项目最危险的一块）
│   ├── collect.sh           硬件采集 + 内存核对 / PCIe 链路 / 阵列卡 / 电源判定
│   ├── network.sh           网口拉起、联网校时、DHCP+ping 连通性、协商速率核对
│   ├── stress.sh            CPU / 内存 / 硬盘压测 + 采样器 + 日志判读纯函数
│   ├── gpu.sh               显卡探测（含驱动不匹配识别）与压测
│   ├── verify.sh            测后复查：SMART 前后对比、dmesg、SEL、硬盘温度
│   ├── disks.jq             盘筛选规则
│   └── smart.jq             SMART 字段归一化（SATA / SAS / NVMe 统一成一组键）
└── report/
    ├── generate_report.py   客户报告生成器
    └── generate_internal.py 内部工程报告生成器（复用前者的工具函数）
```

### 几个关键函数

| 函数 | 在哪 | 干什么 |
|---|---|---|
| `capture [-t 秒] <文件> <命令...>` | `core.sh` | 所有采集的唯一入口。带超时、吃掉 bash 的 `Killed`、超时留 TIMEOUT 记录 |
| `result_add <id> <名称> <状态> <结论> [证据]` | `core.sh` | 唯一的判定出口。写 `results.jsonl`，屏幕只打 id 和状态 |
| `metric_add <组> <键> <值>` | `core.sh` | 零散数值，进报告的"实测指标"表 |
| `count_lines <文件>` | `core.sh` | 所有计数必须走它，理由见 §11 |
| `live_media_disks()` | `storage.sh` | 反查启动 U 盘。漏一条就可能写穿自己 |
| `resolve_disk_sysfs()` | `storage.sh` | 纯 sysfs 上溯到整盘，不依赖 udev/lsblk |
| `dmesg_hw_error_pattern()` | `verify.sh` | 内核日志里真正代表硬件故障的关键字 |
| `gpu_scan_driver_mismatch()` | `gpu.sh` | 从 NVRM 原话里认出"驱动不支持这张卡" |

**判读类逻辑一律抽成纯函数**（只吃文件路径、只吐字符串，不碰硬件），
这样回归测试可以直接喂真实日志给它。项目里所有 `*_parse_*` / `*_scan_*` /
`*_pattern` 都是这个用途。

---

## 五、数据流：一次运行产出什么

```
                    采集命令
                       │  capture()
                       ▼
              <run-dir>/raw/**            全部原始输出，谁都不许改
                       │
        ┌──────────────┼───────────────┐
        │              │               │
     判定函数      采样器循环       collect_deep()
   result_add()   sys_metrics.csv    raw/deep/**
        │         gpu_metrics.csv    （只留档，不判定）
        ▼              │               │
  results.jsonl        │               │
  metrics.jsonl        │               │
        └──────────────┴───────┬───────┘
                               │
                  ┌────────────┴────────────┐
                  ▼                         ▼
        generate_report.py         generate_internal.py
                  │                         │
          报告名.html  ✅交付        raw/INTERNAL_*.html  🔒内部
```

一次运行的目录长这样：

```
<U盘>\out\20260731_101500_2x-Intel-Xeon-Gold-6530_512GB\
    20260731_101500_2x-Intel-Xeon-Gold-6530_512GB.html   ← 交给客户的就是这个
    klburn.log            全程运行日志
    results.jsonl         每一项判定：id / 名称 / 状态 / 结论 / 证据文件
    metrics.jsonl         零散实测数值
    meta.json             版本、git commit、阈值、时间预算、环境标志
    sys_metrics.csv       每 5 秒：CPU 温度/频率/负载/内存/功耗/逐颗封装温度
    gpu_metrics.csv       每 5 秒：逐卡温度/功耗/频率/利用率/显存
    raw\
        INTERNAL_20260731_101500_....html   ← 内部工程报告，就放在这儿
        dmidecode.txt  lspci-vv.txt  smart-pre\  smart-post\  nic\  stress\
        deep\           扩展留档：光模块、NVMe 控制器参数、完整开机日志……
```

目录名格式 **`日期_时间_CPU型号_内存容量`**，多路机器 CPU 前带路数（`2x-`）。
重名会自动加 `_02` 后缀 —— RTC 停摆的机器上连测两次会得到完全相同的时间戳，
不防一手就会把上一次的报告整个盖掉。

### 为什么内部报告放在 `raw/` 里

防手滑。客户要的是那个和目录同名的 `.html`；`raw/` 整个目录本来就不外发。
文件名再加 `INTERNAL_` 前缀、页面顶部再压一条红色横幅 —— 三道保险。

内部报告就在 `raw/` 里，所以它里面指向 `smart-pre/sda.txt`、`deep/…` 的
相对链接**点开即用**，不用再翻目录。

---

## 六、判定规则总表

| id | 项目 | PASS | WARN | SKIP | FAIL |
|---|---|---|---|---|---|
| `collect_system` | 硬件信息采集 | dmidecode 读到 | — | — | dmidecode 读不到 |
| `check_mem_cap` | 内存容量核对 | 装机 ≈ 识别 | 差值超允差 | 取不到其一 | — |
| `check_pcie_link` | PCIe 链路 | 端点都达额定 | 有降级 | 解析不到 | — |
| `collect_disk` | 硬盘信息采集 | 采到 | 无硬盘 | — | — |
| `collect_nic` | 网卡 | 有物理口 | 无物理口 | — | — |
| `check_nic_speed` | 协商速率 | 都达额定 | 有口没跑满 | 没接网线 | — |
| `test_nic` | 网卡连通性 | 已接线的都 ping 通 | 有口不通 | 一根线都没接 | — |
| `collect_ipmi` | IPMI/BMC | BMC 在线 | — | 无 BMC | — |
| `collect_raid` | 阵列卡 | 采到型号+固件 | BMC 有槽位传感器却全无读数 | 无卡 / 工具不支持该型号 | — |
| `check_psu` | 电源 | 在位且有交流输入 | 没进电 / 分不清 | BIOS 不上报 | **BMC 确认有电、模块仍报异常** |
| `gpu_detect` | GPU | 驱动认全 | — | 无卡 / 无驱动 / **驱动与卡不匹配** | 有卡、驱动认不到、又无不匹配证据 |
| `verify_dmesg_boot` | 开机内核日志 | 无硬件错误 | — | 没采到 | 有硬件错误 |
| `stress_cpu` | CPU 压测 | 无失败项、温度正常 | 温度偏高 | — | 有失败项 / 异常退出 / 超温 |
| `stress_mem` | 内存压测 | 无校验错误 | **被 OOM killer 打死** | — | 有硬件异常/校验错误 |
| `stress_disk` | 硬盘压测 | 无 I/O 错误 | — | 未确认 / 无可测盘 | fio 报错 |
| `stress_gpu` | GPU 压测 | 无计算错误、温度正常 | 温度偏高 / 被 OOM 连坐 | 没带压测程序 | FAULTY 卡 / 计算错误 / 超温 |
| `verify_ecc` | 内存 ECC 复查 | 前后无新增 | **新增可纠正（CE）** | 内核无 EDAC 接口 | **新增不可纠正（UE）** |
| `verify_throttle` | CPU 热节流复查 | 压测期间没节流 | **压测期间有节流** | 无 thermal_throttle 接口 | — |
| `verify_aer` | PCIe 错误计数复查 | 前后无新增 | 新增可纠正 | 固件未开放 AER | **新增不可纠正（致命/非致命）** |
| `verify_smart` | SMART 复查 | 前后无新增 | 测前就有的计数 | 无硬盘 | **前后有增长** |
| `verify_disk_temp` | 硬盘温度 | 都低于告警线 | 偏高 | 都不上报温度 | 超上限 |
| `verify_dmesg` | 内核日志复查 | 无硬件错误 | — | — | 有硬件错误 |
| `verify_sel` | BMC 事件复查 | 无新增 | 新增非告警级 | 无 BMC | 新增告警级 |
| `collect_deep` | 扩展信息留档 | 永远 PASS（只留档不判定） | — | — | — |

几条值得单独说的：

**电源的 FAIL 门槛卡得很死。** 只接一半电源线在测试台上是常态，
所以"没进电"绝不能判故障。判 FAIL 只有一种情况：**BMC 确认这一路有交流输入、
模块却还报异常**。没有 BMC 时 DMI 对"没插线"和"模块坏了"报的都是
`Present, Critical`，光看 DMI 分不出来 —— 这种情况判 WARN 提示人工确认。

**显卡驱动与卡不匹配判 SKIP 不判 FAIL。** 判据是内核里 NVRM 自己打的原话
（`NVRM: ... is not supported by the NVIDIA <版本> driver release`）。
驱动明确说"这张卡我不支持"，那是我们盘里的驱动旧了，跟客户的卡好不好没关系。
只认到一部分卡时还要求"不支持的卡数"能盖住"少认的卡数"，盖不住的部分仍然判 FAIL ——
不能让一张真坏的卡混在不匹配里蒙混过关。

**阵列卡永远不会是 FAIL**，因为它只采集不压测。

**三条计数器判定（1.7.0 新增）判的都是差值，不是绝对值。** 一台用过的机器
带着历史计数是正常的；要回答的是"这一轮压测把什么逼出来了"，和 SMART 前后
对比完全同一个口径。计数器全部取自**内核自带的 sysfs**
（`/sys/devices/system/edac/`、`thermal_throttle/`、`aer_dev_*`），
**不依赖 `ras-mc-ctl` / `edac-util`** —— 盘里带那两个工具只是为了多一份人可读的
原始记录，判定不读它们。读不到接口一律 SKIP：很多平台和虚拟机压根没有 EDAC。

其中**热节流那条最容易被忽略**：散热不行、但温度没到告警线的机器，只有它看得
出来 —— CPU 自己在降频保护，于是温度曲线反而好看，光看温度什么都发现不了。
它判 WARN 不判 FAIL：热节流是保护机制正常工作，机器本身没坏。

---

## 七、阈值与现场覆盖

压测期间每 5 秒采一次样，取整段峰值来判：

| 项目 | 变量 | WARN | FAIL |
|---|---|---|---|
| CPU（`coretemp`/`k10temp`/`zenpower`/`cpu_thermal`，退路是 thermal zone） | `CPU_TEMP_*` | ≥ 95 °C | ≥ 100 °C |
| GPU（`nvidia-smi` 读数，逐卡判） | `GPU_TEMP_*` | ≥ 83 °C | ≥ 90 °C |
| 硬盘（SMART 上报的测后温度，逐盘判） | `DISK_TEMP_*` | ≥ 70 °C | ≥ 80 °C |

默认值写在 [`../rootfs/opt/klburn/lib/core.sh`](../rootfs/opt/klburn/lib/core.sh)，
形如 `: "${CPU_TEMP_WARN:=95}"`。现场想临时改：`Alt+F2` 进另一个控制台，
在 `/opt/klburn/klburn.conf` 里写一行同名赋值即可覆盖。

**实际生效的阈值会写进 `meta.json` 的 `thresholds`，报告里显示的就是这一份** ——
现场改了阈值，报告不会和判定对不上。

### klburn.conf 能覆盖的全部变量

`klburn.conf` 由 `chroot-setup.sh` 在构建时生成（里面是品牌抬头那几项），
现场直接往后追加即可。加载顺序是
`core.sh` → **`klburn.conf`** → `ui.sh` / `storage.sh` / `collect.sh` / `network.sh` /
`gpu.sh` / `stress.sh` / `verify.sh`，所以两边的写法都能被覆盖：`core.sh` 的值先落地
再被覆写，后面几个 lib 的 `: "${VAR:=默认}"` 看到已有值就不动。

| 变量 | 默认 | 定义在 | 作用 |
|---|---|---|---|
| `CPU_TEMP_WARN` / `CPU_TEMP_FAIL` | 95 / 100 | `core.sh` | CPU 峰值温度告警 / 故障线（°C） |
| `GPU_TEMP_WARN` / `GPU_TEMP_FAIL` | 83 / 90 | `core.sh` | 显卡峰值温度，逐卡判 |
| `DISK_TEMP_WARN` / `DISK_TEMP_FAIL` | 70 / 80 | `core.sh` | 硬盘测后温度，逐盘判 |
| `MEM_TEST_PERCENT` | 100 | `stress.sh` | 在算好的可用量之上再打个折。**不是"总内存的百分比"**，算法见上一节 |
| `NET_CARRIER_WAIT` | 8 | `network.sh` | 拉起链路后等载波的秒数（PHY 协商要时间） |
| `NET_DHCP_TIMEOUT` | 20 | `network.sh` | 单口 DHCP 超时 |
| `NET_PING_COUNT` | 4 | `network.sh` | 每个口 ping 网关的次数 |
| `NET_TIME_SYNC_TIMEOUT` | 12 | `network.sh` | 单次校时尝试的超时（chronyd 一次性模式） |
| `NET_TIME_SERVERS` | 阿里 / cn.pool / cloudflare | `network.sh` | 校时候选源，**数组**：`NET_TIME_SERVERS=(ntp.内网.lan)` |
| `MEGARAID_SCAN_MAX` | 32 | `collect.sh` | 阵列卡物理盘有界试探的设备号上限 |
| `MEGARAID_SCAN_MISS` | 12 | `collect.sh` | 连续失败多少次收工。**别定小**：设备号从 8 开始是很常见的排法，定成 4 就永远扫不到 |

> `NET_TIME_SERVERS` 是数组，没有 `: "${arr:=默认}"` 这种写法，所以 `network.sh` 里
> 是用 `declare -p` 判"定义过没有"来兜的。**新增数组型可覆盖项时照这个写**，
> 裸赋值会把现场的覆盖原样顶掉，而且不会有任何报错。

只有阈值那六项会进 `meta.json` 和报告 —— 其余是采集行为参数，不参与判定。

> CPU 那两档 0.6.0 起从 88/98 放宽到 95/100：服务器 CPU 满载跑到 80 多度是常态，
> 88 告警太灵敏，现场每台机器都刷黄。Intel 服务器 CPU 的 Tjmax 一般在 100~105 °C，
> 到 100 度已经在降频保护了，那才是真的散热不行。

**读不到温度就整条跳过，绝不当成故障。** 服务器 CPU 的温度驱动不一定是
`coretemp`/`k10temp`，部分 SATA 盘和阵列卡后面的盘也不通过 SMART 上报温度。

### 内存压测容量怎么算

```
余量   = 总内存的 10%，下限 2GB，上限 8GB
目标量 = (MemAvailable - 余量) × MEM_TEST_PERCENT%      # 默认 100
```

两个坑都踩过，所以是现在这个形状：

1. **不能按"总内存"的百分比算。** live 系统的 overlay 上层在内存里（tmpfs），
   按总内存去分配会直接触发 OOM。
2. **也不能直接按 `MemAvailable` 的百分比算。** 0.7.0 就栽在这：一台 32GB 的机器，
   `MemAvailable` 29194MB，按 95% 取到 27734MB，跑到第 9 分钟被 OOM killer 打死。
   `MemAvailable` 是**此刻**的估计，而测试跑起来之后 tmpfs 还在涨、squashfs 的
   page cache 也在争内存。**必须先扣一个绝对余量，再谈百分比。**

余量取「总内存的 10%，夹在 2GB 和 8GB 之间」，是因为 live 系统本身的占用
**不随机器内存增长**：32GB 机器扣 3.1GB（覆盖约 82%），512GB 机器只扣 8GB（约 98%）——
小内存保守、大内存激进，正好符合"内存越大越该测透"。

### 时间预算

CPU / 内存 / GPU **并发**跑满所选时长，互不占用彼此的时间。
硬盘单独测（fio 裸盘读写要是跟 CPU/内存满载凑一起，带宽/IOPS 会被 CPU 争用扭曲），
额外占所选时长的 30%：

| 档位 | CPU / 内存 / GPU（并发） | 硬盘（之后单独跑） | 压测合计 |
|---|---|---|---|
| QUICK 快速     | 10 分钟 | 3 分钟     | 13 分钟 |
| STANDARD 标准  | 30 分钟 | 9 分钟     | 39 分钟 |
| EXTENDED 加长  | 1 小时  | 18 分钟    | 1 小时 18 分钟 |
| LONG 长测      | 2 小时  | 36 分钟    | 2 小时 36 分钟 |
| SOAK 深度      | 4 小时  | 1 小时 12 分 | 5 小时 12 分钟 |
| ENDURANCE 耐久 | 8 小时  | 2 小时 24 分 | 10 小时 24 分钟 |

不确认破坏性写入时（默认就是不确认）硬盘那段为 0，压测合计就等于所选时长。
"压测合计"不含采集、测后复查和出报告的时间，现场从开机到看到结论还要再多几分钟。

档位的英文 key 存进 `meta.json` 的 `profile`（屏幕上显示的也是它），
报告里显示对应的中文名 —— 两边靠 `generate_report.py` 里的 `PROFILE_TEXT` 对上，
加档位时记得同时加一行映射，认不出来的 key 会原样显示，不会吞掉。

---

## 八、两处最危险的代码

### 8.1 报告落盘的四层回退（`storage.sh`）

0. **所有 device-mapper 设备里文件系统是 exFAT 的**（Ventoy 唯一挂得上的那一个）
1. 卷标是 `KLBURN` 的分区
2. live 介质所在盘上的 exFAT 分区（同一根 U 盘的第二分区）
3. 任意可移动盘上的 exFAT 分区

四层都找不到 → 报告落 `/tmp`，屏幕打黄色大框警告，并把 `lsblk`/`blkid`/
`/sys/block`/dm slaves 链整个倒进 `klburn.log` 存证。

**不要试图"挑一个最合适的"再挂 —— 挑不准。** Ventoy 下 exFAT 分区会同时以
真实分区（`sdb1`）和 dm 映射（`dm-1`）两种身份出现，而真实分区被 device-mapper 以
`FMODE_EXCL` 独占持有，直接挂只会得到 `Can't open blockdev`；Rufus 场景下则相反。
所以是**把所有候选收集起来逐个真去挂，谁能挂上且可写就用谁**。

> 第 0 层是 0.8.0 补的，之前 Ventoy 下会翻车：1~3 层的候选全靠 `blkid` 枚举，
> 而 `blkid` 只扫 `/dev` 下真实存在的节点；Ventoy 禁掉了 udev 规则，
> `/dev/mapper` 下只有 `control`，有时连 `/dev/dm-N` 都不会被创建 ——
> 于是唯一能挂的候选凭空消失，报告落 `/tmp`，关机就没了。
> 第 0 层直接读 `/sys/block/dm-*`（不受 udev 影响），缺设备节点就按 sysfs 里的
> 设备号 `mknod` 补建，再用 `blkid -p` 低层探测（普通 `blkid` 走缓存，
> 刚造出来的节点查不到）。

### 8.1b 阵列卡后面的物理盘（`collect.sh`）

严格说这块不"危险"，但它是**最容易悄悄失效**的一处：阵列卡跑 RAID 模式时
`/dev/sdX` 是逻辑盘，物理盘根本不在 `/dev` 下。直接 `smartctl -a /dev/sda`
读到的是逻辑盘，没有任何 SMART 属性 —— 于是「测前测后 SMART 对比」这一项
在带阵列卡的机器上**整项空跑**：报告写着 PASS，实际一块物理盘都没查过。
而那些盘恰恰是最可能坏的。

透传本身很简单：`smartctl -a -d megaraid,<设备号> /dev/sda`。
难点只在"设备号是多少"，两条路，先走便宜的：

1. **sysfs**：`megaraid_sas` 会把物理盘也注册进 SCSI 层，只是不给它们块设备。
   同一个 host 下"有 SCSI 设备、但 `device/block` 不存在"的那些，target id 就是设备号。
2. **有界试探**：sysfs 什么都没给出来时（不同固件行为不一样），从 0 开始试，
   连续失败 `MEGARAID_SCAN_MISS`（默认 12）次就收工。

不管哪条路，拿到的候选都要**真读一次**才算数（`megaraid_pd_probe`）——
sysfs 的 target id 和阵列卡的设备号并非所有固件都一一对应。

两条路都只在确认了 host 驱动是 `megaraid_sas` 之后才走，
**没有阵列卡的机器一次 smartctl 都不会多跑**。连续失败上限不能定太小：
设备号从 8 开始是很常见的排法，定成 4 就永远扫不到。

采集目标统一收敛到 `SMART_TARGETS[]`，每项是 `key|设备|-d类型`：

```
sda|/dev/sda|                 逻辑盘 / 普通盘
sda-pd8|/dev/sda|megaraid,8   卡后面那块物理盘
```

`collect_smart` / `verify_smart` / `verify_disk_temp` / `collect_deep` 一律按
这个列表走，**不要再各自去 basename 设备路径** —— 物理盘没有 `/dev` 节点，
按路径遍历的话它们一块都覆盖不到，而且不会有任何报错。
测前建立一次、测后原样复用：前后必须逐项对齐，否则"压测前后对比"
就成了拿不同的盘互相比。

### 8.2 裸盘写入的排除规则（`storage.sh`）

被 fio 写的盘必须全部通过这些检查，任一命中就排除：

| 排除条件 | 理由 |
|---|---|
| `loop* ram* zram* sr* fd* dm-* md*` | 虚拟设备 / 软 RAID |
| 是 KLBurn U 盘本身 | 通过 `/cdrom` 挂载源、iso9660 分区、数据分区三条线反查 |
| `removable=1` 或 `hotplug=1` | 任何 USB 设备 |
| 盘上有任何分区已挂载 | 系统在用 |
| 容量为 0 | 空读卡器之类 |

排除的盘和原因会打在屏幕上、也写进报告。

**一旦这里退化，fio 会把启动 U 盘当成空盘写穿** —— 测试盘当场报废，历史报告全丢。
`tests/test-disk-exclusion.sh` 用 loop + 分区 + dm-linear 搭出和 Ventoy 一模一样的
设备链，并**故意删掉 `/dev/mapper` 下的符号链接**来复现 Ventoy 禁用 udev 的条件，
验证仍能反查出启动 U 盘。

破坏性写入前还有两道人工确认：原样打出 `yes` 回车（打错、直接回车、120 秒超时
一律跳过）→ 最终警告面板再列一遍要被擦除的盘，按 `y` 才真的开始（60 秒超时跳过）。
**跳过记 SKIP，不算 FAIL。**

---

## 九、构建流水线

```
1. 准备源 ISO          下载 / 校验（清华镜像，断点续传）
2. 解包 ISO 目录树      xorriso -osirrox（不用 loop mount，WSL 里更稳）
3. 合并 squashfs 层     5 层 → 1 层，丢掉安装器和 HWE 内核
4. chroot 定制          装包 + 铺 KLBurn + 装驱动 + 关掉碍事的服务
5. 打包 squashfs        zstd -19
6. 改引导配置           grub.cfg 加内核参数、删 HWE 菜单项
7. 重算 md5sum.txt
8. 重打包 ISO           引导参数从源 ISO 原样继承，BIOS/UEFI 双引导
9. 拷回 out/
```

耗时：首次约 10~15 分钟（不含下载），之后增量构建约 5~8 分钟。

### 层裁剪

Ubuntu 24.04.4 的 live server ISO 有 5 层 squashfs（下面是压缩后体积）：

| 层 | 大小 | 处理 |
|---|---|---|
| `ubuntu-server-minimal` | 159 MB | **保留**，基础系统 |
| `...ubuntu-server` | 142 MB | **保留**，server 软件集 |
| `...installer` | 671 MB | 丢弃，subiquity 安装器 |
| `...installer.generic` | 256 MB | **保留**，⚠️ 内核和全部驱动模块在这层 |
| `...installer.generic-hwe` | 267 MB | 丢弃，第二套 HWE 内核 |

⚠️ **内核模块（exfat / megaraid_sas / mpt3sas / nvme 等）全在 `installer.generic` 层里**，
丢掉它会得到一个认不到任何硬盘的系统。构建脚本里有自检，合并后找不到
`/lib/modules` 会直接报错停下。

层是靠**文件名里点的个数**表示依赖顺序的，合并时按点数升序叠加。后续层不能用
`unsquashfs -f` 直接往上叠（层里带硬链接时目标已存在会 FATAL），
所以是"解到独立目录 → 处理 overlayfs 删除标记 → rsync 覆盖合并"。

### 网卡固件：live-server 镜像把它剪光了

Ubuntu 的 live-server 镜像里 `linux-firmware` 在 dpkg 眼里是
"install ok installed"，**文件却被剪掉了**（连 `.list` 都删了，看包管理器
完全看不出来）：磁盘上只剩 `amd` / `amd-ucode` / `intel-ucode` / `regulatory.db`。

危害不是"少个功能"，是**报告说谎**。`bnx2x`（Broadcom 10G，Dell R6x0 /
HP Gen8-9 上到处都是）必须先加载固件才能起来；固件不在 → 驱动起不来 →
`ip link` 里一个物理口都看不到 → `collect_nic` 判 WARN「无物理口」。
一台有 4 个网口的机器，报告上写着它没网卡 —— 而且全程零报错，
只在 `dmesg` 里留一行 `Direct firmware load ... failed`。

所以 `chroot-setup.sh` 会 `--reinstall linux-firmware` 装回来，
再按 `config.sh` 的 `FIRMWARE_PRUNE` 剪掉服务器用不到的（616MB → 92MB）。

⚠️ **`FIRMWARE_PRUNE` 是黑名单，必须一直是黑名单。** 漏一条只是多占地方；
换成白名单，漏一条就是"某张网卡的驱动起不来"。
验收在 `tests/check-firmware.sh`：拿 `modinfo -F firmware` 问驱动自己要什么，
剪多了那边当场跑红。

⚠️ 剪 `nvidia/` 那条写的是 `nvidia/[a-z]*`。linux-firmware 的 nouveau GSP 固件
按芯片代号分目录（`ad102` / `ga100` / `gb202`…），而 NVIDIA 驱动自己铺的那份在
`nvidia/595.84/`（数字开头）。写成 `nvidia` 会把后者一起删掉，
而 open 内核模块**没有 GSP 固件就起不来** —— 表现是开机 `nvidia.ko` 加载失败，
被 `gpu.sh` 判 FAIL「驱动加载失败」，好卡判成坏卡。
`chroot-setup.sh` 里有断言把这件事钉在构建期。

### 盘里只能有一个内核

`casper/vmlinuz` 引导哪个内核，`/lib/modules` 下就只该有哪个。

多出来的那套是这么进来的：装 NVIDIA 要 `dkms`，`dkms` 的 Recommends 指向
`linux-headers-generic` 这个**元包**，元包跟着 archive 里最新的 ABI 走，
于是 `linux-image-generic` → 一整套新内核（模块 155MB + `/usr/src` 头文件 157MB）
跟着进盘，而它一行代码都不会被执行。

内核版本**不靠 `ls /lib/modules | head -1` 猜**（那是按字典序取第一个，
而这时候盘里常常有两个）。`build-iso.sh` 用 `bzimage_kver()` 从
`casper/vmlinuz` 的 bzImage 头里读出真正会被引导的版本，传进 chroot。
猜错的两种后果都长得像硬件故障：

- 给不会被引导的那个内核编 NVIDIA 模块 → 开机 `nvidia.ko` 加载失败 → 判「显卡故障」
- 把该留的那套模块当多余的删掉 → 开机认不到任何硬盘

两条硬断言：`chroot-setup.sh` 里清理完必须只剩 `$KVER`；
`build-iso.sh` 出了 chroot 再验一次，**而且要和 `casper/vmlinuz` 对版本** ——
只数数量分不出"清掉多余的"和"清掉该留的"。

⚠️ 清理那步会 `apt-get purge` 元包 + `autoremove`，而 **autoremove 的射程比
想象中远**：第一次跑就顺手带走了 `amd64-microcode`（它是 `linux-image-generic`
的 Recommends）。所以微码和 `thermald` 现在显式列在 `PKGS_PLATFORM` 里
（= 手动安装标记 = autoremove 不碰），
并且「关键工具点名」在清理之后**再跑一遍**。

### vendor/ 离线包

`vendor/` 不进版本库（体积大、有授权限制），构建脚本自动检测：

| 放什么 | 不放会怎样 |
|---|---|
| `vendor/nvidia/NVIDIA-Linux-x86_64-*.run` | 出一张不含显卡驱动的盘，有卡的机器 GPU 项记 SKIP |
| `vendor/gpu_burn/{gpu_burn,compare.fatbin}` | 显卡型号/显存/驱动版本照常进报告，但不做满载压测 |
| `vendor/storcli/storcli64` | 阵列卡只能报 PCI 型号，读不到固件版本和逻辑盘状态 |
| `vendor/{perccli,arcconf,ssacli,sas3ircu}/` | 同上，对应 Dell PERC / Adaptec / HPE Smart Array / IT 模式 HBA。采集时挨个试、命中即用；一个都不放也正常，那一项判 SKIP **不判 FAIL** |
| `vendor/logo.png` | 报告抬头不显示 logo |

`INCLUDE_NVIDIA` **默认按 `vendor/nvidia/` 里有没有驱动自动决定**；
`--with-nvidia` 强制带（缺驱动直接报错，不会静默出一张残盘），`--without-nvidia` 强制不带。

### gpu_burn 为什么必须静态链接

gpu-burn 的 Makefile 默认动态链接 `-lcuda -lcublas -lcudart`，还往二进制里
硬编构建机的 CUDA 路径。但是：

- `libcuda.so` 来自**显卡驱动** → 目标机器上有 ✅
- `libcublas.so` / `libcudart.so` 来自 **CUDA Toolkit** → 目标机器上没有 ❌

直接打包出来的盘一跑就是 `error while loading shared libraries: libcublas.so.12`，
然后被 `gpu_stress()` 判成「gpu_burn 异常退出 → 显卡故障」，纯粹的误杀。

随包带 `.so` 也能解决，但 `libcublasLt.so` 一个就 717MB。所以改成用 `nvprune`
裁剪静态库（只留 `GPU_ARCHS` 里那几代）再静态链接，最后是一个 330MB 出头的
自包含二进制。`chroot-setup.sh` 里有自检：装完用 `ldd` 确认没有动态依赖
cuBLAS/cudart，依赖了就直接让构建失败。

### NVIDIA 驱动必须用 open kernel module

`chroot-setup.sh` 装驱动时显式传 `-M=open`，装完还用 `modinfo -F license` 复核
（open 是 `Dual MIT/GPL`，proprietary 是 `NVIDIA`）。

NVIDIA 的说明是：proprietary 模块只支持到 Turing / Ampere / Ada / Hopper，
**Blackwell 及以后只有 open 模块支持**。用 proprietary 装完，RTX 5090 /
RTX PRO 6000 上 `nvidia-smi` 一张卡都认不到 —— 而那会被记成 FAIL「驱动加载失败」，
把好卡判成坏卡。595 系列的默认值恰好就是 open，但默认值是会变的，不能拿它当保证。

### 抬头（品牌）

全部集中在 [`../build/config.sh`](../build/config.sh) 顶部的「品牌抬头」一块：
`COMPANY_NAME` / `REPORT_TITLE` / `PRODUCT_NAME` / `COMPANY_LOGO_FILE`。
每一项都支持构建期环境变量覆盖（`KLBURN_COMPANY_NAME` 等），
适合同一份源码出多个抬头的盘：

```bash
KLBURN_COMPANY_NAME="XX科技有限公司" sudo -E ./build/build-iso.sh
```

抬头在**构建时**钉进 ISO（`chroot-setup.sh` → `/opt/klburn/klburn.conf` →
`meta.json` → 报告抬头），**现场运行时绝不询问操作员**。
报告生成器里没有任何写死的公司名。

---

## 十、扩展点：加一项新检查

以"加一项风扇转速检查"为例，改动落在四个地方：

**1. 采集** —— 在 `collect.sh` 里落原始数据，一律走 `capture`：

```bash
capture -t 30 "fan-speeds.txt" ipmitool sdr type fan
```

**2. 判读** —— 抽成**纯函数**（只吃文件、只吐字符串），这样测试能直接喂样本：

```bash
# fan_parse_speeds <文件> -> 每行 "风扇名 转速"
fan_parse_speeds() { ... }
```

**3. 判定** —— 唯一出口是 `result_add`，四态想清楚再写：

```bash
check_fans() {
  local rows; rows="$(fan_parse_speeds "$RAW_DIR/fan-speeds.txt")"
  if [[ -z "$rows" ]]; then
    # 读不到 ≠ 有问题
    result_add "check_fans" "风扇" "$ST_SKIP" "本机未提供风扇转速传感器" ""
    return
  fi
  ...
}
```

**4. 挂进汇总入口** —— `collect_all()` 或 `verify_all()`。
**这一步最容易漏，而漏了不会有任何报错**：判定函数还在、只是再没被调用过，
报告里那一项就凭空消失，既不是 PASS 也不是 SKIP。所以
`test-hw-checks.sh` 里有一组"汇总入口调用链不能少人"的断言，
加了新检查记得同时加进那个列表。

写文案时对照 [`report-policy.md`](report-policy.md)：客户可见的 detail 里
不许出现内部用语，`test-hw-checks.sh` 的全局扫描会自动约束新写的文案。

需要给内部报告加解读的话，在 `generate_internal.py` 的 `assess()` 里加一条 finding
（`GOOD/WATCH/RISK/INFO` 四级），它**不影响整机结论**。

最后：`./tests/run-all.sh`。

---

## 十一、不变量清单（改代码前必读）

这些每一条都对应一次真实的翻车。改到相关代码时别退回去。

### 判读类

1. **绝不用 `grep -q '关键字'` 判压测日志。** `stressapptest`/`stress-ng`/`gpu_burn`
   正常跑完的日志里本来就带 `Found 0 hardware incidents`、`errors: 0`、`failed: 0`。
   早期版本这么写，结果是**每一台好机器都被判 FAIL**。一律把数字抠出来做数值比较。

   **这条也管 JSON。** 整机结论（`factory-test.sh` 里那个 PASS/FAIL 大字）曾经是
   `grep -q '"status":"FAIL"' results.jsonl` 判的 —— 能用纯粹因为 `jq -cn` 的紧凑
   输出恰好没有空格，格式一变就永远匹配不上，不会有任何报错，表现是**每台机器
   都显示绿色 PASS**。1.3.0 改成 `jq` 解析，和报告生成器走同一条路。
   判错方向是把坏机器放出厂，比误伤好机器更糟。
2. **多卡 gpu_burn 的错误数写在同一行、用 ` - ` 分隔**（`errors: 0 - 14`），
   要取 `errors:` 到 `temps:` 之间的**全部**数字求和，只匹配第一个会漏掉后面几张卡。
3. **退出码 137（OOM）必须排在"异常退出"判定之前**，并且判 WARN 不判 FAIL。
4. **dmesg 关键字不能用裸 `NMI`**（会命中每台机器开机都有的三行正常日志），
   也不能用 `EDAC.*(CE|UE)`（"CE" 在 SOURCE/DEVICE/INTERFACE 里都有）。
   加新关键字必须同时在真故障日志和健康机日志上各跑一遍。

   **豁免噪声时反过来也要卡死。** 漏豁免会误伤好机器，至少看得见；
   **豁免扩大化会把真故障一起吃掉，而且永远不会有人发现**。
   `dev fd[0-9]`（软驱，BMC 虚拟媒体挂的那种真机上也有）是唯一按设备名豁免的，
   写成 `dev [a-z]` 就会把 `sda`/`nvme0n1` 的 I/O error 一起放过。
   每加一条设备名豁免，都要同时补一组"真盘必须照常命中"的成对断言。
5. **PCIe 链路只查端点，绝对不能查 PCI bridge。** 桥的 LnkCap 是槽位能力、
   LnkSta 是与对端协商的结果，对端是张老卡就必然降速，这是设计如此。
   用**白名单**挑设备类而不是"排除桥"：白名单漏一类顶多少查一个设备，
   黑名单漏一类就是满屏误报。
6. **显卡驱动不匹配的 PCI 地址不在 "not supported by" 那一行上** ——
   NVRM 长消息是折行打的，地址在前一行的 `The NVIDIA GPU <地址>` 上。

### Shell 陷阱

7. **所有计数走 `count_lines()`。** `grep -c` 在计数为 0 时**既打印 "0" 又返回 1**，
   于是 `$(grep -c . f || echo 0)` 得到两行的 `"0\n0"`，拿去做算术直接报错，
   而且**只在健康机器上发作**（干净机器的 dmesg-errors.txt 必然是空的）。
8. **同一条 `local` 里后一个变量看不到前一个刚赋的值**（bash 在调用 local 之前
   就把参数全展开了）。`mem_gap_tolerance_mb` 和 `net_dhcp` 都栽过。
9. **`set -e`/`pipefail` 下，一次失败的赋值型命令替换能把整个脚本静默杀死。**
   `config.sh` 里的 `getent`、`chroot-setup.sh` 里的 `find` 都栽过 —— 一律 `|| true`。
10. **`... | grep -q X && echo yes || echo no` 在 `pipefail` 下是错的。**
    `grep -q` 匹配到就退出，上游吃到 SIGPIPE 返回 141，整条管道判失败，
    于是"匹配成功"反而走 `||` 分支。先数数再比。
11. **正则匹配不到"以中文标点结尾 + 反斜杠"的行。** 实测 GNU sed 4.9 / gawk 上
    `/\\$/` 对 `。\` 收尾的行匹配失败，拼接续行要按字符取最后一位，绕开正则引擎。
12. **`${#arr[@]:-0}` 不是合法写法**（取长度不能和 `:-` 默认值连用），
    bash 报 `bad substitution`。数组在文件顶部声明过就直接取长度。
    这个错在判定路径上会被吞掉，表现成"所有盘的 SMART 复查都变 SKIP"。
13. **测试脚本 source 被测的 lib 时，当心同名函数。** `core.sh` 里也有 `ok()`，
    一旦把测试自己的 `ok()` 顶掉，后面的断言会照常打勾却不再计数 ——
    屏幕全绿、总数悄悄少一截（实测少了 40 条）。
    `test-hw-checks.sh` 末尾有一条自检守着这件事。

### 界面与流程

14. **不要用 `\033[A` 做粘滞刷新区。** 只要有别的东西往控制台上写
    （内核 OOM 消息、bash 的 `Killed`、并发子 shell 的日志），光标就不在预期位置，
    之后每次 `\r` 都回到错的行，看着就像整个程序卡死。

    1.7.0 起改成**整屏定期重绘**：每 2 秒 `ESC[H ESC[2J` + 从第一行画一遍。
    被别人写脏了下一次重绘自动修好，不跟光标较劲。**但这有前提**，三条都要成立：
    - 压测子进程的 stdout/stderr 全部重定向进日志文件，一个字都不上屏
    - 进仪表盘前 `console_quiet_on`（`dmesg -n 1`）把内核消息压下去，
      退出时 `console_quiet_off` 恢复；只动 console loglevel，**不动 ring buffer**
      （dmesg 采集和 OOM 判定读的都是 ring buffer）
    - `capture()` 里吃掉 bash `Killed` 的那层不能动

    单行 `\r` 只剩两处，都是"这时候屏幕上没有别的写入者"的场景：
    时长选择菜单、配置核对面板的倒计时。

23. **框线只用 ASCII（`+ - | =`），屏幕上不许出现任何非 ASCII 字节。**
    现场是通过 BMC 的 KVM 或串口看这块屏幕的，字体和字符集都不受我们控制，
    一个 Unicode 制表符就能把整屏顶成乱码 —— 而那块屏幕是操作员判断
    "机器现在什么状态"、以及"要不要擦这几块盘"的唯一依据。
    所有进面板的文本都过 `ascii_clean()`（`ui.sh`），那是唯一的收口处：
    型号串来自 dmidecode / nvidia-smi，理论上带得进非 ASCII 字节。
    `tests/test-screen-render.sh` 逐行扫渲染输出，一个字节都不放过。

24. **面板每一行都必须正好等于面板宽度。** 多一列就折行，折行之后整屏重绘的
    行数就对不上，画出来是滚动的碎片。宽度跟着 `tput cols` 走但夹在 80~120 之间
    （下限是串口/BMC 的 80 列，上限是"再宽一行扫不过来"）。
    列宽靠 `printf '%-*.*s'` 同时补齐和截断，不许只补不截。
15. **并发压测期间只能有一个采样器。** CPU 和内存各起一个会同时往
    `sys_metrics.csv` 里写，同一时刻的数据记两遍，报告曲线每个点画两次，
    还可能撞出两行表头。
16. **`cleanup` 必须 `pkill -P` 再 `kill`。** 真正干活的进程是子 shell 的子进程，
    只 kill 子 shell 的话孙进程会被 init 收养后继续往已收尾的 csv 里写。
17. **新增 CSV 列一律加在末尾。** 报告生成器用 `csv.DictReader` 按列名取值，
    中间插一列会让老数据错位。
18. **报告目录重名要避开，不能覆盖。** RTC 停摆的机器每次开机回退到完全相同的
    时间点，连测两次会得到一模一样的目录名。

### 采集覆盖面

19. **不要按 `/dev` 路径遍历要采 SMART 的盘。** 阵列卡后面的物理盘没有 `/dev`
    节点，按路径走的话它们一块都覆盖不到，而且不会有任何报错 ——
    统一走 `SMART_TARGETS[]`（见 §8.1b）。

### 交付边界

20. **交付报告里不出现内部用语**，包括嵌入的原始文件内容和折叠块标题里的
    `raw/xxx.txt` 路径（文件名往往就是工具名）。采集失败标记
    （`(command not found: ...)` / `(TIMEOUT after ...)`）要从嵌入内容里剔掉。
21. **交付报告只列参与判定的字段**；寿命类字段不参与判定，留在工程数据里。
22. **内部评估绝不能反过来改变整机结论。** 结论只看 `results.jsonl` 里有没有 FAIL。

---

## 十二、测试地图

全部不需要真实服务器硬件，在 WSL 里随时可跑：

```bash
./tests/run-all.sh
```

| 测试 | 锁住什么 | 改了谁就要跑 |
|---|---|---|
| `lint.sh` | shellcheck 静态检查。build/（开了 `set -Eeuo pipefail`、以 root 跑）和 rootfs+tests（不开 `-e`）两套豁免规则，**豁免类数本身也有断言守着**。没装 shellcheck 就跳过 | 任何 `.sh` |
| `test-log-parsing.sh` | 压测日志判读、OOM 不判故障、**显卡驱动不匹配不判成坏卡** | `lib/stress.sh`、`lib/gpu.sh` |
| `test-hw-checks.sh` | 内存核对、电源判定、网卡判读、阵列卡 BMC 交叉核对、硬盘温度、PCIe 链路、开机内核日志、dm 设备枚举、**客户文案不许有内部用语**、**计数不能算出 `0\n0`**、**汇总入口调用链不能少人**、**整机结论必须解析 JSON 而不是匹配文本** | `lib/collect.sh`、`lib/network.sh`、`lib/verify.sh`、`lib/core.sh`、`lib/storage.sh`、`factory-test.sh` |
| `test-screen-render.sh` | 现场界面：**屏幕输出里不许有非 ASCII 字节**、每行正好等于面板宽度（80/100/120 三档）、8 卡全显示 / 9 卡显示 8 + `and 1 more`、缺硬件整块不渲染、读不到数据画 `--` 不画 0、配置面板装不下时砍最长的那段而不是滚屏；另有一组源码守卫（不许再出现 `\033[A`、不许有 Unicode 制表符、`console_quiet_on/off` 要成对） | `lib/ui.sh`、`lib/core.sh` 的读数函数、`factory-test.sh` |
| `test-report-render.sh` | 客户报告渲染：不泄露通电时间/git hash/内部用语、`Unknown!` 归一化、二级编号不跳号、空 run-dir 不崩 | `report/generate_report.py` |
| `test-internal-report.sh` | 内部报告**必须**含通电时间/commit/内部工具名；内部评估要抓得住温差/混插/磨损/不匹配/链路降级；**内部评估不改变整机结论**；老 run-dir 不崩 | `report/generate_internal.py` |
| `test-capture.sh` | 采集超时不把 bash 的 `Killed` 漏到屏幕上，且要留下 TIMEOUT 记录 | `lib/core.sh` |
| `test-concurrent-burn.sh` | CPU/内存/GPU 是真并发不是排队、并发期间只能有一个采样器、cleanup 要连孙进程一起收 | `factory-test.sh`、`lib/ui.sh`、`lib/gpu.sh`、`lib/stress.sh` |
| `test-disk-exclusion.sh` | U 盘反查排除（Ventoy 同构设备链）。**需要 root** | `lib/storage.sh` |

上面这些都在 `run-all.sh` 里。下面两条**不在**，要单独跑：

| 测试 | 锁住什么 | 什么时候跑 |
|---|---|---|
| `e2e-qemu.sh` | **把出好的 ISO 在 QEMU 里真的启动一次**：能不能引导、数据分区认不认得出、报告有没有真的落到"U 盘"上、盘里跑的是不是这次构建的代码。**需要 root**（losetup / 挂 exFAT / KVM） | 出盘之后、发货之前 |
| `check-firmware.sh` | **盘里关键驱动要的固件一个都不能少**：拿 `modinfo -F firmware` 问驱动自己要什么，再逐个去 `<rootfs>/lib/firmware` 下找。顺带复核"有且只有一个内核"和 CPU 微码在不在 | 构建之后（它查的是构建工作区里的 rootfs） |
| `mutate.sh` | 把已修好的 bug 逐个塞回代码，确认对应的用例真的会跑红。**逃掉 = 那条守卫是摆设** | 改了任何判定逻辑或守卫之后 |

```bash
sudo ./tests/e2e-qemu.sh                          # BIOS 冒烟，约 3 分钟
sudo ./tests/e2e-qemu.sh --firmware uefi          # UEFI（OVMF + q35）
sudo ./tests/e2e-qemu.sh --no-data-partition      # U 盘上没有可用 exFAT 分区
sudo ./tests/e2e-qemu.sh --stage full             # 完整跑一遍 QUICK 档，约 20 分钟
sudo ./tests/e2e-qemu.sh --stage full --disk-stress   # 再加上"fio 真写盘"，约 20 分钟
./tests/check-firmware.sh                         # 固件对账，几秒
./tests/mutate.sh                                 # 全部变异，约 3~5 分钟
./tests/mutate.sh --list                          # 看有哪些变异、各由谁守
```

`check-firmware.sh` 之所以不能进 `run-all.sh`：它要一个**已经构建出来的 rootfs**
（默认 `${KLBURN_WORK:-$HOME}/klburn-build/rootfs`，也可以 `--rootfs` 指定），
没构建过就无从查起 —— 定位和 `e2e-qemu.sh` 一样。
没有 rootfs 时它判 0 项跳过，不判失败。

> 它守的东西没有别的测试能替：live-server 镜像把 `linux-firmware` 的文件剪光了，
> 而 `bnx2x` 这类驱动**必须先加载固件才能起来**。固件不在 → 驱动起不来 →
> `ip link` 里一个物理口都看不到 → `collect_nic` 判 WARN「无物理口」。
> **一台有 4 个网口的机器，报告上写着它没网卡**，全程零报错。
> 这种"少一整块硬件"的失效，单元测试和 QEMU 都造不出来。

**BIOS 和 UEFI 两条都要跑。** ISO 是双引导的，但两条走的引导链完全不同
（SeaBIOS + isohybrid MBR vs OVMF + ESP 里的 grub），只验一条等于只验了一半 ——
而真服务器基本都是 UEFI。

`--no-data-partition` 把第 4 个分区格成 ext4，四层回退一层都不会命中。
验的是**报告不会被写到不该写的地方、流程也不卡死**；
"屏幕上有没有打黄色大框警告"程序断言不了，看 `shot-15.ppm`（那个框只停 8 秒）。

### 破坏性 fio 真写盘（`--disk-stress`）

```bash
sudo ./tests/e2e-qemu.sh --stage full --disk-stress --workdir /home/li/e2e-ds   # 约 20 分钟
```

守的是**全项目最危险的一条路径**：fio 往裸盘写随机数据，而启动 U 盘就插在
同一台机器上。反查排除一旦退化，测试盘当场报废、历史报告全丢，不可逆。
在这之前，守它的只有 `test-disk-exclusion.sh` 用 loop + dm-linear 搭的设备链，
**一次都没真让 fio 跑起来写过盘**。

难点是那两道确认提示出现的时刻不固定（在 `collect_all` 之后，采集耗时随机器变），
**按时间盲发按键不可接受 —— 按错方向就是真擦盘**。

解法是**轮询 `usb.img`**：虚拟机写进 exFAT 的 `klburn.log`，在宿主机看来就是
镜像里的一段字节，跑着的时候直接 `grep -a` 就能看到（实测延迟 3 秒以内；
U 盘那块**没有** `cache=unsafe`，flush 是真会落盘的）。四个锚点：

| 锚点（`klburn.log` 里的字串） | 意思 | 接着做什么 |
|---|---|---|
| `Report      :` | 开机完成，时长菜单要出来了 | 发**一次** `1`（菜单是单键读，多发的会漏进下一个提示的整行读取，`1yes` ≠ `yes`） |
| `live media disks` | 选档生效、`scan_disks` 开始了 | 等采集 |
| `verify_dmesg_boot` | `collect_all` 的最后一条日志 | 等 3 秒，发一个 `spc` 把配置核对面板放过去 |
| `Configuration review done` | 配置核对面板已过 | 等 3 秒，发 `y` `e` `s` `ret` |
| `Disk stress test confirmed by operator` | 两道确认都过了 | 等 fio 跑完 |

> `Configuration review done` 是 1.7.0 加的。在那之前 `verify_dmesg_boot` 之后
> 紧接着就是写确认，直接发 `yes` 就行；加了配置核对面板以后，`y` 会被面板的
> **单键读**吃掉，剩下 `es` 进整行读 —— 不等于 `yes`，这一轮就静默变成了跳过，
> 而表面上看像是确认机制不灵。放过面板用的那个 `spc` 是特意选的：
> 万一它落到后面那个整行读上，`confirm_disk_write` 会先把空白全部去掉再比
> （`norm="${answer//[[:space:]]/}"`），一个前导空格不会把 `yes` 变成别的东西。

第二道（最终警告面板）没有自己的日志锚点（面板只是 `printf`），
但它紧跟第一道、中间不做任何硬件动作，时间窗是确定的，而且面板本身有 60s 超时；
发完之后有锚点可验，没过就补发一次。

开跑前还有一条断言：**四个锚点在开机前都不能已经在镜像里**。
否则轮询会在第 0 秒误命中，确认键就在完全错误的时刻发出去 —— 而这一轮的按键
是"确认擦盘"。

三条验收缺一不可：

1. 两块 `spare*.img` 的**实际占用**从 ~0 涨到 GB 级，且头 1MB 有非零字节 —— fio 真写了
2. `usb.img` 第 4 分区还挂得上，**而且开跑前预埋的"上一轮的报告"一个字节没变** ——
   只验"挂得上"不够：分区表没被动、文件全没了照样挂得上
3. `results.jsonl` 里 `stress_disk` 是 **PASS 不是 SKIP** —— SKIP 也能让整轮"全绿"，
   而它意味着确认键没打中、这一轮根本没写过盘

**它验过自己会红。** 把 `scan_disks` 的排除判断整个反过来
（`if [[ -n "$why" ]]` → `if [[ -z "$why" ]]`，启动 U 盘就成了 fio 的目标），
出一张变异 ISO 跑一次 —— 结果是 7 项通过、2 项失败、退出码 1：

```
FAIL 日志里没有 fio 启动的痕迹      <- fio 把 klburn.log 所在的那块分区写掉了
FAIL 第 4 个分区挂不上              <- 连文件系统都没了
```

第一条正是"写穿"的指纹：harness 轮询的那份日志，本身就躺在被 fio 写的那块盘上。

> 这条变异**不能**放进 `mutate.sh`：它要重新出一张 ISO 再跑 20 分钟，
> 而 `mutate.sh` 的契约是"3~5 分钟、不需要构建"。
> 挂进去会让每次跑变异都变成一小时。
> 单元级那条（`media-blind`）在 `mutate.sh` 里，够日常用。

### e2e 仍然**没有**覆盖的场景

| 场景 | 为什么没做 | 怎么补 |
|---|---|---|
| **Ventoy 的 dm 设备链** | QEMU 里没法真装 Ventoy。反查逻辑由 `test-disk-exclusion.sh`（loop + dm-linear 同构设备链）和 `test-hw-checks.sh` 里那组"Ventoy 形状的启动盘必须被排除"覆盖，后者还有 `media-blind` 变异守着 | 真机上用 Ventoy 盘跑一次 |
| **厂商管理工具的真实输出** | `perccli64` / `arcconf` / `ssacli` / `sas3ircu` 这几个闭源二进制我们手上没有，测试里全是桩 | 拿到真卡时核 `raw/raid/` 下的原始输出 |

> 顺带：那张排除表的措辞是 e2e 截图看出问题的 —— 软驱 `/dev/fd0` 原来被标成
> "virtual / software RAID device"。那块屏幕是操作员决定"要不要擦这些盘"时
> 唯一的依据，一条理由明显对不上，他就会开始怀疑整张表。

**`mutate.sh` 绝对不能挂进 `run-all.sh`** —— 它自己会去调各个测试套件，
挂进去就成了递归。

### 这三样加起来仍然盖不到什么

QEMU 里没有 BMC、没有阵列卡、没有真显卡，虚拟盘也不会长坏道。
**尤其是阵列卡后端物理盘那条路（v1.2.0 的主功能）一次真机都没验过**，
而它悄悄失效的表现正是"报告写着 PASS，实际一块物理盘都没查过"。

拿到真机时照 [`first-run-checklist.md`](first-run-checklist.md) 过一遍，
那份列清楚了哪些项只能上真机、每项看到什么才算过。

### e2e 怎么模拟一根 U 盘

Rufus 的 DD 模式就是把 ISO 原样写进 U 盘再在剩余空间建 exFAT 分区，脚本对着
一个文件做同一件事：`cp ISO` → `truncate` 撑大 → `sgdisk -e` 把 GPT 备份头挪到
新末尾 → 建第 4 个分区（ISO 自带 3 个）→ `mkfs.exfat -n KLBURN`。

`klburn.service` 钉死在 tty1 上，串口读不到 UI，所以按键走 QEMU monitor 的
`sendkey` —— 和现场工程师按键盘是同一条路径，**不需要给产品加"无人值守模式"**。
断言则全部落在磁盘产物上：跑完把第 4 个分区挂起来看。

两个踩过的坑写在脚本里，改的时候别退回去：**U 盘那块不能加 `cache=unsafe`**
（QEMU 会忽略 flush，虚拟机一停写入就没了，现象和"产品没落盘"一模一样），
**USB 设备必须给 `bootindex=0`**（挂了空白盘之后 SeaBIOS 会先去试那几块 virtio 盘，
失败后不会回落到 USB，直接 "No bootable device"）。

**这套测试做过变异验证**：把每个已修复的 bug 逐个塞回代码里，确认对应的用例真的会跑红
（一个从没红过的测试等于没写）。其中两次变异一开始没被抓住：

- "把 `verify_disk_temp` 从 `verify_all` 里删掉" —— 判定函数还在、只是再没被调用过，
  报告里那一项凭空消失。后来加了"汇总入口调用链不能少人"那组守卫才堵上。
- "客户文案守卫" 本身曾经是个摆设：它用 `grep -oE 'result_add [^\n]*'` 扫，
  而 grep 是逐行工作的，**只能看到调用的第一行**，所有长文案都写在续行里。
  于是一句「本测试盘未包含」大摇大摆地进了客户报告。现在先拼续行再扫，
  并且专门加了一条"守卫必须抓得住违规文案"的自检断言。

---

## 版本与可追溯

`build/config.sh` 里的 `KLBURN_VERSION` 每次改完脚本都要往上加一格，
**先 bump 再构建**。

0.3.0 出过一次悬案：ISO 构建完之后又改了 `core.sh`/`collect.sh` 却没动版本号，
现场那根盘自称 0.3.0、跑的却是修复前的代码，对着仓库怎么看都对不上。
所以构建脚本还会把源码的 **git commit hash + 工作区脏不脏**钉进盘里
（版本号靠人记得 bump，commit hash 是脚本自己取的，骗不了人）。

这些都写进 `meta.json`，**只出现在内部工程报告里**，客户报告的页脚一个字都没有。
