#!/usr/bin/env bash
#
# 变异测试：把已经修好的 bug 逐个塞回代码里，确认对应的用例真的会跑红。
#
#     ./tests/mutate.sh              # 跑全部变异（约 3~5 分钟）
#     ./tests/mutate.sh verdict-grep # 只跑一条
#     ./tests/mutate.sh --list       # 看有哪些
#
# ================================================================
# 为什么要有它
# ================================================================
# 「一个从没红过的测试等于没写」是这个项目反复说的一句话，而且是有依据的：
# 客户文案守卫曾经是个摆设（用 grep 扫 result_add，grep 逐行工作、只看得到
# 调用的第一行，而长文案全写在续行里），一句"本测试盘未包含"就那么进了客户报告。
#
# 问题在于，这种验证一直是**一次性人工**做的 —— 做完就没了，下次谁改了守卫，
# 没人会再手工验一遍。这个脚本把它固化成可重复执行的闸门。
#
# ================================================================
# 每条变异都对应一次真实翻车
# ================================================================
# 不要为了凑数加变异。加一条的标准是：**它曾经真的发生过，或者它一旦发生
# 后果严重到必须有人守**。每条都在下面写清楚它对应哪条不变量。
#
# ================================================================
# 安全性
# ================================================================
# 这个脚本会**真的改源码文件**，所以：
#   - 开跑前记下每个目标文件的 sha256
#   - 每条变异跑完立刻从备份还原
#   - trap 保证中途被打断也还原
#   - 最后再比一次 sha256，对不上就大声报错
# 它不碰 git，也不要求工作区干净 —— 但你自己的改动和变异混在一起时，
# 万一还原失败会很难分辨，所以最后那道 sha256 校验是硬性的。
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RT="rootfs/opt/klburn"

# ================================================================
# 变异清单
# ================================================================
# 每条五个字段，用 $'\x1f' 分隔（正文里出现的概率为零）：
#   id ¦ 说明（对应哪条不变量）¦ 要跑哪个测试套件 ¦ 会被改的文件 ¦ 施加变异的函数名
#
# 文件单独列一列，而不是让变异函数顺便返回 —— 备份必须发生在施加之前，
# 让函数兼职报告文件名的话就得先跑一次再回滚，那才是真正危险的设计。
S=$'\x1f'
MUTATIONS=(
"verdict-grep${S}整机结论换回 grep 匹配 JSON 文本（§11-1 的 JSON 版：格式一变就每台机器都判 PASS）${S}test-hw-checks${S}$RT/factory-test.sh${S}mut_verdict_grep"
"verdict-empty${S}交付报告把「一条判定都没有」当成通过（什么都没测过的机器打绿色 PASS）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_verdict_empty"
"verdict-empty-int${S}内部报告把「一条判定都没有」当成通过（三处结论口径必须一致）${S}test-internal-report${S}$RT/report/generate_internal.py${S}mut_verdict_empty_int"
"verify-chain${S}把 verify_disk_temp 从 verify_all 里删掉（判定函数还在，只是再没被调用过）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_verify_chain"
"oom-fail${S}内存压测被 OOM 打死不再判 WARN（0.7.0 把好机器拦在出货前的那条）${S}test-log-parsing${S}$RT/lib/stress.sh${S}mut_oom_fail"
"lint-exempt${S}给 lint 偷偷多加一类豁免（豁免清单本身也要有人守）${S}lint${S}tests/lint.sh${S}mut_lint_exempt"
"net-servers${S}NET_TIME_SERVERS 改回裸赋值（现场在 klburn.conf 里换内网 NTP 会被静默顶掉）${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_net_servers"
"fd0-overreach${S}把软驱豁免扩大成所有设备（真盘的 I/O error 会被一起吃掉，坏盘查不出来）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_fd0_overreach"
"disk-none-fail${S}没装硬盘时判 FAIL 而不是 WARN（§2-2：能力缺失 ≠ 硬件故障，会把无盘机器拦在出货前）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_disk_none_fail"
)

