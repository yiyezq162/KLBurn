# CLAUDE.md

给 Claude Code 的项目备忘。人看的文档在 [`README.md`](README.md)（怎么用）、
[`docs/architecture.md`](docs/architecture.md)（怎么改）和
[`CHANGELOG.md`](CHANGELOG.md)（哪个版本改了什么）。

## 这是什么

服务器出厂老化测试 U 盘。源码在 Windows 上编辑、在 **WSL（Ubuntu-24.04）里构建**、
产物是一个能自启动的 ISO，最终跑在被测服务器上。

## 跑测试

在 WSL 里跑，不要在 Git Bash 里跑（Git Bash 的 sed/awk 在多字节场景下行为和目标环境不同）：

```bash
wsl -d Ubuntu-24.04 -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/run-all.sh"
```

`tests/test-disk-exclusion.sh` 需要 root，`run-all.sh` 在非 root 下会自动跳过它。
改了 `lib/storage.sh` 就单独补一次：

```bash
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && ./tests/test-disk-exclusion.sh"
```

## 构建 ISO

**要 root，而且必须显式指定 `KLBURN_WORK`** —— 以 root 身份进 WSL 时 `$HOME` 是
`/root`，不指定的话工作区会跑到 `/root/klburn-build`，那 3GB 的源 ISO 缓存就白下了：

```bash
wsl -d Ubuntu-24.04 -u root -e bash -c "cd /mnt/c/Users/li/Desktop/project/KLBurn && KLBURN_WORK=/home/li/klburn-build ./build/build-iso.sh"
```

- 工作区（含已下载的源 ISO 缓存）：`/home/li/klburn-build`
- 首次约 10~15 分钟，增量约 5~8 分钟；产物自动拷回项目的 `out/`
- 带显卡驱动是**自动**的：`vendor/nvidia/*.run` 在就带上。
  `--without-nvidia` 强制不带，`--with-nvidia` 强制带（缺驱动会直接报错）

从 PowerShell 调 `wsl -e bash -c "..."` 时引号很容易被吃掉。命令一复杂就先把脚本
写到文件里再执行，别在命令行上硬拼。

## 改完代码必做

1. **先 bump `build/config.sh` 里的 `KLBURN_VERSION` 再构建**（先 bump 再构建，
   0.3.0 栽过：盘自称一个版本、跑的是另一版代码），同时在
   [`CHANGELOG.md`](CHANGELOG.md) 顶上加一节 —— 客户报告里只有版本号，
   查不到那个版本干了什么就等于没有可追溯性
2. `./tests/run-all.sh` 全绿（里面已经包含 `lint.sh` 的 shellcheck）
3. 改了会进客户报告的文案 → 一定跑 `test-hw-checks.sh` + `test-report-render.sh`

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
