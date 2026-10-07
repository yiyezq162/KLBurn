# AGENTS.md

给 Codex 的项目备忘。**人看的文档在 [`README.md`](README.md)**，
它是入口索引，按读者分到 `docs/` 下的各份。

> **不要往仓库里写「待办 / 下一步计划 / TODO」类的文件。** 这类文件很快过期，
> 而且和 CHANGELOG、architecture 里的内容互相打架。计划直接在对话里讲给用户，
> 让他自己决定记在哪。仓库里只留**当前事实**：代码、不变量、版本记录、
> 以及真机检查清单那种操作时照着过的东西。

## 这是什么

服务器出厂老化测试 U 盘。源码可在 **macOS、Windows 或 Linux** 上编辑；
**构建与完整测试在 x86_64 Ubuntu 24.04 上执行**，产物是自启动 ISO，最终跑在被测服务器上。
WSL 只是 Windows 下的一种 Linux 环境，不是项目必须使用的平台。

## 开发环境：先确认当前主机

- Mac mini M4 是 Apple Silicon（arm64）开发机，可以编辑、提交代码和查看报告。
  现有 ISO 是 amd64；构建、完整回归、变异测试和 QEMU 验收交给 x86_64 Ubuntu。
- Linux 可以是物理机、局域网虚拟机或 Windows 的 WSL。普通 Ubuntu 无需 WSL。
- 先检查当前主机、SSH 连接、权限和工具；不要假定已装 WSL、已有缓存或剩余空间。
  已有源码 CI 和专用 `nas-ci-klburn`，标签 `self-hosted, Linux, X64, nas-klburn`；先读 `docs/CI.md`。ISO 专用后端是 NAS `KLBurn-BuildVM`，不是 Docker Runner；普通开发不重注册，不在 NAS 宿主机/普通 Runner 内执行挂载、loop 或 KVM 构建。
- 下文 Bash 命令都在 Linux 执行。Mac 可通过已配置的 SSH 连接执行，复杂操作先写成
  Linux 端临时脚本。Windows 只有在使用 WSL 时才需要 PowerShell → WSL 包装。
- 文本用 UTF-8 无 BOM、LF；`.gitattributes` 已固定换行。入口脚本的执行权限由 Git 保存。
- 仅修改文档或修复仓库入口脚本的 Git 执行权限，不改变盘内行为时，不 bump ISO 版本、
  不为此构建 ISO 或打发布 tag。进入盘内的代码修改继续遵守下面的完整发布顺序。
- `vendor/`、`out/`、`test_out/` 不进 Git；换开发机时需另行迁移离线包和必要真机样本。
  不要为方便迁移把客户原始报告提交进仓库。详见 [`docs/building.md`](docs/building.md)。

1.9.5 起开机先选**测试范围**（全量 / CPU / 内存 / 显卡 / 硬盘 / 仅导出报告），
再选时长。范围之外的项目**整项不跑、也不产生结论行**。

**1.10.0 起同一份源码出两种盘**（`--edition full|mem`，构建时钉死）：
`mem` 是**内存专用盘** —— 开机不问任何东西、约三分钟、只读内存明细 + 压一遍内存，
硬盘/阵列卡/显卡/电源/BMC/PCIe 完全不碰，网卡只用来校时。
判定口径也窄一格：**只有内存坏才 FAIL**，坏网卡坏阵列卡不影响结论；
外加一条查假条子的 —— **序列号重复判 FAIL**（那批假内存压测都能过，只有序列号露馅）。
说明见 [`docs/mem-edition.md`](docs/mem-edition.md)，主流程是
`rootfs/opt/klburn/memtest.sh`（不是 `factory-test.sh`）。

