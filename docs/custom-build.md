# 定制名称与自动构建

工具入口位于 `tools/customize/`。工具仅使用 Python 标准库，不安装虚拟机、
不调整网络、不写物理磁盘、不推送 Git 或上传定制资料。定制版本不是官方发行版。

查看第三方组件官方获取入口与许可边界：

```sh
python3 tools/customize/klburn-builder.py --dependencies
```

不能随源码分发的驱动或工具不打包进本工具；从官方入口获取所需版本，并保留
许可协议。能够下载、内部使用或编译，不等于能够公开分发包含它的 ISO。

## 各平台入口

需要 Python 3.10 或更新版本与 Git；SSH 模式还需要 OpenSSH。

| 平台 | 入口 | 实际 ISO 构建位置 |
|---|---|---|
| Windows | `KLBurn-Windows.cmd` | 自行配置的 SSH 后端；或在符合条件的 WSL Ubuntu 内运行 Linux 入口 |
| macOS | `KLBurn-macOS.command` | SSH x86_64 Ubuntu 24.04 后端；不能在 Apple Silicon 原生构建 amd64 ISO |
| Linux | `KLBurn-Linux.sh` | 符合条件的本机，或 SSH 后端 |

Windows 没有 WSL 时不自动安装；WSL 没有可用 KVM 时选择 SSH 后端。
macOS 若系统 Python 版本过旧，请安装新版 Python，再用其完整路径运行
`klburn-builder.py`，不要把系统 Python 的存在当作版本满足条件。

## 独立工作区

以下名称均为虚构示例。`--ref` 必须选择包含本工具的源码 tag 或 commit，
不是任意旧版本；执行前应核对所选源码的可信来源。

私有候选 `v1.11.2` 的品牌测试曾将当前配置固定视作官方品牌，导致合法定制
配置在源码检查阶段停止。修复位于 `e03ed14`，验证定制构建时须选择包含该修复
的源码提交；旧 tag 不重写，也不能把仅准备成功描述为双版构建通过。

```sh
python3 tools/customize/klburn-builder.py \
  --source /path/to/KLBurn --ref <已核对的源码commit> \
  --workspace /path/to/new-custom-workspace \
  --name "示例 实验室" --console-name "Example Lab" \
  --report-title "服务器测试报告" --mem-report-title "内存专用测试报告" \
  --backend prepare
```

`prepare` 只准备源码，**构建与验收 NOT_RUN**。不接受已存在的工作区，
不会覆盖原始源码。新工作区保留上游 commit，提交品牌配置并移除 origin，
避免误推送。定制版本号带 `-custom.<品牌哈希>`，报告抬头带“定制构建”。

独立定制仓库使用本地 Git 构建身份 `KLBurn Custom Builder` /
`builder@example.invalid`，用于定制提交及未签名 annotated tag；不会改动原始
仓库或用户/root 的全局 Git 配置，也不依赖后端预先配置个人邮箱或签名密钥。
继续旧工作区时同样只设置该工作区的本地构建身份。
1.11.3 工具在干净后端曾于两版验收完成后因 tag 缺少身份而退出；该失败不能
称为工具端到端通过，修复自 1.11.4 起提供。

中文显示名称与报告抬头保留在报告中。启动控制台和 GRUB 只能使用安全 ASCII
名称，这是串口/BMC 显示约束，不是中文数据丢失。logo 可用 `--logo /path/to/logo.png`
提供，限 1 MiB；仅进入自己的定制源码，绝不自动发布。

## 后端与验收

后端需要 x86_64 Ubuntu 24.04、root 构建权限、非交互 `sudo`、KVM、loop/mount
能力以及构建/验收工具。独立完整构建预检要求至少 40 GiB 可用空间，工作区应在
Linux 本地文件系统；网络共享可保存已完成的冷数据，不用作 rootfs 工作区。

```sh
python3 tools/customize/klburn-builder.py --check-backend
```

预检不代表发布通过。缺少工具会明确停止，不自动安装系统依赖。
后端若依赖网络代理，请在实际运行工具的环境中配置标准 `http_proxy` /
`https_proxy`（或大写形式）、`all_proxy`、`no_proxy` 变量。工具仅请求 sudo 保留
这些已配置的变量名，不把代理值放进命令参数，也不保留其他环境变量。
sudo 策略不允许保留时会停止，需由后端管理员配置相应权限；不会修改网络或绕过策略。
后台服务和 SSH 非交互命令不一定继承登录终端的环境，必须分别验证。
不要把含凭据的代理值提交到源码、品牌配置或公开日志中。
准备好后使用 `--backend local`，或 `--backend ssh --ssh builder@example-build-host`
（此主机名是虚构示例，请换成自己的 SSH 配置别名）。SSH 目标必须预先完成
host key 核验、密钥配置与所需权限；工具不关闭 host key 检查、不接受密码参数。

