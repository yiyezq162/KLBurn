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

  # 逐项走 smart_target_keys（定义在 collect.sh）而不是 DISK_SMART：
  # 阵列卡后面的物理盘没有自己的 /dev 节点，只有一个 key（sda-pd8），
  # 按设备路径遍历的话它们一块都对比不到。
  local keys=()
  while read -r base; do [[ -n "$base" ]] && keys+=("$base"); done < <(smart_target_keys)

  if (( ${#keys[@]} == 0 )); then
    result_add "verify_smart" "硬盘 SMART 复查" "$ST_SKIP" "无本机硬盘" ""
    return
  fi

  local bad=() warned=() base
  local fields=(realloc_sectors pending_sectors uncorrectable crc_errors media_errors)
  local fieldnames=("重分配扇区" "待处理扇区" "不可修正错误" "接口CRC错误" "NVMe介质错误")

  for base in "${keys[@]}"; do

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
      "${#keys[@]} 块盘压测前后无新增坏道/错误计数" "raw/smart-post/"
  fi
}

# ---------------------------------------------------------------- 硬盘温度
# 压测把盘的温度顶上去是正常的，顶过头就不正常。这一项出厂时最容易漏：
# 盘本身没坏、SMART 也干净，但机箱风道或盘位散热不行，装到客户机房里就变成
# "这盘怎么越跑越慢"（NVMe 到点会自己降速）。
#
# 只认真读到的数字：不上报温度的盘（部分 SATA 盘、部分阵列卡固件）
# 直接不参与判定，不能因为读不到就当成有问题。
verify_disk_temp() {
  local keys=()
  while read -r base; do [[ -n "$base" ]] && keys+=("$base"); done < <(smart_target_keys)

  if (( ${#keys[@]} == 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_SKIP" "无本机硬盘" ""
    return
  fi

  local hot=() over=() seen=0 base t
  for base in "${keys[@]}"; do
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

  # 现场 99% 会跳过硬盘压测，这时候盘并没有被压过 —— 写"压测结束时温度"
  # 会让客户以为我们烤过盘了。CPU/内存那一轮照样跑了十几分钟、机箱确实热过，
  # 这个读数有意义，只是不能说成是硬盘压测的结果。
  # DISK_CONFIRMED 是 factory-test.sh 里的全局（现场当场确认过破坏性写入才为 1），
  # verify_all 和它在同一个 shell 里。
  local when="压测结束时"
  (( ${DISK_CONFIRMED:-0} == 1 )) || when="测试结束时"

  if (( seen == 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_SKIP" \
      "所有盘都没有通过 SMART 上报温度（部分 SATA 盘和阵列卡后面的盘不提供）" ""
  elif (( ${#over[@]} > 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_FAIL" \
      "${when} ${over[*]} 超过上限 ${DISK_TEMP_FAIL}°C，散热不足（NVMe 到这个温度通常已经在降速）" \
      "raw/smart-post/"
  elif (( ${#hot[@]} > 0 )); then
    result_add "verify_disk_temp" "硬盘温度" "$ST_WARN" \
      "${when} ${hot[*]} 偏高（告警线 ${DISK_TEMP_WARN}°C）；共 ${seen} 块盘上报了温度" \
      "raw/smart-post/"
  else
    result_add "verify_disk_temp" "硬盘温度" "$ST_PASS" \
      "${seen} 块盘${when}温度均低于 ${DISK_TEMP_WARN}°C" "raw/smart-post/"
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
  # ---- 1.8.0 新增：设备**中途从总线上消失** ----
  # 1.7.8 现场那台 RTX 5090 开测 20 秒就掉下 PCIe 总线，内核刷了 3019 行
  # "GPU lost from the bus"，而当时这个模式里一个 NVIDIA 关键字都没有 ——
  # 1.1MB 的 NVRM 报错喂进来命中数是 0，于是"内核日志复查 PASS"。
  #
  # ⚠️ 只收**明确说设备没了**的三条原话，一条都不能再宽：
  #   - 它们和"驱动版本不支持这张卡"（NVRM: ... is not supported by /
  #     No NVIDIA GPU found / probe routine was not called）完全不重叠。
  #     那几句是**我们带的驱动旧了**，判 FAIL 就是把好卡说成坏卡，
  #     是这个项目的第二条红线。tests/test-hw-checks.sh 里有成对断言钉着。
  #   - 不收裸 "Xid"（正常日志里也会出现这三个字母的其他含义），
  #     不收 RmInitAdapter（开机阶段驱动没起来也会打，含义不唯一）。
  # 在你那 7 份真机样本上对过：坏的那台命中 3019 行，其余 6 台全 0。
  pat+='|GPU lost from the bus|NV_ERR_GPU_IS_LOST|has fallen off the bus'
  printf '%s' "$pat"
}

# ---------------------------------------------------------------- 错误摘要
#
# 1.8.0 现场那台坏卡的报告上写的是：
#   「压测期间内核日志出现 3018 条硬件错误。示例：[Thu Aug 6 14:08:00 2026]
#     NVRM: GPU0 nvAssertOkFailedNoLog: Assertion failed: GPU lost from the
#     bus [NV_ERR_GPU_IS_LOST] (0x0000000F) returned from _intrService...」
#
# 两个毛病：
#   1. **"3018 条"读起来像 3018 个不同的毛病**，实际上是同一句话被刷了 3016 遍
#      （核对过：3018 行里只有 3 种写法，而且全是同一件事——显卡掉总线）。
#   2. 示例直接把内核的断言原文贴给客户，那串东西连我们自己都要愣一下。
#
# 所以按"抹掉时间戳和数字之后长得一样就算同一类"归并，报的是**类别数**，
# 每类给一条剪短的代表。这不改变判定，只改变怎么说。
#
# 抽成纯函数，见 tests/test-hw-checks.sh。

# dmesg_error_kinds <错误文件> -> 每行 "条数<TAB>代表原文"，按条数从多到少
dmesg_error_kinds() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  # 归一化：去掉行首时间戳、把十六进制和十进制数字抹平，
  # 这样 "GPU0"/"GPU1"、"@ intr.c:1653"/"@ intr.c:1700" 会并成一类。
  awk '
    {
      raw = $0
      key = raw
      sub(/^\[[^]]*\][[:space:]]*/, "", key)
      gsub(/0x[0-9a-fA-F]+/, "0xN", key)
      gsub(/[0-9]+/, "N", key)
      if (!(key in cnt)) { rep[key] = raw; ord[++m] = key }
      cnt[key]++
    }
    END { for (i = 1; i <= m; i++) printf "%d\t%s\n", cnt[ord[i]], rep[ord[i]] }
  ' "$f" 2>/dev/null | sort -rn -k1,1
}

# dmesg_error_family <一行日志> -> 这条错误说的是哪种硬件问题（中文），认不出返回空
#
# 客户报告里要出现的是"显卡从 PCIe 总线上掉线"，不是
# "nvAssertOkFailedNoLog: Assertion failed: ... @ intr.c:1653"。
# 内核断言原文对客户没有任何意义，原文完整留在 raw/dmesg-errors.txt 里（ref 指着它）。
#
# ⚠️ 这只是**贴标签**，不参与判定 —— 判定在 dmesg_hw_error_pattern 那边已经做完了。
# 认不出来的一律走"其他"分支并附上原文，绝不能因为认不出就把这条错误吞掉。
dmesg_error_family() {
  local l="${1:-}"
  case "$l" in
    *"GPU lost from the bus"*|*NV_ERR_GPU_IS_LOST*|*"has fallen off the bus"*)
      printf '显卡/扩展卡从 PCIe 总线上掉线' ;;
    *"in FAULT state"*|*"killing adapter"*|*"reset adapter never cleared"*|*"Reset failed"*)
      printf '存储控制器/阵列卡固件进入故障状态' ;;
    *"Machine Check"*|*"Hardware Error"*)
      printf 'CPU 机器检查异常（MCE）' ;;
    *"EDAC MC"*" CE "*|*"EDAC MC"*" UE "*|*Uncorrected*|*uncorrectable*)
      printf '内存 ECC 错误' ;;
    *"medium error"*|*"Buffer I/O error"*|*"I/O error"*|*"ATA bus error"*|*"failed command"*)
      printf '硬盘读写错误' ;;
    *"DPC: containment"*|*ERR_FATAL*|*ERR_NONFATAL*|*"PCIe Bus Error"*|*"AER:"*|*"EDR: "*)
      printf 'PCIe 链路错误' ;;
    *"thermal throttl"*|*"critical temperature"*)
      printf '温度过高触发降频或保护' ;;
    *"link is down"*)
      printf '网络链路中断' ;;
    *) printf '' ;;
  esac
}

# dmesg_error_summary <错误文件> <总条数> -> 给客户看的一句话
#
# 说的是**有几种问题、各多少条**，不是把内核原文贴出来。
# 1.8.0 之前写的是「出现 3018 条硬件错误。示例：<一大串内核断言>」——
# "3018 条"读起来像 3018 个不同的毛病，实际上是同一件事（显卡掉总线）
# 被刷了 3018 遍。
dmesg_error_summary() {
  local f="${1:-}" total="${2:-0}"
  [[ -f "$f" ]] || { printf '共 %s 条' "$total"; return; }

  local -a fam_name=() fam_cnt=() fam_rep=()
  local cnt line fam i found
  while IFS=$'\t' read -r cnt line; do
    [[ -n "$cnt" ]] || continue
    fam="$(dmesg_error_family "$line")"
    [[ -n "$fam" ]] || fam="其他内核硬件错误"
    found=-1
    for i in "${!fam_name[@]}"; do
      [[ "${fam_name[$i]}" == "$fam" ]] && { found="$i"; break; }
    done
    if (( found >= 0 )); then
      fam_cnt[$found]=$(( fam_cnt[found] + cnt ))
    else
      fam_name+=("$fam"); fam_cnt+=("$cnt")
      # 认不出来的那类才留原文（剪短、去时间戳），已认出的不需要
      if [[ "$fam" == "其他内核硬件错误" ]]; then
        fam_rep+=("$(printf '%s' "$line" | sed -E 's/^\[[^]]*\][[:space:]]*//' | cut -c1-120)")
      else
        fam_rep+=("")
      fi
    fi
  done < <(dmesg_error_kinds "$f")

  (( ${#fam_name[@]} > 0 )) || { printf '共 %s 条' "$total"; return; }

  local out=""
  for i in "${!fam_name[@]}"; do
    [[ -n "$out" ]] && out+="；"
    out+="${fam_name[$i]}（${fam_cnt[$i]} 条）"
    [[ -n "${fam_rep[$i]}" ]] && out+="：${fam_rep[$i]}"
  done

  if (( ${#fam_name[@]} == 1 )); then
    # 最常见的情况：同一件事被刷了几千遍。必须说清楚这是**一个**问题，
    # 不然"3018 条"会被读成 3018 个毛病。
    printf '共 %s 条日志，都指向同一个问题：%s' "$total" "${fam_name[0]}"
    [[ -n "${fam_rep[0]}" ]] && printf '：%s' "${fam_rep[0]}"
  else
    printf '共 %s 条日志，涉及 %s 类问题：%s' "$total" "${#fam_name[@]}" "$out"
  fi
}

# dmesg_scan_hw_errors <输入日志> <输出文件>
# 抽成纯函数，好让回归测试直接拿真实日志喂它，见 tests/test-hw-checks.sh
dmesg_scan_hw_errors() {
  local in="$1" out="$2"
  : > "$out"
  [[ -f "$in" ]] || return 0
  # 噪声豁免。每加一条都要说清楚"为什么它不代表被测机器有问题"。
  #
  # dev fd[0-9] = 软驱。内核探测一个不存在/没插盘的软驱，必然打
  #   "I/O error, dev fd0, sector 0 op 0x0:(READ)"
  # 而上面的模式里有 "I/O error"，于是整机判 FAIL，理由写着
  # 「机器在上电初始化时就有硬件异常」—— 一台完全正常的服务器被拦在出货前。
  #
  # 这不是虚拟机才有的事：**BMC 的虚拟媒体（iDRAC/iLO）挂上虚拟软驱、
  # 或 BIOS 开了软驱模拟，真服务器上一样会打这几行。**
  # 而软驱从来不在我们的测试范围里 —— 它不是被测机器的一部分，
  # 它的探测失败说明不了任何关于这台机器的事。豁免它不会掩盖任何真故障：
  # 真盘是 sd*/nvme*/vd*，一个都不受影响（下面有断言逐条钉着）。
  #
  # 这条是 QEMU 端到端测试（tests/e2e-qemu.sh）跑出来的 —— 单元测试永远
  # 造不出这个场景，因为没人会想到往样本里塞一行软驱日志。
  #
  # AER: enabled with IRQ = 内核**打开** AER 上报功能时打的初始化日志，
  #   "pcieport 0000:00:01.4: AER: enabled with IRQ 25"
  # 每个 root port 一行。上面的模式里有裸的 "AER:"，于是它全部命中，
  # 整机判 FAIL，理由写着「机器在上电初始化时就有硬件异常」——
  # 而这几行的含义恰恰相反：**AER 功能正常启用了**，一个错误都还没发生。
  #
  # 为什么以前没炸：命中与否取决于固件把 AER 交不交给操作系统。Intel 那批板子的
  # BIOS 不交（dmesg 里是 "_OSC: platform does not support [... AER ...]"，
  # 没冒号，不命中），所以一直没露出来；海光 C86（OPN3350）这台交了，
  # 4 个 root port 就是 4 条误报，一台完好的机器被拦在出货前。
  # 凡是固件把 AER 交给 OS 的平台都会中招，和 CPU 厂商无关。
  #
  # 豁免必须窄，只放"启用"这一句。真正的 AER 报错（Corrected error received /
  # Uncorrected / can't recover / device recovery failed …）一条都不受影响，
  # 下面有成对断言钉着。
  grep -EI "$(dmesg_hw_error_pattern)" "$in" 2>/dev/null \
    | grep -viE 'thermal throttl.*not|nouveau|dev fd[0-9]|AER: enabled with IRQ' \
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
    local sample; sample="$(dmesg_error_summary "$RAW_DIR/dmesg-errors-boot.txt" "$n")"
    # 同一张坏阵列卡会在这里和「阵列卡」那一项各判一次 FAIL。两条都对，
    # 但报告抬头写着"失败 2 项"，客户读成两处独立故障 —— 明明是一件事。
    # 两个条件同时成立才点这一句：collect_raid 确认过卡有问题（不是我们缺工具），
    # **而且**这里归并出来的类别里真有阵列卡固件那一类。少了后一条，
    # 一台既有坏卡、又另外有内存 MCE 的机器会被说成"都是阵列卡的事"。
    local same=""
    if (( ${RAID_FAULT_FOUND:-0} == 1 )) \
       && [[ "$sample" == *"存储控制器/阵列卡固件"* ]]; then
      same="其中阵列卡固件故障那几条，和「阵列卡」那一项说的是同一件事，不是两处独立故障。"
    fi
    result_add "verify_dmesg_boot" "开机内核日志复查" "$ST_FAIL" \
      "开机与硬件采集阶段内核日志出现硬件错误（这些发生在压测开始之前，\
说明机器在上电初始化时就有硬件异常）。${sample}${same:+。${same}}" "raw/dmesg-errors-boot.txt"
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
    local sample; sample="$(dmesg_error_summary "$RAW_DIR/dmesg-errors.txt" "$n")"
    result_add "verify_dmesg" "内核日志复查" "$ST_FAIL" \
      "压测期间内核日志出现硬件错误。${sample}" "raw/dmesg-errors.txt"
  else
    result_add "verify_dmesg" "内核日志复查" "$ST_PASS" "压测期间无硬件错误日志" "raw/dmesg-delta.txt"
  fi
}

# ================================================================
# 计数器复查：内存 ECC / CPU 热节流 / PCIe AER
# ================================================================
#
# 这三条判的都是**差值**（压测后减压测前），不是绝对值。理由：
# 一台用过的机器带着历史计数是正常的，我们要回答的是"这一轮压测把什么逼出来了"，
# 和 SMART 前后对比完全一样的口径。
#
# 计数器本身来自内核 sysfs（ecc_snapshot / throttle_snapshot / aer_snapshot，
# 都在 collect.sh 里），**不依赖 ras-mc-ctl / edac-util 这些工具** ——
# 盘里没带工具是能力缺失，不能因此判故障。

# 快照里有没有这一类数据。没有 = 这台机器的内核没暴露这个计数器（很常见），
# 判 SKIP，绝不能当成"计数为 0"更不能当成故障。
_counter_has() {
  local kind="$1" f="$2"
  [[ -f "$f" ]] || return 1
  grep -q "^${kind} " "$f" 2>/dev/null
}

# ---------------------------------------------------------------- 内存 ECC
#
# 这是 1.7.0 最有价值的一条新判定：内存早期退化的直接证据。
# 一条开始出可纠正错误的内存，机器照样能跑、压测照样过，
# 但它装到客户机房里会越来越频繁，最后变成不可纠正 —— 那时候是宕机。
#
# 判定口径（保守）：
#   新增不可纠正（UE）-> FAIL   数据已经错了，没得商量
#   新增可纠正（CE）  -> WARN   还纠得回来，但这条内存不该再出厂
#   两样都没有        -> PASS
#   内核没有 EDAC     -> SKIP   （很多平台/虚拟机没有，不是故障）
verify_ecc() {
  local pre="$RAW_DIR/counters-pre.txt" post="$RAW_DIR/counters-post.txt"

  if ! _counter_has ECC "$pre" || ! _counter_has ECC "$post"; then
    result_add "verify_ecc" "内存 ECC 复查" "$ST_SKIP" \
      "本机内核未提供 EDAC 内存错误计数接口，无法核对压测前后的 ECC 变化。\
此项不影响整机结论。" ""
    return
  fi

  # counters_delta 输出 "<标签> <第几列> <前> <后> <增量>"，
  # ECC 行的第 1 列是可纠正数、第 2 列是不可纠正数
  local ce_rows=() ue_rows=() label col before after delta
  while read -r label col before after delta; do
    [[ -n "$label" ]] || continue
    if   [[ "$col" == "1" ]]; then ce_rows+=("${label} 可纠正 ${before}->${after}（新增 ${delta}）")
    elif [[ "$col" == "2" ]]; then ue_rows+=("${label} 不可纠正 ${before}->${after}（新增 ${delta}）")
    fi
  done < <(counters_delta ECC "$pre" "$post")

  metric_add "mem" "新增ECC可纠正条目" "${#ce_rows[@]}"
  metric_add "mem" "新增ECC不可纠正条目" "${#ue_rows[@]}"

  if (( ${#ue_rows[@]} > 0 )); then
    result_add "verify_ecc" "内存 ECC 复查" "$ST_FAIL" \
      "压测期间出现**不可纠正**内存错误：$(printf '%s；' "${ue_rows[@]}")\
不可纠正错误意味着数据已经出错，对应内存条应予更换。" "raw/counters-post.txt"
  elif (( ${#ce_rows[@]} > 0 )); then
    result_add "verify_ecc" "内存 ECC 复查" "$ST_WARN" \
      "压测期间出现可纠正内存错误：$(printf '%s；' "${ce_rows[@]}")\
错误已被 ECC 纠正，本次运行结果仍然有效；但可纠正错误持续增长通常是内存条\
早期退化的信号，建议更换后复测。" "raw/counters-post.txt"
  else
    result_add "verify_ecc" "内存 ECC 复查" "$ST_PASS" \
      "压测前后无新增内存 ECC 错误（可纠正与不可纠正均为 0）" "raw/counters-post.txt"
  fi
}

# ---------------------------------------------------------------- CPU 热节流
#
# 散热不行、但温度**没到告警线**的机器，就是靠这个看出来的：
# CPU 自己在降频保护，于是温度曲线反而好看，光看温度什么都发现不了。
#
# 判 WARN 不判 FAIL：热节流是保护机制正常工作，机器本身没坏；
# 而且短暂几次节流在高密度机型上是常态。但它必须被看见 ——
# 装到客户机房里就是"这台机器怎么比同批的慢"。
verify_throttle() {
  local pre="$RAW_DIR/counters-pre.txt" post="$RAW_DIR/counters-post.txt"

  if ! _counter_has THROTTLE "$pre" || ! _counter_has THROTTLE "$post"; then
    result_add "verify_throttle" "CPU 热节流复查" "$ST_SKIP" \
      "本机 CPU 未提供热节流计数接口（部分平台与虚拟机不提供）。此项不影响整机结论。" ""
    return
  fi

  local n_core=0 n_pkg=0 sum=0 label col before after delta
  while read -r label col before after delta; do
    [[ "$delta" =~ ^[0-9]+$ ]] || continue
    sum=$(( sum + delta ))
    if [[ "$col" == "1" ]]; then n_core=$(( n_core + 1 )); else n_pkg=$(( n_pkg + 1 )); fi
  done < <(counters_delta THROTTLE "$pre" "$post")

  metric_add "cpu" "压测期间热节流次数" "$sum"

  if (( sum > 0 )); then
    result_add "verify_throttle" "CPU 热节流复查" "$ST_WARN" \
      "压测期间 CPU 触发热节流共 ${sum} 次（涉及 ${n_core} 个核心、${n_pkg} 个处理器封装）。\
热节流是 CPU 的自我保护，出现时会主动降频，因此温度读数可能仍在正常范围。\
常见原因：散热器没压紧、硅脂没铺开、风道不畅或机箱进风温度偏高。\
此项不影响整机结论，但建议检查散热后复测。" "raw/counters-post.txt"
  else
    result_add "verify_throttle" "CPU 热节流复查" "$ST_PASS" \
      "压测期间 CPU 未发生热节流，散热能够支撑满载运行" "raw/counters-post.txt"
  fi
}

# ---------------------------------------------------------------- PCIe AER
#
# 链路层的错误计数。偶发可纠正错误在长链路/转接板上很常见（会被自动重传），
# 压测期间**新增**才值得查；不可纠正错误则是真出事了。
verify_aer() {
  local pre="$RAW_DIR/counters-pre.txt" post="$RAW_DIR/counters-post.txt"

  if ! _counter_has AER "$pre" || ! _counter_has AER "$post"; then
    result_add "verify_aer" "PCIe 错误计数复查" "$ST_SKIP" \
      "本机未提供 PCIe AER 错误计数接口（需要固件开放 AER，部分机型与虚拟机不提供）。\
此项不影响整机结论。" ""
    return
  fi

  local cor=() unc=() label col before after delta
  while read -r label col before after delta; do
    [[ -n "$label" ]] || continue
    if [[ "$col" == "1" ]]; then
      cor+=("${label} 可纠正新增 ${delta}")
    else
      unc+=("${label} 不可纠正新增 ${delta}")
    fi
  done < <(counters_delta AER "$pre" "$post")

  metric_add "pcie" "新增AER可纠正设备数" "${#cor[@]}"
  metric_add "pcie" "新增AER不可纠正设备数" "${#unc[@]}"

  if (( ${#unc[@]} > 0 )); then
    result_add "verify_aer" "PCIe 错误计数复查" "$ST_FAIL" \
      "压测期间 PCIe 链路出现**不可纠正**错误：$(printf '%s；' "${unc[@]}")\
不可纠正的 PCIe 错误通常对应板卡、插槽或转接板的实际故障。" "raw/counters-post.txt"
  elif (( ${#cor[@]} > 0 )); then
    result_add "verify_aer" "PCIe 错误计数复查" "$ST_WARN" \
      "压测期间 PCIe 链路出现可纠正错误：$(printf '%s；' "${cor[@]}")\
可纠正错误会被链路层自动重传，不影响数据正确性；少量出现在长链路或转接板上属常见现象，\
持续增长则建议检查板卡是否插到位、转接板信号质量是否正常。" "raw/counters-post.txt"
  else
    result_add "verify_aer" "PCIe 错误计数复查" "$ST_PASS" \
      "压测前后无新增 PCIe 链路错误" "raw/counters-post.txt"
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

# ---------------------------------------------------------------- 硬盘自检（读结果）
#
# `smartctl -l selftest` 的头一条就是最近一次自检。判据是**盘自己写的那句状态**，
# 我们一个数都不定。ATA 和 NVMe 两种日志的表头不一样，但"状态那一段文字"是
# 同一批固定说法，所以按**文字**认，不按列号取（列号在两种日志里对不上）。
#
# selftest_verdict <smartctl -l selftest 的输出文件> -> ok | fail | running | none
#
#   ok       Completed without error
#   fail     Completed: read failure / electrical failure / servo/seek failure /
#            handling damage / unknown failure、Fatal or unknown error
#            —— **盘自己说它没通过**，这才是 FAIL
#   running  还在跑（我们等不及了），或者被中断 / 被主机打断
#            —— 这是**我们这轮的时间问题**，不是盘的毛病，一律 SKIP
#   none     没有自检日志 / 这块盘不支持 —— 同样 SKIP
#
# ⚠️ 顺序：先认"跑完但失败"，再认"还在跑/被打断"，最后才认"通过"。
#    反过来的话 "Completed: read failure" 里的 "Completed" 会先被当成通过。
selftest_verdict() {
  local f="${1:-}"
  [[ -s "$f" ]] || { printf 'none'; return; }
  if grep -aqiE 'Completed:[[:space:]]*(read|electrical|servo|handling|unknown)|Fatal or unknown error' "$f" 2>/dev/null; then
    printf 'fail'; return
  fi
  if grep -aqiE 'in progress|Interrupted|Aborted by host|Self-test routine in progress' "$f" 2>/dev/null; then
    printf 'running'; return
  fi
  if grep -aqiE 'Completed without error' "$f" 2>/dev/null; then
    printf 'ok'; return
  fi
  printf 'none'
}

verify_disk_selftest() {
  if ! have smartctl || (( ${#SMART_TARGETS[@]} == 0 )); then
    result_add "verify_disk_selftest" "硬盘自检" "$ST_SKIP" \
      "本机未安装可自检的硬盘，本项未做核对。此项不影响整机结论。" ""
    return
  fi

  info "Reading on-disk self-test results ..."
  mkdir -p "$RAW_DIR/smart-selftest" 2>/dev/null || true

  local item key dev dtype t v
  local n_ok=0 n_fail=0 n_run=0 n_none=0 bad_list=""
  for item in "${SMART_TARGETS[@]:-}"; do
    [[ -n "$item" ]] || continue
    IFS='|' read -r key dev dtype <<< "$item"
    t="$(cat "$RAW_DIR/smart-pre/${key}.dtype" 2>/dev/null || true)"
    if [[ -n "$t" ]]; then
      capture "smart-selftest/${key}.txt" smartctl -l selftest -d "$t" "$dev" || true
    else
      capture "smart-selftest/${key}.txt" smartctl -l selftest "$dev" || true
    fi
    v="$(selftest_verdict "$RAW_DIR/smart-selftest/${key}.txt")"
    case "$v" in
      ok)      n_ok=$(( n_ok + 1 )) ;;
      fail)    n_fail=$(( n_fail + 1 )); bad_list="${bad_list}${bad_list:+、}${key}" ;;
      running) n_run=$(( n_run + 1 )) ;;
      *)       n_none=$(( n_none + 1 )) ;;
    esac
  done

  # ⚠️ **盘自己说它没通过 = 真故障，一条都不许被"其他盘都好"冲淡。**
  if (( n_fail > 0 )); then
    result_add "verify_disk_selftest" "硬盘自检" "$ST_FAIL" \
      "${n_fail} 块硬盘自带的自检未通过（${bad_list}）。这是硬盘自身给出的结论，\
说明盘体存在读写或机械故障，需更换后复测。" "raw/smart-selftest/"
  elif (( n_ok > 0 )); then
    local extra=""
    (( n_run + n_none > 0 )) && extra="；另有 $(( n_run + n_none )) 块盘本轮未取得自检结论，不影响整机结论"
    result_add "verify_disk_selftest" "硬盘自检" "$ST_PASS" \
      "${n_ok} 块硬盘自带的自检全部通过（由硬盘自身完成并给出结论）${extra}" \
      "raw/smart-selftest/"
  else
    # 一块都没取到结论：要么没跑完、要么这些盘不提供自检。
    # **两种都是本轮的条件问题，不是盘的毛病** —— SKIP。
    result_add "verify_disk_selftest" "硬盘自检" "$ST_SKIP" \
      "本轮未取得硬盘自带自检的结论（自检未在本轮内完成，或该型号硬盘不提供此功能），\
本项未做核对。此项不影响整机结论。" "raw/smart-selftest/"
  fi
}

# ---------------------------------------------------------------- BMC 传感器
#
# ⚠️⚠️ **这是全项目里唯一一处"拿阈值去判"的地方 —— 而那个阈值不是我们定的。**
#
# `ipmitool sensor list` 每行十列：
#     名称 | 读数 | 单位 | 状态 | lnr | lcr | lnc | unc | ucr | unr
# 后六列是**主板厂商烧进管理控制器的**上下限（下不可恢复 / 下临界 / 下告警 /
# 上告警 / 上临界 / 上不可恢复）。拿实测读数去比它，和"我们替客户定一个标准"
# 是**相反**的两件事 —— 那是在读这台机器自己的说明书。
# 风扇转速、VRM 温度、各路电压、进风口温度全都在这张表里，而 1.9.1 之前
# 我们只读了电源那两三行；一颗停转的风扇是工厂最常见的缺陷之一，
# 而它在这张表里是明写着的。
#
# 拿 test_out 十份真机数据量过：每台 25~91 条数值型传感器带完整阈值，
# 越线 0 条 —— 新判定在好机器上不许亮，这一条先验过才敢加。
#
# 三个坑：
#   1. **离散量传感器要整条跳过。**它的读数是 `0x80` 这种事件位、第四列是
#      `0x0080` 而不是 ok/nc/cr，混着判会把 `PWR_Button` 判成异常。
#      判据是"读数是数字"（正面判定），和 1.8.3 电源那次是同一课。
#   2. **读数恰好为 0 一律降一级。**0 既可能是"这个位置没装部件"，也可能是
#      "装了但停转/没输出"，**从读数上分不开** —— 分不开的东西不该去染
#      客户的结论（report-policy 二-5）。所以 0 只判 WARN 并写明两种可能。
#   3. 没有任何数值型阈值的传感器跳过：没有可比的东西，不是"没问题"。
#   4. **已经查明没接交流电的那几路电源，它的 0 读数另算一档**（1.10.1）。
#      见 lib/collect.sh 里 PSU_NOAC_IDS 的那段说明：check_psu 已经把
#      「PSU3 没插线」写进报告了，这里再报一遍 Vin/Vout/风扇 三个 0，
#      是同一件事的第二种说法。摘掉的是重复，不是结论。
#
# ipmi_sensor_scan <sensor list 文件> [没接交流电的电源编号，空格分开]
#   -> 每条**可判**的传感器一行："<级别>|<名称>|<读数>|<单位>|<说明>"
#      级别 = ok / warn / crit / zero / noac
#   调用方按级别自己数，好让"共核对了几项"和"几项越线"出自同一次扫描。
ipmi_sensor_scan() {
  local f="${1:-}" noac="${2:-}"
  [[ -s "$f" ]] || return 0
  awk -F'|' -v noac="$noac" '
    function t(x) { gsub(/^[[:space:]]+/, "", x); gsub(/[[:space:]]+$/, "", x); return x }
    function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
    # 阈值和读数都是 "600.000" 这种写法，整数就去掉小数尾巴
    function fmt(v) { return (v == int(v)) ? sprintf("%d", v) : sprintf("%.2f", v) }
    # 这条传感器是不是挂在"已知没接交流电"的那几路电源上。
    # ⚠️ 编号后面必须紧跟非数字或行尾，否则 3 会命中 PSU31_Vin。
    #    和 collect.sh 里 psu_status_state 那条正则是同一课。
    function on_noac_psu(nm,   i, u) {
      if (nnoac == 0) return 0
      u = toupper(nm)
      for (i = 1; i <= nnoac; i++)
        if (u ~ ("^(PSU|PS)_?[ ]?" noacs[i] "([^0-9]|$)")) return 1
      return 0
    }
    BEGIN { nnoac = split(noac, noacs, /[[:space:]]+/)
            if (nnoac == 1 && noacs[1] == "") nnoac = 0 }
    NF >= 10 {
      name = t($1); val = t($2); unit = t($3)
      lnr = t($5); lcr = t($6); lnc = t($7); unc = t($8); ucr = t($9); unr = t($10)
      if (!isnum(val)) next
      lo_c = isnum(lcr) ? lcr + 0 : (isnum(lnr) ? lnr + 0 : "")
      hi_c = isnum(ucr) ? ucr + 0 : (isnum(unr) ? unr + 0 : "")
      lo_w = isnum(lnc) ? lnc + 0 : ""
      hi_w = isnum(unc) ? unc + 0 : ""
      if (lo_c == "" && hi_c == "" && lo_w == "" && hi_w == "") next
      v = val + 0
      lvl = "ok"; why = ""
      if      (lo_c != "" && v < lo_c) { lvl = "crit"; why = "低于主板设定的临界下限 " fmt(lo_c) }
      else if (hi_c != "" && v > hi_c) { lvl = "crit"; why = "高于主板设定的临界上限 " fmt(hi_c) }
      else if (lo_w != "" && v < lo_w) { lvl = "warn"; why = "低于主板设定的告警下限 " fmt(lo_w) }
      else if (hi_w != "" && v > hi_w) { lvl = "warn"; why = "高于主板设定的告警上限 " fmt(hi_w) }
      if (lvl == "crit" && v == 0) lvl = "zero"
      # ⚠️ **只有"读数恰好为 0"这一档才降级。** 同一路电源的散热片温度真超了
      #    上限，那是 crit，照样得亮 —— 没进电和部件过热是两回事。
      if (lvl == "zero" && on_noac_psu(name)) lvl = "noac"
      printf "%s|%s|%s|%s|%s\n", lvl, name, fmt(v), unit, why
    }' "$f" 2>/dev/null
}

# 单位换成中文报告里读得下去的写法，并给出这条传感器量的是什么。
# 认不出来的单位原样留着（绝不吞信息）。
#
# ⚠️ **那个上下限也要带单位。**`ipmi_sensor_scan` 吐出来的 why 结尾是个
#    光秃秃的数字（结构化数据里不该塞单位），拼成一句话时必须补回去 ——
#    否则客户读到的是「96 °C，高于主板设定的告警上限 95」：95 什么？
#    和 1.9.1 把逐卡满载读数拆进表格之后单位就没了是同一个毛病，
#    只不过那次是拆没的，这次是拼漏的。
ipmi_sensor_phrase() {
  local name="$1" val="$2" unit="$3" why="$4" cat u
  case "$unit" in
    RPM)          cat="风扇";  u="RPM" ;;
    "degrees C")  cat="温度";  u="°C" ;;
    Volts)        cat="电压";  u="V" ;;
    Watts)        cat="功率";  u="W" ;;
    Amps)         cat="电流";  u="A" ;;
    percent)      cat="占比";  u="%" ;;
    *)            cat="读数";  u="${unit}" ;;
  esac
  printf '%s %s：%s %s，%s %s' "$cat" "$name" "$val" "$u" "$why" "$u"
}

verify_bmc_sensors() {
  if [[ "${IPMI_OK:-0}" != "1" ]]; then
    result_add "verify_bmc_sensors" "部件传感器复查" "$ST_SKIP" \
      "本机未提供管理控制器，读不到风扇转速 / 温度 / 电压等部件传感器，本项未做核对。\
此项不影响整机结论。" ""
    return
  fi

  info "Checking BMC sensors against board-defined limits ..."
  local f="$RAW_DIR/ipmi-sensors-post.txt"
  [[ -s "$f" ]] || f="$RAW_DIR/ipmi-sensors.txt"

  local rows; rows="$(ipmi_sensor_scan "$f" "${PSU_NOAC_IDS:-}")"
  local n_all n_crit n_warn n_zero n_noac
  n_all="$(printf '%s\n' "$rows"  | grep -c . || true)"
  n_crit="$(printf '%s\n' "$rows" | grep -c '^crit|' || true)"
  n_warn="$(printf '%s\n' "$rows" | grep -c '^warn|' || true)"
  n_zero="$(printf '%s\n' "$rows" | grep -c '^zero|' || true)"
  n_noac="$(printf '%s\n' "$rows" | grep -c '^noac|' || true)"
  for v in n_all n_crit n_warn n_zero n_noac; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' 0
  done

  if (( n_all == 0 )); then
    # 有 BMC，但一条带阈值的数值型传感器都没有（部分精简 BMC 就是这样）
    result_add "verify_bmc_sensors" "部件传感器复查" "$ST_SKIP" \
      "本机管理控制器未提供带上下限的部件传感器读数，本项未做核对。此项不影响整机结论。" \
      "raw/ipmi-sensors-post.txt"
    return
  fi

  # 越线的逐条留一份证据文件（客户报告里只列前几条，剩下的在这儿）。
  # ⚠️ noac 那几条也写进去 —— 报告里不单列了，但排查的人要看得到我们
  #    确实读到了、并且是**有意**降级的，不是漏掉了。
  local ev=""
  if (( n_crit + n_warn + n_zero + n_noac > 0 )); then
    ev="raw/ipmi-sensor-breach.txt"
    printf '%s\n' "$rows" | grep -v '^ok|' > "$RAW_DIR/ipmi-sensor-breach.txt" 2>/dev/null || true
  fi

  # 列成一句话。**只列前 6 条**：一台 271 个传感器的机器真坏起来能刷出几十行，
  # 客户报告里糊一整屏没人看得下去，剩下的指向证据文件。
  _sensor_list() {
    local want="$1" n=0 lvl name val unit why out=""
    while IFS='|' read -r lvl name val unit why; do
      [[ "$lvl" == "$want" ]] || continue
      n=$(( n + 1 ))
      (( n > 6 )) && continue
      out="${out}${out:+；}$(ipmi_sensor_phrase "$name" "$val" "$unit" "$why")"
    done <<< "$rows"
    (( n > 6 )) && out="${out}，等共 ${n} 项"
    printf '%s' "$out"
  }

  # 没接交流电那几路的 0 读数：**不单列告警，但也不装作没读到。**
  # 一句话交代清楚"这几项是因为那一路没进电才是 0，上面电源那条已经说明"，
  # 客户对得上号，也不会以为我们漏查了几项。
  local noac_txt=""
  (( n_noac > 0 )) && noac_txt="（另有 ${n_noac} 项读数为 0 的电压/风扇传感器\
挂在本次未接入交流电的电源上，属于该路没进电的必然读数，详见上方「电源」一项）"

  if (( n_crit > 0 )); then
    result_add "verify_bmc_sensors" "部件传感器复查" "$ST_FAIL" \
      "压测后有 ${n_crit} 项部件读数超出主板设定的临界范围：$(_sensor_list crit)。\
这些上下限由主板厂商写入管理控制器，超出即表示对应部件或其供电异常，需检修后复测。" "$ev"
  elif (( n_warn > 0 || n_zero > 0 )); then
    local msg=""
    (( n_warn > 0 )) && msg="有 ${n_warn} 项部件读数越过主板设定的告警线（尚未到临界线）：$(_sensor_list warn)。"
    (( n_zero > 0 )) && msg="${msg}有 ${n_zero} 项部件读数为 0：$(_sensor_list zero)。\
读数为 0 既可能是该位置未安装部件，也可能是部件已停转或无输出，两者从读数上分不开。"
    result_add "verify_bmc_sensors" "部件传感器复查" "$ST_WARN" \
      "${msg}机器仍可正常工作，建议出货前现场确认散热与供电。${noac_txt}" "$ev"
  else
    result_add "verify_bmc_sensors" "部件传感器复查" "$ST_PASS" \
      "压测结束后核对 $(( n_all - n_noac )) 项部件传感器（风扇转速 / 温度 / 电压 / 功率等），\
读数均在主板设定的上下限之内${noac_txt}" "raw/ipmi-sensors-post.txt"
  fi
  unset -f _sensor_list
}

# ---------------------------------------------------------------- 汇总入口
#
# 各项都受本轮**测试范围**管（见 core.sh 的 scope_runs）。三条要记住的：
#
#   * **整机复查那四条**（dmesg / SEL / AER / BMC 传感器）在任何跑了压测的
#     范围里都跑：它们查的是"这一轮机器整体有没有报错"，和压了哪个部件无关。
#     只压了 CPU 的那一轮里，PCIe 总线报了 AER、BMC 记了电源掉电，
#     照样是这台机器的毛病。
#   * **verify_ecc 在 cpu 范围也跑**：CPU 满载会把内存也带起来，ECC 计数照样有意义。
#   * 整个 verify_all 只在**跑过压测**的范围里调用（见 factory-test.sh）——
#     「仅导出报告」那一档压根没有"测后"这回事。
verify_all() {
  section "PHASE 5/5  POST-TEST VERIFICATION"
  if scope_runs verify_disk; then
    collect_smart "post"
    verify_smart
    verify_disk_temp
    # 自检是 PHASE 1 发起的，这里只读结果。排在 collect_smart post 之后没关系
    # （它自己跑自己的 smartctl -l selftest），但必须在 verify_all 里 ——
    # 少了这一句，盘在后台白跑一遍自检，没人去看结果。
    verify_disk_selftest
  fi
  # 计数器测后快照。必须排在下面三条判定之前 —— 它们读的就是这份。
  collect_counters "post"
  scope_runs verify_ecc      && verify_ecc
  scope_runs verify_throttle && verify_throttle
  if scope_runs verify_common; then
    verify_aer
    verify_dmesg
    verify_sel
    capture "sensors-post.txt" sensors
    # 测后传感器快照必须排在 verify_bmc_sensors 之前 —— 那一条判的就是这份。
    # （排反了它会退去读测前那份，于是"压测把风扇跑停了"这类事永远查不出来。）
    # ⚠️ **快照照采，只是判定分开管**（scope_runs sensors_state）：范围窄的那几轮
    #    raw/ 里一样留着完整的测后传感器读数，排查时对得上，只是不去染结论。
    [[ "${IPMI_OK:-0}" == "1" ]] && capture -t 60 "ipmi-sensors-post.txt" ipmitool sensor list
    scope_runs sensors_state && verify_bmc_sensors
  fi
  return 0
}
