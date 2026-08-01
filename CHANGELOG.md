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

已有：`v0.4.0` `v0.8.0` `v1.1.0` `v1.2.0`。中间的 0.5~0.7、0.9~1.0 没有 tag ——
那几个号只在工作区里存在过，从来没有单独提交，见文末「git 之前」。

---

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
