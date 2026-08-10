# KLBurn —— 服务器出厂老化测试 U 盘

插上 U 盘，开机，走开。跑完拔盘，U 盘里多出一份**中文验收报告**（HTML + PDF），
连同全部原始数据。**不装系统、不联网、不依赖任何服务端。**

```
插盘 → 开机 → 选范围（60秒倒计时）→ 选时长（30秒倒计时）→ 走开
        两个菜单不按都用默认：全量测试 + 标准 30 分钟
                      ↓
   U 盘里多出一个文件夹：报告 + 全部原始数据 ← PASS / FAIL 大字
```

基于 Ubuntu Server 24.04.4 LTS 重打包。接了网线会顺手做联网校时和网口连通性测试，
**纯属加分项，不接网线不影响任何判定。**

---

## 先看这里：你是哪种读者

| 你要干的事 | 看这份 |
|---|---|
| **拿着盘站在服务器前面** | [`docs/operating.md`](docs/operating.md) —— 每一屏长什么样、怎么选、出问题怎么办 |
| **看懂跑出来的报告** | [`docs/reports.md`](docs/reports.md) —— 产出哪些文件、哪份交付、六个范围各长什么样 |
| **做一根 U 盘** | [`docs/usb-rufus.md`](docs/usb-rufus.md) —— Rufus 写盘 + 建 exFAT 分区 |
| **出盘 / 发版** | [`docs/building.md`](docs/building.md) —— 构建、换抬头、发布顺序 |
| **想知道盘里有什么工具** | [`docs/toolbox.md`](docs/toolbox.md) —— 每个工具管什么、缺了会怎样 |
| **改代码** | [`docs/architecture.md`](docs/architecture.md) —— 模块地图、判定总表、**改代码前必读的不变量清单** |
| **写报告文案** | [`docs/report-policy.md`](docs/report-policy.md) —— 哪些东西绝不能给客户看 |
| **第一次拿真机跑** | [`docs/first-run-checklist.md`](docs/first-run-checklist.md) —— QEMU 盖不到的那些 |
| **手里有份旧报告，想知道那张盘当时会干什么** | [`CHANGELOG.md`](CHANGELOG.md)（报告里写着版本号） |

---

## 六个入口：整机全测，还是只测一个部件

开机第一个菜单问的是**测什么**：

| 键 | 范围 | 报告目录后缀 | 用在哪 |
|---|---|---|---|
| **1** | **全量测试**（默认） | `_Full` | **出厂验收就用它** |
| 2 | CPU 单独测试 | `_CPU` | 换过 CPU、或怀疑算力 / 算错 |
| 3 | 内存单独测试 | `_MEM` | 换过内存条、或查 ECC |
| 4 | 显卡单独测试 | `_GPU` | 只验显卡，不陪跑一整轮 |
| 5 | 硬盘单独测试 | `_DISK` | 只压盘，**时长全给硬盘** |
| 6 | 仅导出报告 | `_INFO` | 只要一份配置清单，几分钟出结果 |

不管选哪个，**硬件清单、配置核对、网卡三项都照跑**。范围以外的项目
**整项不做，报告里也不会出现对应的结论行**。

> ⚠️ **单项专测的报告不能当整机验收依据。** 报告抬头第一行就写着本轮范围，
> 结论下面还有一句"哪些部件这一轮没测"；"仅导出报告"那一档**不会出现 PASS 大字**。
> 批次汇总里这些机器写成 `PASS(CPU)` 这种形状，排序筛选时和 `PASS` 不是同一个值。

---

## 它测什么

| 阶段 | 干什么 | 出什么结论 |
|---|---|---|
| **① 硬件信息采集** | 整机 / CPU / 内存逐条 / 硬盘（含阵列卡后面的物理盘）/ 网卡 / 显卡 / 电源 / BMC | 硬件清单，"有啥列啥，没有的标未安装" |
| **② 配置一致性核对** | 同规格部件型号与固件是否一致、内存容量对不对、PCIe 链路有没有降级、序列号对不对得上、平台关键设置 | 不一致判 **WARN**（配置问题，不是硬件坏了） |
| **③ 性能基准** | CPU 浮点算力、内存带宽、硬盘顺序读写、显卡传输 / 显存带宽 / 卡间互联 | **只报数，不判合格**（见下 ②） |
| **④ 部件专项验证** | 让部件自己查一遍：处理器计算正确性（SDC）、硬盘 SMART 自检、网卡自检、显卡厂商诊断 | 部件自己说坏了才判 FAIL |
| **⑤ 压力测试** | CPU / 内存 / 显卡**并发**跑满全部选定时长；硬盘单独跑（要现场确认） | 有失败项 / 超温 / 掉卡判 FAIL |
| **⑥ 测后复查** | ECC 计数、热节流、PCIe AER、内核日志、BMC 事件、SMART 坏道增长、部件传感器——**全部按压测前后差值判** | 压测把问题逼出来了才判 FAIL |

