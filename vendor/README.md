# vendor/ —— 离线安装包放这里

这个目录里的东西**不进版本库**（体积大、有授权限制），需要你手动下载后放进来。
构建脚本会自动检测：文件在就装进 ISO，不在就跳过对应功能（不会报错中断）。

目录结构：

```
vendor/
├── storcli/
│   └── storcli64                      # Broadcom 阵列卡命令行工具
├── nvidia/
│   └── NVIDIA-Linux-x86_64-XXX.XX.run # NVIDIA 驱动离线包
├── gpu_burn/
│   ├── gpu_burn                       # 编译好的 gpu_burn（./build/build-gpu-burn.sh 产出）
│   └── compare.fatbin
└── logo.png                           # 可选：报告抬头 logo（PNG，建议高度 100px 内）
```

一览：

| 放什么 | 不放会怎样 |
|---|---|
| `nvidia/*.run` | 出一张不含显卡驱动的盘；有卡的机器 GPU 项记 SKIP，不算故障 |
| `gpu_burn/` | 显卡型号/显存/驱动版本照常进报告，但不做满载压测，也就没有温度功耗曲线 |
| `storcli/storcli64` | 阵列卡只能报 PCI 反查到的型号，读不到固件版本和逻辑盘状态（见下方说明：**卡后面物理盘的 SMART 不依赖它**） |
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

下载得到的是一个 zip，解压后路径类似 `Unified_storcli_all_os/Linux/storcli64`
（有的版本在 `Linux/` 下是 rpm 包，可以用
`rpm2cpio storcli-*.rpm | cpio -idmv` 解出 `opt/MegaRAID/storcli/storcli64`）。

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

> 注：storcli64 只认 Broadcom / LSI 系阵列卡（MegaRAID SAS 那一系，
> 比如 SAS-3 3108 [Invader]、9361/9364、SAS-3.5 3508/3516 等）。
> 别家阵列卡（Adaptec/微芯的 arcconf、Intel VROC）需要另外准备工具，目前没有集成，
> 报告里会判 SKIP 并写「当前测试环境的管理工具不支持该型号」。
>
> **阵列卡始终只采集不压测**，所以这一项永远不会是 FAIL。

---

## 4. logo.png（可选）

报告抬头显示的公司 logo。PNG 格式，会被 base64 内嵌进报告 HTML，
所以别放太大的图（建议 < 100KB，高度 100px 以内）。

```
vendor/logo.png
```

同时记得改 `build/config.sh` 里的「品牌抬头」一块（`COMPANY_NAME` 等）。
