# 构建与发布

> 写给**出盘的人**：怎么把源码变成一张能插上服务器就跑的 U 盘，
> 以及改完代码之后按什么顺序发布。
>
> 现场怎么用看 [`operating.md`](operating.md)，改代码看
> [`architecture.md`](architecture.md)。

---

## 一、环境

源码在 Windows 上编辑，**在 WSL（Ubuntu-24.04）里构建**，产物是一个能自启动的 ISO。

```bash
# 构建依赖（只需一次）
sudo apt-get update
sudo apt-get install -y xorriso squashfs-tools rsync curl ca-certificates \
                        gdisk fdisk file zstd python3 jq dosfstools mtools
```

要编可选件的话另外还要：

```bash
# vendor/bench/cpuflops（CPU 算力，非 Intel 平台唯一能测出数的那个）
sudo apt-get install -y gcc libopenblas-dev

# vendor/bench/opendcdiag（处理器计算正确性诊断）
sudo apt-get install -y git meson ninja-build g++ libboost-dev libeigen3-dev \
                        libzstd-dev zlib1g-dev
```

### ⚠️ 构建目录绝不能放在 `/mnt/c` 下

工作区默认 **`~/klburn-build`**，也就是 WSL 的原生文件系统。

`/mnt/c` 走 9p 协议，解 squashfs 要写几十万个小文件，性能会差到不可用
（几分钟的活干几小时）。**构建脚本里有硬性检查**，检测到 `/mnt/*` 直接拒绝执行。
换位置用 `export KLBURN_WORK=$HOME/somewhere-else`。

源码本身放 `/mnt/c` 下没问题（只读几十个小文件），产物 ISO 最后会自动拷回 `out/`。

需要约 **12 GB** 磁盘（源 ISO 缓存 3.2G + 解包 3.2G + 根文件系统 2.5G +
临时 1.5G + 输出 ~1.5G）。

---

## 二、构建

```bash
sudo ./build/build-iso.sh
```

第一次会自动从清华镜像下载 `ubuntu-24.04.4-live-server-amd64.iso`（约 3.2GB，
支持断点续传）。**每次构建都会强制校验源 ISO 的 sha256**（官方值钉在 `config.sh` 里，
没有 stamp 跳过）——3.4GB 从镜像站拉下来完全不验的话，同步到一半、断点续传接错、
磁盘悄悄坏一个扇区，都会安安静静做出一张有问题的盘，而且要等装到服务器上才发现。

耗时：首次约 10~15 分钟（不含下载），增量约 5~8 分钟。

```bash
sudo ./build/build-iso.sh                    # 常规构建
sudo ./build/build-iso.sh --without-nvidia   # 出一张不含显卡驱动的盘
sudo ./build/build-iso.sh --rebuild-fs       # 强制重解 squashfs（换了源 ISO 时）
sudo ./build/build-iso.sh --clean            # 清空工作区（保留已下载的源 ISO）
sudo ./build/build-iso.sh --iso /path/to.iso # 用指定的源 ISO
sudo ./build/build-iso.sh --skip-download    # 源 ISO 不在就报错，不去下载
```

**带不带显卡驱动是自动的**：`vendor/nvidia/*.run` 在就带上。
`--without-nvidia` 强制不带，`--with-nvidia` 强制带（缺驱动直接报错）。

