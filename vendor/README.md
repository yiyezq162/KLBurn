# vendor/ —— 离线安装包放这里

这个目录里的东西**不进版本库**，需要你手动下载后放进来。
构建脚本会自动检测：文件在就装进 ISO，不在就跳过对应功能（不会报错中断）。

目录结构：

```
vendor/
├── storcli/
│   └── storcli64                      # Broadcom 阵列卡命令行工具（第一阶段就能用）
├── nvidia/
│   └── NVIDIA-Linux-x86_64-XXX.XX.run # NVIDIA 驱动离线包（第二阶段）
├── gpu_burn/
│   ├── gpu_burn                       # 编译好的 gpu_burn 可执行文件（第二阶段）
│   └── compare.ptx
└── logo.png                           # 可选：报告抬头 logo（PNG，建议高度 100px 内）
```

---

## 1. storcli64（阵列卡工具）

**作用**：采集 Broadcom / LSI / MegaRAID 阵列卡的型号、固件版本、逻辑盘状态。
没有它的话，报告里阵列卡一栏只能显示 lspci 认到的 PCI 型号。

**下载地址**：
- Broadcom 官网支持页：https://www.broadcom.com/support/download-search
  搜索 `StorCLI`，选 "Management Software and Tools" 分类
- 下载得到的是一个 zip，解压后路径类似
  `Unified_storcli_all_os/Linux/storcli64`（有的版本在 `Linux/` 下是 rpm 包，
  可以用 `rpm2cpio storcli-*.rpm | cpio -idmv` 解出 `opt/MegaRAID/storcli/storcli64`）

**放置**：
```
vendor/storcli/storcli64
```
不需要 chmod，构建脚本会自动加执行权限。

**也可以偷懒**：Broadcom 那个 zip 解出来是一层套一层的目录
（`Unified_storcli_all_os/Linux/storcli64`）。直接把整个解压结果原样丢进
`vendor/storcli/` 就行，构建脚本会自己往下递归找 `storcli64`／`storcli`，
不用每次出盘都手工翻目录把那个文件捞出来。构建日志里会打出它最终用的是哪个路径。

**怎么确认装上了**：构建时看 chroot 那段的输出——
`[chroot] storcli64 已安装（来自 vendor/...）` 就是成了；
如果打的是 `vendor/storcli/ 下没找到 storcli64`，那就是没放对地方。

**装上之后报告里多出什么**：阵列卡的固件版本、逻辑盘（VD）状态、
卡后面挂了哪些物理盘及其状态。没有它的话这一项是 WARN，只能从 PCI 反查到型号。
注意 storcli64 **只采集不压测**，阵列卡本身不做破坏性操作。

> 注：storcli64 只认 Broadcom / LSI 系阵列卡（MegaRAID SAS 那一系，
> 比如 SAS-3 3108 [Invader]、9361/9364、SAS-3.5 3508/3516 等）。
> 如果你的机器用的是别家阵列卡（如 Adaptec/微芯的 arcconf、Intel VROC），
> 需要另外准备工具，目前脚本没有集成，报告会标注为"检测到阵列卡但无对应工具"。

---

## 2. NVIDIA 驱动（第二阶段才需要）

**作用**：GPU 服务器的显卡识别 + 压测。第一阶段精简版 ISO 不需要这个。

**下载地址**：https://www.nvidia.cn/drivers/  或  https://www.nvidia.com/download/index.aspx
- 产品类型选 **Data Center / Tesla** 或 **GeForce**（要覆盖 RTX 4090/5090 就选 GeForce 那条线，
  数据中心卡和消费卡现在是同一套驱动分支）
- 操作系统选 **Linux 64-bit**
- 下载类型选 **Linux x64 (AMD64/EM64T) Display Driver**
- 得到文件名形如 `NVIDIA-Linux-x86_64-570.86.16.run`

**版本要求**：
- RTX 4090 (sm_89)：≥ 520 即可
- RTX 5090 (sm_120, Blackwell)：**必须 ≥ 570.xx**
- RTX Pro 6000 Blackwell：**必须 ≥ 570.xx**

所以直接选 570 或更新的版本，一个驱动通吃三种卡。

**放置**：
```
vendor/nvidia/NVIDIA-Linux-x86_64-570.86.16.run
```
文件名不用改，构建脚本按 `NVIDIA-Linux-x86_64-*.run` 通配匹配（取第一个）。

---

## 3. gpu_burn（第二阶段才需要）

**作用**：把显卡拉满做矩阵运算并校验结果，能查出算错数的坏卡。

这个需要在 WSL 里自己编译（因为要 CUDA 工具链）。详细步骤见项目根目录
`README.md` 的「第二阶段：加入 GPU 模块」一节。

编译产物放：
```
vendor/gpu_burn/gpu_burn
vendor/gpu_burn/compare.ptx
```

---

## 4. logo.png（可选）

报告抬头显示的公司 logo。PNG 格式，会被 base64 内嵌进 report.html，
所以别放太大的图（建议 < 100KB，高度 100px 以内）。

放置：
```
vendor/logo.png
```

同时记得改 `build/config.sh` 里的 `COMPANY_NAME`。
