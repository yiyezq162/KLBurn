# 变更记录

每张盘的报告里都写着它是哪个版本（`meta.json` 的 `klburn_version`，内部工程报告
的页脚也有）。这份文件的用途就是：**拿着一份半年前的报告，能查出那张盘到底会干什么、
不会干什么。**

版本号在 [`build/config.sh`](build/config.sh) 的 `KLBURN_VERSION`。
规矩是**先 bump 再构建** —— 0.3.0 栽过一次，见下面「git 之前」那一节。

> 光靠版本号还不够：构建脚本会把源码的 git commit hash 和「工作区脏不脏」
> 一起钉进盘里。版本号靠人记得 bump，commit hash 是脚本自己取的，骗不了人。

每个发布过的版本都有一个 annotated tag，`git show v1.2.0` 能直接看到那一版的
说明和当时的断言数：

```bash
git tag -l --sort=version:refname
```

已有：`v0.4.0` `v0.8.0` `v1.1.0` `v1.2.0` `v1.3.0` `v1.4.0` `v1.4.2`
`v1.5.0` `v1.6.0`。

**版本号和 tag 不是一一对应的**，对不上的都有原因，别当成漏打：

| 号 | 为什么没有自己的 tag |
|---|---|
| 0.5~0.7、0.9~1.0 | 只在工作区里存在过，从来没有单独提交，见文末「git 之前」 |
| 1.4.1 | 内容并进了 `v1.4.2` |

`v1.5.0` 打在 1.6.0 bump 之前的最后一个 commit 上，所以
`git log v1.5.0..v1.6.0` 拿到的正好是 1.6.0 那一节的改动。

**tag 指向的就是那张盘构建自的那个 commit** —— `git show v1.6.0` 的 hash
和盘里 `klburn.conf` 的 `GIT_COMMIT` 对得上。这条比"tag 打在最新一次提交上"
重要：报告上只有版本号和 commit hash，两边对不上就查不下去了。
本条说明本身是发版之后补的，所以它在 tag 之后。

---

## 1.6.0

- **阵列卡管理工具从只支持 storcli 扩到五个厂商。** 内核驱动 in-tree 全都有
  （`megaraid_sas` / `mpt3sas` / `mpi3mr` / `smartpqi` / `aacraid` / `hpsa`），
  盘认得到、SMART 也读得到；缺的是读**阵列卡自己**的固件版本和逻辑盘状态的
  那个闭源 CLI —— 而一张卡只有对得上的那个工具认得：

  | 放到 `vendor/` | 认哪些卡 |
  |---|---|
  | `storcli/storcli64` | Broadcom / LSI MegaRAID（原有） |
  | `perccli/perccli64` | Dell PERC |
  | `arcconf/arcconf` | Microchip / Adaptec（`smartpqi`、`aacraid`） |
  | `ssacli/ssacli` | HPE Smart Array |
  | `sas3ircu/sas3ircu` | LSI/Broadcom HBA 的非 RAID（IT）模式 |

  以前盘里只带 `storcli64`，于是**所有非 Broadcom 的阵列卡都只能报一个 PCI 型号**。
  现在采集时挨个试、命中即用；`chroot-setup.sh` 按同样的方式递归找并 `chmod`。

  `storcli64` 仍然**单独先试**：报告生成器是按 `storcli-show.txt` 这个固定文件名
  去读、去嵌进报告的，那条路径不能动。其余几家的原始输出落在 `raw/raid/`。

  > 一个都不放也完全正常 —— 那一项判 **SKIP，绝不 FAIL**。少带工具是我们这边
  > 环境的限制，跟被测机器好不好毫无关系（二号原则）。客户可见文案里也照旧
  > 不出现任何工具名。

  ⚠️ **这几个二进制我们手上没有，测试里全是桩。** 桩守住的是代码路径
  （挨个试 / 命中即用 / 都不命中判 SKIP / 文案里不许有工具名），
  **真工具的输出格式没人验过** —— 第一次拿到真卡时要核 `raw/raid/` 下的原始输出。

  没做 `mstflint`：迈络思网卡的固件版本 `ethtool -i` 本来就给
  （`firmware-version: 16.35.2000`），为同一个字段再引一个没法验证的闭源工具，
  只会多一条没人走过的代码路径。

## 1.5.0

