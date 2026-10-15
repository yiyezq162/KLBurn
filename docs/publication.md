# 公开交付操作与闸门

仓库可见性、GitHub Release 和 GitHub Pages 都是独立的外部发布动作。
这些脚本不会自动把仓库改为公开。项目所有者尚未确认公开时，只进行私有构建、
测试和资料准备，不启用公开发布变量，不执行 Pages 发布。

## 源码和双版 ISO

遵守 [构建与发布](building.md) 的顺序：版本与 CHANGELOG → 源码回归及所需变异
→ 干净提交 → full/mem 串行构建 → 两版固件/依赖及 QEMU 冒烟 → full 完整真写盘
→ 人工核对截图、报告与品牌 → 在对应源码 commit 创建 annotated tag。

源码检查、QEMU 工作流断言与真机验收分别记录，不合并分母；失败尝试保留。
根权限磁盘检查和实际报告内容不能由非 root 源码回归代替。

## 公开前审核

审核当前文件、全部 Git 引用、历史 Release 资产、Actions 日志与 artifacts。
密钥扫描没有命中不等于不存在敏感信息，还需核对客户身份、原始报告、内部运维
信息、图片内容与第三方版权。具体组件边界见 [第三方说明](third-party.md)。

历史公司名称可保留，但这不是允许历史秘密或客户原始数据公开的授权。
需要撤销凭据、删除历史资产或重写历史的问题，交由项目所有者决定。
不覆盖旧 tag 或历史发布资产。

包含 Intel LINPACK/HPL 功能的公开介绍、官网和 Release 说明须显示以下归属，
并随二进制保留适用版权、条件和免责声明；不得暗示权利人为 KLBurn 背书：

> This product includes software developed at the University of Tennessee, Knoxville, Innovative Computing Laboratory.

这是对应 LINPACK 附带 HPL 2.3 声明中的广告归属条件，不是其他组件的分发许可。

## 三平台工具资产

在与 ISO 相同的干净源码 commit 运行：

```sh
python3 build/package-tools.py --output /path/to/new-tool-output
```

工具 ZIP 不带第三方驱动、用户品牌、客户样本或内部日志。
逐平台验证实际入口；没有 Windows 执行环境时保留 Windows NOT_RUN。

## 静态下载索引

获得明确公开授权、完成审核并发布资产后，使用 GitHub 实际返回的 Release JSON，
而不是手填版本时间或猜测链接。新版所需资产为 full/mem ISO 和三个平台工具 ZIP；
其 SHA256 附件与适用的许可证、源码提供材料按实际交付清单发布。
内部 `manifest.json`、构建日志、私有样本不直接成为公共附件。

```sh
gh api repos/yiyezq162/KLBurn/releases/tags/vVERSION > /private/release.json
python3 tools/update-site-release.py \
  --iso-receipt /private/release-VERSION/manifest.json \
  --tools-receipt /private/tool-output/tools-manifest.json \
  --release-json /private/release.json \
  --iso-dir /private/iso-output --tools-dir /private/tool-output \
  --previous site/releases.json --output /private/releases-reviewed.json
```

路径是说明用示例，需换成实际路径；`VERSION` 必须是已通过验收并发布的版本。
导出器重新读取本地文件计算 SHA256，再与内部收据和 GitHub 上传后 digest/size
核对。ISO 和工具必须同 commit；预发布标记直接取 GitHub，禁止顺手提升稳定版。
输出只允许公开字段，保留已有版本索引且拒绝覆盖同版本记录。

审阅输出后更新 `site/releases.json` 并提交。网站访客只读取随网站发布的 JSON，
无需调用 GitHub API。索引不是公开授权或分发许可证明。

## GitHub Pages

`.github/workflows/pages.yml` 仅支持手动触发，并要求同时满足：

1. 项目所有者已经明确批准此次公开。
2. 仓库确实为公开，仓库变量 `KLBURN_PUBLICATION_ENABLED` 为 `true`。
3. 手动输入确认值 `PUBLISH`，静态索引检查通过。

它只上传 `site/`，不上传源码工作区、out、vendor 或私有收据。使用 GitHub Pages
默认地址，不配置自定义域名或自有服务器。启用前应配置 GitHub Pages 的 Actions
来源，并检查 `github-pages` 环境的审批设置。

发布后以未登录浏览器检查页面与每个真实下载链接，并重新核对下载字节的
SHA256。桌面、手机与横屏检查包含导航、排版、校验值换行和控制台错误。
本地截图与元数据夹具测试不能代替这一步。