# ================================================================
# 施加变异的原语
# ================================================================
# 一律按**整行**替换/删除，锚点用固定字符串（grep -F），不写正则 ——
# 正则锚点一旦因为代码微调而失配，变异其实没施加上，测试当然是绿的，
# 于是这里会报告"这条变异逃掉了"。那是**假警报**，比漏报还难查。
# 所以锚点必须**恰好命中一行**，命中 0 次或多次都当场判错。

anchor_count() { grep -cF -- "$2" "$1" 2>/dev/null || echo 0; }

replace_line() {
  local f="$1" needle="$2" new="$3" n
  n="$(anchor_count "$f" "$needle")"
  if [[ "$n" != "1" ]]; then
    printf '锚点在 %s 里命中 %s 次（要求恰好 1 次），变异无法可靠施加' "$f" "$n"
    return 1
  fi
  awk -v needle="$needle" -v new="$new" \
      'index($0, needle) { print new; next } { print }' "$f" > "$f.mut" && mv "$f.mut" "$f"
}

delete_line() {
  local f="$1" needle="$2" n
  n="$(anchor_count "$f" "$needle")"
  if [[ "$n" != "1" ]]; then
    printf '锚点在 %s 里命中 %s 次（要求恰好 1 次），变异无法可靠施加' "$f" "$n"
    return 1
  fi
  awk -v needle="$needle" 'index($0, needle) { next } { print }' "$f" > "$f.mut" && mv "$f.mut" "$f"
}

# ================================================================
# 各条变异（函数名要和上面清单里的对上）
# 每个函数只负责改文件，成功回 0、失败把原因打到 stdout
# ================================================================

mut_verdict_grep() {
  replace_line "$RT/factory-test.sh" \
    "if jq -e -s 'any(.[]; .status == \"FAIL\")'" \
    'if grep -q '"'"'"status":"FAIL"'"'"' "$RUN_DIR/results.jsonl" 2>/dev/null; then'
}

mut_verdict_empty() {
  replace_line "$RT/report/generate_report.py" \
    "no_results = not statuses" \
    "    no_results = False"
}

mut_verdict_empty_int() {
  replace_line "$RT/report/generate_internal.py" \
    'overall = "FAIL" if ("FAIL" in st or not st) else "PASS"' \
    '    overall = "FAIL" if "FAIL" in st else "PASS"'
}

mut_verify_chain() {
  delete_line "$RT/lib/verify.sh" "  verify_disk_temp"
}

mut_oom_fail() {
  replace_line "$RT/lib/stress.sh" \
    "(( rc == 137 )) || return 1" \
    "  (( rc == 1370 )) || return 1"
}

mut_lint_exempt() {
  replace_line "tests/lint.sh" \
    'EXCLUDE_RUNTIME="SC2034,SC2155,SC2120"' \
    'EXCLUDE_RUNTIME="SC2034,SC2155,SC2120,SC2086"'
}

# 豁免噪声最危险的失败方式不是"漏豁免"（那会误伤好机器，至少看得见），
# 而是"豁免扩大化"—— 顺手把真盘的 I/O error 一起吃掉，坏盘从此查不出来，
# 而且永远不会有人发现。
mut_fd0_overreach() {
  replace_line "$RT/lib/verify.sh" \
    "| grep -viE 'thermal throttl.*not|nouveau|dev fd[0-9]' \\" \
    "    | grep -viE 'thermal throttl.*not|nouveau|dev [a-z]' \\"
}

# 「本机未安装硬盘」和「硬盘坏了」是两回事。判成 FAIL 的话，出厂只测
# CPU/内存/网卡的无盘机器会被整机判不合格 —— 把好机器拦在出货前，
# 比漏判更糟（§2-2）。这条变异守的是 collect_disk 那三条分支里最要紧的一条。
mut_disk_none_fail() {
  replace_line "$RT/lib/collect.sh" \
    '"硬盘信息采集" "$ST_WARN"' \
    '      result_add "collect_disk" "硬盘信息采集" "$ST_FAIL" \'
}

mut_net_servers() {
  replace_line "$RT/lib/network.sh" \
    "declare -p NET_TIME_SERVERS >/dev/null 2>&1 || \\" \
    "NET_TIME_SERVERS=(ntp.aliyun.com cn.pool.ntp.org time.cloudflare.com) # 变异：裸赋值"
}

