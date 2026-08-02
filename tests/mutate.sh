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
"counter-postfix${S}断言计数改回 (( PASS++ ))（X=0 时返回 1，让 cond && ok || bad 两边都跑）${S}lint${S}tests/lint.sh${S}mut_counter_postfix"
"media-blind${S}scan_disks 不再反查启动 U 盘（Ventoy 下前两层同时落空，fio 会把测试盘写穿）${S}test-hw-checks${S}$RT/lib/storage.sh${S}mut_media_blind"
"ecc-ue-warn${S}内存不可纠正错误判 WARN 而不是 FAIL（数据已经错了，这种机器不能出厂）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_ecc_ue_warn"
"ecc-noedac-pass${S}读不到 EDAC 时判 PASS 而不是 SKIP（没查过和查过没问题被混为一谈）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_ecc_noedac_pass"
"counter-abs${S}计数器判定看绝对值而不是前后差值（带着历史计数的二手机器会被全判故障）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_counter_abs"
"screen-nonascii${S}面板不再过滤非 ASCII（一个中文字节就能把 BMC 上那屏顶成乱码）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_screen_nonascii"
"gpu-cap-fail${S}超过 8 张卡时不再收口（进度条被挤出屏幕，现场看不到测到哪了）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_gpu_cap"
"review-hang${S}配置核对面板的倒计时永不到点（现场插上去像死机，最怕的那种）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_review_hang"
"csv-unread${S}sys_metrics 多采一列却没人读（采了没人看等于没采）${S}test-internal-report${S}$RT/report/generate_internal.py${S}mut_csv_unread"
"rawindex-gap${S}加了新采集却忘了在 raw 索引里写说明（没人知道那份文件是什么）${S}test-internal-report${S}$RT/report/generate_internal.py${S}mut_rawindex_gap"
"emph-literal${S}判定文案里的 **重点** 原样印给客户（客户看到两串字面星号）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_emph_literal"
)

# ================================================================
# 有两条守卫**故意没有**变异 —— 不是漏了
# ================================================================
# 本脚本的契约是"3~5 分钟、不需要构建"。下面这两条都违反它，硬塞进来会让
# 每次跑变异都变成一小时，最后的结果是没人再跑它。
# （和 e2e 那条"把启动 U 盘写穿"的变异同一个道理，见 architecture.md。）
#
#   build-gpu-burn.sh 的逐代 cubin 自检
#       要重新裁剪 1GB 的 cuBLAS 静态库再链接一遍，十几分钟起步，
#       而且要机器上装着 CUDA。它自己已经红过一次（1.7.0 那版体积启发式
#       就是被它的前身抓出来的），不是没验过的守卫。
#
#   check-firmware.sh 的 pci.ids 日期断言
#       check-firmware 要一个**已经构建出来的 rootfs**，没构建过它判 0 项跳过。
#       在没有 rootfs 的机器上塞这条变异，会得到"逃掉了"的**假警报** ——
#       而假警报比漏报还难查，人会去改一条本来就没问题的守卫。

# ================================================================
# 施加变异的原语
# ================================================================
# 一律按**整行**替换/删除，锚点用固定字符串（grep -F），不写正则 ——
# 正则锚点一旦因为代码微调而失配，变异其实没施加上，测试当然是绿的，
# 于是这里会报告"这条变异逃掉了"。那是**假警报**，比漏报还难查。
# 所以锚点必须**恰好命中一行**，命中 0 次或多次都当场判错。

anchor_count() { grep -cF -- "$2" "$1" 2>/dev/null || echo 0; }

