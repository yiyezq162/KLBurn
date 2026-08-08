#!/usr/bin/env bash
# KLBurn GPU 模块
#
# 四种情况必须严格区分，不能混：
#   A. lspci 里没有 NVIDIA 设备      -> SKIP「未安装独立显卡」，不是故障
#   B. 有设备且驱动正常              -> 加载驱动并压测，逐卡出数据
#   C. 有设备，驱动也在，但**驱动版本不支持这张卡**
#                                    -> SKIP「驱动与显卡不匹配」，不是故障
#   D. 有设备、驱动认不到、又没有不匹配的证据
#                                    -> FAIL（卡坏了 或 供电/插槽有问题）
#
# C 和 D 的区别是这个模块最要紧的一件事。判据是内核里 NVRM 自己打的原话
# （见 gpu_mismatch_pattern）：驱动明确说"这张卡我不支持"，那是**我们这边**
# 带的驱动版本旧了，跟客户的卡好不好毫无关系 —— 判 FAIL 就是把好卡说成坏卡。
#
# 还有一种：这张盘构建时没有打包显卡驱动 —— 同样是我们环境的限制，标 SKIP。

GPU_PRESENT=0        # lspci 看到的 NVIDIA 显卡数量
GPU_USABLE=0         # nvidia-smi 能正常读到的数量
GPU_PCI_LIST=""
GPU_MISMATCH=0       # 驱动版本与显卡不匹配（内部报告要用）

# ---------------------------------------------------------------- 日志判读
# gpu_burn 日志 -> "<FAULTY卡数> <累计计算错误数>"
#
# ⚠️ 不能用 grep -qi 'error' 判定：gpu_burn 每一行进度都带 "errors: 0"，
#    按关键字匹配会把每一张好卡都判成故障。
#    正常结尾是 "GPU 0: OK"，坏卡是 "GPU 0: FAULTY"。
# 单独抽成纯函数以便脱机回归测试，见 tests/test-log-parsing.sh
gpu_parse_burn_log() {
  local log="$1" faulty err_sum seg
  faulty="$(grep -cE 'GPU[[:space:]]+[0-9]+:[[:space:]]*FAULTY' "$log" 2>/dev/null)"

  # 多卡时 gpu_burn 把每张卡的错误数写在同一行、用 " - " 分隔：
  #     errors: 0 - 14   temps: 74 C - 88 C
  # 所以要取 "errors:" 到 "temps:" 之间的**全部**数字求和，
  # 只匹配第一个数字会漏掉后面几张卡（这正是本函数第一版的 bug）。
  # 错误数是累计值，取最后一行进度即可，不能把每行都加起来。
  seg="$(grep -oE 'errors:[^A-Za-z]*' "$log" 2>/dev/null | tail -1)"
  err_sum="$(printf '%s' "$seg" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')"

  [[ "$faulty"  =~ ^[0-9]+$ ]] || faulty=0
  [[ "$err_sum" =~ ^[0-9]+$ ]] || err_sum=0
  printf '%s %s' "$faulty" "$err_sum"
}

# ---------------------------------------------------------------- 掉卡判据
#
# 1.7.8 现场实测：一张 RTX 5090 在开测第 20 秒掉下 PCIe 总线，整轮依旧判 PASS、
# 零告警。事后翻采集数据，四条证据里有三条就摆在那儿，没有任何一条判定去读：
#
#   证据                        好机器        掉卡那台
#   采样里读得到卡的行           125/125       3/718
#   gpu_burn 进度 proc'd         81 -> 29241   109 -> 109（纹丝不动）
#   内核日志 "GPU lost from bus" 0 行          3019 行
#   gpu_burn 自己的结论          GPU 0: OK     GPU 0: OK   <- 唯一没区分度的
#
# 偏偏当时只读了最后那条。**gpu_burn 的结论只能用来判"算错了"，判不了
# "卡还在不在"** —— 卡掉线之后它会一直重复打印掉线前最后一次成功的缓存统计行
# （错误数当然还是 0），跑完照样打 "GPU 0: OK"、退出码 0。
#
# 两个判据都做成纯函数，好拿真实日志脱机回归，见 tests/test-log-parsing.sh。

