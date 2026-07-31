#!/usr/bin/env bash
# KLBurn GPU 模块
#
# 三种情况必须严格区分，不能混：
#   A. lspci 里没有 NVIDIA 设备      -> SKIP「未安装独立显卡」，不是故障
#   B. 有设备且驱动正常              -> 加载驱动并压测，逐卡出数据
#   C. 有设备但驱动加载不起来        -> FAIL（卡坏了 或 驱动/供电/插槽有问题）
#
# 另外还有一种：精简版 ISO 压根没打包驱动 —— 这是构建选择，不是硬件问题，
# 所以标 SKIP 并写明原因，不能算 FAIL。

GPU_PRESENT=0        # lspci 看到的 NVIDIA 显卡数量
GPU_USABLE=0         # nvidia-smi 能正常读到的数量
GPU_PCI_LIST=""

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
  # 文案给客户看：只说"本次测试环境未包含显卡驱动"，不提测试盘/精简版/构建选择——
  # 那是我们内部怎么打包的事，客户看到只会以为机器缺东西。
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

  GPU_USABLE="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c . || true)"

  # ---------- 情况 C：有卡但驱动起不来 ----------
  if (( GPU_USABLE == 0 )); then
    capture "gpu-modprobe-error.txt" dmesg -T
    result_add "gpu_detect" "GPU" "$ST_FAIL" \
      "PCI 上能看到 ${GPU_PRESENT} 张 NVIDIA 显卡，但驱动加载失败 / nvidia-smi 读不到任何设备（显卡、供电或插槽异常）" \
      "raw/gpu-smi-query.txt"
    return 1
  fi

  # ---------- 情况 C 变体：认到的卡比 PCI 上少 ----------
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
  for idx in $(awk -F, 'NR>1{print $2}' "$csv" | sort -un); do
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
  if (( faulty > 0 || err_sum > 0 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_FAIL" \
      "gpu_burn 报告 ${faulty} 张卡 FAULTY、累计 ${err_sum} 处计算校验错误（显卡故障）；$detail" \
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
      "gpu_burn 异常退出（退出码 $rc）；$detail" "raw/stress/gpu-burn.log"
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
