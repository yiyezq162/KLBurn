# CLAUDE.md

给 Claude Code 的项目备忘。人看的文档在 [`README.md`](README.md)（怎么用）、
[`docs/architecture.md`](docs/architecture.md)（怎么改）和
[`CHANGELOG.md`](CHANGELOG.md)（哪个版本改了什么）。

> **不要往仓库里写「待办 / 下一步计划 / TODO」类的文件。** 这类文件很快过期，
> 而且和 CHANGELOG、architecture 里的内容互相打架。计划直接在对话里讲给用户，
> 让他自己决定记在哪。仓库里只留**当前事实**：代码、不变量、版本记录、
> 以及真机检查清单那种操作时照着过的东西。

## 这是什么

服务器出厂老化测试 U 盘。源码在 Windows 上编辑、在 **WSL（Ubuntu-24.04）里构建**、
产物是一个能自启动的 ISO，最终跑在被测服务器上。

## 构建 ISO —— **自己构建，别丢给用户**

这台机器上构建 ISO 是**你能做也应该做**的事：WSL 装好了、源 ISO（3.4GB）已缓存、
`/home` 还有 900G+。不要把 `sudo ./build/build-iso.sh` 当成"请用户去跑"的东西
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
- 带显卡驱动是**自动**的：`vendor/nvidia/*.run` 在就带上。
  `--without-nvidia` 强制不带，`--with-nvidia` 强制带（缺驱动会直接报错）
- 构建第一步会强制校验源 ISO 的 sha256（`config.sh` 里钉着官方值），
  每次构建都跑，没有 stamp 跳过

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

构建完还要跑一条固件对账（几秒，不要 root，查的是构建工作区里的 rootfs）：

```
wsl -d Ubuntu-24.04 -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && KLBURN_WORK=/home/li/klburn-build ./tests/check-firmware.sh"
```

它守的是「盘里关键驱动要的固件一个都不能少」。少了不会有任何报错 ——
驱动起不来，`ip link` 里那块网卡就是不存在，报告写着这台机器没网卡。
它也不在 `run-all.sh` 里（要一个已构建的 rootfs）。

发货前那一遍还要加上「fio 真写盘」这条（约 20 分钟，验的是 U 盘不被写穿）：

```
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/e2e-qemu.sh --stage full --disk-stress --workdir /home/li/klburn-e2e-ds"
```

`e2e-qemu.sh` 要 root（losetup / 挂 exFAT / KVM）。它会**断言盘里的版本号和
`config.sh` 一致** —— 所以 bump 完版本必须先重新构建再跑 e2e，否则它会红在
"版本对不上"。那不是 bug，那正是它要拦的事（改完代码拿旧 ISO 跑）。

排查 e2e 时一定加 `--workdir /home/li/某个目录`：默认落 `mktemp -d`，
而 **WSL 的 `/tmp` 跨 `wsl -e` 调用不保留**，`--keep` 也留不住，
截图和镜像下一条命令就没了。

## 从 Windows 调 WSL 的几个坑（都实际踩过）

1. **用 PowerShell 工具，别用 Bash 工具跑 `wsl ... /mnt/c/...`。**
   Git Bash 会把 `/mnt/c/...` 重写成 `C:/Program Files/Git/mnt/c/...`，
   脚本直接找不到。
2. **命令一复杂就先把脚本写进 scratchpad 再执行**，别在命令行上硬拼引号 ——
   嵌套引号被吃掉之后，报错信息会指向完全不相干的地方，很难查。
3. **绝不要用 PowerShell 的 `Set-Content`/`Out-File` 改仓库里的文件** ——
   `-Encoding UTF8` 默认加 BOM，而 `config.sh` 这类文件是被 `source` 的，
   BOM 会顶掉 shebang。改文件一律用 Edit/Write 工具。
   （`tests/lint.sh` 现在有 BOM/CRLF 守卫，但别指望它兜底。）
4. **脚本正在跑的时候不要编辑它。** bash 是边读边执行的，改了会错位。
5. 读后台任务的输出文件用 `-Encoding UTF8`，否则中文是乱码。

## 改完代码必做

1. **先 bump `build/config.sh` 里的 `KLBURN_VERSION` 再构建**（先 bump 再构建，
   0.3.0 栽过：盘自称一个版本、跑的是另一版代码），同时在
   [`CHANGELOG.md`](CHANGELOG.md) 顶上加一节 —— 客户报告里只有版本号，
   查不到那个版本干了什么就等于没有可追溯性
2. `./tests/run-all.sh` 全绿（里面已经包含 `lint.sh` 的 shellcheck）
3. 改了会进客户报告的文案 → 一定跑 `test-hw-checks.sh` + `test-report-render.sh`
4. 改了**判定逻辑或守卫** → 再跑 `./tests/mutate.sh`（把修好的 bug 塞回去，
   守卫必须跑红；逃掉 = 那条守卫是摆设）。它不在 `run-all.sh` 里，
   也**不能**放进去 —— 它自己要调各个套件，挂进去就是递归
5. **改了会进盘里的代码（`rootfs/**`、`build/**`）→ 自己重新构建，然后跑
   `e2e-qemu.sh` 冒烟**（约 3 分钟）。软驱那条误判就是它跑出来的，
   单元测试造不出来那个场景。发货前再跑一次 `--stage full`（约 20 分钟）
6. 全绿之后**主动汇报结果**（构建版本、断言数、e2e 结果），
   而不是丢一条命令让用户自己去跑一遍确认

## 三条最容易踩的红线

1. **交付报告（与报告目录同名的 `.html`）只放参与判定的内容**：不出现内部实现细节
   （盘里带了什么工具、构建目录、源码版本），也不列不参与判定的寿命类字段。
   具体禁词表在 `tests/test-hw-checks.sh` 的 `FORBIDDEN` 里，规范见
   [`docs/report-policy.md`](docs/report-policy.md)。
   内部报告 `raw/INTERNAL_*.html` 不受此限，那份不交付。
2. **能力缺失 ≠ 硬件故障。** 盘里少带工具、驱动版本不支持客户的新卡、现场没接网线 ——
   一律 SKIP 并写「此项不影响整机结论」，绝不判 FAIL。
   把好机器拦在出货前，比漏判更糟。
3. **不要用 `grep -q '关键字'` 判压测日志。** 那些工具正常跑完的日志里本来就带
   `errors: 0`、`failed: 0` 字样，关键字匹配会把每一台好机器都判 FAIL。

更多不变量（bash 陷阱、界面刷新、CSV 列顺序等）见
[`docs/architecture.md` 第十一节](docs/architecture.md#十一不变量清单改代码前必读)，
那一节的每一条都对应一次真实翻车，改到相关代码前先读。