# gpu_sample_stats <csv> -> "<总采样行数> <有效采样行数>"
#
# 有效 = 这一行真的读到了一块卡（卡号和温度都是数字）。
#
# ⚠️ 故意用"正面判定"，不去匹配错误文案。读不到设备时的原话各版本不一样
# （No devices were found / GPU is lost / NVIDIA-SMI has failed ...），
# 挨个匹配迟早漏一种，而"这一行是不是一条正常读数"是确定的。
gpu_sample_stats() {
  local csv="${1:-}"
  [[ -f "$csv" ]] || { printf '0 0'; return; }
  awk -F, 'NR>1 && $0 ~ /[^[:space:]]/ {
             t++
             if ($2 ~ /^[0-9]+$/ && $4 ~ /^-?[0-9]+$/) v++
           }
           END { printf "%d %d", t+0, v+0 }' "$csv" 2>/dev/null
}

# gpu_burn_progress_steps <日志> -> 进度计数出现过多少个不同取值
#
# "proc'd: N" 是累计完成的计算批次，正常跑一小时会从两位数涨到几万；
# 卡掉线之后这个数字永远停在掉线前那一刻。
#
# 返回 0 = 日志里根本没有进度行（gpu_burn 换了版本 / 日志被截断）。
# **那种情况一律不判** —— 读不出来是我们这边的能力问题，不是机器的故障。
#
# ⚠️ gpu_burn 的进度是用 \r 原地刷新的，整个日志可能只有"一行"，
#    所以必须先把 \r 换成换行再数。
gpu_burn_progress_steps() {
  local log="${1:-}" n
  [[ -f "$log" ]] || { printf '0'; return; }
  # 不能写成 `... | grep -c . || printf 0`：grep -c 在计数为 0 时既打印 "0"
  # 又返回 1，|| 分支再补一个 0，结果是 "00"（core.sh 里 count_lines 那条注释）。
  n="$(tr '\r' '\n' < "$log" 2>/dev/null \
       | grep -oE "proc'd:[[:space:]]*[0-9]+" \
       | grep -oE '[0-9]+' | sort -un | grep -c .)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# ---------------------------------------------------------------- 驱动/显卡不匹配
# 驱动装了、模块也加载了，但这张卡它不认 —— NVRM 会在内核日志里明说。
# 官方驱动源码里的固定字符串，几代驱动都没变过：
#
#   NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:2b85) installed in this system
#   NVRM: is not supported by the NVIDIA 550.54.14 driver release.
#   NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:1b06) installed in this system
#   NVRM: is not supported by open nvidia.ko.
#   NVRM: No NVIDIA GPU found.
#   NVRM: The NVIDIA probe routine was not called for 1 device(s).
#
# 注意长消息在 dmesg 里是折行的，每一折行都带 "NVRM:" 前缀，所以按行匹配
# "NVRM: 这一行里出现关键短语" 是可靠的，不需要跨行拼。
#
# 抽成纯函数以便脱机回归测试，见 tests/test-log-parsing.sh
gpu_mismatch_pattern() {
  printf '%s' 'NVRM:.*not supported by|NVRM:.*No NVIDIA GPU found|NVRM:.*probe routine was not called|NVRM:.*minimum required driver version'
}

# gpu_scan_driver_mismatch <内核日志文件> -> 命中的 NVRM 原话，最多 5 行；没有则空
gpu_scan_driver_mismatch() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  grep -aE "$(gpu_mismatch_pattern)" "$f" 2>/dev/null | tail -5 || true
}

