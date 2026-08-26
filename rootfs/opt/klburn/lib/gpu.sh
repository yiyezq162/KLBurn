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
GPU_TEMP_FROM_CARD=0 # 温度判据取自显卡自己上报的限值（0 = 用的静态兜底）
# 逐卡的满载运行读数，压测过程中攒起来，收尾时统一出一条结论。
# 每项 "卡号|最低频率|平均频率|峰值风扇%|距温度上限余量|平均功耗W"，读不到的位置是 "-"。
GPU_LOAD_ROWS=()

# ---------------------------------------------------------------- 显卡自己的温度限值
#
# **别凭空写一个"显卡多少度算高"。**GPU_TEMP_WARN 原来钉死 83°C，而 1.9.2 现场
# 那张 RTX 4090 自己报的最高工作温度就是 84°C —— 一张跑在设计工作点上的好卡，
# 每一轮都要刷一条"温度偏高"的黄。每一代卡、每一种散热形态（涡轮 / 被动 / 水冷）
# 的限值都不一样，这个数只有卡自己知道，问它就是了。BMC 传感器那边早就是这么做的。
#
# `nvidia-smi -q` 的温度段有两种写法，都要认：
#
#   绝对值（数据中心卡 / 老驱动）      余量值（Ada 起改成了 T.Limit 写法）
#     GPU Current Temp      : 33 C       GPU Current Temp           : 43 C
#     GPU Shutdown Temp     : 92 C       GPU T.Limit Temp           : 41 C
#     GPU Slowdown Temp     : 89 C       GPU Shutdown T.Limit Temp  : -7 C
#     GPU Max Operating Temp: 85 C       GPU Slowdown T.Limit Temp  : -2 C
#                                        GPU Max Operating T.Limit Temp : 0 C
#
# 余量那种给的是"离限值还差几度"：基准点 = 当前温度 + T.Limit，
# 某个限值的绝对温度 = 基准点 - 它自己那个 T.Limit 值。
# 上面这张实测的 4090：基准 43+41 = 84，降频 84-(-2) = 86，关机 84-(-7) = 91。
# 也就是说它满载压到 84°C 正是厂家标的工作点，不是"温度偏高"。
#
# ⚠️ 算出来的数必须过一遍常识关（60~130 且关机温度高于降频温度）。驱动/固件
#    给的数不对时宁可退回静态兜底，也绝不能拿一个 20°C 的"降频阈值"去判每张卡。
#
# gpu_temp_limits <nvidia-smi -q 的输出文件> <卡号> -> "<降频温度> <关机温度>"
#   读不出来什么都不输出（调用方退回静态兜底）
gpu_temp_limits() {
  local f="${1:-}" idx="${2:-0}"
  [[ -s "$f" ]] || return 0
  awk -v want="$idx" '
    BEGIN { n = -1; cur = 0 }
    # 每张卡一段，段头是顶格的 "GPU 00000000:27:00.0"（缩进行都是段内内容）
    /^GPU [0-9A-Fa-f]+:/ { n++; cur = (n == want + 0); next }
    !cur { next }
    {
      line = $0; sub(/\r$/, "", line)
      i = index(line, ":")
      if (i == 0) next
      key = substr(line, 1, i - 1)
      val = substr(line, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      sub(/[ \t]*[Cc][ \t]*$/, "", val)          # 去掉单位
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val !~ /^-?[0-9]+$/) next               # N/A 之类一律让开
      v[key] = val + 0
    }
    END {
      slow = ""; shut = ""
      if ("GPU Slowdown Temp" in v) slow = v["GPU Slowdown Temp"]
      if ("GPU Shutdown Temp" in v) shut = v["GPU Shutdown Temp"]
      if ((slow == "" || shut == "") \
          && ("GPU Current Temp" in v) && ("GPU T.Limit Temp" in v)) {
        ref = v["GPU Current Temp"] + v["GPU T.Limit Temp"]
        if (slow == "" && ("GPU Slowdown T.Limit Temp" in v))
          slow = ref - v["GPU Slowdown T.Limit Temp"]
        if (shut == "" && ("GPU Shutdown T.Limit Temp" in v))
          shut = ref - v["GPU Shutdown T.Limit Temp"]
      }
      if (slow == "" || shut == "") exit
      if (slow < 60 || slow > 130) exit
      if (shut < 60 || shut > 130) exit
      if (shut <= slow) exit
      printf "%d %d", slow, shut
    }
  ' "$f" 2>/dev/null
}