还必须明确提供自己的离线组件和回归样本：

- `--vendor /path/to/verified-vendor`：完整组件及 `full-vendor.sha256`。
  工具不从维护者 NAS 下载私有工具，也不自动下载或接受新的下载协议。
  调用者须先阅读并接受适用版本的条款，再提供离线组件并启动构建。
  **既有 NVIDIA 安装步骤使用 `--accept-license` 非交互参数**；启动包含该组件的
  构建前应知晓这一行为。接受安装许可不等于获得公开再分发权利，不能据此公开 ISO。
  输入目录不要携带仓库跟踪的顶层 `vendor/README.md`（它是 KLBurn 的源码说明，
  不是离线组件）；旧版说明覆盖新版源码会触发脏源码守卫并停止。
  各第三方组件自己的 README、许可证和归属文件必须保留，不在此排除范围内。
- `--fixtures /path/to/private-fixtures`：原有真实传感器与电源回放守卫所需输入。
  至少包含可判传感器与未接交流电的真实观察；不得用虚构输入冒充该验收。
  这些数据仅用于你指定的构建后端，不能上传官方仓库。

当前严格发布入口依赖这些输入。**仅下载源码、不提供离线依赖或必要样本，不能
完成双版发行构建。** 工具会停止，而非删除守卫或生成缺件的“完整 ISO”。

执行顺序是：独立定制提交 → 干净源码检查 → 源码回归与变异 → full/mem 串行
构建 → 两版固件/依赖与 QEMU 冒烟 → full 完整真写盘验收 → 本地 annotated tag。
真写盘验收针对隔离 QEMU 测试磁盘，不是宿主物理盘。

本地结果在工作区 `source/out/`，主日志为 `build.log`。SSH 结果下载到本地
`output/` 并再次校验 ISO 的 SHA256；远端路径记在本地 `remote-build.json`。
失败时保留工作区与日志，不自动清理或覆盖。Linux 上可用 `--resume <工作区>`
继续已准备的工作区；发布收据已完成或 tag 已存在时，严格入口会拒绝覆盖。

SSH 模式另存 `ssh-session.log`，即使在源码/环境预检阶段失败、尚未产生远端
`build.log`，也能保留诊断。远端解包由接收用户拥有文件，不保留发送端的数值 UID；
不通过关闭 Git 所有权检查来绕过跨平台权限问题。

1.11.8 起，SSH 源码归档按 Git 索引保留 644/755 权限，修复 Windows/NTFS 等
发送端丢失脚本执行位而接收端无法启动的问题。接收端在独立定制仓库启用
`core.filemode`，执行位被修改时仍触发脏源码守卫；原始仓库和全局 Git 配置不改。
这项传输回归在 POSIX 接收端模拟权限丢失，不代表已执行 Windows 本机验收。

## 品牌配置与信任边界

集中配置为 `build/branding.json`，由 `build/branding.py` 验证、转义后传入构建。
配置摘要写入盘内 `BRAND_SHA256`，完整配置随盘保留。原始环境变量品牌覆盖
不再接受，因为它不进入源码 commit，无法可靠追溯。

品牌字符串不作 shell 代码解释；控制字符、任意 logo 路径及不安全控制台字符
会拒绝。报告生成器继续 HTML 转义。工具不会对整棵源码做字符串替换。
仅使用自己有权使用的名称和 logo；MIT 不授予第三方商标权。

源码测试、入口运行、QEMU 与真机硬件验收是不同证据。不得把其中一项替代另一项。

## 维护者打包入口

在完成源码提交、工作区干净后执行：

```sh
python3 build/package-tools.py --output /path/to/new-tool-output
```

分别生成 Windows、macOS、Linux ZIP 与 SHA256。ZIP 使用固定时间戳，只从当前
commit 读取明确允许的程序、入口、说明与 MIT 许可证；不读取 vendor、客户样本
或内部构建日志。`SOURCE.json` 记录来源 commit、版本和包内文件哈希。
输出已存在时拒绝覆盖；打包不会上传或公开任何文件，也不代表 ISO 验收已通过。