- **装回 linux-firmware —— 之前有 8 类网卡/HBA 的驱动在盘里根本起不来。**
  Ubuntu 的 live-server 镜像把 `linux-firmware` 的**文件**剪光了（dpkg 里它还是
  "install ok installed"，连 `.list` 都删了，看包管理器完全看不出来），
  磁盘上只剩 118MB，其中 99MB 还是 NVIDIA 驱动自己铺的 GSP 固件。

  拿 `modinfo -F firmware` 对着盘里的驱动逐个点账，结果是**需要 35 个固件，
  一个都没有**：

  | 驱动 | 缺 | 是什么 |
  |---|---|---|
  | `bnx2x` | 6 | Broadcom 10G，Dell R6x0 / HP Gen8-9 上到处都是 |
  | `nfp` | 11 | Netronome Agilio |
  | `qla2xxx` | 6 | QLogic FC HBA |
  | `tg3` | 4 | Broadcom 1G（板载最常见） |
  | `cxgb4` | 3 | Chelsio T4/T5/T6 |
  | `bfa` | 3 | Brocade FC HBA |
  | `ice` | 1 | Intel E810 25/100G，缺 DDP 包会降级进 safe mode |
  | `qed` | 1 | Marvell FastLinQ |

  > 危害不是"少个功能"，是**报告说谎**。`bnx2x` 必须先加载固件才能起来；
  > 固件不在 → 驱动起不来 → `ip link` 里一个物理口都看不到 →
  > `collect_nic` 判 WARN「无物理口」。
  > **一台有 4 个网口的机器，报告上写着它没网卡。**
  > 而且全程没有任何报错，只在 dmesg 里留一行 `Direct firmware load ... failed`。

  现在 `chroot-setup.sh` 里 `--reinstall linux-firmware` 装回来，
  再按 `config.sh` 的 `FIRMWARE_PRUNE` 剪掉服务器用不到的。
  **那是黑名单不是白名单** —— 漏一条只是多占地方，白名单漏一条就是少一块网卡。

  | | 体积 | 文件数 |
  |---|---|---|
  | 装回来（完整包） | 616 MB | 5927 |
  | 剪掉 | −524 MB | −4627 |
  | 剩下 | **92 MB** | 1300 |

  剪掉的大头：`nvidia/`（nouveau GSP，107MB，我们 blacklist 了 nouveau）、
  `mrvl`（79MB）、`mellanox`（79MB，全是 mlxsw **交换机**芯片固件）、
  `iwlwifi-*`（78MB）、`qcom`（61MB）、`amdgpu`（28MB）、
  ath/mediatek/brcm 等无线（约 50MB）。
  `intel/`（含 `intel/ice/ddp/ice.pkg`）、`i915`、`rtl_nic` 都留着。

- **清掉那套从来不会被执行的多余内核。** 盘里一直有两套：
  `6.8.0-100-generic`（`casper/vmlinuz` 真正引导的）和 `6.8.0-136-generic`。
  来路是装 NVIDIA 要 `dkms`，`dkms` 的 Recommends 指向 `linux-headers-generic`
  这个**元包**，元包跟着 archive 里最新的 ABI 走，于是
  `linux-image-generic` → 一整套新内核跟着进盘。
  省下 **155MB 模块 + 157MB `/usr/src` 头文件**。

- **内核版本不再靠 `ls /lib/modules | head -1` 猜。** 那是按字典序取第一个，
  而 chroot 里此刻常常有两个内核。现在由 `build-iso.sh` 从 `casper/vmlinuz`
  的 bzImage 头里读出真正会被引导的版本（`bzimage_kver()`），传进 chroot。

  > 猜错的两种后果都很难查，而且**都长得像硬件故障**：给不会被引导的那个内核
  > 编 NVIDIA 模块 → 开机 `nvidia.ko` 加载失败 → 判「显卡故障」；
  > 把该留的那套模块当多余的删掉 → 开机认不到任何硬盘。

- **两条新的构建期硬断言**（和已有的「合并后必须有 `/lib/modules`」并列）：
  - `rootfs` 里有且只有一套内核模块，且版本 == `casper/vmlinuz` ——
    只数数量分不出"清掉多余的"和"清掉该留的"，所以必须对版本。
  - 带显卡驱动时 `/lib/firmware/nvidia/<版本号>/` 必须非空 ——
    open 内核模块没有 GSP 固件起不来。固件剪裁那条写的是 `nvidia/[a-z]*`
    正是为了绕开这个数字开头的目录，这条断言把"有人改回 `nvidia`"钉死在构建期。