# 把温度判据换成"这几张卡自己报的限值"。
#
# ⚠️ 全局只有 GPU_TEMP_WARN / GPU_TEMP_FAIL 这一对数：压测判定、报告里曲线图的
#    图注、现场界面的配色三处共用它。所以多卡时取**最保守的一组**（各取最小），
#    分卡去判就会出现"图注写 86、判定按 91"这种同一页自相矛盾的报告。
gpu_resolve_temp_thresholds() {
  local f="$RAW_DIR/gpu-smi-full.txt"
  local idx slow shut w="" ff=""
  for (( idx = 0; idx < GPU_USABLE; idx++ )); do
    read -r slow shut < <(gpu_temp_limits "$f" "$idx")
    [[ "$slow" =~ ^[0-9]+$ && "$shut" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$w"  ]] || (( slow < w  )); then w="$slow";  fi
    if [[ -z "$ff" ]] || (( shut < ff )); then ff="$shut"; fi
  done
  if [[ -z "$w" || -z "$ff" ]]; then
    dbg "[GPU] cards report no usable temperature limits - keeping defaults ${GPU_TEMP_WARN}/${GPU_TEMP_FAIL}"
    return 0
  fi
  GPU_TEMP_WARN="$w"
  GPU_TEMP_FAIL="$ff"
  GPU_TEMP_FROM_CARD=1
  info "[GPU] temperature limits read from the cards: warn ${w}C / fail ${ff}C"
}

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

# ---------------------------------------------------------------- 满载运行读数
# gpu_load_stats <gpu_metrics.csv> <卡号>
#   -> "<最低SM频率> <平均SM频率> <峰值风扇%> <距温度上限最小余量> <平均功耗W>"
#
# 列序（表头 GPU_CSV_HEADER 在 gpu_monitor_start 上面）：
#   1 time  2 index  3 name  4 temp_c  5 power_w  6 clock_sm_mhz
#   7 util_pct  8 mem_used_mb  9 fan_pct  10 temp_tlimit_c
#   11 pci_bus_id  12 serial  13 vbios_version  14 util_mem_pct
#   15~19 ECC（SRAM 可纠正 / SRAM 奇偶 / SRAM SEC-DED / DRAM 可纠正 / DRAM 不可纠正）
#   20 sw_thermal_slowdown
# 本函数只用前十列 —— 那十列的位置是钉死的，后面加多少列都不影响。
#
# ⚠️ **要跳过每张卡的前两个采样点。**采样器和 gpu_burn 是同一刻起来的，
#    头一两个点采到的还是空载降频后的频率（实测几百 MHz），算进去的话
#    报告上会凭空多出一条"满载最低频率 210MHz"，看着像严重降频。
#    这和 stress.sh 里 phase_freq_stats 是同一个坑，同一个解法。
#
# ⚠️⚠️ **跳几个点是按"这张卡的第几次采样"算的，而且最低/平均/平均功耗
#    三样必须一起跳。**1.9.2 之前只有最低频率跳、两个平均值从头加，于是
#    那句结论里可能出现"平均频率 2686MHz（最低 2688MHz）"——最低的比平均的
#    还高。两个数都没算错，是两个口径；但客户读到的是"这报告算错了"，
#    而一份被怀疑算错了的报告，后面每个数字都要重新解释一遍。
#    同一组样本算出来的 min <= avg 是**结构上**成立的，不必拿断言去兜。
#
# ⚠️ 读不到的列（老驱动没有 tlimit、被动散热的卡没有风扇）输出 **`-`**，
#    绝不能当成 0 —— "风扇转速 0%" 和 "这张卡没有风扇" 是两件事。
#    也不能输出空串：五个值是靠 `read -r a b c d e` 按位取的，
#    空串会让后面的值整体左移一位（"风扇转速" 那一格显示出功耗）。
gpu_load_stats() {
  local csv="${1:-}" idx="${2:-}"
  [[ -f "$csv" ]] || { printf -- '- - - - -'; return; }
  awk -F, -v i="$idx" '
    # 按**这张卡的第几次采样**存，频率和功耗共用同一个下标 —— 跳前两个点的
    # 时候两样才会一起跳。风扇取峰值、距温度上限取最小余量，这两个是极值，
    # 跳不跳都不会自相矛盾，所以照旧边读边算。
    NR > 1 && $2 == i {
      n++
      if ($6 ~ /^[0-9]+$/) { chas[n] = 1; cval[n] = $6 + 0 }
      if ($5 ~ /^[0-9.]+$/) { phas[n] = 1; pval[n] = $5 + 0 }
      if ($9  ~ /^[0-9]+$/ && ($9 + 0 > fan || fanseen == 0)) { fan = $9 + 0; fanseen = 1 }
      if ($10 ~ /^-?[0-9]+$/ && (tlseen == 0 || $10 + 0 < tl)) { tl = $10 + 0; tlseen = 1 }
    }
    END {
      cmin = ""; cavg = ""; pavg = ""
      start = (n > 2 ? 3 : 1)
      for (k = start; k <= n; k++) {
        if (chas[k]) {
          if (cmin == "" || cval[k] < cmin) cmin = cval[k]
          csum += cval[k]; cn++
        }
        if (phas[k]) { psum += pval[k]; pn++ }
      }
      if (cn > 0) cavg = int(csum / cn + 0.5)
      if (pn > 0) pavg = int(psum / pn + 0.5)
      printf "%s %s %s %s %s",
             (cmin == "" ? "-" : cmin), (cavg == "" ? "-" : cavg),
             (fanseen ? fan : "-"), (tlseen ? tl : "-"),
             (pavg == "" ? "-" : pavg)
    }' "$csv" 2>/dev/null
}

# 上面那五个值里，哪些是真读到了。**别把 "-" 当成 0 写进报告。**
gpu_stat_ok() { [[ -n "${1:-}" && "$1" != "-" ]]; }

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

  # 温度判据换成卡自己报的限值。**必须排在这里** —— meta.json / 报告图注 /
  # 现场界面配色都读同一对变量，晚于它们定下来就来不及了。
  gpu_resolve_temp_thresholds

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
#
# 采哪几列：**先探一次再定**。
#
# nvidia-smi 的行为是"**只要有一个字段不认，整条查询直接报错退出**"，而不是
# 每个驱动每张卡都认全部字段：老驱动不认 `temperature.gpu.tlimit`、被动散热的
# 数据中心卡没有 `fan.speed`、消费级卡（5090 这类）没有 ECC 那五列、
# `clocks_event_reasons.*` 在老驱动上叫 `clocks_throttle_reasons.*`。
# 为了多采几列而写死一条长查询，代价是在那些机器上**一行采样都拿不到**，
# 然后报告里显卡温度/功耗曲线整个消失。所以按"全 -> 少 -> 最少"逐档探，
# 第一档能跑通就用第一档。
#
# ⚠️⚠️ **CSV 列序固定、列只增不改，而且少采到的列不能让别的列整体左移。**
#
# 1.10.2 之前这道阶梯只从**尾巴**上砍，"少采到的列一定在最后"，所以在末尾
# 补空列就够了。现在字段多了，砍的顺序也不再是简单的后缀 ——
# `clocks_event_reasons` 换成老名字 `clocks_throttle_reasons` 是**同一列**的
# 两种写法，按位置拼就会把 ECC 的数字写进风扇转速那一格。
# 改成**按字段名定位**：每个字段占 CSV 的哪一列写死在 gpu_field_col() 里，
# 采样行由 awk 按这张表往对应格子里填，没采到的格子留空。
#
# 列号一旦定下就不许改：lib/ui.sh 的仪表盘和 gpu_load_stats 都是按列号读
# 前十列的，盘外还有人拿旧 run-dir 重新出报告。
GPU_CSV_HEADER="time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb,fan_pct,temp_tlimit_c,pci_bus_id,serial,vbios_version,util_mem_pct,ecc_ce_sram,ecc_ue_sram_parity,ecc_ue_sram_secded,ecc_ce_dram,ecc_ue_dram,sw_thermal_slowdown"
GPU_CSV_COLS=20

# 阶梯上各段。第 1~10 列那几段的位置不许动（见上面）。
GPU_Q_BASE="index,name,temperature.gpu,power.draw,clocks.sm,utilization.gpu,memory.used"
GPU_Q_ID="pci.bus_id,serial,vbios_version,utilization.memory"
GPU_Q_FAN="fan.speed"
GPU_Q_TL="temperature.gpu.tlimit"
GPU_Q_SLOW="clocks_event_reasons.sw_thermal_slowdown"
GPU_Q_SLOW_OLD="clocks_throttle_reasons.sw_thermal_slowdown"
GPU_Q_ECC="ecc.errors.corrected.volatile.sram,ecc.errors.uncorrected.volatile.sram.parity,ecc.errors.uncorrected.volatile.sram.secded,ecc.errors.corrected.volatile.dram,ecc.errors.uncorrected.volatile.dram"

# gpu_field_col <nvidia-smi 字段名> -> 它在 gpu_metrics.csv 里的列号（1 起）
#
# 认不出来的字段给 0；调用方碰到 0 会把整条查询丢掉 —— 宁可少采一列，
# 也不能把一个值填进不知道是哪一格的位置。
gpu_field_col() {
  case "${1:-}" in
    index)                  printf '2'  ;;
    name)                   printf '3'  ;;
    temperature.gpu)        printf '4'  ;;
    power.draw)             printf '5'  ;;
    clocks.sm)              printf '6'  ;;
    utilization.gpu)        printf '7'  ;;
    memory.used)            printf '8'  ;;
    fan.speed)              printf '9'  ;;
    temperature.gpu.tlimit) printf '10' ;;
    pci.bus_id)             printf '11' ;;
    serial)                 printf '12' ;;
    vbios_version)          printf '13' ;;
    utilization.memory)     printf '14' ;;
    ecc.errors.corrected.volatile.sram)          printf '15' ;;
    ecc.errors.uncorrected.volatile.sram.parity) printf '16' ;;
    ecc.errors.uncorrected.volatile.sram.secded) printf '17' ;;
    ecc.errors.corrected.volatile.dram)          printf '18' ;;
    ecc.errors.uncorrected.volatile.dram)        printf '19' ;;
    # 同一列的新旧两种写法：CUDA 12.x 起叫 event，之前叫 throttle
    clocks_event_reasons.sw_thermal_slowdown)    printf '20' ;;
    clocks_throttle_reasons.sw_thermal_slowdown) printf '20' ;;
    *) printf '0' ;;
  esac
}