# ================================================================
# 跑
# ================================================================
if [[ "${1:-}" == "--list" ]]; then
  printf '%-20s %-18s %s\n' "变异" "由谁守" "说明"
  for m in "${MUTATIONS[@]}"; do
    IFS="$S" read -r id desc suite _fn <<< "$m"
    printf '%-20s %-18s %s\n' "$id" "$suite" "$desc"
  done
  exit 0
fi

ONLY="${1:-}"

BACKUP="$(mktemp -d)"
RESTORED=1
restore_all() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cp -p "$BACKUP/$(echo "$f" | tr '/' '_')" "$f" 2>/dev/null
  done < <(cat "$BACKUP/.touched" 2>/dev/null)
}
cleanup() {
  restore_all
  rm -rf "$BACKUP"
  (( RESTORED )) || printf '\n\033[1;31m⚠ 有文件没能还原，检查 git status！\033[0m\n'
}
trap cleanup EXIT

: > "$BACKUP/.touched"

CAUGHT=0; ESCAPED=0; BROKEN=0
ESCAPED_LIST=()

printf '\n\033[1;36m===== 变异测试 =====\033[0m\n'
printf '每条变异都必须让对应的测试套件跑红；没红 = 那条守卫是摆设\n\n'

for m in "${MUTATIONS[@]}"; do
  IFS="$S" read -r id desc suite target fn <<< "$m"
  [[ -n "$ONLY" && "$ONLY" != "$id" ]] && continue

  printf '\033[1m%s\033[0m  (%s)\n' "$id" "$suite"
  printf '    %s\n' "$desc"

  if [[ ! -f "$target" ]]; then
    printf '    \033[31m✗ 目标文件不存在：%s\033[0m\n\n' "$target"
    BROKEN=$(( BROKEN + 1 )); continue
  fi

  # 备份必须在施加之前。这里不碰 git —— 用 git checkout 兜底会把你自己
  # 没提交的改动一起冲掉，那是拿别人的工作去换测试的方便。
  cp -p "$target" "$BACKUP/$(echo "$target" | tr '/' '_')"
  echo "$target" >> "$BACKUP/.touched"

  if ! err="$($fn 2>&1 | tail -1)"; then
    printf '    \033[31m✗ 施加失败：%s\033[0m\n\n' "$err"
    BROKEN=$(( BROKEN + 1 ))
    restore_all; continue
  fi

  # 跑对应的套件，**必须**非零退出
  if ./tests/"$suite".sh >/dev/null 2>&1; then
    printf '    \033[31m✗ 逃掉了 —— %s 仍然全绿，这条守卫是摆设\033[0m\n\n' "$suite"
    ESCAPED=$(( ESCAPED + 1 )); ESCAPED_LIST+=("$id -> $suite")
  else
    printf '    \033[32m✓ 被 %s 抓住\033[0m\n\n' "$suite"
    CAUGHT=$(( CAUGHT + 1 ))
  fi

  restore_all
done

# ---------------------------------------------------------------- 还原校验
printf '\033[1m还原校验\033[0m\n'
DIRTY=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  b="$BACKUP/$(echo "$f" | tr '/' '_')"
  cmp -s "$f" "$b" || DIRTY="$DIRTY $f"
done < <(sort -u "$BACKUP/.touched" 2>/dev/null)

if [[ -z "$DIRTY" ]]; then
  printf '  \033[32m所有被改过的文件都已还原\033[0m\n'
else
  RESTORED=0
  printf '  \033[1;31m这些文件没还原回去：%s\033[0m\n' "$DIRTY"
fi

printf '\n========================================\n'
printf '抓住 %d 条，逃掉 %d 条，施加失败 %d 条\n' "$CAUGHT" "$ESCAPED" "$BROKEN"
if (( ESCAPED )); then
  printf '\033[1;31m逃掉的：\033[0m\n'
  printf '  %s\n' "${ESCAPED_LIST[@]}"
  printf '逃掉 = 那条守卫抓不住它对应的 bug，要么补断言，要么把变异改准\n'
fi
(( ESCAPED == 0 && BROKEN == 0 && RESTORED == 1 )) \
  && { printf '\033[1;32m全部被抓住\033[0m\n'; exit 0; } \
  || exit 1