- **新增 [`tests/check-firmware.sh`](tests/check-firmware.sh)**：拿 `modinfo` 问
  驱动自己要哪些固件，再逐个去盘里找。25 个关键驱动（以太网 / FC HBA / 阵列卡），
  缺一个就红。**不需要固件的驱动故意留在表里** —— 哪天内核升级后它开始要固件了，
  这里会当场跑红，而不是等到现场发现少了一块网卡。
  它要一个已构建的 rootfs，所以和 `e2e-qemu.sh` 一样**不在** `run-all.sh` 里。

- **`amd64-microcode` / `intel-microcode` / `thermald` 改成显式安装**
  （`config.sh` 的 `PKGS_PLATFORM`）。它们本来是 `linux-image-generic` 的
  Recommends、带自动安装标记；purge 掉那个元包之后，紧跟着的 `autoremove`
  把它们一起收走了 —— **1.5.0 第一次构建就真的把 CPU 微码弄丢了**，
  是上面那条新测试的微码断言逮住的。

  > 顺带补了一条：`chroot-setup.sh` 的「关键工具点名」原来只在装完包时跑一次，
  > 现在**清理内核之后再跑一遍**。"装上了、后来又被 autoremove 收走"这条路
  > 以前完全没人看着。

  `autoremove` 同时带走的还有 `bpfcc-tools` / `bpftrace` / `libllvm18` /
  `libclang-cpp18` / `upower` / `usbmuxd` 等一串（`ubuntu-kernel-accessories`
  那棵树）。这些 KLBurn 一个都不用，留着只是占地方，就不再装回来了；
  包数 814 → 788。

- **体积**（同一份源码、同样的 zstd-19）：

  | | 1.4.2 | 1.5.0 |
  |---|---|---|
  | ISO | 1,514,956,800 B | **1,314,162,688 B**（−191.5 MiB，−13.3%）|
  | rootfs（未压缩） | 3.7 GB | 3.2 GB |
  | `/lib/firmware` | 118 MB / 140 个文件 | 212 MB / 1446 个文件 |

  固件那一栏两边都含 NVIDIA 驱动自带的 99MB GSP —— 真正的 linux-firmware
  内容是 19MB → 113MB。清内核省下的比装固件涨的多得多，所以盘整体是小了的。

- **端到端终于真的让 fio 写了一次盘**：`e2e-qemu.sh --stage full --disk-stress`。
  这是全项目最危险的一条路径 —— fio 往裸盘写随机数据，而启动 U 盘就插在同一台
  机器上；反查排除一旦退化，测试盘当场报废、历史报告全丢，不可逆。
  在这之前守它的只有 `test-disk-exclusion.sh` 用 loop + dm-linear 搭的设备链，
  **一次都没真让 fio 跑起来写过盘**。

  难点是那两道确认提示出现的时刻不固定（在 `collect_all` 之后，采集耗时随机器变），
  **按时间盲发按键不可接受 —— 按错方向就是真擦盘**。
  解法是轮询 `usb.img`：虚拟机写进 exFAT 的 `klburn.log`，在宿主机看来就是镜像里的
  一段字节，跑着的时候直接 `grep -a` 就能看到（实测延迟 3 秒以内）。
  四个锚点串起整条路，开跑前还断言"这四个锚点现在都不在镜像里"——
  否则轮询会在第 0 秒误命中，而这一轮的按键是"确认擦盘"。

  三条验收缺一不可，实测 29/0：
  1. 两块空白盘实际占用 0 → 2.1G，头 1MB 有 94 万个非零字节 —— fio 真写了
  2. U 盘第 4 分区还挂得上，**开跑前预埋的「上一轮的报告」一个字节没变**，
     两个报告目录并存 —— 没写穿
  3. `stress_disk` 判 **PASS 不是 SKIP** —— 确认键真打中了

  > 只验"分区还挂得上"远远不够：分区表没被动、文件全没了，照样挂得上。

  **这条端到端不是摆设，是验过的。** 把 `scan_disks` 的排除判断整个反过来
  （`if [[ -n "$why" ]]` → `if [[ -z "$why" ]]`，于是启动 U 盘变成 fio 的目标），
  出一张变异 ISO 跑了一次 —— **它跑红了**（7 项通过、2 项失败，退出码 1）。
  红的方式还很说明问题：

  ```
  FAIL 日志里没有 fio 启动的痕迹      <- fio 把 klburn.log 所在的分区写掉了
  FAIL 第 4 个分区挂不上              <- 连文件系统都没了
  ```

  第一条正是"写穿"的指纹：harness 读的那份日志，本身就在被 fio 写的那块盘上。

