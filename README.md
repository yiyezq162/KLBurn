<div align="center">

# KLBurn

**服务器出厂老化测试启动盘**

插上 U 盘，开机，走开。跑完拔盘，U 盘里就有一份中文验收报告。

[官网](https://yiyezq162.github.io/KLBurn/) · [下载](#下载) · [快速上手](#快速上手) · [文档](#文档) · [更新日志](CHANGELOG.md)

![License](https://img.shields.io/badge/license-MIT-126044)
![Platform](https://img.shields.io/badge/target-x86__64%20server-126044)
![Base](https://img.shields.io/badge/base-Ubuntu%2024.04.4-126044)

</div>

---

## 下载

| 版本 | 适合 | 开机后 | 下载 |
|---|---|---|---|
| **整机测试版**（full） | 出厂验收、整机老化 | 选范围、选时长；不按键默认全量 + 30 分钟 | 暂未公开 |
| **内存专用版**（mem） | 一批内存逐台过筛、查假条子 | 什么都不用选，约 3 分钟出结果 | 暂未公开 |

> [!NOTE]
> **目前只公开源码和官网，ISO 暂不提供下载。** 第三方组件的分发条件核验完成后，
> 下载会出现在 [Releases](https://github.com/yiyezq162/KLBurn/releases) 和[官网](https://yiyezq162.github.io/KLBurn/#download)。
> 现在可以[从源码构建](#从源码构建)。

两种盘出自同一份源码、同一个版本号，每次成对发布。

---

## 快速上手

**1. 校验镜像**：下载 ISO 后比对 SHA256。full 和 mem 的校验值不一样，别混用。

**2. 制作 U 盘**（Windows + [Rufus](https://rufus.ie/zh/)，详见 [U 盘制作](docs/usb-rufus.md)）

- 分区类型 GPT，目标系统 UEFI。点「开始」后**必须选「以 DD 映像模式写入」**
- 写完后 Windows 提示格式化，**点取消**
- 在剩余空间新建一个 **exFAT** 分区，卷标写 **`KLBURN`**（全大写）。报告就存在这里

> [!WARNING]
> 写盘会清空整根 U 盘，先确认盘里没有要留的东西，并核对磁盘容量。

**3. 开机测试**：BIOS 启动菜单选 U 盘（一般按 `F11` / `F12` / `F7` / `Esc`）。

```
插盘 → 开机 → 选范围（60 秒倒计时）→ 选时长（30 秒倒计时）→ 走开
              两个菜单都不按，就默认「全量测试 + 标准 30 分钟」
```

**4. 拿报告**：屏幕上出现 PASS / FAIL 大字后拔盘。把 U 盘插回电脑，
打开 `KLBURN` 分区里本轮的文件夹，**`<目录名>.html` / `.pdf` 就是交给客户的报告**。

现场每一屏的样子和出错时的排查，见[现场操作](docs/operating.md)。

---

## 测试范围（整机版）

开机第一个菜单问的是**测什么**：

| 键 | 范围 | 报告目录后缀 | 什么时候用 |
|:-:|---|---|---|
| **1** | **全量测试**（默认） | `_Full` | **出厂验收就用这个** |
| 2 | CPU 单独测试 | `_CPU` | 换过 CPU，或怀疑算力、算错 |
| 3 | 内存单独测试 | `_MEM` | 换过内存条，或查 ECC |
| 4 | 显卡单独测试 | `_GPU` | 只验显卡 |
| 5 | 硬盘单独测试 | `_DISK` | 只压盘，时长全给硬盘 |
| 6 | 仅导出报告 | `_INFO` | 只要一份配置清单，几分钟出结果 |

硬件清单、配置核对和网卡检测每个范围都跑。范围外的项目整项不跑，
报告里也没有它们的结论行。

> [!IMPORTANT]
> 单项测试的报告**不能当整机验收依据**。报告抬头写着本轮范围，「仅导出报告」不显示 PASS 大字。

## 它测什么

| 阶段 | 内容 | 怎么判 |
|---|---|---|
| ① 硬件采集 | 整机 / CPU / 逐条内存 / 硬盘（含阵列卡后的物理盘）/ 网卡 / 显卡 / 电源 / BMC | 有什么列什么 |
| ② 配置核对 | 同规格部件的型号和固件、内存容量、PCIe 降级、序列号 | 不一致判 WARN |
| ③ 性能基准 | CPU 浮点、内存带宽、硬盘读写、显卡带宽和互联 | **只报数，不判合格** |
| ④ 专项验证 | CPU 计算正确性、SMART 自检、网卡自检、显卡厂商诊断 | 部件自己报错才判 FAIL |
| ⑤ 压力测试 | CPU / 内存 / 显卡并发跑满时长，硬盘单独跑 | 出错、超温、掉卡判 FAIL |
| ⑥ 测后复查 | ECC、热节流、PCIe AER、内核日志、BMC 事件、SMART 增量 | 按压测前后差值判 |

每一项 PASS / WARN / SKIP / FAIL 的判定条件见
[`architecture.md` §6](docs/architecture.md#六判定规则总表)。

## 产出什么

| 文件 | 用途 |
|---|---|
| `<目录名>.html` + `.pdf` | ✅ 交给客户。自包含的中文报告，双击就能看 |
| `meta.json`、`results.jsonl`、`*.csv`、`klburn.log`、`SHA256SUMS` | 内部留档 |
| `raw\`（含 `INTERNAL_*.html` 工程报告） | 内部复盘、追溯 |

内存专用版还额外输出一份「一条内存一行」的 CSV。多台的 CSV 拼在一起按序列号排序，
有问题的那批会排到一起。详见[报告说明](docs/reports.md)。

## 内存专用版

整机盘太重的时候用它，比如买到一批可疑内存，要一台一台过。

- 读出每条内存的槽位、厂商、型号、**序列号**、频率、生产周次，再压测一遍，并查 ECC 和内核日志
- 硬盘、阵列卡、显卡、电源、BMC 都不碰，网卡只用来校时
- **只有内存坏才判 FAIL**
- 查假条子：**同一台机器上序列号重复**判 FAIL；**SPD 逐字节相同**说明是克隆条子

详见[内存专用版说明](docs/mem-edition.md)。

<details>
<summary><b>设计原则：和「随便跑个 stress」有什么不同</b></summary>

<br>

- **四态判定，不把「没有」说成「坏了」**：没装显卡、没接网线判 SKIP，不影响结论；
  装了但认不到才判 FAIL。一条判定都没有时，报告直接写明「本报告无效」。
- **性能只报数，不设阈值**：验收标准由做验收的人来定，代码里没有任何「参考值」。
- **测试环境自己的问题不算到机器头上**：比如压测进程被 OOM 杀掉判 WARN，
  驱动不支持新卡判 SKIP，好机器不会被判坏。
- **阵列卡后面的物理盘也要查到**：自动识别阵列卡，逐块透传读 SMART。
- **日志判读只看数字**：不靠关键字匹配，正常日志里的 `errors: 0` 不会被误判成失败。
- **U 盘自己绝不会被写坏**：fio 目标盘要经过五道排除，Ventoy 场景按设备号反查。
- **破坏性写入要确认两次**：先原样输入 `yes`，最终警告页上再按 `y`。
- **报告落盘有四层回退**：卷标 → 同盘 exFAT → 其他可移动 exFAT → dm 设备。
- **屏幕是给人看的**：整屏刷新的仪表盘，方便拍照发群。
- **每条守卫都有变异测试**：故意注入故障，确认守卫真的会报红。

</details>

---

## 文档

| 想做什么 | 看这份 |
|---|---|
| 做一根 U 盘 | [U 盘制作（Rufus + exFAT）](docs/usb-rufus.md) |
| 站在服务器前操作 | [现场操作](docs/operating.md) |
| 看懂报告 | [报告说明](docs/reports.md) |
| 只查内存 | [内存专用版](docs/mem-edition.md) |
| 第一次上真机 | [真机首跑清单](docs/first-run-checklist.md) |
| 查旧报告对应的版本 | [更新日志](CHANGELOG.md) |
| 盘里有哪些工具 | [工具清单](docs/toolbox.md) |
| 构建与发版 | [构建文档](docs/building.md) |
| 换名称 / 报告抬头 | [定制构建](docs/custom-build.md) |
| 改代码 | [架构与不变量](docs/architecture.md) · [报告文案规范](docs/report-policy.md) |
| CI 与公开发布 | [CI](docs/CI.md) · [公开发布](docs/publication.md) |

## 从源码构建

源码在 macOS、Windows、Linux 上都能编辑，**ISO 必须在 x86_64 Ubuntu 24.04 上构建**
（Apple Silicon 的 Mac 请通过 SSH 连一台 Linux 构建机）。

```bash
sudo apt-get install -y xorriso squashfs-tools rsync curl ca-certificates \
                        gdisk fdisk file zstd python3 jq dosfstools mtools
sudo KLBURN_WORK="$HOME/klburn-build" ./build/build-iso.sh               # 整机版，首次下载约 3.2 GB 源 ISO
sudo KLBURN_WORK="$HOME/klburn-build" ./build/build-iso.sh --edition mem # 内存专用版
./tests/run-all.sh                                                       # 源码回归
```

产物在 `out/`。构建目录要放在 Linux 本地文件系统上，WSL 的 `/mnt/c` 会被拒绝。
完整说明见[构建文档](docs/building.md)；想换成自己的名称和报告抬头，见[定制构建](docs/custom-build.md)。

<details>
<summary><b>项目结构</b></summary>

```
KLBurn/
├── build/            构建脚本、版本与包列表（config.sh）
├── rootfs/opt/klburn 盘内程序：factory-test.sh（整机）、memtest.sh（内存）、lib/、report/
├── tools/            仓库侧工具（批量汇总、报告对比、定制构建），不进盘
├── tests/            源码回归、变异测试、QEMU 验收
├── docs/             文档
├── site/             官网（GitHub Pages）
└── vendor/           离线包，不进 Git（见 vendor/README.md）
```

</details>

---

## 许可证与联系

KLBurn 自有的原创代码和文档采用 [MIT 许可证](LICENSE)，**MIT 不覆盖整张 ISO**。
镜像里的第三方软件、驱动、固件、字体和运行库各自适用其许可证；本项目不改变这些许可证的权利与义务，
也不代表相关厂商，不暗示获得其认证或背书。第三方归属与分发条件见[第三方许可说明](docs/third-party.md)。

问题反馈请提 [Issue](https://github.com/yiyezq162/KLBurn/issues)。版权、许可证或归属问题请发邮件到
**[yiyezq162@gmail.com](mailto:yiyezq162@gmail.com)**，并写明涉及的版本、文件和权利依据。
我们核实后，会按适用许可补充声明、修正分发或下架。

### 第三方归属

整机版使用的 Intel LINPACK 附带 HPL 归属声明：

> This product includes software developed at the University of Tennessee, Knoxville, Innovative Computing Laboratory.

UEFI 启动组件 shim 所含 OpenSSL／SSLeay 代码的原文致谢：

> This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit. (http://www.openssl.org/)
>
> This product includes cryptographic software written by Eric Young (eay@cryptsoft.com).
>
> This product includes software written by Tim Hudson (tjh@cryptsoft.com).

完整声明见 [shim 15.8 版权原文](docs/licenses/shim-15.8.COPYRIGHT)。这些声明不代表相关机构或作者为 KLBurn 背书。