# ⚠️ 锚点和替换文本一律走 ENVIRON 传给 awk，**绝不能用 `awk -v`**。
#    `-v` 会对值做一遍反斜杠转义处理：锚点里的 `\033` 会在 awk 里变成一个真的
#    ESC 字节，而文件里是 `\`+`0`+`3`+`3` 四个字符，于是 index() 永远匹配不上。
#    表现极其难查 —— 上面 anchor_count 用的是 grep -F，它照样报"命中 1 次"，
#    于是变异**静默没施加**、对应套件照常全绿，最后被报成"这条守卫逃掉了"。
#    假警报比漏报还难查：人会去改一条本来就没问题的守卫。
#    （counter-postfix 就是这么栽的，它的锚点里正好有 \033。）
#
# 再加一道后置检查：施加完文件必须真的变了。锚点匹配得上、替换却没生效
# 这件事只要发生过一次，就说明"逃掉"这个结论本身不可信。
_apply_awk() {
  local f="$1" prog="$2"
  MUT_NEEDLE="${3:-}" MUT_NEW="${4:-}" awk "$prog" "$f" > "$f.mut" \
    || { rm -f "$f.mut"; printf 'awk 执行失败（%s）' "$f"; return 1; }
  if cmp -s "$f" "$f.mut"; then
    rm -f "$f.mut"
    printf '变异没有真的改到 %s —— 锚点匹配得上、替换却没生效' "$f"
    return 1
  fi
  mv "$f.mut" "$f"
}

replace_line() {
  local f="$1" needle="$2" new="$3" n
  n="$(anchor_count "$f" "$needle")"
  if [[ "$n" != "1" ]]; then
    printf '锚点在 %s 里命中 %s 次（要求恰好 1 次），变异无法可靠施加' "$f" "$n"
    return 1
  fi
  _apply_awk "$f" \
    'index($0, ENVIRON["MUT_NEEDLE"]) { print ENVIRON["MUT_NEW"]; next } { print }' \
    "$needle" "$new"
}