**发布必须成对**：普通整机测试版（full）每次出盘，都同时构建、验收同版本的
内存专用版（mem），两张盘对应同一个干净 commit、同一个 annotated tag。
整机版菜单里的「内存专项」仍属于 full，不是第三种 ISO。
mem 只安装内存采集/SPD、内存压测/ECC、中文报告、USB 落盘和联网校时所需组件；
不带 NVIDIA/CUDA、显卡压测/诊断、CPU 性能基准或硬盘/阵列卡/BMC 检测工具。
保留 CPU 微码和显示、网卡、USB、存储启动所需内核驱动/固件，不能以瘦身破坏启动与报告落盘。
full ↔ mem 切换时重建 rootfs，保留源 ISO 缓存；必须核对无跨 edition 工具残留。
后续不以精简 ISO 体积为工作目标或发布门槛；保留已实现的 edition 工具边界。
内存升级尚未完成时仍按实际可用资源串行构建、验收，不能假定已有新增内存。

## 文档去哪儿找

| 要查什么 | 看哪份 |
|---|---|
| **内存专用盘**（第二种盘） | [`docs/mem-edition.md`](docs/mem-edition.md) |
| 判定口径、模块地图、**不变量清单** | [`docs/architecture.md`](docs/architecture.md) |
| 哪些内容不能进交付报告 | [`docs/report-policy.md`](docs/report-policy.md) |
| 输出了哪些文件、六个范围各长什么样 | [`docs/reports.md`](docs/reports.md) |
| 盘里封了哪些工具、缺了会怎样 | [`docs/toolbox.md`](docs/toolbox.md) |
| 构建参数、发布顺序 | [`docs/building.md`](docs/building.md) |
| 现场每一屏长什么样 | [`docs/operating.md`](docs/operating.md) |

**改了行为就要同步改文档。** 改判定 → architecture §6；改报告内容 →
report-policy + reports.md；加/换工具 → toolbox.md + vendor/README.md。

## 构建 ISO —— **自己构建，别丢给用户**

代码修改需要出盘时，优先使用已经配置好的 Linux 构建环境，自己构建、自己验，
然后汇报结果。环境尚未连接时，说明实际缺什么；不要声称已经构建或测试。

**要 root，而且必须显式指定 `KLBURN_WORK`** —— sudo/root 的 `$HOME` 可能是
`/root`，工作区换位置就会失去已有缓存。以下在 Linux 源码目录执行：

```bash
sudo KLBURN_WORK="$HOME/klburn-build" ./build/build-iso.sh
sudo KLBURN_WORK="$HOME/klburn-build" ./build/build-iso.sh --edition mem
```

这里的 `$HOME` 由调用 sudo 的普通用户 shell 展开。以 root 登录时，应显式填入实际
构建工作区的绝对路径。长任务要用后台任务或持续会话，并保存日志，避免 SSH 断开中断。

共用工作区是安全的，但理由要说清楚：`klburn.service` 在 `rootfs/` 覆盖层里，
`chroot-setup.sh` 每次构建都先 `cp -a "$STAGE/overlay/." /` 把它**原样铺回来**
（`ExecStart=…/factory-test.sh`），之后才按 edition 决定改不改。
所以 mem 盘构建完再构建 full 盘，ExecStart 会自己回到 factory-test.sh。
**顺序反过来就会出错**，别把那个 `cp -a` 挪到 sed 后面去。

- 工作区（含源 ISO 缓存）：构建机本地 Linux 文件系统上的固定目录；两种 edition 串行构建
- 成对构建与验收入口：`sudo KLBURN_WORK=/实际工作区 ./build/release.sh --mutate`。
  先完成源码测试和提交；入口拒绝脏源码/已有版本 tag，串行构建与验收两版后才打 tag。
- 首次约 10~15 分钟，增量约 5~8 分钟；产物自动拷回项目的 `out/`
- 其余参数见 [`docs/building.md`](docs/building.md)

**构建要串一串事的时候（构建 + 跑 e2e + 收结果），把整串写成一个 `.sh` 放进
scratchpad，再一次性挂后台执行。** 别拆成好几轮前台命令。

## 跑测试

