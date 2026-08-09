# vendor/ —— 离线安装包放这里

这个目录里的东西**不进版本库**（体积大、有授权限制），需要你手动下载后放进来。
构建脚本会自动检测：文件在就装进 ISO，不在就跳过对应功能（不会报错中断）。

目录结构：

```
vendor/
├── storcli/
│   └── storcli64                      # Broadcom / LSI 阵列卡命令行工具
├── perccli/                           # 可选：Dell PERC
│   └── perccli64
├── ssacli/                            # 可选：HPE Smart Array
│   └── ssacli
├── sas3ircu/                          # 可选：LSI/Broadcom HBA（IT 模式）
│   └── sas3ircu
├── nvidia/
│   └── NVIDIA-Linux-x86_64-XXX.XX.run # NVIDIA 驱动离线包
├── gpu_burn/
│   ├── gpu_burn                       # 编译好的 gpu_burn（./build/build-gpu-burn.sh 产出）
│   └── compare.fatbin
├── bench/                             # 可选：性能基准程序，整个子目录原样铺进盘里
│   ├── cuda-samples/                  #   bandwidthTest / p2pBandwidthLatencyTest
│   ├── linpack/                       #   xlinpack_xeon64 + libiomp5.so
│   └── mlc/                           #   mlc 或 mlc_avx512
└── logo.png                           # 可选：报告抬头 logo（PNG，建议高度 100px 内）
```

一览：

| 放什么 | 不放会怎样 |
|---|---|
| `nvidia/*.run` | 出一张不含显卡驱动的盘；有卡的机器 GPU 项记 SKIP，不算故障 |
| `gpu_burn/` | 显卡型号/显存/驱动版本照常进报告，但不做满载压测，也就没有温度功耗曲线 |
| `storcli/storcli64` | 阵列卡只能报 PCI 反查到的型号，读不到固件版本和逻辑盘状态（见下方说明：**卡后面物理盘的 SMART 不依赖它**） |
| `perccli/` `ssacli/` `sas3ircu/` | 同上，只是对应的是 Dell PERC / HPE Smart Array / IT 模式 HBA。一个都不放也正常，那一项判 SKIP 不判 FAIL |
| `bench/` | 性能基准那几项（显卡传输带宽、显卡间互联、CPU 算力、内存带宽）判 SKIP。硬盘带宽不受影响（`fio` 在盘里） |
| `logo.png` | 报告抬头不显示 logo |

---

## 1. NVIDIA 驱动

**作用**：显卡识别 + 压测的前提。

**下载地址**：https://www.nvidia.cn/drivers/  或  https://www.nvidia.com/download/index.aspx

- 操作系统选 **Linux 64-bit**，下载类型选 **Linux x64 (AMD64/EM64T) Display Driver**
- 得到文件名形如 `NVIDIA-Linux-x86_64-595.84.run`

**一个驱动通吃所有卡** —— NVIDIA 的 Unix `.run` 包是一份统一的支持列表，
消费卡、工作站卡、数据中心卡混在一起，不需要区分「GeForce 驱动」和「数据中心驱动」。
595.84（当前 Latest Production Branch）的支持列表覆盖：

| 卡 | 架构 | PCI ID |
|---|---|---|
| RTX 4090 | Ada (sm_89) | `10de:2684` |
| RTX 5090 | Blackwell (sm_120) | `10de:2B85` |
| RTX PRO 6000 Blackwell WS | Blackwell (sm_120) | `10de:2BB1` |
| L20 | Ada (sm_89) | `10de:26BA` |
| H100 | Hopper (sm_90) | `10de:2339` |

