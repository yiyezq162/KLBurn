#!/usr/bin/env bash
# KLBurn 测后复查
#   1) 对比测前/测后 SMART，看有没有新增坏道
#   2) dmesg 里找硬件错误
#   3) IPMI SEL 里找压测期间新增的事件
#
# 这一步是出厂测试真正的价值所在：压测本身不出错不代表机器没问题，
# 要看压测把什么问题逼出来了。
#
# 只判"压测有没有把问题逼出来"，不判盘的新旧：
# 通电时间/通电次数/累计读写量一律不进报告，也不参与判定 —— 我们会用拆机盘，
# 这些数字对客户没有意义。盘好不好看的是 SMART 健康状态和坏道计数有没有增长。

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

  # 真正代表硬件问题的关键字。故意不含泛泛的 "error"，否则噪声太大。
  local pat='Machine Check|Hardware Error|MCE|EDAC.*(CE|UE)|Uncorrected|uncorrectable|'
  pat+='PCIe Bus Error|AER:|I/O error|Buffer I/O error|medium error|'
  pat+='ATA bus error|failed command|link is down|controller failure|'
  pat+='NMI|thermal throttl|critical temperature|Out of memory'

  grep -EI "$pat" "$RAW_DIR/dmesg-delta.txt" 2>/dev/null \
    | grep -viE 'thermal throttl.*not|nouveau' \
    > "$RAW_DIR/dmesg-errors.txt" || true

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