在 x86_64 Ubuntu 的 Bash 里跑。macOS 自带 Bash/BSD 工具和 Git Bash 不作为完整回归环境：

```
./tests/run-all.sh
```

要 root 的两个（`run-all.sh` 在非 root 下自动跳过第一个，第二个本来就不在里面）：

```
sudo ./tests/test-disk-exclusion.sh
sudo ./tests/e2e-qemu.sh --stage smoke --workdir "$HOME/klburn-e2e-smoke"
```

构建完还要跑一条对账（几秒，不要 root，查的是构建工作区里的 rootfs）：

```
KLBURN_WORK="$HOME/klburn-build" ./tests/check-firmware.sh
```

它守两件事：**关键驱动要的固件一个都不能少**，**`tools/bench/` 下每个程序的依赖库
一个都不能少**。少了都不会有任何报错 —— 驱动起不来，`ip link` 里那块网卡就是不存在，
报告写着这台机器没网卡；或者程序在盘里却一跑就找不到动态库，现场表现是
"这一项莫名其妙 SKIP"。它不在 `run-all.sh` 里（要一个已构建的 rootfs）。

发货前那一遍还要加上「fio 真写盘」这条（约 20 分钟，验的是 U 盘不被写穿）：

```
sudo ./tests/e2e-qemu.sh --stage full --disk-stress --workdir "$HOME/klburn-e2e-ds"
```

`e2e-qemu.sh` 要 root（losetup / 挂 exFAT / KVM）。它会**断言盘里的版本号和
`config.sh` 一致** —— 所以 bump 完版本必须先重新构建再跑 e2e，否则它会红在
"版本对不上"。那不是 bug，那正是它要拦的事（改完代码拿旧 ISO 跑）。
验新的范围菜单用 `--scope info`（冒烟档最快）。
**内存专用盘要单走一条**（那张盘开机不问任何东西，发任何一键都会飘到收尾菜单）：

```
sudo ./tests/e2e-qemu.sh --edition mem --stage smoke --workdir "$HOME/klburn-e2e-mem"
```

它整轮只有三分钟，所以冒烟档就一路验到报告本体（三份交付物 + 没混进
内存以外的判定项 + 那句「本报告仅针对内存」）。

排查 e2e 时一定加 `--workdir`，指定构建机本地持久目录；需要保留结果再加 `--keep`。
默认临时目录可能被清理；旧 WSL 环境还踩过 `/tmp` 跨调用不保留的问题。
虚拟机跑 QEMU 应开放嵌套虚拟化并确认 `/dev/kvm` 可用，否则会退回很慢的软件模拟。

**`mutate.sh` 1.9.5 起跑在源码副本里、默认并行**（105 条约 3 分半）：
真工作区只读，所以跑的时候**可以**看 `git diff`、可以提交。
但**别改源码** —— 它开跑前给整棵树留了指纹，跑完比对。
看结果先看**基线自检**那一段：干净副本里各套件必须全绿，不绿就整轮作废
（那时候每条变异都会显示"被抓住"，而那个绿是假的）。

## Windows 使用 WSL 时的专属注意事项

**仅在 Windows + WSL 环境适用。macOS / 普通 Linux 不套用这些命令包装。**
路径和发行版名称必须按当前主机确认，不复用旧电脑的用户名。

1. **用 PowerShell 工具，别用 Bash 工具跑 `wsl ... /mnt/c/...`。**
   Git Bash 会把 `/mnt/c/...` 重写成 `C:/Program Files/Git/mnt/c/...`，
   脚本直接找不到。
2. **命令一复杂就先把脚本写进 scratchpad 再执行**，别在命令行上硬拼引号 ——
   嵌套引号被吃掉之后，报错信息会指向完全不相干的地方，很难查。
   PowerShell 还会把 `$(nproc)`、`$?` 这类先展开掉。
