# CLAUDE.md

项目说明与开发约束统一见 [AGENTS.md](AGENTS.md)，请先读它并遵守其中的不变量、
报告红线、测试要求与发布顺序。人看的入口是 [README.md](README.md)。

源码可在 macOS、Windows 或 Linux 编辑；现有 amd64 ISO 的构建与完整测试在
x86_64 Ubuntu 24.04 执行。Mac mini M4 用于开发，Linux 可通过 SSH 连接。
WSL 是 Windows 下的可选环境，不能假定当前机器已安装或只能使用 WSL。