- **`test-hw-checks.sh` 补一组"Ventoy 形状的启动盘必须被排除"**，并加变异
  `media-blind`。排除有三层（`rm=1` / 有分区挂载 / `live_media_disks`），
  而 **Ventoy 场景下前两层同时落空** —— 它拿 dm-mapper 把 ISO 和 exFAT 包了一层，
  那个 dm 设备 udev 不处理、lsblk 完全看不见，于是 U 盘的 `rm` 报 0、分区也不
  显示为已挂载。那时候只剩走 sysfs slaves 链的 `live_media_disks`。

- **shellcheck 收紧到 `-S info` 的分诊做完了，结论是不动**。多出来的 26 条 SC2015
  逐条看过：**`rootfs/opt/klburn/` 下一条都没有**，全在 `tests/` 和 `build/` 里，
  没有一条落在判定路径上；形状只有"断言助手 `cond && ok || bad`"和
  `[[ -f ]] && sed || true` 两种，A 那一侧全是 `[[ ]]` 或直接对文件跑 grep，
  **没有管道**，撞不上 §11-10 那个 pipefail + SIGPIPE 的真陷阱。

  所以不豁免 SC2015（豁免掉就再也看不见新写的了），改成把它们**安全的前提**
  钉住：`ok()`/`bad()` 必须返回 0。写成 `PASS=$((PASS+1))` 是赋值、永远返回 0；
  改成 `(( PASS++ ))` 求的是**旧值**，`PASS` 为 0 那次返回 1 ——
  于是"断言通过"之后接着把 `bad` 也跑一遍。`lint.sh` 新增一条守卫，
  配变异 `counter-postfix`。

- **修 `mutate.sh` 一个会给出假警报的 bug。** 它拿 `awk -v` 传锚点，
  而 **`-v` 会对值做一遍反斜杠转义处理** —— 锚点里的 `\033` 在 awk 里变成一个
  真的 ESC 字节，文件里却是 `\033` 四个字符，`index()` 永远匹配不上。
  偏偏前面那道 `anchor_count` 用的是 `grep -F`，照样报"命中 1 次"，
  于是**变异静默没施加、对应套件照常全绿，最后被报成"这条守卫逃掉了"**。
  假警报比漏报还难查：人会跑去改一条本来就没问题的守卫。
  现在锚点走 `ENVIRON` 传（不做任何转义处理），并加一道后置检查 ——
  施加完文件必须真的变了，没变就当场判"施加失败"而不是"逃掉"。

  > 是新加的 `counter-postfix` 撞出来的，它的锚点里正好有 `\033`。
  > 变异总数 8 → 11，全部被抓住。

- **新增 `collect_disk` 的单元测试**（`test-hw-checks.sh`，13 条）。
  21 个判定 id 里它是唯一一个单元测试碰不到的，一直只有 QEMU 里那台虚拟机在跑，
  而虚拟机永远只走"普通盘"那一条分支。现在三条分支都有断言，
  其中最要紧的是**没装硬盘时判 WARN 不判 FAIL**，
  并在 `mutate.sh` 里加了对应变异（`disk-none-fail`）。

## 1.4.2

- **裸盘排除表的理由分开写。** 原来 `loop*|ram*|zram*|sr*|fd*|dm-*|md*` 共用
  一句 "virtual / software RAID device"，于是软驱 `/dev/fd0` 被标成
  "software RAID device"。现在逐类写（loopback / RAM disk / optical drive /
  floppy drive / device-mapper / software RAID）。

  > 这块屏幕是操作员决定「要不要擦这些盘」时**唯一的依据**，一条理由明显
  > 对不上，他就会开始怀疑整张排除表 —— 而这张表是防止写穿启动盘的最后一道
  > 人工关。是 QEMU 端到端的截图看出来的。

- **e2e 新增两个场景**：`--firmware uefi`（OVMF + q35）和
  `--no-data-partition`（第 4 分区格成 ext4，四层回退一层都不命中）。
  ISO 是双引导的，但 BIOS 和 UEFI 走的引导链完全不同，只验一条等于只验一半，
  而真服务器基本都是 UEFI。三个场景实测：BIOS 9/0、UEFI 9/0、无数据分区 7/0。
