#!/usr/bin/env bash
# 只在 fbterm 成功建立的 PTY 内显示两道确认，不运行测试或写任何候选盘。
set -uo pipefail
export LC_ALL=C
source /opt/klburn/lib/core.sh
[[ ! -f /opt/klburn/klburn.conf ]] || source /opt/klburn/klburn.conf
source /opt/klburn/lib/ui.sh
source /opt/klburn/lib/storage.sh
session="$1"
# 输入由父进程在 0700 临时目录中用 declare -p 生成，绝不是设备字符串拼接命令。
# shellcheck disable=SC1091
source "$session/state"
printf 'started\n' > "$session/started" || exit 1
KLB_DISK_CJK=1
# 仅这两屏省去六行装饰标题，把空间留给双语风险说明。
BRAND_COMPACT=1
DISK_SKIP_REASON=""
info "Disk confirmation: UTF-8 framebuffer terminal"
if confirm_disk_write "$2"; then
  printf 'confirmed\n' > "$session/result"
else
  printf '%s\n' "${DISK_SKIP_REASON:-确认未完成，跳过破坏性硬盘测试}" > "$session/reason"
fi
