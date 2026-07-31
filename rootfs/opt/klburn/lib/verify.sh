#!/usr/bin/env bash
# KLBurn 测后复查
#   1) 对比测前/测后 SMART，看有没有新增坏道
#   2) dmesg 里找硬件错误
#   3) IPMI SEL 里找压测期间新增的事件
#
# 这一步是出厂测试真正的价值所在：压测本身不出错不代表机器没问题，
# 要看压测把什么问题逼出来了。
#
# 判据是"压测有没有把问题逼出来"：SMART 健康状态，以及坏道类计数在压测前后
# 有没有增长。寿命类字段（通电时间/通电次数/累计读写量）不参与判定，
# 采集下来存进工程数据即可。

# 取某块盘某个字段。读的是 collect_smart 已经归一化好的 .norm.json。
smart_field() {
  local phase="$1" base="$2" field="$3"
  local f="$RAW_DIR/smart-$phase/${base}.norm.json"
  [[ -f "$f" ]] || { printf ''; return; }
  jq -r --arg k "$field" '(.[$k] // "") | tostring' "$f" 2>/dev/null
}

# ---------------------------------------------------------------- SMART 前后对比
verify_smart() {
  info "Comparing pre/post SMART data ..."

  if (( ${#DISK_SMART[@]} == 0 )); then
    result_add "verify_smart" "硬盘 SMART 复查" "$ST_SKIP" "无本机硬盘" ""
    return
  fi

  local bad=() warned=() dev base
  local fields=(realloc_sectors pending_sectors uncorrectable crc_errors media_errors)
  local fieldnames=("重分配扇区" "待处理扇区" "不可修正错误" "接口CRC错误" "NVMe介质错误")

  for dev in "${DISK_SMART[@]}"; do
    base="$(basename "$dev")"

    # SMART 总体健康状态
    local passed; passed="$(smart_field post "$base" smart_passed)"
    if [[ "$passed" == "false" ]]; then
      bad+=("${base}: SMART 总体健康状态为 FAILED")
    fi

    # NVMe 严重告警位
    local cw; cw="$(smart_field post "$base" critical_warning)"
    if [[ -n "$cw" && "$cw" =~ ^[0-9]+$ ]] && (( cw != 0 )); then
      bad+=("${base}: NVMe critical_warning=${cw}（介质只读/温度超限/备件耗尽）")
    fi

    # 逐项对比前后差值
    local i
    for i in "${!fields[@]}"; do
      local k="${fields[$i]}" kn="${fieldnames[$i]}"
      local pre post
      pre="$(smart_field pre  "$base" "$k")"
      post="$(smart_field post "$base" "$k")"
      [[ "$pre"  =~ ^[0-9]+$ ]] || continue
      [[ "$post" =~ ^[0-9]+$ ]] || continue
      if (( post > pre )); then
        bad+=("${base}: 压测期间${kn} 由 ${pre} 增加到 ${post}")
      elif (( post > 0 )); then
        warned+=("${base}: ${kn}=${post}（测试前就存在，非本次压测产生）")
      fi
    done
  done

  if (( ${#bad[@]} > 0 )); then
    result_add "verify_smart" "硬盘 SMART 复查" "$ST_FAIL" \
      "$(printf '%s；' "${bad[@]}")" "raw/smart-post/"
  elif (( ${#warned[@]} > 0 )); then
    result_add "verify_smart" "硬盘 SMART 复查" "$ST_WARN" \
      "$(printf '%s；' "${warned[@]}")" "raw/smart-post/"
  else
    result_add "verify_smart" "硬盘 SMART 复查" "$ST_PASS" \
      "${#DISK_SMART[@]} 块盘压测前后无新增坏道/错误计数" "raw/smart-post/"
  fi
}

# ---------------------------------------------------------------- 硬盘温度
# 压测把盘的温度顶上去是正常的，顶过头就不正常。这一项出厂时最容易漏：
# 盘本身没坏、SMART 也干净，但机箱风道或盘位散热不行，装到客户机房里就变成
# "这盘怎么越跑越慢"（NVMe 到点会自己降速）。
#
# 只认真读到的数字：SMART 不上报温度的盘（部分 SATA 盘、阵列卡后面的盘）
# 直接不参与判定，不能因为读不到就当成有问题。
verify_disk_temp() {
  if (( ${#DISK_SMART[@]} == 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_SKIP" "无本机硬盘" ""
    return
  fi

  local hot=() over=() seen=0 dev base t
  for dev in "${DISK_SMART[@]}"; do
    base="$(basename "$dev")"
    # 测后读数才有意义（测前是冷的）；测后取不到就退回测前，聊胜于无
    t="$(smart_field post "$base" temperature_c)"
    [[ "$t" =~ ^[0-9]+$ ]] || t="$(smart_field pre "$base" temperature_c)"
    [[ "$t" =~ ^[0-9]+$ ]] || continue
    (( t > 0 && t < 150 )) || continue        # 明显不可信的读数不要
    seen=$(( seen + 1 ))
    metric_add "disk" "${base} 测后温度" "$t"
    if   (( t >= DISK_TEMP_FAIL )); then over+=("${base} ${t}°C")
    elif (( t >= DISK_TEMP_WARN )); then hot+=("${base} ${t}°C")
    fi
  done

  if (( seen == 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_SKIP" \
      "所有盘都没有通过 SMART 上报温度（部分 SATA 盘和阵列卡后面的盘不提供）" ""
  elif (( ${#over[@]} > 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_FAIL" \
      "压测结束时 ${over[*]} 超过上限 ${DISK_TEMP_FAIL}°C，散热不足（NVMe 到这个温度通常已经在降速）" \
      "raw/smart-post/"
  elif (( ${#hot[@]} > 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_WARN" \
      "压测结束时 ${hot[*]} 偏高（告警线 ${DISK_TEMP_WARN}°C）；共 ${seen} 块盘上报了温度" \
      "raw/smart-post/"
  else
    result_add "verify_disk_temp" "硬盘温度" "$ST_PASS" \
      "${seen} 块盘压测结束时温度均低于 ${DISK_TEMP_WARN}°C" "raw/smart-post/"
  fi
}

# ---------------------------------------------------------------- dmesg 查错
#
# 真正代表硬件问题的关键字。故意不含泛泛的 "error"，否则噪声太大。
#
# ⚠️ 这个模式的每一条都拿现场真机日志验过：正样本是那台 MegaRAID 濒死的机器
# （dmesg 里有完整故障链），负样本是同一台机器换了张盘之后的健康日志（2575 行）
# 加上一份手工挑的"长得像错误但完全正常"的行。加新关键字必须两边都跑一遍，
# 见 tests/test-hw-checks.sh 里「内核日志关键字」那组。
#
# 两个曾经踩过/差点踩到的坑，改的时候别退回去：
#   1. 裸 NMI —— 会命中每台机器开机都有的三行正常日志：
#          ACPI: X2APIC_NMI (uid[...] high edge lint[0x1])
#          ACPI: LAPIC_NMI  (acpi_id[...] high edge lint[0x1])
#          NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.
#      只在扫 delta 时没发作（它们都在开机阶段，被 comm -13 减掉了），
#      一旦拿去扫开机日志就是每台机器三条误报。所以换成真正的 NMI 故障原文。
#   2. EDAC.*(CE|UE) —— "CE" 两个字母在 SOURCE / DEVICE / INTERFACE 里都有，
#      而 EDAC 初始化时会刷十几行 "EDAC MC0: Giving out device to module ..."。
#      收紧成 EDAC 真实报错的格式：EDAC MC0: 1 CE memory read error on ...
dmesg_hw_error_pattern() {
  local pat='Machine Check|Hardware Error|mce: \[Hardware Error\]|'
  pat+='EDAC MC[0-9]*: [0-9]+ (CE|UE) |Uncorrected|uncorrectable|'
  # NMI 只认真正的故障原文，不认裸 NMI（见上面第 1 条）
  pat+='Uhhuh\. NMI|NMI: (IOCK|PCI system) error|Dazed and confused|'
  pat+='PCIe Bus Error|AER:|I/O error|Buffer I/O error|medium error|'
  pat+='ATA bus error|failed command|link is down|controller failure|'
  pat+='thermal throttl|critical temperature|Out of memory|'
  # ---- 以下是 0.5.0 新增：驱动 / 控制器级故障 ----
  # 现场那台 MegaRAID 开机 3 秒就出事，完整链条是
  #   DPC: containment event, ERR_NONFATAL -> AER: can't recover
  #   -> FW in FAULT state -> resetting adapter -> reset never cleared (x3)
  #   -> Reset failed, killing adapter -> Failed from megasas_fault_detect_work
  # 旧模式里只有 "AER:" 能命中其中两条，而那两条又都在开机阶段、被 delta 减掉了，
  # 于是整台机器判 PASS。
  pat+='DPC: containment event|ERR_FATAL|ERR_NONFATAL|EDR: |'
  pat+='in FAULT state|killing adapter|reset adapter never cleared|'
  pat+='Reset failed|device recovery failed|'
  pat+='resetting .*adapter|Failed from [a-z_]+ [0-9]'
  printf '%s' "$pat"
}

# dmesg_scan_hw_errors <输入日志> <输出文件>
# 抽成纯函数，好让回归测试直接拿真实日志喂它，见 tests/test-hw-checks.sh
dmesg_scan_hw_errors() {
  local in="$1" out="$2"
  : > "$out"
  [[ -f "$in" ]] || return 0
  grep -EI "$(dmesg_hw_error_pattern)" "$in" 2>/dev/null \
    | grep -viE 'thermal throttl.*not|nouveau' \
    > "$out" || true
  return 0
}

# 开机与采集阶段的内核日志复查。
#
# 为什么非要单独来一项：verify_dmesg 扫的是 delta（测后减测前），
# 而 delta 按定义**排除了开机阶段的一切**。现场那台机器的阵列卡是开机 3 秒
# 就挂的，9 条故障日志全在 dmesg-pre 里，被 comm -13 一条不剩地减光，
# 于是"内核日志复查 PASS"。光改正则修不好这个，必须单独扫一遍 dmesg-pre。
#
# 判 FAIL 而不是 WARN：用的是和 verify_dmesg 完全同一套关键字，
# 那边命中即 FAIL，这边没道理更宽松——一张开机就进 FAULT state、
# 被内核 kill 掉的阵列卡，就是坏了。模式已经在真实健康机日志上验过零误报。
#
# 在 PHASE 1 结束时调用（不是 PHASE 4）：让现场在开始压测之前就知道机器有硬伤，
# 而不是白等 30 分钟跑完才看到。
verify_dmesg_boot() {
  info "Scanning boot-time kernel log for hardware errors ..."

  if [[ ! -f "$RAW_DIR/dmesg-pre.txt" ]]; then
    result_add "verify_dmesg_boot" "开机内核日志复查" "$ST_SKIP" "未采集到开机内核日志" ""
    return
  fi

  dmesg_scan_hw_errors "$RAW_DIR/dmesg-pre.txt" "$RAW_DIR/dmesg-errors-boot.txt"
  local n; n="$(count_lines "$RAW_DIR/dmesg-errors-boot.txt")"

  if (( n > 0 )); then
    local sample; sample="$(head -3 "$RAW_DIR/dmesg-errors-boot.txt" | tr '\n' ' ' | cut -c1-300)"
    result_add "verify_dmesg_boot" "开机内核日志复查" "$ST_FAIL" \
      "开机与硬件采集阶段内核日志出现 ${n} 条硬件错误（这些发生在压测开始之前，\
说明机器在上电初始化时就有硬件异常）。示例：${sample}" "raw/dmesg-errors-boot.txt"
  else
    result_add "verify_dmesg_boot" "开机内核日志复查" "$ST_PASS" \
      "开机与硬件采集阶段无硬件错误日志" "raw/dmesg-pre.txt"
  fi
}

verify_dmesg() {
  info "Scanning kernel log for hardware errors ..."
  capture "dmesg-post.txt" dmesg -T

  # 取压测期间新增的那部分
  if [[ -f "$RAW_DIR/dmesg-pre.txt" ]]; then
    comm -13 <(sort "$RAW_DIR/dmesg-pre.txt") <(sort "$RAW_DIR/dmesg-post.txt") \
      > "$RAW_DIR/dmesg-delta.txt" 2>/dev/null || cp "$RAW_DIR/dmesg-post.txt" "$RAW_DIR/dmesg-delta.txt"
  else
    cp "$RAW_DIR/dmesg-post.txt" "$RAW_DIR/dmesg-delta.txt"
  fi

  dmesg_scan_hw_errors "$RAW_DIR/dmesg-delta.txt" "$RAW_DIR/dmesg-errors.txt"

  local n; n="$(count_lines "$RAW_DIR/dmesg-errors.txt")"

  if (( n > 0 )); then
    local sample; sample="$(head -3 "$RAW_DIR/dmesg-errors.txt" | tr '\n' ' ' | cut -c1-300)"
    result_add "verify_dmesg" "内核日志复查" "$ST_FAIL" \
      "压测期间内核日志出现 ${n} 条硬件错误。示例：${sample}" "raw/dmesg-errors.txt"
  else
    result_add "verify_dmesg" "内核日志复查" "$ST_PASS" "压测期间无硬件错误日志" "raw/dmesg-delta.txt"
  fi
}

# ---------------------------------------------------------------- IPMI SEL
verify_sel() {
  if [[ "${IPMI_OK:-0}" != "1" ]]; then
    result_add "verify_sel" "BMC 事件日志复查" "$ST_SKIP" "无 BMC，跳过" ""
    return
  fi

  info "Checking BMC system event log ..."
  capture -t 60 "ipmi-sel-post.txt" ipmitool sel list

  local pre_n post_n new_n
  pre_n="$(count_lines "$RAW_DIR/ipmi-sel-pre.txt")"
  post_n="$(count_lines "$RAW_DIR/ipmi-sel-post.txt")"
  new_n=$(( post_n - pre_n ))
  (( new_n < 0 )) && new_n=0

  if (( new_n > 0 )); then
    tail -n "$new_n" "$RAW_DIR/ipmi-sel-post.txt" > "$RAW_DIR/ipmi-sel-new.txt" 2>/dev/null || true
    # 只有真正的告警才判 FAIL，普通的开关机/日志清空事件不算
    local crit
    # 这里带 -E 的模式匹配，用不上 count_lines，但道理完全一样：
    # grep -c 在匹配数为 0 时自己已经打印了 "0"，只是返回码是 1。
    # 绝不能再 `|| echo 0` 补一个，那会得到两行的 "0\n0"，算术直接报错。
    crit="$(grep -icE 'Critical|Non-recoverable|Failure|Uncorrectable|Predictive|Asserted' \
            "$RAW_DIR/ipmi-sel-new.txt" 2>/dev/null)"
    [[ "$crit" =~ ^[0-9]+$ ]] || crit=0
    if (( crit > 0 )); then
      result_add "verify_sel" "BMC 事件日志复查" "$ST_FAIL" \
        "压测期间 BMC 新增 ${new_n} 条事件，其中 ${crit} 条为告警级" "raw/ipmi-sel-new.txt"
    else
      result_add "verify_sel" "BMC 事件日志复查" "$ST_WARN" \
        "压测期间 BMC 新增 ${new_n} 条事件（非告警级）" "raw/ipmi-sel-new.txt"
    fi
  else
    result_add "verify_sel" "BMC 事件日志复查" "$ST_PASS" "压测期间无新增 BMC 事件" "raw/ipmi-sel-post.txt"
  fi
}

# ---------------------------------------------------------------- 汇总入口
verify_all() {
  section "PHASE 4/4  POST-TEST VERIFICATION"
  collect_smart "post"
  verify_smart
  verify_disk_temp
  verify_dmesg
  verify_sel
  capture "sensors-post.txt" sensors
  [[ "${IPMI_OK:-0}" == "1" ]] && capture -t 60 "ipmi-sensors-post.txt" ipmitool sensor list
  return 0
}