# gpu_mismatch_devices <内核日志文件> -> 被驱动判为"不支持"的显卡 PCI 地址，去重
# 用来核对"认不到的卡数"能不能被不匹配全部解释掉 —— 解释不掉的部分仍然判 FAIL，
# 不能让一张真坏的卡混在不匹配里蒙混过关。
#
# ⚠️ 地址不在"not supported by"那一行上。NVRM 的长消息是折行打的，
# 卡的地址在**前一行**：
#     NVRM: The NVIDIA GPU 0000:c9:00.0 (PCI ID: 10de:2bb1)
#     NVRM: installed in this system is not supported by the NVIDIA
# 所以要认的是 "The NVIDIA GPU <地址>" 这一行。它正好也能把真故障的日志区分开——
# 卡挂了时 NVRM 打的是 "NVRM: GPU 0000:c9:00.0: RmInitAdapter failed"，
# 没有 "The NVIDIA" 三个词。
gpu_mismatch_devices() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  grep -aE 'NVRM:.*The NVIDIA GPU [0-9a-fA-F]{4}:' "$f" 2>/dev/null \
    | grep -aoE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]' \
    | sort -u || true
}

gpu_detect() {
  info "Detecting NVIDIA GPUs ..."

  # VGA controller / 3D controller 且厂商是 NVIDIA
  GPU_PCI_LIST="$(lspci -nn 2>/dev/null \
    | grep -iE '(VGA compatible controller|3D controller)' \
    | grep -i 'nvidia' || true)"
  GPU_PRESENT="$(printf '%s' "$GPU_PCI_LIST" | grep -c . || true)"

  printf '%s\n' "$GPU_PCI_LIST" > "$RAW_DIR/gpu-lspci.txt"

  # ---------- 情况 A：没有独立显卡 ----------
  if (( GPU_PRESENT == 0 )); then
    result_add "gpu_detect" "GPU" "$ST_SKIP" "未安装独立显卡" ""
    return 0
  fi

  info "Found $GPU_PRESENT NVIDIA GPU(s) on the PCI bus"

  # ---------- 测试环境未包含显卡驱动 ----------
  # 文案给客户看：只说"本次测试环境未包含显卡驱动"，不提这张盘是怎么打包的——
  # 那是我们内部的事，客户看到只会以为机器缺东西。
  if [[ "${INCLUDE_NVIDIA:-0}" != "1" ]]; then
    result_add "gpu_detect" "GPU" "$ST_SKIP" \
      "检测到 ${GPU_PRESENT} 张 NVIDIA 显卡（型号见硬件清单）。\
本次测试环境未包含显卡驱动，因此未做显卡压力测试。此项不影响整机结论。" \
      "raw/gpu-lspci.txt"
    return 0
  fi

  # ---------- 尝试加载驱动 ----------
  modprobe nvidia      >/dev/null 2>&1 || true
  modprobe nvidia_uvm  >/dev/null 2>&1 || true
  sleep 2

  # 说好了带驱动，运行时却找不到管理程序 —— 这是**我们这边环境的问题**，
  # 不是被测机器的问题，绝不能判 FAIL 说人家显卡坏了。
  if ! have nvidia-smi; then
    result_add "gpu_detect" "GPU" "$ST_SKIP" \
      "检测到 ${GPU_PRESENT} 张 NVIDIA 显卡（型号见硬件清单）。\
本次测试环境的显卡驱动未就绪，因此未做显卡压力测试。此项不影响整机结论。" \
      "raw/gpu-lspci.txt"
    return 1
  fi

  capture "gpu-smi-query.txt" nvidia-smi
  capture "gpu-smi-full.txt"  nvidia-smi -q
  # 驱动自身的版本/license，nvidia-smi 起不来时这是唯一还能问出版本号的地方。
  # 只进工程数据，不进客户报告。
  capture "gpu-driver-modinfo.txt" modinfo nvidia

  GPU_USABLE="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c . || true)"

  # 认不全的时候先问一句内核：是卡的问题，还是我们带的驱动不认这张卡？
  local missing=$(( GPU_PRESENT - GPU_USABLE ))
  local mism="" mism_n=0
  if (( missing > 0 )); then
    capture "gpu-modprobe-error.txt" dmesg -T
    mism="$(gpu_scan_driver_mismatch "$RAW_DIR/gpu-modprobe-error.txt")"
    if [[ -n "$mism" ]]; then
      printf '%s\n' "$mism" > "$RAW_DIR/gpu-driver-mismatch.txt"
      mism_n="$(gpu_mismatch_devices "$RAW_DIR/gpu-modprobe-error.txt" | grep -c . || true)"
      [[ "$mism_n" =~ ^[0-9]+$ ]] || mism_n=0
    fi
  fi

  # ---------- 情况 C：驱动版本不支持这张卡 ----------
  # 一张卡都认不到时，只要有 NVRM 的不匹配原话就足够定性（那种情况下
  # NVRM 往往打的是 "No NVIDIA GPU found"，没有逐卡的 PCI 地址可数）。
  # 认到一部分时则要求"不支持的卡数"能盖住"少认的卡数"，盖不住说明
  # 还有卡是因为别的原因没起来 —— 那部分仍然要判 FAIL。
  if [[ -n "$mism" ]] && (( GPU_USABLE == 0 || mism_n >= missing )); then
    GPU_MISMATCH=1
    warn "[GPU] Driver does not support $missing of $GPU_PRESENT card(s) - not a hardware fault."
    local rest=""
    (( GPU_USABLE > 0 )) && rest="其余 ${GPU_USABLE} 张已正常识别并参与测试。"
    result_add "gpu_detect" "GPU" "$ST_SKIP" \
      "检测到 ${GPU_PRESENT} 张 NVIDIA 显卡（型号见硬件清单）。\
本次测试环境的显卡驱动版本与其中 ${missing} 张不匹配，这 ${missing} 张未做显卡测试。\
${rest}此项不影响整机结论。" \
      "raw/gpu-lspci.txt"
    (( GPU_USABLE == 0 )) && return 1
    return 0
  fi

  # ---------- 情况 D：有卡但驱动起不来，且没有不匹配的证据 ----------
  if (( GPU_USABLE == 0 )); then
    result_add "gpu_detect" "GPU" "$ST_FAIL" \
      "PCI 上能看到 ${GPU_PRESENT} 张 NVIDIA 显卡，但驱动加载失败、系统读不到任何一张（显卡、供电或插槽异常）" \
      "raw/gpu-smi-query.txt"
    return 1
  fi

  # ---------- 情况 D 变体：认到的卡比 PCI 上少 ----------
  if (( GPU_USABLE < GPU_PRESENT )); then
    result_add "gpu_detect" "GPU" "$ST_FAIL" \
      "PCI 上有 ${GPU_PRESENT} 张显卡，驱动只认到 ${GPU_USABLE} 张（有卡异常）" \
      "raw/gpu-smi-query.txt"
    return 1
  fi

  # ---------- 情况 B：正常 ----------
  local names
  names="$(nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null | paste -sd'; ' -)"
  result_add "gpu_detect" "GPU" "$ST_PASS" "识别到 ${GPU_USABLE} 张显卡：${names}" "raw/gpu-smi-full.txt"
  return 0
}