- e2e 冒烟档补一张 15 秒的截图 —— 找不到数据分区时那个黄色大框只停 8 秒，
  等到 30 秒就被采集日志顶走了。
- 修 e2e 自己踩的 §11-7：`grep -c . || echo 0` 在计数为 0 时会得到两行的
  `"0\n0"`，表现成"期望 0、实际 0，却判不相等"，而且**只在健康路径上发作**。

> **端到端仍然没覆盖破坏性 fio 真写盘**（验证 U 盘不被写穿）——
> 那两个确认提示出现的时刻不固定，盲发按键难以稳定命中。
> 详见 [`docs/architecture.md` §12](docs/architecture.md#十二测试地图)
> 和 [`docs/first-run-checklist.md`](docs/first-run-checklist.md) 第二节。

## 1.4.1

- **交付报告新增结构性快照断言**。原来的断言全是"某个字符串在不在"，
  而报告生成器 1100 行 Python 最危险的失效方式**不是文案写错，是整块塌掉**：
  一节没渲染、曲线画成空图、判定表少几行 —— 每条单看都还"有内容"，
  字符串断言一条都不会红，客户拿到的却是缺东西的报告。
  现在查骨架不查文案（三个一级章节、8 个硬件小节、
  **判定条数必须等于 results.jsonl 条数且逐状态对得上**、结论大字只能有一个、
  有采样数据就必须真画出 polyline）。锚点全部拿 QEMU 真跑出来的那份报告核对过。
- **修好上一版那个"只会红、不会挂"的守卫。** 1.4.0 给 7 个套件加的
  `command_not_found_handle` 有个致命缺陷：bash 在 fork 出的子进程里执行它，
  `FAIL=$((FAIL+1))` 加不到父进程头上 —— 屏幕上红一条，最后那行汇总却还是
  "失败 0 项"，**正好是本项目最恨的那种"屏幕全绿"**。
  （写结构性断言时打错函数名，当场被它抓住，也当场暴露了它自己。）
  现在直接 `kill -TERM $$` 中止套件，退出码非零。变异验证过：注入一个打错的
  函数名，退出码 143。
- 新增 [`docs/first-run-checklist.md`](docs/first-run-checklist.md)：
  QEMU 结构上盖不到的项（IPMI/BMC、阵列卡透传、真显卡、SMART 真增长、
  破坏性写盘、UEFI/Ventoy 引导）列清楚，每项写明看到什么才算过。
  **优先级最高的是阵列卡后端物理盘 —— v1.2.0 的主功能，一次真机都没验过。**
- **lint 新增 BOM / CRLF 检查**。源码在 Windows 编辑、WSL 构建、Linux 上跑，
  这两样都真会发生，而且都不会有像样的报错（CRLF 是
  `bad interpreter: ...bash^M`，BOM 会顶掉 shebang、被 source 时粘进第一个 token）。
  CRLF 那半边 `.gitattributes` 已经从源头钉住，**BOM 一直没人管** ——
  而 PowerShell 的 `Set-Content -Encoding UTF8`、`Out-File`、记事本另存为默认全加 BOM。
  （不是假想：这次拿 PowerShell 改一次 `config.sh` 的版本号就加上了，
  而那个文件是被 `source` 的。）两个方向都做了变异验证。
- 清掉 `out/` 里 8.4GB 陈旧 ISO（含 0.6.0/0.7.0/1.0.0 这些连 commit 都没有的版本）。
- 回归测试 361 → 372 项。

## 1.4.0

主要是补"我们怎么知道它是对的"，外加一条**由此发现的真判定 bug**。

### 软驱的 I/O error 不再判成硬件故障

QEMU 端到端第一次真跑起来，就在一台什么毛病都没有的"机器"上判出了 FAIL：

```
verify_dmesg_boot FAIL
  开机与硬件采集阶段内核日志出现 3 条硬件错误……
  I/O error, dev fd0, sector 0 op 0x0:(READ)
```

内核探测一个不存在/没插盘的软驱必然打这行，而硬件错误模式里有 `I/O error`。

**这不是虚拟机才有的事** —— BMC 虚拟媒体（iDRAC/iLO）挂了虚拟软驱、或者 BIOS
开了软驱模拟，真服务器上一样会打。也就是说这条一直存在，只是还没撞上：
撞上的那天，一台完全正常的服务器会被拦在出货前，理由写着「机器在上电初始化时
就有硬件异常」。正是二号原则最怕的那种误判。

现在 `dev fd[0-9]` 进噪声豁免。**豁免卡得很窄**，因为豁免扩大化比漏豁免更危险
（漏豁免误伤好机器，看得见；扩大化会把真盘的 I/O error 一起吃掉，坏盘从此
查不出来，而且没人会发现）。所以断言是成对的：fd0 放过，`sda`/`nvme0n1`/`vdb`/`sdak`
一个都不许放过；变异测试里也有一条专门把豁免改宽，必须被抓住。

> 单元测试永远造不出这个场景 —— 没人会想到往 dmesg 样本里塞一行软驱日志。
> 这就是为什么需要真的把盘跑起来。

**这一版没有其它判定逻辑改动。**

### 出好的盘会在 QEMU 里真开机跑一遍 —— `tests/e2e-qemu.sh`

在此之前，355 项断言全是单元级的：喂文件给纯函数、看它吐什么。**没有任何一条
验证过「插上去、开机、真的跑完、报告真的落到盘上」** —— 这中间任何一环断掉
（服务没起、数据分区没认出来、报告生成器在真环境里崩），单元测试一条都不会红，
现场却是空手而归。

`v0.4.0` 的 tag 里写着"已在 QEMU 里做过完整端到端验证"，但那是人工做的，
仓库里一行脚本都没留下。现在固化成两档：

```bash
sudo ./tests/e2e-qemu.sh                 # 冒烟，约 3 分钟
sudo ./tests/e2e-qemu.sh --stage full    # 完整 QUICK 档，约 20 分钟
```

做法：照着 Rufus 的 DD 模式把 ISO 拷成磁盘镜像、撑大、建第 4 个分区、
`mkfs.exfat -n KLBURN`，另挂两块空白盘当本机硬盘；按键走 QEMU monitor 的
`sendkey`（`klburn.service` 钉死在 tty1 上，串口读不到 UI），**所以不需要给产品
加任何"无人值守模式"，测的就是现场工程师按键盘那条路**；断言全部落在磁盘产物上。

顺带覆盖到了 `collect_disk` —— 21 个判定 id 里唯一一个单元测试碰不到的。

### 变异验证从人工活变成脚本 —— `tests/mutate.sh`

「一个从没红过的测试等于没写」一直是人工验一次就完了。现在是可重复的闸门：
把 7 条已修好的 bug 逐个塞回代码 → 跑对应套件 → **必须跑红** → 还原。

它上来就抓到一个真缺口：v1.3.0 修的 `NET_TIME_SERVERS` 裸赋值问题**没有任何
断言守着**，把代码改回去整套测试照样全绿。已补上（连标量覆盖一起测）。

脚本本身不碰 git，改文件前先备份、跑完立刻还原、trap 兜底，最后再逐个 `cmp`
校验还原结果。**不能挂进 `run-all.sh`** —— 它自己要调各个套件，挂进去就是递归。

### 其它

- **`SRC_ISO_SHA256` 填上了**。校验代码一直写着，但值是空的 → 永远跳过，
  等于 3.4GB 从镜像站拉下来完全不验（镜像同步到一半、断点续传接错、
  磁盘坏个扇区，都会安静地做出一张有问题的盘）。值取自 Ubuntu 官方
  `releases.ubuntu.com/24.04/SHA256SUMS`，本地缓存那份已核对一致。
  **换 `UBUNTU_POINT` 时必须同时换它。**
- `command_not_found_handle` 铺到全部 7 个测试套件（原来只有一个有）。
  断言函数名打错时会计一条失败，而不是往 stderr 打一行就没了。
- 回归测试 355 → 361 项，变异 8 条全部被抓住。

## 1.3.0

**整机结论不再靠文本匹配。** `factory-test.sh` 屏幕上那个 PASS/FAIL 大字，之前是
`grep -q '"status":"FAIL"' results.jsonl` 判出来的 —— 它依赖 `jq -cn` 的输出恰好
没有空格，输出格式一变就永远匹配不上，而且不会有任何报错，表现是**每台机器都显示
绿色 PASS**。现在改走 `jq` 解析，和报告生成器同一条路，两边不会打架。

> 这条正是 §11 一号不变量（不要拿关键字匹配当判定）自己没守住的地方。

**一条判定都没有，不再算作通过。** `results.jsonl` 为空 / 读不出来 / 解析不了
（采集阶段就崩了、U 盘写满了、进程被收掉），以前会走进"没有 FAIL"那一支 ——
**一台什么都没测过的机器，屏幕、交付报告、内部报告三处都显示合格。**
现在三处统一判 FAIL 并写明「本次测试未产生任何判定结果，本报告无效」。

> 措辞只说这轮没跑成、请重测，**不借用真 FAIL 那句「不建议出货」**：机器根本没被
> 评估过，我们没有任何依据说它不好。这是 [`docs/report-policy.md`](docs/report-policy.md)
> 的规矩，也有断言守着。

- `build/build-iso.sh`：兑现 overlayfs 删除标记那句 `rm -rf` 加了 `${rel:?}` 兜底。
  脚本以 root 跑，`rel` 万一算成空串，`rm -rf -- "$dst/"` 能把整个 rootfs 端掉。
- `lib/network.sh`：`NET_TIME_SERVERS` 改成"没定义过才给默认值"。它是数组、没有
  `: "${VAR:=默认}"` 那种写法，之前是裸赋值 —— 而 `klburn.conf` 在这个文件之前被
  source，现场想换内网 NTP 会被原样顶掉，且不会有任何报错。
- 新增 `tests/lint.sh`（shellcheck 静态检查），已挂进 `run-all.sh`。
  上面 `rm -rf` 那条就是它先指出来的。没装 shellcheck 就跳过，不影响出盘。
- `test-report-render.sh` 加了 `command_not_found_handle`：断言函数名打错时会计一条
  失败，而不是往 stderr 打一行 `command not found` 就没了（实测踩到过，
  屏幕照样"全部通过"，只是少数了几条）。
- 文档：新增本文件；`architecture.md` §7 补上 **klburn.conf 能覆盖的全部变量**
  （之前 13 个可调项里只写了 6 个）。
- 回归测试 334 → 355 项。

## 1.2.0

**阵列卡后面的物理盘也读 SMART。** RAID 模式下 `/dev/sdX` 是逻辑盘，物理盘根本不在
`/dev` 下，直接读 SMART 读到的是逻辑盘、没有任何属性 —— 于是「测前测后 SMART 对比」
这一项在带阵列卡的机器上**整项空跑**：报告写着 PASS，实际一块物理盘都没查过。
而那些盘恰恰是最可能坏的。

现在自动认出 `megaraid_sas`，用 `smartctl -d megaraid,N` 逐块透传读，型号 / 序列号 /
温度 / 坏道增长照常进报告和判定。设备号先从 sysfs 推，推不出来就有界试探。
采集目标统一收敛到 `SMART_TARGETS[]`，测前建立一次、测后原样复用。

**这条路不依赖 storcli64。** 没放厂商工具也照样有物理盘的健康数据。

## 1.1.0

- **交付报告与内部报告分家。** 新增 `raw/INTERNAL_<机器名>.html`：设备台账字段、
  逐颗 CPU 温差、光模块收发光功率、本次采集的缺口、源码 commit、raw/ 全文件索引。
  交付报告同步收紧成「只放参与判定或支撑判定的内容」，寿命类字段全部移出。
  规范落成 [`docs/report-policy.md`](docs/report-policy.md)。
- **显卡驱动版本不支持这张卡时判 SKIP，不再当成坏卡。** 判据是内核里 NVRM 自己
  打的原话。驱动明确说"这张卡我不支持"，那是我们盘里的驱动旧了，跟客户的卡无关。
- **测试时长从 3 档扩到 6 档**（QUICK / STANDARD / EXTENDED / LONG / SOAK / ENDURANCE）。
- **构建去掉分阶段流程**，显卡驱动改为按 `vendor/nvidia/` 里有没有东西自动决定；
  品牌抬头独立成 `config.sh` 顶部一整块，支持构建期环境变量覆盖。
- **修好一条形同虚设的文案守卫。** 它用 `grep -oE 'result_add [^\n]*'` 扫，而 grep
  逐行工作，**只看得到调用的第一行**，可所有长文案都写在反斜杠续行里 ——
  于是一句「本测试盘未包含」大摇大摆地进了客户报告。现在先拼续行再扫，并且加了一条
  "守卫必须抓得住违规文案"的自检断言。**一个从没红过的测试等于没写。**
- 新增 `tests/run-all.sh`；README 只讲怎么用，开发内容独立成
  [`docs/architecture.md`](docs/architecture.md)。

## 0.8.0

- **Ventoy 下报告落不到 U 盘，修复。** 原先的候选全靠 `blkid` 枚举，而 `blkid` 只扫
  `/dev` 下真实存在的节点；Ventoy 禁掉了 udev 规则，`/dev/mapper` 下只有 `control`，
  有时连 `/dev/dm-N` 都不会被创建 —— 唯一能挂的候选凭空消失，报告落 `/tmp`，
  关机就没了。现在多了第 0 层：直接读 `/sys/block/dm-*`，缺设备节点就按 sysfs 里的
  设备号 `mknod` 补建，再用 `blkid -p` 低层探测。
- **联网校时从未真正生效**，修复；新增网口协商速率达标校验（x16 的卡插 x8 槽那类问题）。
- **新增 PCIe 链路校验**（额定 vs 实际协商）。只查端点，不查 PCI bridge ——
  桥的 LnkSta 是与对端协商的结果，对端是张老卡就必然降速，那是设计如此。
- **新增开机内核日志检查**，并收紧硬件错误关键字：裸 `NMI` 会命中每台机器开机都有的
  三行正常日志，`EDAC.*(CE|UE)` 里的 "CE" 在 SOURCE/DEVICE/INTERFACE 里都有。
- **NVIDIA 驱动强制 open kernel module**（`-M=open` + `modinfo -F license` 复核）。
  proprietary 模块只支持到 Hopper，Blackwell 用它装完 `nvidia-smi` 一张卡都认不到 ——
  而那会被记成 FAIL「驱动加载失败」，把好卡判成坏卡。
- **gpu_burn 改静态链接。** `libcublas`/`libcudart` 来自 CUDA Toolkit，目标机器上没有，
  动态链接的版本一跑就是 `error while loading shared libraries`，然后被判成显卡故障。
  改用 `nvprune` 裁剪静态库再静态链接，330MB 出头的自包含二进制。
- **报告目录重名要避开，不能覆盖。** RTC 停摆的机器每次开机回退到完全相同的时间点，
  连测两次会得到一模一样的目录名，第二次直接把第一次盖掉。
- 阈值和 git commit hash 写进 `meta.json`；重做压测界面（逐颗 CPU、逐卡 GPU 实时读数）；
  回归测试新增 83 项断言。

## 0.4.0

第一阶段完成：一根 U 盘插上服务器，开机自动跑完整套出厂测试，
报告落到 U 盘里。硬件采集 + CPU/内存/GPU/硬盘压测 + 测后复查 + 中文 HTML 报告。

---

## git 之前

仓库是从 0.4.0 开始记的。在那之前（以及 0.5.0~0.7.0、0.9.0~1.0.0 这几个只在工作区
里存在过、没有单独提交的号）留下的教训，都写进了各自相关的文档里，这里只留索引：

| 版本 | 事 | 现在写在哪 |
|---|---|---|
| 0.3.0 | ISO 构建完之后又改了 `core.sh`/`collect.sh` 却没动版本号，现场那根盘自称 0.3.0、跑的却是修复前的代码，对着仓库怎么看都对不上。**「先 bump 再构建」这条规矩就是这么来的**，构建脚本也是从那之后开始钉 git commit hash 的 | [`build/config.sh`](build/config.sh) 顶部、[`docs/architecture.md` 版本与可追溯](docs/architecture.md#版本与可追溯) |
| 0.6.0 | CPU 温度阈值从 88/98 放宽到 95/100。服务器 CPU 满载 80 多度是常态，88 告警太灵敏，现场每台机器都刷黄 | [`docs/architecture.md` §7](docs/architecture.md#七阈值与现场覆盖) |
| 0.7.0 | 一台完全正常的机器，内存压测被 OOM killer 打死、退出码 137 被当成"测试进程异常退出"判了 FAIL，硬生生被拦在出货前。内存压测容量算法因此重做（先扣绝对余量再谈百分比），并立下**「把好机器拦在出货前，比漏判更糟」** | [`docs/architecture.md` §2](docs/architecture.md#二四条核心原则)、[`docs/report-policy.md`](docs/report-policy.md) |

> 早期用 `grep -q '关键字'` 判压测日志、把每一台好机器都判成 FAIL 的那次，
> 也在这个阶段。它现在是 [§11 的一号不变量](docs/architecture.md#十一不变量清单改代码前必读)。