**版本要求**：Blackwell（RTX 5090 / RTX PRO 6000）**必须 ≥ 570**，
且只能用 open kernel module —— 构建脚本已经显式传 `-M=open` 并在装完后用
`modinfo -F license` 复核，理由见
[`../docs/architecture.md`](../docs/architecture.md#九构建流水线)。

**放置**：

```
vendor/nvidia/NVIDIA-Linux-x86_64-595.84.run
```

文件名不用改，构建脚本按 `NVIDIA-Linux-x86_64-*.run` 通配匹配（取第一个）。

> **驱动比卡旧会怎样**：`nvidia-smi` 认不到那张卡，但 KLBurn 不会把它判成坏卡 ——
> 它会去内核日志里找 NVRM 的原话（`... is not supported by the NVIDIA <版本>
> driver release`），认出这是"驱动与显卡不匹配"，判 SKIP。
> 内部工程报告里会写明具体的 PCI ID 和驱动版本，换个新驱动重新出盘就行。

**已知限制**：H100 的 SXM/HGX 版（带 NVSwitch）需要 `nvidia-fabricmanager`，
本项目未包含，PCIe 版不受影响；H100 若开了 MIG，gpu_burn 的行为尚未验证。

---

## 2. gpu_burn

**作用**：把显卡拉满做矩阵运算并校验结果，能查出算错数的坏卡。

需要在 WSL 里自己编译一次（要 CUDA 工具链），**不需要 root，也不需要机器上真有 N 卡**：

```bash
# 装 CUDA Toolkit（只为编译，必须 ≥ 12.8，因为 sm_120 是 12.8 才加进去的）
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y cuda-toolkit-12-8 build-essential git

# 编译（需要能访问 GitHub）
./build/build-gpu-burn.sh
```

脚本会：自动在 `/usr/local/cuda*` 下找 `nvcc` → 从 GitHub 克隆
[wilicc/gpu-burn](https://github.com/wilicc/gpu-burn) → 编译 →
**裁剪 cuBLAS 静态库并静态链接** → 把 `gpu_burn` 和 `compare.fatbin` 装进
`vendor/gpu_burn/`。克隆失败的话脚本会提示你手动把源码解压到那个目录再重跑。

三个可用的环境变量：

| 变量 | 默认 | 用途 |
|---|---|---|
| `CUDAPATH` | 自动在 `/usr/local/cuda`、`cuda-13*`、`cuda-12*` 里找 | 自动找不到 nvcc 时手工指定 |
| `COMPUTE`  | `75` | gpu_burn 自己那个 compare 核的 PTX 基线架构 |
| `GPU_ARCHS`| `80 86 89 90 120` | cuBLAS 里保留哪几代卡的 cubin |

> `COMPUTE` 定低不会削弱压测强度：`compare` 核走 PTX/fatbin + 驱动 JIT，PTX 向上兼容；
> 真正的算力负载来自 cuBLAS 里的预编译 cubin。定低反而让更老的卡也能跑。
>
> ⚠️ `compare.fatbin` 是 gpu_burn 运行时按**相对路径**加载的，丢了会直接跑不起来，
> 所以 chroot 里没找到会直接报错停下。（上游早些年产出的是 `compare.ptx`，
> 两个名字构建脚本都认。）

产物放：

```
vendor/gpu_burn/gpu_burn
vendor/gpu_burn/compare.fatbin
```

---

## 3. storcli64（阵列卡工具）

**作用**：采集 Broadcom / LSI / MegaRAID 阵列卡的型号、固件版本、逻辑盘状态、
卡后面挂了哪些物理盘。没有它的话，报告里阵列卡一栏只能显示 lspci 认到的 PCI 型号。

**下载地址**：Broadcom 官网支持页 https://www.broadcom.com/support/download-search
搜索 `StorCLI`，选 "Management Software and Tools" 分类。

`docs.broadcom.com` 上有直链，形如
`https://docs.broadcom.com/docs-and-downloads/<版本>_storcli_rel.zip`
（2026-08 当前是 `007.2705.0000.0000_storcli_rel.zip`，约 33MB）。
版本号会变，直链失效就回上面那个搜索页。

**这个 zip 套了两层**，而且里面**没有裸的 `storcli64`**，只有各平台的安装包：

```
storcli_rel.zip
└── Unified_storcli_all_os.zip
    └── Unified_storcli_all_os/
        ├── Linux/storcli-<版本>-1.noarch.rpm
        ├── Ubuntu/storcli_<版本>_all.deb      ← 我们的盘是 Ubuntu，用这个
        ├── ARM/ EFI/ FreeBSD/ VMware/ Windows/
        └── readme.txt
```

二进制在包里的 `/opt/MegaRAID/storcli/storcli64`，取出来：

```bash
dpkg-deb -x Unified_storcli_all_os/Ubuntu/storcli_*_all.deb /tmp/storcli-x
cp /tmp/storcli-x/opt/MegaRAID/storcli/storcli64 vendor/storcli/
```

只有 rpm 的话：`rpm2cpio storcli-*.rpm | cpio -idmv`，同样在
`opt/MegaRAID/storcli/storcli64`。

> 取出来的应该是一个 **静态链接的 ELF x86-64** 可执行文件（`file` 一下确认），
> 8MB 上下。静态链接这点要紧：盘里的 rootfs 很精简，动态链接的版本会因为
> 缺库跑不起来，而 `collect_raid` 只会看到"命令跑不出东西"，不会告诉你为什么。

**放置**：

```
vendor/storcli/storcli64
```

不需要 chmod，构建脚本会自动加执行权限。
**也可以偷懒**：直接把整个解压结果原样丢进 `vendor/storcli/`，
构建脚本会自己往下递归找 `storcli64`／`storcli`，构建日志里会打出它最终用的是哪个路径。

**怎么确认装上了**：构建时看 chroot 那段的输出 ——
`[chroot] storcli64 已安装（来自 vendor/...）` 就是成了。

> **没放 storcli64 也不会丢掉物理盘的健康数据。** 卡后面那些盘的 SMART 是
> 靠 `smartctl -d megaraid,N` 透传读的，设备号从 sysfs 推出来（推不出来就有界试探），
> 整条路不依赖任何厂商工具 —— 型号、序列号、温度、坏道计数、以及压测前后的
> 增长对比都照常有。storcli64 补上之后多出来的是**阵列卡自己**的信息：
> 固件版本、逻辑盘（VD）状态、以及每块物理盘在卡上的槽位和状态。

> 注：storcli64 **只认 Broadcom / LSI 系**阵列卡（MegaRAID SAS 那一系，
> 比如 SAS-3 3108 [Invader]、9361/9364、SAS-3.5 3508/3516 等）。
> 别家的卡要用别家的工具，见下面 3b。
>
> **阵列卡始终只采集不压测**，所以这一项永远不会是 FAIL。

---

## 3b. 别家的阵列卡工具（可选，放几个算几个）

一张阵列卡**只有对得上的那个厂商工具认得**。采集时是挨个试、命中即用，
一个都没带也完全正常 —— 那一项判 SKIP，只报 PCI 反查到的型号，
**永远不会因此判 FAIL**（少带工具是我们这边的事，不是被测机器的毛病）。

| 放到 | 装进盘里的名字 | 认哪些卡 | 怎么从下载包里取出来 |
|---|---|---|---|
| `vendor/perccli/` | `perccli64` | **Dell PERC**（H7xx/H8xx…） | `Perccli_*_Linux.tar.gz` → 里面是 rpm：`rpm2cpio perccli-*.rpm \| cpio -idm` → `opt/MegaRAID/perccli/perccli64` |
| `vendor/ssacli/` | `ssacli` | **HPE Smart Array**（P4xx/P8xx、Gen9~Gen10） | `ssacli-*.rpm`：`rpm2cpio ... \| cpio -idm` → `opt/smartstorageadmin/ssacli/bin/ssacli` |
| `vendor/sas3ircu/` | `sas3ircu` | **LSI/Broadcom HBA 的非 RAID（IT）模式**（9300/9400 系） | `SAS3IRCU_P16.zip` 解开 → `SAS3IRCU_P16/sas3ircu_rel/sas3ircu/sas3ircu_linux_x64_rel/sas3ircu` |

和 storcli 一样：**可以直接把整个解压结果原样丢进对应目录**，
构建脚本会往下递归找那个可执行文件，构建日志里会打出它最终用的是哪个路径
（`[chroot] ssacli 已安装（来自 vendor/...）`），最后还会汇总一句
`[chroot] 阵列卡管理工具共装了 N 个`。

> **`arcconf`（Microchip / Adaptec）不备。** 它按控制器系列分版本，手上没有
> 对应的卡就无从判断该下哪一个，备个错版本还不如不备。真拿到 Adaptec 卡时，
> 在 `build/chroot-setup.sh` 的 `VENDOR_RAID_TOOLS` 和 `lib/collect.sh` 的
> `RAID_TOOL_ORDER` 里各加一行就行 —— `raid_tool_run` 里那个 case 分支还留着。

> ⚠️ **静态链接的优先。** 这张盘的 rootfs 是剪过的，动态链接的工具会因为缺库
> 跑不起来，而现场看到的只是"阵列卡那项判了 SKIP"，查不出原因。
> 构建期已经有自检兜底：装完会用 `readelf` 读它的 NEEDED、逐个去盘里找，
> 缺库直接让构建停下并打出缺哪几个。
> （当前这四个里 `ssacli` 是动态链接的，要 `libstdc++` / `libgcc_s` 等 7 个库，
> 24.04 的基础系统里都有，自检通过。）

> ⚠️ `perccli64` 和 `storcli64` 是同一套东西换的皮，**子命令完全一样，
> 但版本对不上会认不到卡**（storcli 认不了 PERC，反过来也一样）。
> 所以两个都放着最省事，采集时会先试 storcli、不命中再试 perccli。

> ⚠️ 这几个工具**没有在真卡上验证过** —— 我们手上没有对应的硬件和二进制。
> 代码路径（挨个试、命中即用、都不命中判 SKIP、文案里不出现工具名）
> 有回归测试用桩守着，但**真工具的输出格式没人验过**。
> 第一次拿到真卡时照 [`../docs/first-run-checklist.md`](../docs/first-run-checklist.md)
> 核一遍 `raw/raid/` 下的原始输出。

**Intel VROC** 目前没有集成（它的 `mdadm`/`VROC CLI` 那条路和上面几个都不一样），
遇到会判 SKIP 并写「当前测试环境的管理工具不支持该型号」。

---

## 4. logo.png（可选）

报告抬头显示的公司 logo。PNG 格式，会被 base64 内嵌进报告 HTML，
所以别放太大的图（建议 < 100KB，高度 100px 以内）。

```
vendor/logo.png
```

同时记得改 `build/config.sh` 里的「品牌抬头」一块（`COMPANY_NAME` 等）。

---

## 5. bench/ —— 性能基准程序（可选，1.9.0 新增）

**作用**：量出验收单上那些**预期值**（GB/s、GFlops、MB/s）。

这四个程序都不在 Ubuntu 源里，也都不能重新分发到本仓库，所以要手工放进来。
**一个都不放完全正常** —— 对应的判定会干净地记 SKIP（「本次测试环境未包含…
基准测试程序，此项不影响整机结论」），绝不判 FAIL。

### 目录结构：整个子目录原样铺进盘里

```
vendor/bench/
├── cuda-samples/
│   ├── bandwidthTest                 # 主机↔显存、显存内部的传输带宽
│   └── p2pBandwidthLatencyTest       # 显卡两两之间的互联带宽
├── linpack/
│   ├── xlinpack_xeon64               # CPU 浮点算力
│   ├── help.lpk  xhelp.lpk           # 它自己要读的帮助文件，一起放
│   └── （老版本还要 libiomp5.so，见下）
└── mlc/
    └── mlc                           # 内存峰值读带宽
```

⚠️ **和阵列卡工具不一样：这里是把整个子目录原样铺进 `/opt/klburn/tools/bench/<子目录>/`，
不是只捞一个可执行文件出来。** 有的程序要带自己的运行库和数据文件，
只捞二进制的话现场跑起来是一行 `error while loading shared libraries`，
而那行报错落在日志里看着像"这台机器有问题"。运行时 `bench_run()` 会把程序
自己那个目录加进 `LD_LIBRARY_PATH`；构建期还会用 `readelf` 逐个自检依赖库
在不在盘里，缺了会打 WARN（不中断构建 —— 基准程序是可选件）。

> **关于 `libiomp5.so`：新版本不需要了。** oneMKL 2025.3 里的 `xlinpack_xeon64`
> 是静态链接的，`readelf` 只报 libpthread / libm / libdl / libc（实测确认）。
> 老一些的分发版确实要它，所以上面那条"整个目录铺进去"的规矩仍然有效 ——
> 换版本时用 `readelf -d xlinpack_xeon64 | grep NEEDED` 自己看一眼，
> 要的话把 `libiomp5.so` 一并放进同一个子目录就行。

### 各自从哪来

**cuda-samples**（BSD-3，NVIDIA 官方开源）—— **有现成脚本，直接跑**：

```bash
./build/build-bench.sh
```

它做的事：克隆 NVIDIA/cuda-samples、切到 `v12.8`、用 nvcc 把两个样例
**静态链接** 编出来、`ldd` 自检、放进 `vendor/bench/cuda-samples/`。
需要机器上装了 CUDA（和 `build-gpu-burn.sh` 同一套），**不需要有 N 卡**。

⚠️ 两件不能改的事，都写在那个脚本顶部：

- **必须 `-cudart static`**（和 gpu_burn 同一个道理）：盘里没有 `libcudart.so`，
  动态链接的二进制一跑就是 "error while loading shared libraries"，
  而那行报错落在日志里看着像"这台机器有问题"。脚本编完会 `ldd` 查一遍，
  查出动态依赖直接让构建失败。
- **tag 钉在 `v12.8`**：上游从 **13.0 起把 `bandwidthTest` 整个删掉了**
  （换成了 `nvbandwidth`，输出格式完全不同），而验收单上写的就是
  `bandwidthTest`，报告的解析函数也是按它的表头写的。

**Intel Optimized LINPACK Benchmark**（`xlinpack_xeon64`）。
它**不再单独发布**了，现在跟着 oneMKL 走。两条路：

```bash
# 路子一（本项目实际用的）：直接从 Intel 的 apt 仓库取那个 deb 解开，
#   不动系统的 apt 配置，只当成一个 tar 包用
curl -LO https://apt.repos.intel.com/oneapi/pool/main/intel-oneapi-mkl-core-devel-2025.3-2025.3.1-8_amd64.deb
dpkg-deb -x intel-oneapi-mkl-core-devel-*.deb x
cp x/opt/intel/oneapi/mkl/*/share/mkl/benchmarks/linpack/{xlinpack_xeon64,help.lpk,xhelp.lpk} \
   vendor/bench/linpack/

# 路子二：装了 oneAPI 的机器上直接拷
#   ${MKLROOT}/share/mkl/benchmarks/linpack/
```

**不用拷它自带的 `lininput_xeon64`** —— 那份样例是一串从 1000 到 45000 的
15 个规模，跑一轮要很久。运行时会按内存容量自动生成一份只跑一个规模的
（上限 40000 阶，四次约一分钟），也可以在 `klburn.conf` 里用 `BENCH_LINPACK_N` 写死。

**Intel Memory Latency Checker**（Intel 官网免费下载）：

```bash
curl -LO https://downloadmirror.intel.com/866182/mlc_v3.12.tgz
tar xzf mlc_v3.12.tgz && cp Linux/mlc Linux/redist.txt vendor/bench/mlc/
```

> **v3.12 起不再有单独的 `mlc_avx512`**，包里只有一个 `mlc`，
> AVX-512 变成了开关 `-Z`。验收单上写的 `mlc_avx512` 对应的就是它 ——
> 要严格按那个口径测，在 `klburn.conf` 里写 `BENCH_MLC_AVX512=1`。
> 默认不加：不是每颗 CPU 都有 AVX-512，加了在没有的平台上直接跑不出结果。
> 它同目录的 `redist.txt` 明确把 `mlc` 列为 Redistributable。

### 没有"阈值"这回事

⚠️ **这几项只报实测值，报告里不会有"参考值 / 是否达标"这种东西，
也不要去加。**

理由很直接：这张盘是**插上就跑、无人值守**的。现场没有人、也没有地方去填
"这台机器的带宽应该是多少"。凭空写一个数进来，等于我们替客户定了一个
他没定过的标准，再拿它去说这台机器行不行 —— 那个数字从哪来的谁也说不清。

**各家的验收要求不一样，同一个数字换个机型可能高得离谱也可能低得可笑。**
我们的责任到"把数量准、写清楚"为止；谁做验收，谁拿自己那份要求来对。

所以基准项的状态只有两种：**量到了 → PASS（文案里就是那个实测值）**、
**量不到 → SKIP**（没放程序 / 没有显卡 / 程序没返回有效结果）。
不会是 WARN，也不会是 FAIL，更不会影响整机结论。

能配的只有"怎么测"的参数（跑几次、多大矩阵、队列深度、每个方向跑多少秒），
见 `build/chroot-setup.sh` 里生成 `klburn.conf` 的那一段。
