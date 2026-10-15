# 构建与发布

> 写给**出盘的人**：怎么把源码变成一张能插上服务器就跑的 U 盘，
> 以及改完代码之后按什么顺序发布。
>
> 现场怎么用看 [`operating.md`](operating.md)，改代码看
> [`architecture.md`](architecture.md)。

---

## 一、环境

源码可在 **macOS、Windows 或 Linux** 编辑，**构建与完整测试在 x86_64 Ubuntu 24.04
上执行**，产物是自启动的 amd64 ISO。Linux 可以是物理机、局域网虚拟机或 WSL；
WSL 是 Windows 的一种选择，不是构建脚本的强制前提。

### Apple Silicon Mac 开发

Apple Silicon Mac（arm64）可直接 clone 仓库、编辑和提交代码、查看生成的报告与截图。
现有构建会在 amd64 rootfs 内执行 chroot 命令，不能直接拿 ARM Ubuntu 替代构建机。
Mac 通过已配置的 SSH 连接到 **x86_64 Ubuntu** 后，在 Linux 源码目录执行本文命令。
macOS 自带 Bash/BSD 工具不作为全套回归环境。请使用自己配置的兼容 Linux 后端；
源码 CI 与 ISO 发行验收的边界见 [CI 说明](CI.md)，不能把源码检查当成整套发布验收。

迁移或首次 clone 时注意：

- 保留完整 Git 历史和 tags，用于按报告版本回查；从 GitHub 下载 ZIP 不含这些。
- 文本使用 UTF-8 无 BOM、LF（由 `.gitattributes` 固定），入口脚本的执行权限由 Git 保存。
- `vendor/` 不进版本库，驱动和基准程序要单独迁移到 Linux checkout。
  定制 logo 位于独立定制源码的 `build/custom-logo.png`，与品牌配置一并提交追溯。
  低层构建成功不等于完整发行验收：严格成对发布入口在离线组件缺失时停止，
  不能把缺件产物称为完整可用版本。组件清单及官方获取入口见
  [vendor/README.md](../vendor/README.md)。
- `test_out/` 存放调用者有权使用的私有真机回放样本，不进入版本库；
  依赖它的回归需在自己的测试机另行配置，不依赖维护者的存储或账号。
  可信 CI 仅使用必要传感器/电源文本的私有副本，见 [CI](CI.md)。
  现有真机传感器/未接交流电覆盖自检在缺输入时会失败，不能当成跳过或已覆盖。
  不要把客户原始报告推到 GitHub。
- `out/` 的旧 ISO、日志和截图另行保存，clone 不会下载它们。
- 虚拟机跑 QEMU 要开放嵌套虚拟化，让 `/dev/kvm` 可用；脚本支持纯模拟，但会慢很多。
  构建与磁盘测试需要 root、loop 设备及挂载权限。
- 同一个 `KLBURN_WORK` 的任务串行运行，缓存保留在 Linux 本地文件系统。
  full / mem 可以依次共用；长任务使用持久会话或后台任务并保存日志。

内存版 QEMU 验收根据实际报告完成信号结束等待，上限 900 秒；不是睡够一个固定
时长就关机。受限虚拟机的内存分配和 PDF 生成可能变慢，超时仍算验收失败，
须保留日志排查，不能缩短压测或跳过 HTML/PDF/CSV 检查。

以下安装与测试命令均在 Linux 上执行。

```bash
# 构建依赖（只需一次）
sudo apt-get update
sudo apt-get install -y xorriso squashfs-tools rsync curl ca-certificates \
                        gdisk fdisk file zstd python3 jq dosfstools mtools binutils kmod
```

要编可选件的话另外还要：

```bash
# vendor/bench/cpuflops（CPU 算力，非 Intel 平台唯一能测出数的那个）
sudo apt-get install -y gcc libopenblas-dev

# vendor/bench/opendcdiag（处理器计算正确性诊断）
sudo apt-get install -y git meson ninja-build g++ libboost-dev libeigen3-dev \
                        libzstd-dev zlib1g-dev
```

### 构建工作区放 Linux 本地文件系统

工作区必须显式指定 **`KLBURN_WORK`**（例如普通用户的 `~/klburn-build`），
使用构建机本地 Linux 文件系统（例如 ext4），
不要放 Mac/NAS 网络共享或宿主机共享目录。

