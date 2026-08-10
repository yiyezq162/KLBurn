#!/usr/bin/env bash
# KLBurn 部件专项验证（可选件）
#
# 和另外两块的分工，一句话说清：
#
#   压测（stress.sh）    机器**扛不扛得住**满载 —— 跑很久，看有没有报错 / 超温
#   基准（bench.sh）      机器**跑得有多快** —— 跑几十秒，量一个数字出来
#   本文件               **算得对不对 / 部件自己怎么说** —— 跑一遍厂商或社区
#                        的专项诊断，结论由那个工具给
#
# 为什么需要第三块：`stress-ng` 抓的是"跑挂了没有"，抓不到**算完了但算错了**。
# 那类缺陷叫静默数据损坏（SDC，业界也叫"会算错的核"），Google 和 Meta 各自
# 发过论文之后，它已经出现在做 AI / HPC 的客户的验收单上。
# 同理 `gpu_burn` 是个**功耗病毒**（把卡烤满），它不走显存总线、不验 ECC 纠错
# 逻辑，而那正是 NVIDIA 自己的诊断工具干的事。
#
# ================================================================
# 三条定性，改之前先读：
#
# 1. **这里的结论是那个工具给的，不是我们定的。**
#    和 bench.sh 不一样：基准项只报数不判合格，而这里的工具会明确说
#    "这颗 CPU 算错了""这张卡的显存有问题" —— 那是真故障，判 FAIL 天经地义。
#    我们仍然不定任何数值门槛。
#
# 2. **没带工具 = SKIP，永远不是 FAIL。**两个都不在 Ubuntu 源里、也不能
#    随我们重新分发，要构建时手工放进 vendor/。没放就是**我们这张盘**的
#    能力缺口，跟被测机器好不好毫无关系（一号红线）。
#
#    ⚠️ 而且这种 SKIP **不进交付报告** —— 传 `origin=self`（见 core.sh 的
#    result_add）。客户读到「当前测试环境未包含显卡厂商诊断程序」，
#    得到的信息不是"这台机器没问题"，是"这家供应商的工具箱是破的"。
#    1.9.4 之前这两行是真印出去过的，被当面骂过一次。
#
# 3. **跑了但没跑成 ≠ 机器有问题。**工具非零退出、日志里却找不到任何一条
#    "某项测试失败"的证据时，一律 SKIP —— 那可能是环境、参数、驱动版本的事，
#    分不清的东西不该去染客户的结论（report-policy 二-5）。
#
# ⚠️⚠️ **"带了工具"那条路一次真机都没跑过。**手上没有服务器、也没有 N 卡，
#    离线只验到"没有工具时干净地 SKIP"这一半。放工具进去之后第一次跑，
#    照 docs/first-run-checklist.md 里那两条逐项确认。
#
# 判读逻辑一律抽成纯函数（只吃文件路径和退出码、只吐字符串），
# 见 tests/test-log-parsing.sh。
# ================================================================

VALIDATE_LOG_DIR=""

validate_init() {
  VALIDATE_LOG_DIR="$RAW_DIR/validate"
  mkdir -p "$VALIDATE_LOG_DIR"
}

# ---------------------------------------------------------------- CPU 算得对不对
#
# sdc_verdict <退出码> <日志> -> pass | fail | inconclusive
#
# OpenDCDiag（Intel 开源，Apache-2.0）跑完的退出码：0 = 全过。
# 非零**不一定**是机器的问题（参数不对、CPU 不支持某组测试、被超时打断都会非零），
# 所以非零时必须在日志里找到**明确的失败证据**才敢判 FAIL。
#
# ⚠️ 顺序不能反：先认失败证据，再认 exit 0。反过来的话，一份既有失败行
#    又碰巧退出 0 的日志会被读成通过。
sdc_verdict() {
  local rc="${1:-1}" log="${2:-}"
  if [[ -f "$log" ]] && grep -aqiE '^ *- (failed|fail):|\bfailed\b.*\bthread\b|Test .* failed|data (miscompare|corruption)' "$log" 2>/dev/null; then
    printf 'fail'; return
  fi
  [[ "$rc" == "0" ]] && { printf 'pass'; return; }
  printf 'inconclusive'
}