3. **绝不要用 PowerShell 的 `Set-Content`/`Out-File` 改仓库里的文件** ——
   `-Encoding UTF8` 默认加 BOM，而 `config.sh` 这类文件是被 `source` 的，
   BOM 会顶掉 shebang。改文件一律用 Edit/Write 工具。
   （`tests/lint.sh` 现在有 BOM/CRLF 守卫，但别指望它兜底。）
4. **脚本正在跑的时候不要编辑它。** bash 是边读边执行的，改了会错位。
5. 读后台任务的输出文件用 `-Encoding UTF8`，否则中文是乱码。
6. **loop 设备的分区节点不是 `losetup -P` 一返回就有的**，要等一下再 mount，
   否则 `special device /dev/loopXp4 does not exist`。

## 改完代码必做

1. **先 bump `build/config.sh` 里的 `KLBURN_VERSION` 再构建**（0.3.0 栽过：
   盘自称一个版本、跑的是另一版代码），同时在 [`CHANGELOG.md`](CHANGELOG.md)
   顶上加一节 —— 客户报告里只有版本号，查不到那个版本干了什么就等于没有可追溯性
2. `./tests/run-all.sh` 全绿（里面已经包含 `lint.sh` 的 shellcheck）
3. 改了会进客户报告的文案 → 一定跑 `test-hw-checks.sh` + `test-report-render.sh`
4. 改了**判定逻辑或守卫** → 再跑 `./tests/mutate.sh`。它不在 `run-all.sh` 里，
   也**不能**放进去 —— 它自己要调各个套件，挂进去就是递归
5. **改了会进盘里的代码（`rootfs/**`、`build/**`）→ 自己重新构建，然后跑
   `e2e-qemu.sh` 冒烟**（约 3 分钟）。软驱那条误判就是它跑出来的，
   单元测试造不出来那个场景。发货前再跑一次 `--stage full`（约 20 分钟）
6. **改了现场界面（`lib/ui.sh`）→ 跑 `--stage full` 并且真的去看截图**
   （`shot-*.ppm`，用 `pnmtopng` 转一下再看）。1.7.2/1.7.3 有七个问题是
   **只有看图才发现的**，当时断言全绿。**"断言全绿"和"这屏能看"是两回事。**

   > ⚠️ 那张压测仪表盘的截图是**等日志锚点**截的，不是死等 N 秒。1.9.5 之前是
   > `sleep 240`，OpenDCDiag 进盘之后 PHASE 2 长了两分钟，那张截到的就不再是
   > 仪表盘了 —— **而所有断言照样全绿**，因为没有任何断言在看那张图。
7. **改了行为就同步改文档**（见上面那张表）
8. 全绿之后**主动汇报结果**（构建版本、断言数、e2e 结果），
   而不是丢一条命令让用户自己去跑一遍确认

## 提交与打 tag —— **默认动作，不用问**

> **每构建一版，就提交一次、打一个 tag。**不管有没有拿去真机测过。
> 这是**默认行为，不需要征求同意**（用户 2026-08-10 明确交代）。
> 理由很简单：报告上只有版本号和 commit hash，漏一次就断一环，
> 半年后拿着一份报告回来查，查不到那版代码长什么样。

**顺序是死的，别自己改：**

```
1. bump build/config.sh 的 KLBURN_VERSION + 写 CHANGELOG
2. ./tests/run-all.sh 全绿（判定逻辑动了再加 mutate.sh）
3. git commit          ← 必须在构建之前，工作区要干净
4. 构建 ISO             ← 这时 klburn.conf 里记的才是干净的 commit hash
5. check-firmware.sh + e2e-qemu.sh 冒烟
   两个 edition 都验；full 加完整真写盘验收，mem 核对精简工具与报告三件套
6. git tag -a v<版本>   ← 两版都通过后，打在第 3 步那个 commit 上
```