# gpu_field_colmap <逗号分隔的字段列表> -> 逗号分隔的列号，和字段一一对应
# 任何一个字段认不出来就整条失败（返回 1），调用方跳过那一档。
gpu_field_colmap() {
  local list="${1:-}" f c out=""
  local IFS=,
  for f in $list; do
    c="$(gpu_field_col "$f")"
    [[ "$c" == "0" ]] && return 1
    out="${out}${out:+,}${c}"
  done
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

gpu_query_fields() {
  local q
  for q in "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN,$GPU_Q_TL,$GPU_Q_SLOW,$GPU_Q_ECC" \
           "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN,$GPU_Q_TL,$GPU_Q_SLOW_OLD,$GPU_Q_ECC" \
           "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN,$GPU_Q_TL,$GPU_Q_ECC" \
           "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN,$GPU_Q_TL,$GPU_Q_SLOW" \
           "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN,$GPU_Q_TL,$GPU_Q_SLOW_OLD" \
           "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN,$GPU_Q_TL" \
           "$GPU_Q_BASE,$GPU_Q_ID,$GPU_Q_FAN" \
           "$GPU_Q_BASE,$GPU_Q_ID" \
           "$GPU_Q_BASE"; do
    gpu_field_colmap "$q" >/dev/null || continue
    if timeout 20 nvidia-smi --query-gpu="$q" --format=csv,noheader,nounits \
         >/dev/null 2>&1; then
      printf '%s' "$q"; return 0
    fi
  done
  printf '%s' "$GPU_Q_BASE"
}

GPU_MONITOR_PID=""
# gpu_query_each_card <字段列表> -> 原始 csv 行 / 掉线错误行
#
# 在 595.84 + RTX 5090 的真机上，压测期间一次查询整组 GPU 的长字段列表
# 只返回 GPU0；空闲时的 nvidia-smi 清单仍然显示 8 张卡，所以探测阶段看不出
# 问题。每张卡单独指定 -i，并行发起查询，既保证每张卡都有机会落一行，
# 又不把 8 次查询串起来拖长 5 秒采样周期。
#
# 掉线卡的错误原文保留为短行，不补成完整 CSV；ui.sh / gpu_sample_stats
# 依靠列数不足识别掉线，不能把旧读数继续画在屏幕上。
gpu_query_each_card() {
  local q="${1:-}" tmp idx pid
  [[ "${GPU_USABLE:-0}" =~ ^[1-9][0-9]*$ ]] || return 0
  tmp="$(mktemp -d "${RUN_DIR:-/tmp}/.gpu-query.XXXXXX" 2>/dev/null)" || return 1
  local pids=()
  for (( idx = 0; idx < GPU_USABLE; idx++ )); do
    (
      timeout 4 nvidia-smi -i "$idx" --query-gpu="$q" \
        --format=csv,noheader,nounits > "$tmp/$idx" 2>&1 || true
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  for (( idx = 0; idx < GPU_USABLE; idx++ )); do
    if [[ -s "$tmp/$idx" ]]; then
      cat "$tmp/$idx"
    else
      printf 'No devices were found\n'
    fi
  done
  rm -rf "$tmp"
}

gpu_monitor_start() {
  local csv="$RUN_DIR/gpu_metrics.csv"
  local q map
  q="$(gpu_query_fields)"
  map="$(gpu_field_colmap "$q")" || map=""
  dbg "gpu sampler fields: $q"
  dbg "gpu sampler colmap: $map"
  echo "$GPU_CSV_HEADER" > "$csv"
  (
    while :; do
      local now; now="$(date '+%H:%M:%S')"
      gpu_query_each_card "$q" \
        | while IFS= read -r line; do
            # 只压掉逗号周围的空格，不能用 tr -d ' '——那会把显卡型号里的
            # 空格也吃掉，报告图例会变成 NVIDIAGeForceRTX4090
            printf '%s' "$line" | sed 's/[[:space:]]*,[[:space:]]*/,/g'
          done \
        | awk -F, -v OFS=, -v n="$GPU_CSV_COLS" -v t="$now" -v map="$map" '
            BEGIN { m = split(map, mc, ",") }
            {
              # ⚠️ 掉卡时 nvidia-smi 往 stdout 吐的是一整句错误文案
              #    （"No devices were found"）。**绝不能把它补成 20 列**：
              #    lib/ui.sh 的仪表盘正是靠"这一行凑不够列数"认出卡掉了的，
              #    补满之后屏幕上会一直挂着掉线前那一刻的温度和功耗，
              #    而且没有任何提示（1.8.0 现场就是这样）。
              #    原样留档 —— 时间戳还在，事后照样查得出是哪一刻掉的。
              if (NF < 2 || $1 !~ /^[0-9]+$/) { print t "," $0; next }
              for (i = 1; i <= n; i++) o[i] = ""
              o[1] = t
              for (i = 1; i <= m && i <= NF; i++) o[mc[i]] = $i
              s = o[1]
              for (i = 2; i <= n; i++) s = s OFS o[i]
              print s
            }' \
        >> "$csv"
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

# ---------------------------------------------------------------- 张量核模式
# gpu_burn 的 `-tc` 走 cublasGemmEx，压的是张量核，比默认的 FP32/FP64 更接近
# 真实训练负载，温度和功耗也更高。客户验收单点名要这一档。
#
# ⚠️⚠️ **必须先探一次再用，探不通就退回默认模式。**
# 没有张量核的老卡、或者盘里这版 gpu_burn 不认这个参数时，`-tc` 会让它
# 非零退出 —— 而下面 gpu_stress 把"gpu_burn 异常退出"判成显卡故障。
# 那就是拿我们这边的能力缺失去判客户的卡坏了，二号红线。
#
# 探测跑 5 秒。光看退出码不够：有的版本认不出参数会打一段用法然后**正常退出**，
# 所以还要求日志里真的出现逐卡结论行（"GPU 0: OK"）。
GPU_BURN_TC=0
gpu_burn_probe_tc() {
  GPU_BURN_TC=0
  [[ -x "$KLB_TOOLS/gpu_burn" ]] || return 0
  local log="$STRESS_LOG_DIR/gpu-burn-tc-probe.log"
  if ( cd "$KLB_TOOLS" && timeout 300 ./gpu_burn -tc 5 ) > "$log" 2>&1; then
    grep -qiE 'GPU +[0-9]+: +(OK|FAULTY)' "$log" && GPU_BURN_TC=1
  fi
  dbg "gpu_burn -tc supported: $GPU_BURN_TC"
  return 0
}

# ---------------------------------------------------------------- 热降频事件
# gpu_slowdown_samples <gpu_metrics.csv> <卡号> -> "<Active 的采样数> <有效采样数>"
#
# 第 20 列是 nvidia-smi 的 `clocks_event_reasons.sw_thermal_slowdown`，
# 取值是 "Active" / "Not Active"（老驱动那边字段叫 clocks_throttle_reasons，
# 取值一样）。读不到那一列时两个数都是 0 —— 调用方据此跳过，
# **不能当成"没有降频"**（读不出来的标记不是内容）。
gpu_slowdown_samples() {
  local csv="${1:-}" idx="${2:-}"
  [[ -f "$csv" ]] || { printf '0 0'; return; }
  awk -F, -v i="$idx" '
    NR > 1 && $2 == i && $20 != "" {
      n++
      if (tolower($20) ~ /^active$/) a++
    }
    END { printf "%d %d", a+0, n+0 }' "$csv" 2>/dev/null
}

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

  gpu_burn_probe_tc

  local mode="默认（FP32/FP64）"
  (( GPU_BURN_TC == 1 )) && mode="张量核（-tc）"
  info "[GPU] gpu_burn on $GPU_USABLE GPU(s) [$mode], sampling every 5s, $(fmt_dur "$secs")"
  gpu_monitor_start

  # 数组在 `set -u` 下空展开是个老坑，这里干脆写成两条，读起来也更直白。
  if (( GPU_BURN_TC == 1 )); then
    ( cd "$KLB_TOOLS" && ./gpu_burn -tc "$secs" ) \
      > "$STRESS_LOG_DIR/gpu-burn.log" 2>&1 &
  else
    ( cd "$KLB_TOOLS" && ./gpu_burn "$secs" ) \
      > "$STRESS_LOG_DIR/gpu-burn.log" 2>&1 &
  fi
  local pid=$!
  local rc=0
  wait "$pid" || rc=$?

  gpu_monitor_stop

  # 逐卡统计峰值
  local csv="$RUN_DIR/gpu_metrics.csv"
  local idx tmax pmax
  local overheat=0 hot=0
  local clk_min clk_avg fan_max tl_min pow_avg slow_act slow_n
  # ⚠️ 卡号一定要先过滤成纯数字再排序。卡掉线之后这一列里是
  # "No devices were found" 这样的整句错误文案，而 `sort -un` 会把它当成 0 ——
  # 于是它和真正的 0 号卡撞在一起被去重，留下哪一个纯看运气。
  for idx in $(awk -F, 'NR>1 && $2 ~ /^[0-9]+$/ {print $2}' "$csv" | sort -un); do
    tmax="$(awk -F, -v i="$idx" 'NR>1 && $2==i && $4!="" {if($4+0>m) m=$4+0} END{printf "%d", m}' "$csv")"
    pmax="$(awk -F, -v i="$idx" 'NR>1 && $2==i && $5!="" {if($5+0>m) m=$5+0} END{printf "%d", m}' "$csv")"
    metric_add "gpu${idx}" "峰值温度" "${tmax}"
    metric_add "gpu${idx}" "峰值功耗W" "${pmax}"
    # 满载运行的另外四个读数。它们回答的是"这张卡有没有被压到该有的状态"——
    # 温度好看未必是好事：频率掉下来了、功耗上不去，温度当然低。
    read -r clk_min clk_avg fan_max tl_min pow_avg < <(gpu_load_stats "$csv" "$idx")
    gpu_stat_ok "$clk_min" && metric_add "gpu${idx}" "满载最低频率MHz" "$clk_min"
    gpu_stat_ok "$clk_avg" && metric_add "gpu${idx}" "满载平均频率MHz" "$clk_avg"
    gpu_stat_ok "$pow_avg" && metric_add "gpu${idx}" "满载平均功耗W"   "$pow_avg"
    gpu_stat_ok "$fan_max" && metric_add "gpu${idx}" "峰值风扇转速%"   "$fan_max"
    # ⚠️ 这一列（nvidia-smi 的 temperature.gpu.tlimit）是"离**厂家标的温度上限**
    #    还差几度"，不是"离降频还差几度"：同一张 4090 的 -q 输出里，tlimit 归零
    #    的那个点是 Max Operating Temp（84°C），降频还要再高 2°C。原来标成
    #    「距降频阈值」，于是一张跑在设计工作点上的卡在报告里写着"距降频 0°C"。
    gpu_stat_ok "$tl_min"  && metric_add "gpu${idx}" "距温度上限最小余量" "$tl_min"
    # 满载期间有多少个采样点上驱动自己报了"因过热在降频"。
    # ⚠️ 只在真的采到这一列时才记：采不到（老驱动 / 字段被砍掉那几档）
    #    和"一次都没降频"是两回事，记成 0 就是替驱动说了一句它没说过的话。
    read -r slow_act slow_n < <(gpu_slowdown_samples "$csv" "$idx")
    local slow="-"
    if (( slow_n > 0 )); then
      slow="${slow_act}/${slow_n}"
      metric_add "gpu${idx}" "热降频采样占比" "$slow"
    fi
    # 逐卡攒起来，压测判定完之后统一出一条"满载运行状态"的结论
    GPU_LOAD_ROWS+=("${idx}|${clk_min}|${clk_avg}|${fan_max}|${tl_min}|${pow_avg}|${slow}")
    (( tmax >= GPU_TEMP_FAIL )) && overheat=$(( overheat + 1 ))
    (( tmax >= GPU_TEMP_WARN && tmax < GPU_TEMP_FAIL )) && hot=$(( hot + 1 ))
  done

  local burnlog="$STRESS_LOG_DIR/gpu-burn.log"
  local faulty err_sum
  read -r faulty err_sum < <(gpu_parse_burn_log "$burnlog")
  metric_add "gpu" "计算错误总数" "$err_sum"
  metric_add "gpu" "FAULTY卡数" "$faulty"

  # 说清这一轮压的是哪一档：张量核那一档负载更重、温度和功耗都更高，
  # 两份报告的数字放在一起比时，不写明档位就没法比。
  local detail="${GPU_USABLE} 张显卡满载 $(fmt_dur "$secs")"
  (( GPU_BURN_TC == 1 )) && detail="${detail}（张量核满载）"
  # 温度那两条结论里要说清楚这个度数是谁定的 —— 报告里出现一个数，
  # 看的人第一个问题就是"这条线哪来的"。
  local tsrc="（该温度取自显卡自身上报的限值）"
  (( GPU_TEMP_FROM_CARD == 1 )) || tsrc=""

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
      "有 ${overheat} 张卡温度达到 ${GPU_TEMP_FAIL}°C${tsrc}（散热异常）；$detail" "raw/stress/gpu-burn.log"
  elif (( hot > 0 )); then
    result_add "stress_gpu" "GPU 压力测试" "$ST_WARN" \
      "有 ${hot} 张卡温度达到 ${GPU_TEMP_WARN}°C${tsrc}，已进入降频保护区间；$detail" \
      "raw/stress/gpu-burn.log"
  else
    result_add "stress_gpu" "GPU 压力测试" "$ST_PASS" "无计算错误，温度正常；$detail" "raw/stress/gpu-burn.log"
  fi

  check_gpu_load_profile
}

# ---------------------------------------------------------------- 满载运行状态
# 「温度没超标」和「这张卡真的被压到该有的状态」是两回事。
#
# 一张散热不行的卡会自己把频率降下来保护，于是**温度曲线反而好看** ——
# 只看温度什么都发现不了。验收单点名要看的四个读数（频率 / 功耗 / 风扇 /
# 距温度上限的余量）正是为了堵这个口子，所以单独出一条结论。
#
# ⚠️ **这一项只报读数，不判达标与否。**不同型号的卡满载频率从 1400MHz 到
# 2700MHz 都有，凭空写死一个数就是替客户定了一个他没定过的标准；而且这张盘
# 是无人值守跑的，现场也没有地方去填这种数。
# 真正的显卡故障由 stress_gpu 去抓（计算错误 / 掉卡 / 超温），那几条才有资格
# 影响整机结论。
check_gpu_load_profile() {
  (( ${#GPU_LOAD_ROWS[@]} > 0 )) || return 0

  local row idx clk_min clk_avg fan_max tl_min pow_avg slow
  local shown="" nclk=0
  for row in "${GPU_LOAD_ROWS[@]}"; do
    IFS='|' read -r idx clk_min clk_avg fan_max tl_min pow_avg slow <<< "$row"
    local one="显卡${idx}："
    if gpu_stat_ok "$clk_avg"; then
      one="${one}平均频率 ${clk_avg}MHz"
      gpu_stat_ok "$clk_min" && one="${one}（最低 ${clk_min}MHz）"
      nclk=$(( nclk + 1 ))
    fi
    gpu_stat_ok "$pow_avg" && one="${one}，平均功耗 ${pow_avg}W"
    gpu_stat_ok "$fan_max" && one="${one}，风扇最高 ${fan_max}%"
    gpu_stat_ok "$tl_min"  && one="${one}，距显卡自报的温度上限最少还有 ${tl_min}°C"
    # 因过热降频：只在真的采到那一列时才说。**采不到就一个字都不写** ——
    # 写"未发生降频"就是替驱动说了一句它没说过的话。
    # 这里只如实报数，不判它多了还是少了：降到多少算不合格是订单的事。
    if [[ "$slow" == */* ]]; then
      local sa="${slow%%/*}" sn="${slow##*/}"
      if [[ "$sa" =~ ^[0-9]+$ && "$sa" != "0" ]]; then
        one="${one}，${sn} 次采样中有 ${sa} 次显卡自报正因过热降频"
      else
        one="${one}，${sn} 次采样中均未自报过热降频"
      fi
    fi
    shown="${shown}${one}；"
  done

  if (( nclk == 0 )); then
    # 一张卡的频率都没采到 —— 采样器没起来或者驱动不给这一列，不是机器的问题
    result_add "check_gpu_load" "显卡满载运行状态" "$ST_SKIP" \
      "本次未能采集到显卡满载期间的频率读数，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  result_add "check_gpu_load" "显卡满载运行状态" "$ST_PASS" \
    "满载期间各卡的实测运行读数：${shown%；}。" "raw/stress/gpu-burn.log"
}