validate_cpu_sdc() {
  local exe
  # bench_tool 定义在 lib/bench.sh：先找 /opt/klburn/tools/bench/<子目录>/，
  # 再找 tools/，最后 PATH。这里复用它，免得再写一份查找逻辑。
  if ! exe="$(bench_tool opendcdiag sandstone)"; then
    # origin=self：没带程序是**我们这张盘**的能力缺口，跟被测机器无关，
    # 所以这一行只落 results.jsonl 和内部报告，不进交付报告（见 core.sh 的 result_add）。
    result_add "validate_cpu_sdc" "CPU 计算正确性" "$ST_SKIP" \
      "当前测试环境未包含处理器计算正确性诊断程序，本项未做核对。此项不影响整机结论。" \
      "" "self"
    return 0
  fi

  local secs="${VALIDATE_SDC_SECS:-120}"
  info "[VALIDATE] CPU computation correctness, ${secs}s ..."
  local log="$VALIDATE_LOG_DIR/cpu-sdc.log"
  local rc=0
  # --total-time 是整轮上限；再套一层 timeout 兜住它自己不退出的情况。
  # 无人值守的工具里，任何外部程序都必须有一个"短得住"的上限（§11-44-3）。
  timeout --kill-after=30s "$(( secs + 120 ))" \
    "$exe" --total-time="${secs}s" --output-format=tap > "$log" 2>&1 || rc=$?

  case "$(sdc_verdict "$rc" "$log")" in
    pass)
      result_add "validate_cpu_sdc" "CPU 计算正确性" "$ST_PASS" \
        "全核运行 ${secs} 秒的计算正确性诊断，未发现计算结果错误（这一项查的是\
「算完了但算错了」，压力测试查不到这类问题）" "raw/validate/cpu-sdc.log" ;;
    fail)
      result_add "validate_cpu_sdc" "CPU 计算正确性" "$ST_FAIL" \
        "处理器在计算正确性诊断中出现了错误的运算结果。这类缺陷不会让程序崩溃，\
但会让计算结果悄悄出错，属于处理器硬件缺陷，需更换后复测。" "raw/validate/cpu-sdc.log" ;;
    *)
      result_add "validate_cpu_sdc" "CPU 计算正确性" "$ST_SKIP" \
        "本轮未取得处理器计算正确性诊断的有效结论，本项未做核对。此项不影响整机结论。" \
        "raw/validate/cpu-sdc.log" "self" ;;
  esac
}

# ---------------------------------------------------------------- 显卡专项诊断
#
# dcgm_verdict <退出码> <日志> -> pass | fail | inconclusive
#
# `dcgmi diag` 会逐项打 Pass / Fail / Skip。同上：非零退出不等于卡有问题
# （没装 datacenter 驱动、卡不在支持列表里都会非零），要有明确的 Fail 行才判。
dcgm_verdict() {
  local rc="${1:-1}" log="${2:-}"
  if [[ -f "$log" ]] && grep -aqiE '\bFail\b' "$log" 2>/dev/null; then
    printf 'fail'; return
  fi
  [[ "$rc" == "0" ]] && { printf 'pass'; return; }
  printf 'inconclusive'
}

validate_gpu_diag() {
  (( ${GPU_USABLE:-0} > 0 )) || return 0
  local exe
  if ! exe="$(bench_tool dcgmi)"; then
    result_add "validate_gpu_diag" "显卡专项诊断" "$ST_SKIP" \
      "当前测试环境未包含显卡厂商诊断程序，本项未做核对。此项不影响整机结论。" \
      "" "self"
    return 0
  fi

  info "[VALIDATE] GPU vendor diagnostics on $GPU_USABLE card(s) ..."
  local log="$VALIDATE_LOG_DIR/gpu-diag.log"
  local rc=0
  # -r 2 是"快速"档，约半分钟；-r 3 更全但要几分钟。现场默认取快的那档，
  # 想跑深的在 klburn.conf 里写 VALIDATE_DCGM_LEVEL=3。
  timeout --kill-after=30s 600 \
    "$exe" diag -r "${VALIDATE_DCGM_LEVEL:-2}" > "$log" 2>&1 || rc=$?

  case "$(dcgm_verdict "$rc" "$log")" in
    pass)
      result_add "validate_gpu_diag" "显卡专项诊断" "$ST_PASS" \
        "${GPU_USABLE} 张显卡通过了厂商诊断程序的逐项检查（含显存总线与纠错逻辑，\
这些是满载压测覆盖不到的）" "raw/validate/gpu-diag.log" ;;
    fail)
      result_add "validate_gpu_diag" "显卡专项诊断" "$ST_FAIL" \
        "显卡未通过厂商诊断程序的检查。这是显卡厂商自己的诊断结论，\
属于显卡硬件故障，需更换或返修后复测。" "raw/validate/gpu-diag.log" ;;
    *)
      result_add "validate_gpu_diag" "显卡专项诊断" "$ST_SKIP" \
        "本轮未取得显卡厂商诊断的有效结论（诊断程序与当前驱动或显卡型号不匹配），\
本项未做核对。此项不影响整机结论。" "raw/validate/gpu-diag.log" "self" ;;
  esac
}

# ---------------------------------------------------------------- 汇总入口
# 和基准同一个阶段（PHASE 2/5，机器空闲时）。两个都是可选件，
# 一个都没放的时候整段几秒钟就过去了。
#
# 两项都受本轮**测试范围**管（见 core.sh 的 scope_runs）：
# 只测内存 / 只测硬盘 / 仅导出报告时，这两项整项不跑、也不出结论行。
# 「仅导出报告」那一档跑基准但**不跑这里** —— 这两个各要几分钟，
# 而那一档的整个卖点就是几分钟拿到一份配置清单。
validate_all() {
  validate_init
  scope_runs validate_cpu && validate_cpu_sdc
  scope_runs validate_gpu && validate_gpu_diag
  return 0
}
