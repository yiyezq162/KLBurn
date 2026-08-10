# CLAUDE.md

给 Claude Code 的项目备忘。**人看的文档在 [`README.md`](README.md)**，
它是入口索引，按读者分到 `docs/` 下的各份。

> **不要往仓库里写「待办 / 下一步计划 / TODO」类的文件。** 这类文件很快过期，
> 而且和 CHANGELOG、architecture 里的内容互相打架。计划直接在对话里讲给用户，
> 让他自己决定记在哪。仓库里只留**当前事实**：代码、不变量、版本记录、
> 以及真机检查清单那种操作时照着过的东西。

## 这是什么

服务器出厂老化测试 U 盘。源码在 Windows 上编辑、在 **WSL（Ubuntu-24.04）里构建**、
产物是一个能自启动的 ISO，最终跑在被测服务器上。

1.9.5 起开机先选**测试范围**（全量 / CPU / 内存 / 显卡 / 硬盘 / 仅导出报告），
再选时长。范围之外的项目**整项不跑、也不产生结论行**。

## 文档去哪儿找

| 要查什么 | 看哪份 |
|---|---|
| 判定口径、模块地图、**不变量清单** | [`docs/architecture.md`](docs/architecture.md) |
| 哪些内容不能进交付报告 | [`docs/report-policy.md`](docs/report-policy.md) |
| 输出了哪些文件、六个范围各长什么样 | [`docs/reports.md`](docs/reports.md) |
| 盘里封了哪些工具、缺了会怎样 | [`docs/toolbox.md`](docs/toolbox.md) |
| 构建参数、发布顺序 | [`docs/building.md`](docs/building.md) |
| 现场每一屏长什么样 | [`docs/operating.md`](docs/operating.md) |

**改了行为就要同步改文档。** 改判定 → architecture §6；改报告内容 →
report-policy + reports.md；加/换工具 → toolbox.md + vendor/README.md。

## 构建 ISO —— **自己构建，别丢给用户**

这台机器上构建 ISO 是**你能做也应该做**的事：WSL 装好了、源 ISO（3.4GB）已缓存、
`/home` 还有 800G+。不要把 `sudo ./build/build-iso.sh` 当成"请用户去跑"的东西
甩回去 —— 改完代码就自己构建、自己验，然后把结果告诉用户。

**要 root，而且必须显式指定 `KLBURN_WORK`** —— 以 root 身份进 WSL 时 `$HOME` 是
`/root`，不指定的话工作区会跑到 `/root/klburn-build`，那 3GB 的源 ISO 缓存就白下了。

用 **PowerShell 工具**（不是 Bash 工具，理由见下面「调 WSL 的坑」），
并且**挂后台**（增量也要 5~8 分钟，前台会一直卡住）：

```
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && KLBURN_WORK=/home/li/klburn-build ./build/build-iso.sh"
```

- 工作区（含已下载的源 ISO 缓存）：`/home/li/klburn-build`
- 首次约 10~15 分钟，增量约 5~8 分钟；产物自动拷回项目的 `out/`
- 其余参数见 [`docs/building.md`](docs/building.md)

**构建要串一串事的时候（构建 + 跑 e2e + 收结果），把整串写成一个 `.sh` 放进
scratchpad，再一次性挂后台执行。** 别拆成好几轮前台命令。

## 跑测试

在 WSL 里跑，不要在 Git Bash 里跑（Git Bash 的 sed/awk 在多字节场景下行为和目标环境不同）：

```
wsl -d Ubuntu-24.04 -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/run-all.sh"
```

要 root 的两个（`run-all.sh` 在非 root 下自动跳过第一个，第二个本来就不在里面）：

```
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/test-disk-exclusion.sh"
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/e2e-qemu.sh --stage smoke"
```

构建完还要跑一条对账（几秒，不要 root，查的是构建工作区里的 rootfs）：

```
wsl -d Ubuntu-24.04 -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && KLBURN_WORK=/home/li/klburn-build ./tests/check-firmware.sh"
```

它守两件事：**关键驱动要的固件一个都不能少**，**`tools/bench/` 下每个程序的依赖库
一个都不能少**。少了都不会有任何报错 —— 驱动起不来，`ip link` 里那块网卡就是不存在，
报告写着这台机器没网卡；或者程序在盘里却一跑就找不到动态库，现场表现是
"这一项莫名其妙 SKIP"。它不在 `run-all.sh` 里（要一个已构建的 rootfs）。

发货前那一遍还要加上「fio 真写盘」这条（约 20 分钟，验的是 U 盘不被写穿）：

```
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/e2e-qemu.sh --stage full --disk-stress --workdir /home/li/klburn-e2e-ds"
```

`e2e-qemu.sh` 要 root（losetup / 挂 exFAT / KVM）。它会**断言盘里的版本号和
`config.sh` 一致** —— 所以 bump 完版本必须先重新构建再跑 e2e，否则它会红在
"版本对不上"。那不是 bug，那正是它要拦的事（改完代码拿旧 ISO 跑）。
验新的范围菜单用 `--scope info`（冒烟档最快）。

排查 e2e 时一定加 `--workdir /home/li/某个目录`：默认落 `mktemp -d`，
而 **WSL 的 `/tmp` 跨 `wsl -e` 调用不保留**，`--keep` 也留不住，
截图和镜像下一条命令就没了。

**`mutate.sh` 1.9.5 起跑在源码副本里、默认并行**（105 条约 3 分半）：
真工作区只读，所以跑的时候**可以**看 `git diff`、可以提交。
但**别改源码** —— 它开跑前给整棵树留了指纹，跑完比对。
看结果先看**基线自检**那一段：干净副本里各套件必须全绿，不绿就整轮作废
（那时候每条变异都会显示"被抓住"，而那个绿是假的）。

## 从 Windows 调 WSL 的几个坑（都实际踩过）

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
6. git tag -a v<版本>   ← 打在第 3 步那个 commit 上
```

⚠️⚠️ **第 3 步必须排在第 4 步之前，这一条栽过。**
构建脚本会把 `git rev-parse --short HEAD` 和"工作区脏不脏"一起钉进
盘里的 `klburn.conf`。**先构建后提交的话，盘里记的是上一版的 hash 加一个
`-dirty`**（1.9.4 第一次构建就是 `GIT_COMMIT="59f289e-dirty"`，而 59f289e 是
v1.9.3）。这时候再打 tag，tag 指向的 commit 和盘里写的对不上 ——
拿着报告查代码的那条链就断了，而且**不会有任何报错**。

构建完记得核一眼，`GIT_COMMIT` **不许带 `-dirty`**：

```
wsl -d Ubuntu-24.04 -e bash -c "grep -E 'KLBURN_VERSION|GIT_COMMIT' /home/li/klburn-build/rootfs/opt/klburn/klburn.conf"
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