**⑥ 才是出厂测试真正的价值**：压测本身跑完不出错不代表机器没问题，要看它把什么逼出来了。

完整的判定口径（每一项 PASS / WARN / SKIP / FAIL 各是什么条件）在
[`architecture.md` §6](docs/architecture.md#六判定规则总表)。

---

## 产出什么

| 产物 | 去哪儿 |
|---|---|
| **`<目录名>.html` + `.pdf`** | ✅ **随机器交付**，自包含中文报告，双击就能看 |
| `meta.json` / `results.jsonl` / `*.csv` / `klburn.log` / `SHA256SUMS` | ❌ 内部留档 |
| `raw\` 整个目录（含 `INTERNAL_*.html` 工程报告） | ❌ 内部，复盘和日后追溯用 |
| `out/KLBurn-*.iso` | ❌ 内部，出盘用 |

细节见 [`docs/reports.md`](docs/reports.md)。

---

## 几个不太一样的地方

这些是踩了现场的坑之后才长成现在这样的，也是这个项目和"随便跑个 stress"的区别。

**① 四态判定，绝不把"没有"说成"坏了"**
PASS / FAIL / SKIP / WARN 四态。没装阵列卡、没装显卡、没接网线一律 SKIP，
不影响整机结论；**有卡但认不到**才是 FAIL。整机结论只看有没有 FAIL——
但**一条判定都没有也不算通过**：那说明这轮压根没跑成，报告会明确写
「本次测试未产生任何判定结果，本报告无效」，而不是打一个绿色 PASS。

**② 性能数字只报不判，代码里没有任何"阈值 / 参考值"**
这张盘插上就跑、无人值守，现场没有人、也没有地方去填"这台机器该达到多少"。
凭空写一个数进来，等于我们替客户定了一个他没定过的标准。
**谁做验收，谁拿自己的标准去对我们报出来的实测值。**

**③ 测试环境自己的问题，绝不算到客户机器头上**
内存压测被 OOM 打死 → 判 WARN 并写明"这是测试环境的容量限制，不是内存故障"。
驱动版本不支持客户的新卡 → 判 SKIP 说"驱动与显卡不匹配"，而不是把好卡说成故障。
**把好机器拦在出货前，比漏判更糟。**

**④ 阵列卡后面的盘也要真查到**
RAID 模式下 `/dev/sdX` 是逻辑盘，物理盘根本不在 `/dev` 下——直接读 SMART 读到的
是逻辑盘、没有任何属性。这意味着"测前测后 SMART 对比"在带阵列卡的机器上会**整项
空跑**：报告写着 PASS，实际一块物理盘都没查过。现在会自动认出阵列卡逐块透传读取。

**⑤ 日志判读一律抠数字，不做关键字匹配**
`stressapptest` / `stress-ng` / `gpu_burn` 正常跑完的日志里本来就带
`errors: 0`、`failed: 0` 这些字样。早期版本用 `grep -q` 判定，
结果是**每一台好机器都被判 FAIL**。

**⑥ U 盘自己绝不会被写穿**
fio 的目标盘要过五道排除。Ventoy 场景下 udev 被禁、`lsblk` 完全看不见它的 dm 设备，
所以反查走的是 `/sys/dev/block/<主:次>` 设备号，不依赖任何 `/dev` 下的名字。
`tests/test-disk-exclusion.sh` 用 loop + dm-linear 搭出同构设备链专门锁这条路径。

**⑦ 破坏性写入要连过两关**
原样打出 `yes` 回车（打错、直接回车、120 秒超时一律跳过）→ 最终警告面板再列一遍
要被擦除的盘，按 `y` 才真的开始。**选了"硬盘单独测试"也照样要过这两关。**

**⑧ 报告落盘有四层回退**
卷标 → 同一根 U 盘的 exFAT 分区 → 任意可移动盘的 exFAT → dm 映射设备。
四层都找不到才落 `/tmp`，并在屏幕上打黄色大框警告。

**⑨ 屏幕是给人看的，不是滚动的日志**
每一块整屏页面开头都是绿色 ASCII 大字标题 + 当前页名——现场那块屏经常被拍照发群里。
青色框线分区、绿黄红按温度、黄色标出"会被擦掉的盘"。
**颜色只加在边框层，绝不进内容串**（列宽靠 `printf` 补齐，它数的是字符个数，
颜色码混进去整屏重绘立刻错位）。核心断言只有一条：
**把颜色码去掉之后，必须和不上色时一字不差。**

**⑩ 1472 项回归测试 + 105 条变异，全都不需要真实硬件**

```bash
./tests/run-all.sh      # 1472 项断言，顺带过一遍 shellcheck
./tests/mutate.sh       # 把修好的 105 个 bug 塞回去，守卫必须跑红（约 3 分半）
```

「一个从没红过的测试等于没写」——所以每条守卫都有一条变异专门验证它真的会红。

---

## 三分钟出一张盘

```bash
sudo apt-get install -y xorriso squashfs-tools rsync curl ca-certificates \
                        gdisk fdisk file zstd python3 jq dosfstools mtools
sudo ./build/build-iso.sh          # 首次会自动下载约 3.2GB 的 Ubuntu 源 ISO
# 产物在 out/，用 Rufus 写盘（DD 模式），再建一个卷标 KLBURN 的 exFAT 分区
```

⚠️ 构建目录默认 `~/klburn-build`，**绝不能放在 `/mnt/c` 下**（9p 上解 squashfs
慢到不可用，脚本里有硬性检查）。完整说明见 [`docs/building.md`](docs/building.md)。

---

## 项目结构

```
KLBurn/
├── README.md                    本文件（入口索引）
├── CHANGELOG.md                 每个版本改了什么（拿旧报告回查那张盘的行为）
├── docs/
│   ├── operating.md             现场怎么用（六个入口、每一屏、排查）
│   ├── reports.md           ★   输出的文档：产出什么、哪份交付、六个范围各长什么样
│   ├── building.md              构建与发布（含发布顺序）
│   ├── toolbox.md               盘里封了哪些工具、各管什么、缺了会怎样
│   ├── architecture.md      ★   开发文档（模块地图、判定总表、不变量清单）
│   ├── report-policy.md     ★   报告文案规范（哪些东西不能给客户看）
│   ├── first-run-checklist.md   拿到真机时照着过（QEMU 盖不到的那些）
│   └── usb-rufus.md             Rufus 写盘 + 建 exFAT 分区详细步骤
├── build/
│   ├── config.sh            ★   抬头、版本、包列表、层裁剪规则
│   ├── build-iso.sh             一键构建
│   ├── build-{gpu-burn,bench,cpuflops,opendcdiag}.sh   编各个可选件
│   ├── src/klburn-flops.c       CPU 浮点算力程序（链 OpenBLAS，全平台通用）
│   ├── chroot-setup.sh          chroot 内执行的定制
│   └── lib/                     日志/挂载管理、grub.cfg 改写
├── rootfs/                      原样覆盖进 ISO 根文件系统
│   ├── etc/                     开机自启、tty 免密、屏蔽 nouveau
│   └── opt/klburn/
│       ├── factory-test.sh  ★   测试主流程
│       ├── lib/                 core / ui / storage / collect / conformance / bench /
│       │                        validate / network / stress / gpu / verify
│       └── report/
│           ├── generate_report.py    ★ 交付报告
│           └── generate_internal.py  ★ 内部工程报告
├── tools/                       仓库侧工具，**不进盘**（在 WSL 里跑）
│   ├── klburn-summary.py        一批机器一张 CSV（非全量的写成 PASS(CPU) 这种形状）
│   └── klburn-diff.py           两份 run-dir 逐项对比（只报差异不判合格）
├── tests/                       9 个回归测试 + shellcheck，都不需要真实硬件
│   ├── run-all.sh               一次跑完（合计 1472 项断言）
│   ├── mutate.sh            ★   变异测试（跑在源码副本里、默认并行，真工作区只读）
│   ├── check-firmware.sh    ★   固件 + vendor 依赖库对账（要一个已构建的 rootfs）
│   └── e2e-qemu.sh          ★   把 ISO 在 QEMU 里真开机跑一遍（要 root）
├── vendor/                      离线包（不进版本库，见 vendor/README.md）
└── out/                         构建产物 ISO
```