Windows 的 WSL 中，`/mnt/c` 走 9p 协议，解 squashfs 要写几十万个小文件，性能会差到不可用
（几分钟的活干几小时）。**构建脚本里有硬性检查**，检测到 `/mnt/*` 直接拒绝执行。
换位置用 `export KLBURN_WORK=$HOME/somewhere-else`。

源码推荐 clone 到构建机本地目录；WSL 下源码放 `/mnt/c` 也可以。
产物最终复制到**执行构建的那份 checkout** 的 `out/`，不会自动传回 Mac 或上传发布页。
下载或复制到自己的 Mac/Linux/Windows 产物目录后，须复核 `.sha256`。

自动构建工具预检要求工作区所在文件系统至少 **40 GiB 可用空间**，用于源 ISO、
解包、两版构建、产物和隔离 QEMU 测试镜像；保留多个工作区时还需额外空间。

---

## 二、构建

```bash
sudo KLBURN_WORK="$HOME/klburn-build" ./build/build-iso.sh
```

建议每次显式指定 `KLBURN_WORK`，避免 sudo/root 的家目录变化导致换工作区。
上面的 `$HOME` 由普通用户 shell 在调用 sudo 前展开；root 登录时填写实际绝对路径。

第一次会自动从清华镜像下载 `ubuntu-24.04.4-live-server-amd64.iso`（约 3.2GB，
支持断点续传）。**每次构建都会强制校验源 ISO 的 sha256**（官方值钉在 `config.sh` 里，
没有 stamp 跳过）——3.4GB 从镜像站拉下来完全不验的话，同步到一半、断点续传接错、
磁盘悄悄坏一个扇区，都会安安静静做出一张有问题的盘，而且要等装到服务器上才发现。

耗时：首次约 10~15 分钟（不含下载），增量约 5~8 分钟。

```bash
sudo ./build/build-iso.sh                    # 常规构建（整机出厂老化盘）
sudo ./build/build-iso.sh --edition mem      # 内存专用盘（见下）
sudo ./build/build-iso.sh --without-nvidia   # 出一张不含显卡驱动的盘
sudo ./build/build-iso.sh --rebuild-fs       # 强制重解 squashfs（换了源 ISO 时）
sudo ./build/build-iso.sh --clean            # 清空工作区（保留已下载的源 ISO）
sudo ./build/build-iso.sh --iso /path/to.iso # 用指定的源 ISO
sudo ./build/build-iso.sh --skip-download    # 源 ISO 不在就报错，不去下载
```

**带不带显卡驱动是自动的**：`vendor/nvidia/*.run` 在就带上。
`--without-nvidia` 强制不带，`--with-nvidia` 强制带（缺驱动直接报错）。

### 两种盘（`--edition`）

同一份源码出两种盘，**构建时钉死**，现场不会再问任何人：

每次发布成对交付 full 和 mem，两张盘的版本号、源码 commit、tag 必须一致。
full 菜单中的「内存专项」继续保留，它不等于内存专用 ISO，也不需要第三张盘。
1.10.6 起 mem 使用独立包清单，不装 NVIDIA/CUDA、性能基准或存储/BMC 检测工具，
只迁移品牌 logo。显示/有线网卡/USB 启动驱动、固件与 CPU 微码继续保留。
同工作区切换 edition 会重新解包 rootfs；缓存中的源 ISO 不重下载。

| | `full`（默认） | `mem` |
|---|---|---|
| 开机拉起 | `factory-test.sh`（选范围 + 选时长） | `memtest.sh`（**什么都不问，直接开测**） |
| 测什么 | 整机六个阶段 | 只有内存 |
| 报告标题 | 服务器出厂老化测试报告 | 内存专用测试报告 |
| 产物 | `out/KLBurn-*.iso` | `out/KLBurn-MEM-*.iso` |

压测时长（默认 150 秒）也是构建时钉的：

```bash
KLBURN_MEM_BURN_SECONDS=600 sudo -E ./build/build-iso.sh --edition mem
```

内存盘的完整说明见 [`mem-edition.md`](mem-edition.md)。

> ⚠️ 版本差别**只在 `klburn.service` 的 `ExecStart`** 上。`chroot-setup.sh` 改完
> 会当场 `grep -qx` 核对 —— `sed` 没匹配上是静默的，做出来会是一张
> "文件名写着 MEM、开机却跑整机全测流程"的盘，而构建日志里一个字的异常都没有。

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

