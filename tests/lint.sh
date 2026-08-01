#!/usr/bin/env bash
#
# 用 shellcheck 做静态检查。和其它 tests/ 里的脚本一样，不需要任何硬件：
#
# （这一行别写成以 "# shellcheck " 开头 —— 那是 shellcheck 的指令语法，
#   它会试着把后面的中文当成指令去解析，然后报 SC1072/SC1073。
#   本脚本会检查自己，所以这个坑是真踩得到的。）
#
#     ./tests/lint.sh
#
# 为什么值得单独立一条：回归测试守的是"逻辑对不对"，守不住"这行 bash 会不会
# 在某个分支上炸"。项目里翻过的车有一半是 bash 陷阱（见 architecture.md §11），
# 而其中好几类 shellcheck 是能直接看出来的 —— 比如 `rm -rf "$dst/$rel"` 里
# $rel 可能为空、`cd ...` 失败之后照样往下跑。
#
# 没装 shellcheck 就跳过（判 0 项，不判失败）：它是构建机上的开发工具，
# 不是出盘的必要条件，不能因为谁的 WSL 里没装就让整套测试跑红。
#
#     sudo apt-get install -y shellcheck
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）
command_not_found_handle() {
  # ⚠️ 这里**不能**写 FAIL=$((FAIL+1))。bash 是在 fork 出来的子进程里执行这个
  #    handler 的，加了也加不到父进程头上 —— 屏幕上红一条，最后那行汇总却还是
  #    "失败 0 项"，正好是本项目最恨的那种"屏幕全绿"。（实测踩过。）
  #    所以直接把整个套件干掉，让退出码非零、run-all 能看见。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

if ! command -v shellcheck >/dev/null 2>&1; then
  printf '  \033[0;33m跳过：本机没装 shellcheck（apt-get install shellcheck）\033[0m\n'
  printf '通过 %d 项，失败 %d 项\n' 0 0
  exit 0
fi

printf '  shellcheck %s\n\n' "$(shellcheck --version | awk '/^version:/{print $2}')"

# ================================================================
# 两套豁免规则，因为两棵树的 bash 约定本来就不一样
# ================================================================
#
# 共同豁免：
#
#   SC2034  "变量没被用过"。config.sh / core.sh 是纯变量文件，值由**别的**
#           被 source 的脚本消费，shellcheck 跨不过 source 边界，全是误报。
#
# rootfs/ 和 tests/ 额外豁免：
#
#   SC2155  "declare 和赋值分开写，免得吃掉返回值"。这条只在 set -e 下才是
#           问题，而运行时脚本**故意不开 -e**（单项失败必须继续往下跑并落进
#           报告，见 factory-test.sh 顶部）。命中的 5 处全是
#           `local detail="...$(fmt_dur ...)..."` 这种拼中文文案的。
#           build/ 那边开了 -Eeuo pipefail，所以**不豁免**，那里是真问题。
#
#   SC2120  "函数声明里引用了参数，但从没有人传参"。几个纯函数留了
#           `${1:-默认}` 形式的可选入参，只有回归测试会传（正是为了喂样本），
#           生产路径走默认值。
#
EXCLUDE_BUILD="SC2034"
EXCLUDE_RUNTIME="SC2034,SC2155,SC2120"

run_group() {
  local label="$1" exclude="$2"; shift 2
  local out rc
  # 一个文件都没收到时**绝不能报"干净"**：那不是没问题，是根本没检查。
  # 这条守的是本脚本自己 —— 文件表出问题的时候，最坏的结果不是跑红，
  # 是安安静静地绿，然后所有人以为 shellcheck 在盯着。
  if (( $# == 0 )); then
    bad "$label 一个文件都没找到 —— 这不是干净，是根本没检查"
    return
  fi
  out="$(shellcheck -x -S warning -e "$exclude" -f gcc "$@" 2>&1)"; rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok "$label（$# 个文件）干净"
  else
    bad "$label 有 $(printf '%s\n' "$out" | grep -c .) 条告警"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

# 用 find 而不是 git ls-files：后者在 linked worktree（git worktree add 出来的）
# 里会失活 —— 那种目录下的 .git 是个文本文件、里面写着**宿主机格式**的绝对路径，
# 在 WSL 里 git 直接 "fatal: not a git repository"，返回空表。
# 空表配上原来的写法就是"0 个文件 -> 干净 -> 全绿"，比跑红危险得多。
# 顺带这样也不再要求"必须在 git 仓库里"，导出的源码包照样能 lint。
mapfile -t BUILD_SH   < <(find build          -name '*.sh' -type f | sort)
mapfile -t RUNTIME_SH < <(find rootfs tests   -name '*.sh' -type f | sort)

run_group "build/（set -Eeuo pipefail，以 root 跑）" "$EXCLUDE_BUILD"   "${BUILD_SH[@]}"
run_group "rootfs/ + tests/（set -uo pipefail）"     "$EXCLUDE_RUNTIME" "${RUNTIME_SH[@]}"

# ================================================================
# 豁免清单本身也要有人守：豁免掉一整类检查很容易一路加下去，
# 加到最后这条 lint 就只是个摆钩子的地方了。上限拍在这儿，
# 想再加一条就得先在上面写清楚为什么。
check_count() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$label"; else
    bad "$label（期望 $want，实际 $got）"; fi
}
check_count "build/ 的豁免不超过 1 类" 1 \
            "$(printf '%s' "$EXCLUDE_BUILD"   | tr ',' '\n' | grep -c .)"
check_count "runtime 的豁免不超过 3 类" 3 \
            "$(printf '%s' "$EXCLUDE_RUNTIME" | tr ',' '\n' | grep -c .)"

# ================================================================
# SC2015（`A && B || C` 不是 if-then-else）：查过了，不豁免
# ================================================================
# 收紧到 `-S info` 会多出 26 条 SC2015。逐条看过一遍，结论是**都无害**，
# 而且最要紧的一点是：
#
#   **rootfs/opt/klburn/ 下一条都没有** —— 26 条全在 tests/ 和 build/ 里。
#   也就是说没有任何一条落在判定路径上，不存在"潜伏的误判"。
#
# 具体形状只有两种：
#   1. 断言助手      `[[ "$2" == "$3" ]] && ok "$1" || bad "$1"`（占 24 条）
#   2. build-iso.sh  `[[ -f "$f" ]] && sed -i ... || true`（C 是 true，无所谓）
#
# 也撞不上 §11-10 那个真陷阱：那条要求 A 是**管道**
# （`... | grep -q X` 里 grep 匹配到就退出，上游吃 SIGPIPE 返回 141，
# pipefail 下整条管道判失败，于是"匹配成功"反而走 ||）。
# 这 26 条的 A 全是 `[[ ]]` 或者直接对文件跑 grep，没有一条带管道。
#
# 所以不豁免 SC2015（豁免掉就再也看不见新写的了），而是把它们**安全的前提**
# 钉在下面。前提只有一条：ok()/bad() 必须返回 0。
#
# 写成 `PASS=$((PASS+1))` 是赋值，永远返回 0；一旦有人手滑改成 `(( PASS++ ))`，
# 后缀 ++ 求的是**旧值**，PASS 为 0 那一次整条算术命令返回 1 ——
# 于是"断言通过"之后接着把 bad 也跑一遍，同一条断言既记通过又记失败。
# （`(( ++PASS ))` 和 `(( PASS += 1 ))` 求的是新值，不会为 0，都是安全的。）
#
# 只扫**顶格的函数定义行**（`ok() { ... }` / `bad() { ... }` / `check(){ ... }`），
# 不是全文搜 `(( X++ ))`。全文搜会把本文件上面这段注释、以及 mutate.sh 里那条
# 故意写着坏代码的变异载荷一起当成罪证 —— 守卫被自己的说明文字咬死，
# 那种红是假的，会逼着人去把守卫关掉。
counter_offenders="$(grep -rnE '^(ok|bad|chk|check|check_eq|has|has_no)[[:space:]]*\(\)' \
                       tests rootfs 2>/dev/null | grep -F '++' || true)"
if [[ -z "$counter_offenders" ]]; then
  ok "断言计数都是 X=\$((X+1)) 形式（(( X++ )) 在 X=0 时返回 1，会让 && ok || bad 两边都跑）"
else
  bad "这些地方拿 (( X++ )) 计数，会让 \`cond && ok || bad\` 两边都跑：
$(printf '%s' "$counter_offenders" | sed 's/^/       /')"
fi

# ================================================================
# 字节层面的两个坑：BOM 和 CRLF
# ================================================================
# 源码在 Windows 上编辑、在 WSL 里构建、最终跑在 Linux 服务器上，所以这两样
# 都是真会发生的 —— 而且都**不会有像样的报错**：
#
#   CRLF  ->  "bad interpreter: /usr/bin/env bash^M: no such file"
#   BOM   ->  shebang 不在第 0 字节了；被 source 时 BOM 会粘进第一个 token
#
# CRLF 那半边 .gitattributes 已经从源头钉住了（* text=auto eol=lf）。
# **BOM 没人管** —— 而它太容易混进来了：PowerShell 的 Set-Content -Encoding UTF8、
# Out-File、记事本另存为，默认全都加 BOM。（实测：拿 PowerShell 改一次
# config.sh 的版本号就加上了，而那个文件是被 source 的。）
bom_files=""
crlf_files=""
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  [[ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]] && bom_files="$bom_files $f"
done < <(find . -path ./.git -prune -o -type f \
              \( -name '*.sh' -o -name '*.py' -o -name '*.jq' -o -name '*.md' \
                 -o -name '*.conf' -o -name '*.service' \) -print)
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  grep -qU $'\r$' "$f" 2>/dev/null && crlf_files="$crlf_files $f"
done < <(find . -path ./.git -prune -o -type f \
              \( -name '*.sh' -o -name '*.py' -o -name '*.jq' \
                 -o -name '*.conf' -o -name '*.service' \) -print)

[[ -z "$bom_files" ]]  && ok "没有文件带 UTF-8 BOM（会顶掉 shebang、粘进被 source 的第一个 token）" \
                       || bad "这些文件带 BOM：$bom_files"
[[ -z "$crlf_files" ]] && ok "没有脚本带 CRLF（.gitattributes 从源头钉的，这里复核一次）" \
                       || bad "这些脚本带 CRLF：$crlf_files"

# ================================================================
printf '\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
