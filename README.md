# KLBurn — 服务器出厂老化测试 U 盘

一根 U 盘插上服务器，开机自动跑完整套出厂测试，报告直接落到 U 盘的 exFAT 分区，
拔下来插 Windows 电脑双击就能看。**不需要网络也能完整跑完**；接了网线的话会
顺手联网校时、测一下网口连不连得通，纯属加分项，不接网线不影响任何判定。

一个盘通吃所有机型：无显卡的通用服务器、带阵列卡的存储机、多卡 GPU 服务器。
**没有的硬件自动跳过并在报告里标注，不会卡住也不会误判为故障。**

---

## 目录

- [它做什么](#它做什么)
- [快速上手](#快速上手)
- [WSL 构建环境准备](#wsl-构建环境准备)
- [构建 ISO](#构建-iso)
- [制作 U 盘](#制作-u-盘)
- [现场怎么用](#现场怎么用)
- [改了脚本怎么重新出盘](#改了脚本怎么重新出盘)
- [第二阶段：加入 GPU 模块](#第二阶段加入-gpu-模块)
- [项目结构](#项目结构)
- [设计要点](#设计要点)
- [验证状态](#验证状态)
- [故障排查](#故障排查)

---

## 它做什么

### 1. 硬件信息采集
- `dmidecode` 全量：主板 / BIOS / 每颗 CPU / **每根内存条的厂商、颗粒型号、序列号**，
  并核对装机容量和系统实际识别到的容量是否一致（缺条 / 开了内存镜像会在这里被抓到）
- 每块盘 `smartctl -a`：型号、固件、容量、SMART 健康状态。**不采、不报通电时间/通电
  次数/累计读写量**——我们会用拆机盘，这些数字对客户没有判定意义，只保留在
  `raw/smart-*/` 的完整原始输出里
- 阵列卡：只采型号 / 固件，**不压测**；没查到卡时会顺手核对一下 BMC 有没有为
  阵列卡/HBA 预留的温度/供电传感器，有预留但读不到数据会在 SKIP 里提示检查
  卡和转接板/riser 是否插到位
- 网卡：型号（从 lspci 反查）/ 驱动 / 固件；DHCP 取地址 + ping 默认网关做
  连通性测试，没插网线记 SKIP，接了线但连不通才算异常
- 电源：核对每一路有没有交流输入（配合 BMC 传感器读数，比 DMI 报的状态更准）
- IPMI 传感器读数 + SEL 事件日志
- GPU：`nvidia-smi -q` 全量（第二阶段）

### 2. 压力测试
开机菜单选时长（快测 10 分钟 / **标准 30 分钟** / 长测 2 小时，30 秒倒计时默认标准）：

| 项目 | 工具 | 说明 |
|---|---|---|
| CPU | `stress-ng` 全核 | 同时每 5 秒记录温度和频率 |
| 内存 | `stressapptest` | 吃掉可用内存的 90%，校验数据错误 |
| 硬盘 | `fio` 裸盘读写 | **破坏性操作，需现场二次确认**，见下 |
| GPU | `gpu_burn` | 满载，每 5 秒记录温度/功耗/频率（第二阶段） |

**CPU / 内存 / GPU 三项并发压测**：选多长就真的测多长，互不占用彼此的时间——
选 10 分钟，CPU 就是满载 10 分钟，不会因为还要陪跑内存/GPU 而被腰斩。
硬盘单独测（fio 裸盘读写要是跟 CPU/内存满载凑一起，带宽/IOPS 数字会被 CPU
争用扭曲，没有参考价值），跑在并发阶段结束之后，另外占一段时间。

硬盘那段**额外**占所选时长的 30%，不从前三项里扣：

| 选择 | CPU / 内存 / GPU（并发） | 硬盘（之后单独跑） | 压测合计 |
|---|---|---|---|
| QUICK    | 10 分钟 | 3 分钟  | 13 分钟 |
| STANDARD | 30 分钟 | 9 分钟  | 39 分钟 |
| LONG     | 2 小时  | 36 分钟 | 2 小时 36 分钟 |

"压测合计"不含采集、测后复查和出报告的时间，现场实际从开机到看到结论还要再多几分钟。
硬盘那段内部再按 **顺序写 30% + 4K 随机读写 70%** 切分。不确认破坏性写入时
（默认就是不确认）硬盘这段直接为 0，压测合计就等于所选时长。

### 3. 测后复查
这一步才是出厂测试真正的价值——压测本身跑完不代表没问题，要看压测把什么逼出来了：
- 对比**测前 / 测后** SMART，看有没有新增坏道、CRC 错误、NVMe 介质错误
- 扫 `dmesg` 找 MCE / EDAC / PCIe AER / I/O error 等硬件级错误
- 对比 BMC SEL，看压测期间有没有新增告警事件
- 温度是否超阈值

### 4. 报告
输出自包含的 HTML（内嵌 CSS + 手写 SVG 图表，**不依赖任何外网资源**）：
- **① 硬件清单**：这台机器装了什么，有啥列啥，没有的标注"未安装"
- **② 压力测试结果**：每项 PASS / FAIL 大字标注 + 详细数据 + 温度功耗曲线图
- 详细数据可折叠，全部原始 log 同时保留

**报告直接写到 U 盘根目录的 `out\` 文件夹**（不存在会自动创建），
插回 Windows 就能看到，不用手工拷贝。**每次测试单独一个文件夹**：U 盘会反复插不同
机器用，测多了 `out\` 根目录下不会堆一堆散的 .html 文件和同名目录混在一起。

```
<U盘根>\out\
    20260730_143052_2x-Intel-Xeon-Gold-6430_512GB\       ← 每次测试一个文件夹
        20260730_143052_2x-Intel-Xeon-Gold-6430_512GB.html   ← 双击这个看报告
        klburn.log  results.jsonl  meta.json  sys_metrics.csv  raw\...
    20260731_090211_Intel-Xeon-Silver-4310_128GB\        ← 另一台机器，互不影响
        ...
```

命名格式 **`日期_时间_CPU型号_内存容量`**，多路机器 CPU 前带路数（`2x-`）。
整机序列号在报告内容的抬头里。

---

## 快速上手

```bash
# 1. WSL 里装构建依赖（只需一次）
sudo apt-get update
sudo apt-get install -y xorriso squashfs-tools rsync curl ca-certificates \
                        gdisk fdisk file zstd python3 jq dosfstools mtools

# 2. 改公司名
#    编辑 build/config.sh 里的 COMPANY_NAME

# 3. 构建（第一次会自动下载约 3GB 的 Ubuntu 源 ISO）
cd /mnt/c/Users/li/Desktop/project/KLBurn
sudo ./build/build-iso.sh

# 4. 产物在 out/ 目录，用 Rufus 写盘
#    详细步骤见 docs/usb-rufus.md
```

---

## WSL 构建环境准备

### 依赖

```bash
sudo apt-get update
sudo apt-get install -y \
    xorriso squashfs-tools rsync curl ca-certificates \
    gdisk fdisk file zstd python3 jq dosfstools mtools
```

各自的用途：

| 包 | 干什么 |
|---|---|
| `xorriso` | 解包和重打包 ISO，保留原始引导结构 |
| `squashfs-tools` | 解 / 压 squashfs 根文件系统 |
| `rsync` | 合并 squashfs 层（处理硬链接冲突） |
| `zstd` | squashfs 压缩算法 |
| `curl` | 下载 Ubuntu 源 ISO |
| `python3` | 改写 grub.cfg |
| `jq` | 构建脚本和测试脚本都用 |

### 关于构建目录（重要）

构建工作区默认在 **`~/klburn-build`**，也就是 WSL 的原生文件系统。

**绝对不要把它设到 `/mnt/c` 下面。** `/mnt/c` 走的是 9p 协议，
解 squashfs 要写几十万个小文件，性能会差到不可用（几分钟的活干几小时）。
构建脚本里有硬性检查，检测到 `/mnt/*` 会直接拒绝执行。

要换位置的话用环境变量：

```bash
export KLBURN_WORK=$HOME/somewhere-else
```

源码本身放在 `/mnt/c` 下没问题（只是读几十个小文件）。
构建产物 ISO 最后会自动拷回项目的 `out/` 目录。

### 磁盘空间

大约需要 **12 GB**：

| 用途 | 大小 |
|---|---|
| Ubuntu 源 ISO（缓存，只下一次） | 3.2 GB |
| 解包出的 ISO 目录树 | 3.2 GB |
| 合并后的根文件系统 | 2.5 GB |
| 层解包临时目录 | 1.5 GB |
| 输出 ISO | ~1 GB |

---

## 构建 ISO

```bash
cd /mnt/c/Users/li/Desktop/project/KLBurn
sudo ./build/build-iso.sh
```

第一次跑会自动从清华镜像下载 `ubuntu-24.04.4-live-server-amd64.iso`（约 3.2 GB，
支持断点续传，中断了重跑就继续）。之后的构建复用缓存。

### 常用参数

```bash
sudo ./build/build-iso.sh                  # 普通构建（第一阶段，不含 NVIDIA）
sudo ./build/build-iso.sh --with-nvidia    # 第二阶段，需要 vendor/nvidia/*.run
sudo ./build/build-iso.sh --rebuild-fs     # 强制重新解 squashfs（换了源 ISO 时用）
sudo ./build/build-iso.sh --clean          # 清空工作区从头来（保留已下载的源 ISO）
sudo ./build/build-iso.sh --iso /path/to.iso   # 用指定的源 ISO
sudo ./build/build-iso.sh --skip-download  # 源 ISO 不存在就直接报错，不去下载
```

### 构建流程

```
1. 准备源 ISO          下载 / 校验
2. 解包 ISO 目录树      xorriso -osirrox（不用 loop mount，WSL 里更稳）
3. 合并 squashfs 层     5 层 → 1 层，丢掉安装器和 HWE 内核
4. chroot 定制          装包 + 铺 KLBurn + 关掉碍事的服务
5. 打包 squashfs        zstd -19
6. 改引导配置           grub.cfg 加内核参数、删 HWE 菜单项
7. 重算 md5sum.txt
8. 重打包 ISO           引导参数从源 ISO 原样继承，BIOS/UEFI 双引导
9. 拷回 out/
```

耗时：首次约 10~15 分钟（不含下载），之后增量构建约 5~8 分钟。

### 关于层裁剪

Ubuntu 24.04.4 的 live server ISO 有 5 层 squashfs：

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

要调整保留哪些层，改 `build/config.sh` 的 `LAYER_EXCLUDE_PATTERNS`。

---

## 制作 U 盘

**详细图文步骤见 [`docs/usb-rufus.md`](docs/usb-rufus.md)。**

简要版：

1. Rufus 写 ISO，**必须选「DD 映像模式」**（不是 ISO 模式）
2. 磁盘管理 / `diskpart` 在剩余空间建一个 **exFAT** 分区，卷标 **`KLBURN`**（大写）
3. 插服务器，BIOS 选 U 盘启动

报告会写到 U 盘根目录的 `out\` 文件夹下，文件名 `日期_时间_CPU型号_内存容量.html`。

> 如果你会经常改脚本重新出盘，`docs/usb-rufus.md` 末尾有个 **Ventoy 方案**，
> 换版本只要替换 ISO 文件，不用重新写盘和重建分区，省事很多。

---

## 现场怎么用

1. 插 U 盘，开机，BIOS 启动菜单选 U 盘（常见按键 `F11` / `F7` / `Esc` / `F12`）
2. GRUB 菜单 5 秒后自动进入（也可以直接回车）
3. 系统起来后自动进入测试，**首先显示报告存储位置**：
   - 绿色 `Data partition: /dev/sdb2 -> /mnt/klburn-data` = 正常
   - 黄色大框警告 = 没找到 U 盘数据分区，报告只会写到 `/tmp`，关机就没了
4. **尝试联网校时**（几秒到几十秒，接了网线才会有动作）：
   库存/二手机常见主板纽扣电池没电，BIOS 时间会乱掉，报告时间戳就会不准。
   这一步会检查有没有网口接了网线，接了就顺手 DHCP 一下、跟公网时间服务器
   对一次表；没接网线或者连不上时间服务器就直接跳过，继续用现有的 RTC 时间——
   **不影响后续流程，纯粹是顺手修正一下时间**。
5. **选测试时长**：30 秒倒计时，不按键默认标准（30 分钟）
6. 自动采集硬件信息（含每个网口单独 DHCP + ping 网关的连通性测试）
7. **硬盘压测确认（默认跳过）**：
   硬盘的**型号 / 容量 / 序列号 / SMART 健康状态在这一步之前就已经采集完了**，
   报告里一定有。这里问的只是要不要额外做**破坏性的**读写压测。

   要做的话得连过两关：
   - **第一关**：原样打出 `yes` 再回车。直接回车、打成 `yea`、打 `y`、
     或者 120 秒不管 —— 一律**立即跳过**
   - **第二关**：弹出最终警告面板，再列一遍要被擦除的盘，按 `y` 才真的开始；
     按其它任何键或 60 秒超时都跳过

   跳过记为 SKIP，**不算 FAIL**，其余项目照常跑。
8. **CPU / 内存 /（GPU）并发跑满全部选定时长**，屏幕是一条合并进度条；
   硬盘单独测（不占并发那段时间），跑在并发阶段结束之后
9. 测后复查
10. 生成报告，显示 PASS / FAIL 大字
11. 收尾菜单：`r` 重启 / `p` 关机 / `s` 进 shell 排查 / `t` 再测一遍

按 `Alt+F2` 可以切到另一个控制台，root 免密登录，用来手工排查。

> 屏幕上的提示都是英文——Linux 文本控制台默认显示不了中文（会变方块）。
> **报告（U 盘里那个 `.html` 文件）是全中文的**，不受影响。

---

## 改了脚本怎么重新出盘

改 `rootfs/opt/klburn/` 下的任何脚本后：

```bash
sudo ./build/build-iso.sh
```

不需要 `--clean`。构建脚本会复用已解包的 ISO 目录树和根文件系统，
只重新执行 chroot 定制、重压 squashfs、重打包 ISO，大约 5~8 分钟。

然后按 [`docs/usb-rufus.md`](docs/usb-rufus.md) 重新写盘。

**⚠️ Rufus DD 写盘会覆盖整根 U 盘，包括第二分区里已有的报告。**
重新写盘前记得先把 `out\` 文件夹拷出来。（用 Ventoy 方案则没这个问题。）

### 只改了报告样式？

`rootfs/opt/klburn/report/generate_report.py` 可以脱离 U 盘单独调试：

```bash
# 拿一份已有的报告目录重新生成 HTML
python3 rootfs/opt/klburn/report/generate_report.py \
        --run-dir /path/to/20260730_143052_2x-Intel-Xeon-Gold-6430_512GB
```

不给 `--out` 时输出到 `<run-dir>/report.html`（现场跑的时候 `factory-test.sh` 会显式
传 `--out`，落成和目录同名的 `.html`）。改完样式跑一遍
`./tests/test-report-render.sh`，它会造一份假的 run-dir 走完整个渲染并做断言。

---

## 第二阶段：加入 GPU 模块

第一阶段的精简版 ISO **不含 NVIDIA 驱动**。这种情况下，如果机器上插了 N 卡，
报告会标注"检测到 N 张显卡，但本测试盘为精简版（未包含 NVIDIA 驱动），未做 GPU 测试"，
状态是 SKIP，**不算 FAIL**。

要加上 GPU 测试：

### 1. 准备 NVIDIA 驱动

从 https://www.nvidia.cn/drivers/ 下载 Linux x64 驱动 `.run` 包，放到：

```
vendor/nvidia/NVIDIA-Linux-x86_64-570.86.16.run
```

**版本要求**：RTX 5090 和 RTX Pro 6000（Blackwell，sm_120）**必须 ≥ 570.xx**。
RTX 4090（Ada，sm_89）≥ 520 即可。直接用 570+ 一个驱动通吃。

### 2. 装 CUDA Toolkit（只为编译 gpu_burn，WSL 里不需要真显卡）

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y cuda-toolkit-12-8 build-essential git
```

**必须 CUDA ≥ 12.8**，因为 sm_120（Blackwell）是 12.8 才加进去的。
低于 12.8 脚本不会拦，只打一条警告——4090 照样编得出来，5090 可能不被支持。

### 3. 编译 gpu_burn

```bash
./build/build-gpu-burn.sh
```

**不需要 root，也不需要机器上真有 N 卡**（只编译，不运行）。脚本会：
自动在 `/usr/local/cuda*` 下找 `nvcc` → 从 GitHub 克隆
[wilicc/gpu-burn](https://github.com/wilicc/gpu-burn) 到 `~/klburn-build/gpu-burn-src`
（`$KLBURN_WORK` 下，已克隆过就复用并尝试 `git pull`）→ 编译 → 把产物
`gpu_burn` 和 `compare.ptx` 装进 `vendor/gpu_burn/`。

所以这一步**需要能访问 GitHub**。克隆失败的话脚本会提示你手动把源码解压到那个目录再重跑。

两个可用的环境变量：

| 变量 | 默认 | 用途 |
|---|---|---|
| `CUDAPATH` | 自动在 `/usr/local/cuda`、`cuda-13*`、`cuda-12*` 里找 | 自动找不到 nvcc 时手工指定 |
| `COMPUTE`  | `89` | PTX 基线架构 |

> 关于同时兼容 sm_89 和 sm_120：gpu_burn 走的是 **PTX + 驱动 JIT** 的路子
> （`compare.ptx`，不是预编译 cubin）。PTX 是向上兼容的——用 `compute_89` 编出来的
> PTX，在 sm_120 的卡上由驱动 JIT 成原生代码。所以一个文件通吃两代卡。
> 想换基线架构：`COMPUTE=75 ./build/build-gpu-burn.sh`

### 4. 构建带 GPU 的 ISO

```bash
sudo ./build/build-iso.sh --with-nvidia
```

ISO 会大出约 400~500 MB。

### GPU 判定逻辑

| 情况 | 结果 |
|---|---|
| `lspci` 看不到 NVIDIA 设备 | **SKIP**「未安装独立显卡」，不算故障 |
| 有设备，驱动正常，`nvidia-smi` 认全 | **测**，逐卡出温度/功耗曲线 |
| 有设备，但驱动加载失败 / `nvidia-smi` 读不到 | **FAIL**（卡、供电或插槽异常） |
| 有 N 张设备，驱动只认到 M < N 张 | **FAIL**（有卡异常） |
| 精简版 ISO（没打包驱动） | **SKIP**，并写明是构建选择不是硬件问题 |
| 驱动正常，但盘内没带 `gpu_burn` | **SKIP**「只采集了显卡信息未做满载压测」——显卡型号/显存/驱动版本照常进报告，但没有温度/功耗曲线 |

---

## 项目结构

```
KLBurn/
├── README.md                    本文件
├── build/
│   ├── config.sh                ★ 公司名、版本、包列表、层裁剪规则
│   ├── build-iso.sh             一键构建
│   ├── build-gpu-burn.sh        编译 gpu_burn（第二阶段）
│   ├── chroot-setup.sh          chroot 内执行的定制
│   └── lib/
│       ├── common.sh            日志、挂载管理、错误清理
│       └── patch-grub.py        改写 grub.cfg
├── rootfs/                      原样覆盖进 ISO 根文件系统
│   ├── etc/
│   │   ├── systemd/system/klburn.service          开机自启
│   │   ├── systemd/system/getty@.service.d/       tty2~6 免密 root
│   │   └── modprobe.d/klburn-nouveau.conf         屏蔽 nouveau
│   └── opt/klburn/
│       ├── factory-test.sh      ★ 测试主流程
│       ├── lib/
│       │   ├── core.sh          日志、结果记录、温度读取
│       │   ├── ui.sh            控制台界面、倒计时菜单
│       │   ├── storage.sh       ★ 数据分区发现 + 裸盘防呆
│       │   ├── collect.sh       硬件采集
│       │   ├── network.sh       网口拉起 / 联网校时 / DHCP + ping 连通性测试
│       │   ├── stress.sh        CPU/内存/硬盘压测
│       │   ├── gpu.sh           GPU 探测与压测
│       │   ├── verify.sh        测后复查
│       │   ├── disks.jq         盘筛选规则
│       │   └── smart.jq         SMART 字段归一化
│       └── report/
│           └── generate_report.py  ★ 报告生成器
├── tests/                       全部不需要真实硬件，见下方「跑测试」
│   ├── test-log-parsing.sh      压测日志判读
│   ├── test-hw-checks.sh        内存核对 / 电源 / 网卡判读
│   ├── test-report-render.sh    报告渲染
│   ├── test-capture.sh          采集超时行为
│   ├── test-concurrent-burn.sh  并发压测编排
│   └── test-disk-exclusion.sh   U盘排除逻辑（需 root，造 dm 设备）
├── vendor/                      离线包（不进版本库，见 vendor/README.md）
├── docs/
│   └── usb-rufus.md             Rufus 写盘 + 建 exFAT 分区详细步骤
└── out/                         构建产物 ISO
```

### 跑测试

一共 6 个回归测试，**全都不需要真实服务器硬件**，在 WSL 里随时可跑。
样本大多直接取自真机（2x Xeon Gold 6530 那台）的实际输出。

```bash
./tests/test-log-parsing.sh
./tests/test-hw-checks.sh
./tests/test-report-render.sh
./tests/test-capture.sh
./tests/test-concurrent-burn.sh
```

```bash
sudo ./tests/test-disk-exclusion.sh
```

| 测试 | 锁住什么 | 改了谁就要跑 | 额外要求 |
|---|---|---|---|
| `test-log-parsing.sh`     | stressapptest / stress-ng / gpu_burn 日志的判读 | `lib/stress.sh`、`lib/gpu.sh` | — |
| `test-hw-checks.sh`       | 内存容量核对、**电源整体判定**、ping/地址解析、网卡型号反查、阵列卡 BMC 交叉核对、硬盘温度判定、**计数不能算出 `0\n0`**、**`collect_all`/`verify_all` 调用链不能少人** | `lib/collect.sh`、`lib/network.sh`、`lib/verify.sh`、`lib/core.sh` | 硬盘温度那组要 `jq`，没装会自动跳过 |
| `test-report-render.sh`   | 报告渲染：不泄露通电时间、`Unknown!` 归一化、二级编号不跳号、空 run-dir 不崩 | `report/generate_report.py` | `python3` |
| `test-capture.sh`         | 采集命令超时不把 bash 的 `Killed` 漏到屏幕上，且要留下 TIMEOUT 记录 | `lib/core.sh` | 约 12 秒（SIGKILL 宽限期写死 10 秒） |
| `test-concurrent-burn.sh` | CPU/内存/GPU 是真并发不是排队，进度条跟着任务提前退出，**并发期间只能有一个采样器**，**cleanup 要连孙进程一起收**，盘内没带 gpu_burn 时 GPU 结论不能凭空消失 | `factory-test.sh`、`lib/ui.sh`、`lib/gpu.sh`、`lib/stress.sh` | 约 12 秒（要等采样间隔） |
| `test-disk-exclusion.sh`  | U 盘反查排除（Ventoy 同构设备链） | `lib/storage.sh` | **root** + `losetup`/`dmsetup`/`sgdisk`/`blockdev`（`apt install gdisk dmsetup util-linux`） |

共 160 项断言。除 `test-capture.sh` 和 `test-concurrent-burn.sh` 外都是几秒钟跑完。
每个脚本最后打印「通过 N 项，失败 M 项」，有失败就以非零码退出。

**这套测试做过变异验证**：把每个已修复的 bug 逐个塞回代码里，确认对应的用例真的会跑红
（一个从没红过的测试等于没写）。其中"把 `verify_disk_temp` 从 `verify_all` 里删掉"
这个变异一开始没被抓住 —— 判定函数还在、只是再没被调用过，报告里那一项就凭空消失，
既不是 PASS 也不是 SKIP。后来专门加了"汇总入口调用链不能少人"那组守卫才堵上。

**`test-disk-exclusion.sh` 守的是整个项目最危险的一条路径**：用 loop + 分区 +
dm-linear 搭出和 Ventoy 一模一样的设备链，并**故意删掉 `/dev/mapper` 下的符号链接**
来复现 Ventoy 禁用 udev 的条件，验证仍能反查出启动 U 盘。
一旦这里退化，fio 会把启动 U 盘当成空盘写穿——测试盘报废，历史报告全丢。

**为什么专门给"读日志"这件事写测试**：`stressapptest`、`stress-ng`、`gpu_burn`
正常跑完的日志里，本身就带着 `Found 0 hardware incidents`、`errors: 0`、`failed: 0`
这些字样。早期版本用 `grep -q '关键字'` 判定，结果是**每一台好机器都被判 FAIL**——
而且这种错误只有在真机上跑满一整轮才会暴露。现在一律把数字抠出来做数值比较，
并用真实日志样本锁住行为。

---

## 设计要点

### 报告落盘的三层回退
1. 卷标是 `KLBURN` 的分区
2. live 介质所在盘上的 exFAT 分区（同一根 U 盘的第二分区）
3. 任意可移动盘上的 exFAT 分区

三层都找不到 → 报告落 `/tmp`，屏幕打黄色大框警告，并给出排查命令。

### 裸盘写入的排除规则
被 fio 写的盘必须全部通过这些检查，任一命中就排除：

| 排除条件 | 理由 |
|---|---|
| `loop* ram* zram* sr* fd* dm-* md*` | 虚拟设备 / 软 RAID |
| 是 KLBurn U 盘本身 | 通过 `/cdrom` 挂载源、iso9660 分区、数据分区三条线反查 |
| `removable=1` 或 `hotplug=1` | 任何 USB 设备 |
| 盘上有任何分区已挂载 | 系统在用 |
| 容量为 0 | 空读卡器之类 |

排除的盘和原因会打在屏幕上、也写进报告。

### 四态而不是两态
所有测试项的状态是 **PASS / FAIL / SKIP / WARN** 四态，关键是把
"**没有这个硬件**"（SKIP）和"**有但坏了**"（FAIL）严格区分开。
没装阵列卡、没装显卡都不影响整机结论；有卡认不到才是 FAIL。

整机结论只看有没有 FAIL：**只要有任意一项 FAIL，整机就是 FAIL**，SKIP 和 WARN 都不影响。
WARN 不会拉低结论，但会在报告抬头单独列一块（少一条内存、少接一路电源线这类
最容易被漏看、又最该在出厂拦住的事，不能只埋在下面的列表里等人翻）。

### 电源判定：FAIL 的门槛卡得很死

只接一半电源线在测试台上是常态，所以"没进电"绝不能判故障。判 FAIL 只有一种情况：
**BMC 确认这一路有交流输入、模块却还报异常**。

| DMI 状态 | BMC 的 Vin 读数 | 结论 |
|---|---|---|
| Present, OK | 有电压 | **PASS** |
| Present, OK | `na` / 0V | **WARN**：没接电源线，当前无冗余 |
| Present, Critical | `na` / 0V | **WARN**：就是没插线，不是故障 |
| Present, Critical | 有电压 | **FAIL**：模块本身坏了 |
| Present, Critical | **读不到这个传感器** | **WARN**：分不清是没插线还是坏了，提示人工确认 |

最后一行是这次审查加的。以前这种情况判 FAIL —— 而没有 BMC 的机器上，DMI 对
"没插电源线"和"模块坏了"报的都是 `Present, Critical`，光看 DMI 根本分不出来，
判 FAIL 就会把一台好机器拦在出货前。

### 温度阈值

压测期间每 5 秒采一次样，取整段的峰值来判：

| 项目 | 变量 | WARN | FAIL |
|---|---|---|---|
| CPU（`coretemp` / `k10temp` / `zenpower` / `cpu_thermal`，退路是 thermal zone） | `CPU_TEMP_*` | ≥ 88 °C | ≥ 98 °C |
| GPU（`nvidia-smi` 读数，逐卡判） | `GPU_TEMP_*` | ≥ 83 °C | ≥ 90 °C |
| 硬盘（SMART 上报的测后温度，逐盘判） | `DISK_TEMP_*` | ≥ 70 °C | ≥ 80 °C |

CPU/GPU 取压测整段的峰值；硬盘取测后那次 SMART 的读数（测前是冷的，没有参考价值）。

**读不到温度就整条跳过，绝不当成故障**——服务器 CPU 的温度驱动不一定是
`coretemp`/`k10temp`，部分 SATA 盘和阵列卡后面的盘也不通过 SMART 上报温度，
这些都属于正常情况，判定会自动让开（硬盘那项会记 SKIP）。

默认值在 [`rootfs/opt/klburn/lib/core.sh`](rootfs/opt/klburn/lib/core.sh) 里，
写法是 `: "${CPU_TEMP_WARN:=88}"`——现场想临时改，`Alt+F2` 进去在
`/opt/klburn/klburn.conf` 里写一行同名赋值即可覆盖（那个文件在 `core.sh` 之后被 source）。

### 为什么内存按"可用内存"的 90% 而不是"总内存"
live 系统的 overlay 上层在内存里（tmpfs），按总内存的 90% 去分配会直接触发 OOM，
把测试进程打死。所以按 `MemAvailable` 的 90% 算，报告里会同时写明
实际测了多少、占总内存百分之多少。

### 关掉的东西
`snapd`、`cloud-init`、`unattended-upgrades`、`apt-daily.timer`、
`systemd-networkd-wait-online` 全部禁用/移除。
现场无网络，这些服务会让开机白等几十秒甚至几分钟。

---

## 验证状态

第一阶段的 ISO 已在 QEMU 里做过完整的端到端验证：把 ISO 按 Rufus DD 模式
写进一个 16G 磁盘镜像、再建 exFAT `KLBURN` 分区，模拟真实 U 盘启动。

**已实机（虚拟机）验证通过**

| 项目 | 结果 |
|---|---|
| Legacy BIOS 引导（SeaBIOS） | ✅ |
| UEFI 引导（OVMF） | ✅ |
| **Ventoy 启动**（1.1.17，exFAT 主分区，默认 `Ventoy` 卷标） | ✅ 报告落 Ventoy 分区 |
| 开机自动进入测试（无需任何按键） | ✅ |
| exFAT 数据分区自动识别挂载 | ✅ `/dev/sdb4 → /mnt/klburn-data` |
| 报告目录按约定命名建立 | ✅ 当时的格式是 `序列号_日期时间`，0.3.0 起改为 `日期_时间_CPU型号_内存容量` |
| **U 盘自身被排除在压测目标外** | ✅ 显示"the KLBurn USB stick itself" |
| 时长菜单 + 倒计时默认 | ✅ |
| 硬盘破坏性写入二次确认 | ✅ 输入 YES 才写，超时跳过 |
| 无阵列卡/无 BMC/无显卡 → SKIP 而非 FAIL | ✅ 流程不中断 |
| CPU / 内存 / 硬盘压测完整跑完 | ✅ QUICK 10 分钟全流程 |
| 测后 SMART 对比、dmesg 复查 | ✅ |
| 报告写入 exFAT 分区并可读 | ✅ 52 个原始文件 + 40KB 的 HTML 报告 |
| 报告生成器异常输入不崩 | ✅ 7 种边界情况 |
| 压测日志判读 | ✅ 9 项回归测试 |

**尚未验证，上真机时重点看**

- **真实服务器 BIOS 的 U 盘引导兼容性**——QEMU 过了不代表所有品牌 BIOS 都过
- **阵列卡**：storcli64 需要你放进 `vendor/`，真卡上的输出格式没实测过
- **IPMI/BMC**：QEMU 里没有 BMC，SEL 对比逻辑只走了 SKIP 分支
- **CPU 温度采集**：QEMU 没有 coretemp，真机上才知道能不能读到；
  读不到时报告里 CPU 温度曲线为空，但不影响判定
- **大内存机器**：stressapptest 在几百 GB 内存上可能分配失败，
  已写了自动回退到 `stress-ng --vm` 的分支，但没在真机验证过
- **GPU 全链路**：第二阶段，需要你先准备 `vendor/nvidia/*.run`

建议第一块盘先在**库存机**上跑一遍 QUICK（10 分钟），确认主链路，再上正式出货机。

---

## 故障排查

### 构建阶段

**`WORK_DIR=... 位于 Windows 挂载盘上`**
构建目录被设到 `/mnt/c` 了。`export KLBURN_WORK=$HOME/klburn-build` 后重跑。

**`合并后的根文件系统里没有 /lib/modules`**
层裁剪配错了，把 `installer.generic` 层也排除掉了。
检查 `build/config.sh` 的 `LAYER_EXCLUDE_PATTERNS`。

**`failed to create hardlink, because File exists`**
不应该再出现（已用 rsync 合并方案解决）。如果换了源 ISO 又冒出来，
检查 `build-iso.sh` 里逐层解包的那段逻辑。

**apt 装包失败**
WSL 没网，或清华镜像挂了。换 `build/config.sh` 里的 `APT_MIRROR`，
比如 `https://mirrors.aliyun.com/ubuntu/`。

**构建中断后残留挂载点**
脚本有 EXIT trap 会自动清理。真残留了手工清：
```bash
sudo umount -l ~/klburn-build/rootfs/{dev/pts,dev,proc,sys,run} 2>/dev/null
```

### 启动阶段

**BIOS 里看不到 U 盘** → 见 `docs/usb-rufus.md` 常见问题

**启动卡住看不到原因**
GRUB 菜单按 `e`，删掉 `quiet`，`F10` 启动，能看到内核信息。

**进了系统但没自动跑测试**
`Alt+F2` 登录（root 免密），执行：
```bash
systemctl status klburn.service
journalctl -u klburn.service -b --no-pager
```

### 测试阶段

**报告写到了 /tmp**
数据分区没认出来。`Alt+F2` 后：
```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
blkid
```
确认 U 盘第二分区是 exFAT、卷标 `KLBURN`。

**硬盘测试一直被跳过**
看屏幕上列出的排除原因。最常见的是盘上有分区被自动挂载了——
这种情况下脚本会主动避开，属于预期行为。

**报告里的时间不对**
开机后会先尝试联网校时（见「现场怎么用」第 4 步）：接了网线、又连得上公网
时间服务器的话，时间会自动拨准，这条一般不会再遇到。

会遇到通常是两种情况：
1. **现场没接网线 / 连不上时间服务器**：只能退回 BIOS 的 RTC，这时候
   ISO 的时区已设为 `Asia/Shanghai`（在 `build/config.sh` 的 `TIMEZONE` 里改），
   只要机器 BIOS 里的时间本身是准的、并且 RTC 走 UTC（服务器默认），
   报告时间就是对的。如果差了整 8 小时，说明这台机器的 RTC 存的是本地时间，
   去 BIOS 里把时间改成 UTC 即可。
2. **校时本身失败**：多半是 DNS/防火墙挡住了 NTP（UDP 123）出网，
   `Alt+F2` 登录后可以手动跑 `chronyd -q 'server ntp.aliyun.com iburst'`
   看具体报错。

测试脚本发现年份早于 2024、或者测试时间早于这张 ISO 的构建日期时，
会在屏幕和报告里同时给出提示。

**阵列卡这项是 WARN，报告里只有 PCI 型号**
这张盘里没带 `storcli64`。它是 Broadcom 的闭源工具，不在 Ubuntu 源里，
只能手工下载后放进 `vendor/storcli/` 再重新出盘——步骤见
[`vendor/README.md`](vendor/README.md)。整个解压目录原样丢进去就行，
构建脚本会自己递归找。

补上之后阵列卡的固件版本、逻辑盘状态、卡后面挂了哪些物理盘才会进报告。
**阵列卡始终只采集不压测**，所以这一项永远不会是 FAIL。

**没有温度数据**
服务器 CPU 的温度驱动可能不是 `coretemp`/`k10temp`。
报告里的 CPU 曲线会是空的，但 IPMI 传感器读数仍然有采集，
可以看报告"原始日志"里的 `ipmi-sensors.txt`。