delete_line() {
  local f="$1" needle="$2" n
  n="$(anchor_count "$f" "$needle")"
  if [[ "$n" != "1" ]]; then
    printf '锚点在 %s 里命中 %s 次（要求恰好 1 次），变异无法可靠施加' "$f" "$n"
    return 1
  fi
  _apply_awk "$f" 'index($0, ENVIRON["MUT_NEEDLE"]) { next } { print }' "$needle"
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

# tests/ 里到处是 `cond && ok "..." || bad "..."`（-S info 下 26 条 SC2015）。
# 它们安全**只依赖一件事**：ok()/bad() 返回 0。改成后缀 ++ 之后，PASS 为 0 的
# 那一次算术命令返回 1，"断言通过"接着又把 bad 跑一遍 —— 同一条既记通过又记失败。
mut_counter_postfix() {
  replace_line "tests/lint.sh" \
    "ok()  { printf '  \\033[32mOK\\033[0m   %s\\n' \"\$1\"; PASS=\$((PASS+1)); }" \
    "ok()  { printf '  \\033[32mOK\\033[0m   %s\\n' \"\$1\"; (( PASS++ )); }"
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

# 整个项目最危险的一条路径：反查不出启动 U 盘 -> fio 把它当空盘写穿 ->
# 测试盘当场报废、历史报告全丢，不可逆。
# 排除有三层，但 Ventoy 场景下前两层（rm=1 / 有分区挂载）**同时**落空 ——
# 那时候只剩这一层。所以它必须有人守。
mut_media_blind() {
  replace_line "$RT/lib/storage.sh" \
    'media_list="$(live_media_disks' \
    '  media_list=""   # 变异：反查不出启动 U 盘'
}

# 内存的不可纠正错误意味着数据已经出错了，不是"读数偏高"那种程度。
# 判成 WARN 的话整机结论仍然是 PASS，一台内存已经开始坏的机器照常出厂。
mut_ecc_ue_warn() {
  replace_line "$RT/lib/verify.sh" \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_FAIL" \' \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_WARN" \'
}

# 「这台机器没有 EDAC 接口」和「查过了，没有 ECC 错误」是两件完全不同的事。
# 前者判 PASS 等于凭空给出一个没有依据的结论 —— 而报告上看不出区别。
# 这是二号原则（能力缺失 ≠ 结论）在新判定上的同款陷阱。
mut_ecc_noedac_pass() {
  replace_line "$RT/lib/verify.sh" \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_SKIP" \' \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_PASS" \'
}

# 计数器判定必须看**差值**。改成看绝对值的话，任何一台跑过的机器
# （历史上有过一次可纠正错误、开机时有过一次 AER）都会被判有问题 ——
# 而出厂测试要回答的是"这一轮压测把什么逼出来了"。
mut_counter_abs() {
  replace_line "$RT/lib/collect.sh" \
    '        if (d > 0) printf "%s %d %d %d %d\n", $2, i - 2, b, $i, d' \
    '        if ($i > 0) printf "%s %d %d %d %d\n", $2, i - 2, b, $i, $i'
}

# 屏幕上一个非 ASCII 字节都不许有：现场是通过 BMC 的 KVM / 串口看的，
# 字符集不受我们控制。型号串来自 dmidecode / nvidia-smi，带得进非 ASCII。
mut_screen_nonascii() {
  replace_line "$RT/lib/ui.sh" \
    "ascii_clean() { printf '%s' \"\$*\" | LC_ALL=C tr -cd '\\40-\\176'; }" \
    "ascii_clean() { printf '%s' \"\$*\"; }"
}

# 8 张卡已经占了半屏，全铺开会把进度条挤出屏幕 —— 而那是现场最需要看到的一行。
mut_gpu_cap() {
  replace_line "$RT/lib/ui.sh" "DASH_GPU_MAX=8" "DASH_GPU_MAX=999"
}

# 配置核对面板"绝不能卡住流程"是它唯一的硬要求：现场最怕的就是插上去没反应，
# 那会让人直接断电重来。倒计时到点必须自己往下走，不能只等按键。
#
# ⚠️ 这条变异**只改文案不改行为**（把条件改成一个永远不成立的值），
# 而守卫是 `declare -f config_review | grep -q 'remaining <= 0'` —— 只读函数体、
# 不执行它。故意这么设计：真把 break 删掉的话，测试自己会挂死在那儿，
# 变异测试就再也跑不完了。
mut_review_hang() {
  replace_line "$RT/lib/ui.sh" \
    "(( remaining <= 0 )) && { printf '\\n'; break; }" \
    "    (( remaining < -999999 )) && { printf '\\n'; break; }   # 变异：永远不到点"
}

# "采了没人看等于没采"。1.7.0 往 sys_metrics.csv 加了 ecc_ce/ecc_ue 两列，
# 却只有写入方没有读取方 —— 而这种事**不会有任何报错**，只是那份数据白采。
# 守卫是"CSV 表头里除时间/阶段外的每一列都必须有报告生成器在读"。
mut_csv_unread() {
  replace_line "$RT/report/generate_internal.py" \
    'for key, bucket in (("ecc_ce", ce)' \
    '                for key, bucket in (("ecc_ce_MUTATED", ce), ("ecc_ue", ue)):'
}

# 加了新采集却忘了在 RAW_INDEX 里写一条说明。表现是报告里那份文件落进"未分类"，
# 看报告的工程人员根本不知道它是什么、什么时候该点开 —— 和没采一样。
# 这里把 lspci.txt 那条的正则改成匹配不上，模拟"漏写了一条"。
mut_rawindex_gap() {
  replace_line "$RT/report/generate_internal.py" \
    '(r"^lspci\.txt$", "系统"' \
    '    (r"^lspci-MUTATED\\.txt$", "系统", "PCI 设备清单", "查装了什么卡时", "按总线地址反查"),'
}

# 判定文案里的 **重点** 是给写代码的人看的记号。原样进 HTML 的话，
# 客户看到的是「这是测试环境的容量限制，**不是内存故障** ——」两串字面星号，
# 而那句恰恰是最该让人看清的一句。这个坑从 0.7.0 一直躺到 1.7.1 才发现。
mut_emph_literal() {
  replace_line "$RT/report/generate_report.py" \
    'class="rd">%s</span>' \
    "        A('<span class=\"rd\">%s</span>' % E(r.get(\"detail\")))"
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