抬头在**构建时**钉进 ISO，现场不询问。1.11.0 起使用
[`build/branding.json`](../build/branding.json) 集中配置，经验证与 shell 转义后
写进盘内；配置文件与摘要同时保留，定制配置必须在构建前提交。

默认显示名称为 KLBurn，full 与 mem 各有独立报告标题。中文名称进入报告，
控制台名称只接受安全 ASCII；定制盘的大字替换为定制产品名称和 `[CUSTOM]`，
不修改硬件判据、屏幕宽度与帧高守卫。

推荐使用 [跨平台定制入口](custom-build.md) 建立独立工作区、提交配置和运行
双版验收。原先 `KLBURN_COMPANY_NAME` 等未进入 commit 的环境变量覆盖被明确拒绝，
避免品牌配置与盘内追溯不一致。不要对整棵源码粗暴替换字符串。

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

### 成对构建与验收入口

完成源码测试并提交后，在 Ubuntu 的干净 checkout 执行：

```bash
sudo KLBURN_WORK=/srv/klburn/work ./build/release.sh --mutate
```

入口再次运行源码检查（必须有 shellcheck），判定/守卫改动使用 `--mutate`。
它拒绝已有版本 tag、脏源码或构建中源码变动，依次构建 full/mem、核对盘内
版本/commit/edition、固件/动态依赖、两版 QEMU 冒烟及 full 完整真写盘；
两版通过后才生成 annotated tag；不以 ISO 大小作为发布门槛。它不推送 GitHub 或上传 ISO。
`out/release-<版本>/` 保存各阶段日志、盘内配置和 `manifest.json`（含精确文件名、
大小、SHA256、commit、QEMU 内存及真机验收 NOT_RUN）。
完整整机验收使用默认 4096MiB QEMU 内存；2048MiB 的冒烟不能证明全量基准与压测可运行。
内存专用盘可单独使用 `--memory-mb 2048`。验收收据区分实际 QEMU 资源。
构建并行度可用 `KLBURN_BUILD_JOBS=2` 限制；压缩缓存上限为 256MiB。
正式发布要求 `vendor/full-vendor.sha256` 覆盖并校验整机版既有工具与唯一 NVIDIA
安装包，缺失或字节变化会停止，不能把工具缺失后的 SKIP 当作完整交付。
两版包版本清单保存为 `packages.tsv`，离线组件哈希也写进发布收据。

受限构建机应记录实际 RAM、swap、虚拟机 balloon 与 cgroup 限额，串行执行构建。
失败重试必须保留首次失败证据，不把受限虚拟机中的性能数值作为真机性能基准。
`build/release.sh` 自身不设置 VM balloon/swap/cgroup；后台启动者须按实际主机
资源提供限制，不能仅凭虚拟机配置的标称内存推断有足够物理内存。

### 空间与冷数据

空间紧张时，先确认文件归属、进程和挂载状态，再清理本项目不再使用的
一次性构建/测试文件与重复副本。仍需保留的冷数据可归档到自己选择的存储，
迁移前后核对 SHA256；不能删除正在构建或验收的工作区。
当前源码、vendor、源 ISO 缓存和正式发布产物保留在活跃工作区；客户原始报告不能
按临时测试输出删除。模拟 U 盘的报告先只读提取并逐文件校验，日志/截图留存后
才删除一次性 `usb.img`/`spare*.img`。

虚拟磁盘释放的 guest 空间不一定立即成为宿主机可用空间；是否支持回收由
宿主存储和虚拟磁盘配置决定。本工具不修改这些配置，也不自动执行磁盘回收操作。

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
| apt 装包失败 | Linux 构建机没网，或镜像挂了。换 `config.sh` 里的 `APT_MIRROR` |
| 构建中断后残留挂载点 | 脚本有 EXIT trap 会自动清理。真残留了：`sudo umount -l ~/klburn-build/rootfs/{dev/pts,dev,proc,sys,run}` |
| `WARN: ... 缺少依赖库` | `vendor/bench/` 里某个程序在盘里缺 `.so`。见 [`toolbox.md` §六](toolbox.md#六怎么确认一张盘里到底带了什么) |