换 HWE 内核：`KLBURN_KERNEL=hwe`（**默认 generic，别随手改默认**，
理由和验收清单见 [`architecture.md` 的「用哪个内核」](architecture.md#用哪个内核klburn_kernelgenerichwe)）。

---

## 三、`vendor/` 里放什么

`vendor/` **不进版本库**（体积大、有授权限制）。构建脚本自动检测：
**放了就带上，没放就跳过对应功能，绝不报错中断**。

哪些工具、缺了会怎样，一张表在 [`toolbox.md` §五](toolbox.md#五可选件手工放进-vendor-的)；
怎么拿到、怎么放，在 [`vendor/README.md`](../vendor/README.md)。

有现成脚本的三个：

```bash
./build/build-gpu-burn.sh      # 显卡满载压测（要 CUDA，不需要真有 N 卡）
./build/build-bench.sh         # 显卡带宽 / 卡间互联（同上）
./build/build-cpuflops.sh      # CPU 浮点算力（要 gcc + libopenblas-dev）
./build/build-opendcdiag.sh    # 处理器计算正确性诊断（要 meson/ninja/g++ 那一套）
```

---

## 四、做 U 盘

**详细图文见 [`usb-rufus.md`](usb-rufus.md)。** 简要版：

1. Rufus 写 ISO，**必须选「DD 映像模式」**（不是 ISO 模式）
2. 磁盘管理 / `diskpart` 在剩余空间建一个 **exFAT** 分区，卷标 **`KLBURN`**（大写）
3. 插服务器，BIOS 选 U 盘启动

> 经常改脚本重新出盘的话，`usb-rufus.md` 末尾有个 **Ventoy 方案**：
> 换版本只要替换 ISO 文件，不用重新写盘和重建分区。已完整验证过。

⚠️ **Rufus DD 写盘会覆盖整根 U 盘，包括第二分区里已有的报告。**
重新写盘前先把 `out\` 拷出来。（Ventoy 方案没这个问题。）

---

## 五、换成别家的抬头

抬头在**构建时**钉进 ISO，现场运行时绝不会问操作员——一根盘做出来是谁的抬头
就是谁的。报告生成器里没有任何写死的公司名。

改 [`build/config.sh`](../build/config.sh) 顶部那一块：

```bash
COMPANY_NAME="广州市鲲林科技有限公司"      # 报告抬头
REPORT_TITLE="服务器出厂老化测试报告"       # 报告大标题
PRODUCT_NAME="KLBurn"                      # 开机 banner / GRUB 菜单（只能 ASCII）
COMPANY_LOGO_FILE="logo.png"               # 放 vendor/logo.png，留空则不显示
```

也可以不碰文件，用构建期环境变量覆盖（适合同一份源码出多个抬头的盘）：

```bash
KLBURN_COMPANY_NAME="XX科技有限公司" sudo -E ./build/build-iso.sh
```

> ⚠️ **屏幕上那个 ASCII 大字目前是写死的**（`lib/ui.sh` 的 `_BRAND_ART`，
> 拼出来就是 "KLBurn"），改 `PRODUCT_NAME` 不会跟着变——它管的是 banner 下面
> 那行、GRUB 菜单项、`.disk/info`，以及矮屏上退化成一行时的那个名字。
> 大字下面那句说明（`BRAND_TAGLINE`）同理。**要换成别家的名字，这两处得手工改。**
> 报告那边不受影响。

---

## 六、发布顺序（这个顺序是钉死的）

```
bump 版本 → 跑测试 → 提交 → 构建 → 验证 → 打 tag
```

**提交必须排在构建之前。** 构建脚本会把 `HEAD` 的 hash 和"工作区脏不脏"一起写进
盘里的 `klburn.conf`——先构建后提交的话，盘里记的是**上一版的 hash 加一个
`-dirty`**，tag 就指向了一个盘里根本没提到的 commit。1.9.4 第一次构建真踩过。

| # | 干什么 | 命令 |
|---|---|---|
| 1 | **先 bump 再构建** `KLBURN_VERSION` | 改 `build/config.sh` |
| 2 | `CHANGELOG.md` 顶上加一节 | — |
| 3 | 全套测试绿 | `./tests/run-all.sh` |
| 4 | 动了判定逻辑或守卫，再跑变异 | `./tests/mutate.sh` |
| 5 | 提交 | `git commit` |
| 6 | 构建 | `sudo ./build/build-iso.sh` |
| 7 | 固件 + 依赖库对账 | `./tests/check-firmware.sh` |
| 8 | 在 QEMU 里真开机跑一遍 | `sudo ./tests/e2e-qemu.sh --stage smoke` |
| 9 | 发货前那一遍 | `--stage full`、`--stage full --disk-stress` |
| 10 | 打 tag | `git tag -a v1.9.5 -m "..."` |

> **为什么"先 bump 再构建"要单独强调**：0.3.0 栽过一次——ISO 构建完之后又改了
> 代码却没动版本号，于是现场那根盘自称 0.3.0、跑的却是修复前的代码，
> 对着仓库怎么看都对不上。
>
> `e2e-qemu.sh` 会**断言盘里的版本号和 `config.sh` 一致**，所以 bump 完必须
> 先重新构建再跑 e2e，否则它会红在"版本对不上"。那不是 bug，那正是它要拦的事。

---

## 七、只改了报告样式？

两个报告生成器都能脱离 U 盘单独调试，拿一份已有的报告目录重新生成：

```bash
python3 rootfs/opt/klburn/report/generate_report.py   --run-dir /path/to/20260731_101500_..._Full
python3 rootfs/opt/klburn/report/generate_internal.py --run-dir /path/to/20260731_101500_..._Full
```

改完跑 `./tests/test-report-render.sh` 和 `./tests/test-internal-report.sh`。

---

## 八、构建阶段出问题

| 现象 | 原因 / 处理 |
|---|---|
| `WORK_DIR=... 位于 Windows 挂载盘上` | 构建目录被设到 `/mnt/c` 了。`export KLBURN_WORK=$HOME/klburn-build` 后重跑 |
| `合并后的根文件系统里没有 /lib/modules` | 层裁剪配错了，把 `installer.generic` 层也排除掉了。检查 `config.sh` 的 `LAYER_EXCLUDE_PATTERNS` |
| 源 ISO 校验失败 | 换了 `UBUNTU_POINT` 却没同时换 `SRC_ISO_SHA256`；或者下载真坏了 |
| apt 装包失败 | WSL 没网，或镜像挂了。换 `config.sh` 里的 `APT_MIRROR` |
| 构建中断后残留挂载点 | 脚本有 EXIT trap 会自动清理。真残留了：`sudo umount -l ~/klburn-build/rootfs/{dev/pts,dev,proc,sys,run}` |
| `WARN: ... 缺少依赖库` | `vendor/bench/` 里某个程序在盘里缺 `.so`。见 [`toolbox.md` §六](toolbox.md#六怎么确认一张盘里到底带了什么) |