⚠️⚠️ **第 3 步必须排在第 4 步之前，这一条栽过。**
构建脚本会把 `git rev-parse --short HEAD` 和"工作区脏不脏"一起钉进
盘里的 `klburn.conf`。**先构建后提交的话，盘里记的是上一版的 hash 加一个
`-dirty`**（1.9.4 第一次构建就是 `GIT_COMMIT="59f289e-dirty"`，而 59f289e 是
v1.9.3）。这时候再打 tag，tag 指向的 commit 和盘里写的对不上 ——
拿着报告查代码的那条链就断了，而且**不会有任何报错**。

构建完记得核一眼，`GIT_COMMIT` **不许带 `-dirty`**（先将 `KLBURN_WORK` 设为实际工作区）：

```
grep -E 'KLBURN_VERSION|GIT_COMMIT' "$KLBURN_WORK/rootfs/opt/klburn/klburn.conf"
```

tag 用 annotated（`-a`），说明里写清楚那一版干了什么、断言数多少：

```bash
git tag -a v1.9.5 -m "1.9.5：单项专测（六个入口）、OpenDCDiag 进盘、算力换全平台通用量法；run-all 1472 项、mutate 105 条"
```

已发布的 tag 清单在 [`CHANGELOG.md`](CHANGELOG.md) 顶上维护着，打完 tag 顺手补进去。
（`v1.9.1` 没有 tag —— 那次就是"bump 完没马上提交"，留在 CHANGELOG 里当反面教材。）

## 四条最容易踩的红线

1. **交付报告（与报告目录同名的 `.html`）只放参与判定的内容**：不出现内部实现细节
   （盘里带了什么工具、构建目录、源码版本），也不列不参与判定的寿命类字段。
   禁词表在 `tests/test-hw-checks.sh` 的 `FORBIDDEN` 里，规范见
   [`docs/report-policy.md`](docs/report-policy.md)。
   内部报告 `raw/INTERNAL_*.html` 不受此限，那份不交付。
2. **能力缺失 ≠ 硬件故障。** 盘里少带工具、驱动版本不支持客户的新卡、现场没接网线 ——
   一律 SKIP 并写「此项不影响整机结论」，绝不判 FAIL。
   把好机器拦在出货前，比漏判更糟。
3. **不要用 `grep -q '关键字'` 判压测日志。** 那些工具正常跑完的日志里本来就带
   `errors: 0`、`failed: 0` 字样，关键字匹配会把每一台好机器都判 FAIL。
4. **性能数字只报不判 —— 代码里不许有任何"阈值 / 门槛 / 参考值 / 预期值"。**
   这张盘插上就跑、无人值守，现场没有人、也没有地方去填"这台机器该达到多少"；
   凭空写一个数进来，等于我们替客户定了一个他没定过的标准。
   `lib/bench.sh` 那几项只有 **PASS（量到了）和 SKIP（量不到），没有 WARN/FAIL**。
   平台设置（x2APIC / VT-d / SNC / 板载网口）同理：如实读出来写清楚就完事。
   配置一致性不符判 WARN（配置问题，不是硬件坏了）。
   **整机结论只回答一件事：硬件有没有毛病。**
   （1.9.0 一度做过一整套阈值，全删了 —— 别再长回来，测试里有断言钉着。）

**范围功能另有一条同级红线**（1.9.5）：**单项专测的报告绝不能看起来像"这台机器
全测过了"。** 抬头写明范围、结论下面说清哪些没测、目录名带后缀、
「仅导出报告」那一档不出 PASS 大字、批次汇总里写成 `PASS(CPU)`。
四处缺一不可，`mutate.sh` 里各有一条变异钉着。

更多不变量（bash 陷阱、界面刷新、CSV 列顺序等）见
[`docs/architecture.md` 第十一节](docs/architecture.md#十一不变量清单改代码前必读)，
那一节的每一条都对应一次真实翻车，改到相关代码前先读。
**要动 `lib/ui.sh` 的话，先读[第十三节](docs/architecture.md#十三现场界面是怎么画出来的)** ——
那块的分层（渲染是纯函数、颜色只在边框层、每帧先数行数再画）不是风格，
是"整屏重绘不错位"的前提。