# ---------------------------------------------------------------- GPU 采样
GPU_MONITOR_PID=""
gpu_monitor_start() {
  local csv="$RUN_DIR/gpu_metrics.csv"
  echo "time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb" > "$csv"
  (
    while :; do
      local now; now="$(date '+%H:%M:%S')"
      nvidia-smi --query-gpu=index,name,temperature.gpu,power.draw,clocks.sm,utilization.gpu,memory.used \
                 --format=csv,noheader,nounits 2>/dev/null \
        | while IFS= read -r line; do
            # 只压掉逗号周围的空格，不能用 tr -d ' '——那会把显卡型号里的
            # 空格也吃掉，报告图例会变成 NVIDIAGeForceRTX4090
            printf '%s,%s\n' "$now" "$(printf '%s' "$line" | sed 's/[[:space:]]*,[[:space:]]*/,/g')"
          done >> "$csv"
      sleep 5
    done
  ) &
  GPU_MONITOR_PID=$!
}

gpu_monitor_stop() {
  [[ -n "$GPU_MONITOR_PID" ]] || return 0
  kill "$GPU_MONITOR_PID" 2>/dev/null || true
  wait "$GPU_MONITOR_PID" 2>/dev/null || true
  GPU_MONITOR_PID=""
}

# ---------------------------------------------------------------- GPU 压测
#
# 现在和 CPU / 内存并发跑（factory-test.sh 里用 `( gpu_stress ... ) &`），
# 不再自己画进度条 / 打整块横幅，原因见 stress.sh 里 stress_cpu() 顶部注释：
# 三个并发子 shell 同时刷屏会互相打架。
gpu_stress() {
  local secs="$1"

  if (( GPU_USABLE == 0 )); then
    # gpu_detect 已经记过结果了，这里不重复判定
    info "[GPU] No usable GPU - skipping GPU stress."
    return 0
  fi

  if [[ ! -x "$KLB_TOOLS/gpu_burn" ]]; then
    result_add "stress_gpu" "GPU 压力测试" "$ST_SKIP" \
      "本次测试环境未包含显卡满载测试程序，仅采集了显卡型号、显存与驱动版本，\
未做满载压力测试。此项不影响整机结论。" ""
    return 0
  fi

  info "[GPU] gpu_burn on $GPU_USABLE GPU(s), sampling temp/power every 5s, $(fmt_dur "$secs")"
  gpu_monitor_start

  ( cd "$KLB_TOOLS" && ./gpu_burn "$secs" ) \
    > "$STRESS_LOG_DIR/gpu-burn.log" 2>&1 &
  local pid=$!
  local rc=0
  wait "$pid" || rc=$?

  gpu_monitor_stop

  # 逐卡统计峰值
  local csv="$RUN_DIR/gpu_metrics.csv"
  local idx tmax pmax
  local overheat=0 hot=0
  # ⚠️ 卡号一定要先过滤成纯数字再排序。卡掉线之后这一列里是
  # "No devices were found" 这样的整句错误文案，而 `sort -un` 会把它当成 0 ——
  # 于是它和真正的 0 号卡撞在一起被去重，留下哪一个纯看运气。
  for idx in $(awk -F, 'NR>1 && $2 ~ /^[0-9]+$/ {print $2}' "$csv" | sort -un); do
    tmax="$(awk -F, -v i="$idx" 'NR>1 && $2==i && $4!="" {if($4+0>m) m=$4+0} END{printf "%d", m}' "$csv")"
    pmax="$(awk -F, -v i="$idx" 'NR>1 && $2==i && $5!="" {if($5+0>m) m=$5+0} END{printf "%d", m}' "$csv")"
    metric_add "gpu${idx}" "峰值温度" "${tmax}"
    metric_add "gpu${idx}" "峰值功耗W" "${pmax}"
    (( tmax >= GPU_TEMP_FAIL )) && overheat=$(( overheat + 1 ))
    (( tmax >= GPU_TEMP_WARN && tmax < GPU_TEMP_FAIL )) && hot=$(( hot + 1 ))
  done

  local burnlog="$STRESS_LOG_DIR/gpu-burn.log"
  local faulty err_sum
  read -r faulty err_sum < <(gpu_parse_burn_log "$burnlog")
  metric_add "gpu" "计算错误总数" "$err_sum"
  metric_add "gpu" "FAULTY卡数" "$faulty"

  local detail="${GPU_USABLE} 张显卡满载 $(fmt_dur "$secs")"

  # ---------------- 掉卡：排在所有判据最前面 ----------------
  # 卡都不在了，gpu_burn 报的"0 个错误"、采样算出来的"峰值温度 36°C /
  # 峰值功耗 67W"全都只是掉线前那两三个空载读数，一个都不能拿来下结论。
  local samp_total samp_valid samp_lost lost_pct=0
  read -r samp_total samp_valid < <(gpu_sample_stats "$csv")
  samp_lost=$(( samp_total - samp_valid ))
  (( samp_total > 0 )) && lost_pct=$(( samp_lost * 100 / samp_total ))
  metric_add "gpu" "有效采样" "${samp_valid}/${samp_total}"

  # 压测跑够 1 分钟、日志里确实有进度行、而进度自始至终只有一个取值
  # = 卡在中途停止计算了。跑得太短、或读不出进度，一律不判。
  local steps stalled=0
  steps="$(gpu_burn_progress_steps "$burnlog")"
  (( secs >= 60 && steps == 1 )) && stalled=1

  # 再直接问一次驱动：这会儿还认得到几张卡
  #
  # 必须带 timeout：卡卡死在总线上的时候 nvidia-smi 是会一直挂着不返回的，
  # 而这里已经是压测收尾阶段，挂住就等于整轮测试出不了报告。
  local usable_now
  usable_now="$(timeout 60 nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c .)"
  [[ "$usable_now" =~ ^[0-9]+$ ]] || usable_now="$GPU_USABLE"

  # 采样太少（短测/冒烟）时不拿比例说事，否则几行采样就能凑出 100%
  local enough=0; (( samp_total >= 12 )) && enough=1
  local gone=0
  (( enough == 1 && lost_pct >= 50 ))  && gone=1   # 过半采样读不到卡
  (( usable_now < GPU_USABLE ))        && gone=1   # 测完比开测时少认了卡
  (( stalled == 1 && lost_pct >= 10 )) && gone=1   # 进度停滞且伴随采样丢失

  if (( gone == 1 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_FAIL" \
      "显卡在压力测试过程中从系统中掉线：全程 ${samp_total} 次读数里有 ${samp_lost} 次\
已经读不到显卡（测试结束时系统只认到 ${usable_now} 张，开始测试时是 ${GPU_USABLE} 张）。\
掉线之后显卡不再参与运算，因此本项记录的温度与功耗峰值只反映掉线前的空载状态，\
不能代表满载表现。这属于显卡本身、供电或插槽异常，需检修后复测；$detail" \
      "raw/stress/gpu-burn.log"
  elif (( enough == 1 && lost_pct >= 10 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_WARN" \
      "显卡在压力测试期间有 ${samp_lost}/${samp_total} 次读数取不到数据（约 ${lost_pct}%），\
读数期间未发现计算错误。显卡可能存在间歇性掉线或复位，建议出货前复查供电与插槽；$detail" \
      "raw/stress/gpu-burn.log"
  elif (( faulty > 0 || err_sum > 0 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_FAIL" \
      "满载测试报告 ${faulty} 张卡状态异常、累计 ${err_sum} 处计算校验错误（显卡故障）；$detail" \
      "raw/stress/gpu-burn.log"
  elif oom_killed "$rc"; then
    # 和内存那边同样的道理：并发跑的内存压测把系统内存吃光时，OOM killer
    # 会连坐收掉别的大进程，gpu_burn 首当其冲。这跟显卡好不好毫无关系，
    # 判 FAIL 就是误杀。（oom_killed 定义在 lib/stress.sh）
    result_add "stress_gpu" "GPU 压力测试" "$ST_WARN" \
      "本次 GPU 压测未能跑完整个时长：测试系统在运行过程中可用内存不足，\
测试程序被系统回收。这是测试环境的容量限制，**不是显卡故障** —— \
在此之前已完成的计算校验未发现任何错误。${detail}" "raw/stress/gpu-burn.log"
  elif (( rc != 0 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_FAIL" \
      "显卡满载测试程序异常退出（退出码 $rc）；$detail" "raw/stress/gpu-burn.log"
  elif (( overheat > 0 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_FAIL" \
      "有 ${overheat} 张卡温度超过 ${GPU_TEMP_FAIL}°C（散热异常）；$detail" "raw/stress/gpu-burn.log"
  elif (( hot > 0 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_WARN" \
      "有 ${hot} 张卡温度偏高（超过 ${GPU_TEMP_WARN}°C）；$detail" "raw/stress/gpu-burn.log"
  else
    result_add "stress_gpu" "GPU 压力测试" "$ST_PASS" "无计算错误，温度正常；$detail" "raw/stress/gpu-burn.log"
  fi
}
