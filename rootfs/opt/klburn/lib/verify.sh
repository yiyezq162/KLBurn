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

# ---------------------------------------------------------------- 汇总入口
verify_all() {
  section "PHASE 4/4  POST-TEST VERIFICATION"
  collect_smart "post"
  verify_smart
  verify_disk_temp
  # 计数器测后快照。必须排在下面三条判定之前 —— 它们读的就是这份。
  collect_counters "post"
  verify_ecc
  verify_throttle
  verify_aer
  verify_dmesg
  verify_sel
  capture "sensors-post.txt" sensors
  [[ "${IPMI_OK:-0}" == "1" ]] && capture -t 60 "ipmi-sensors-post.txt" ipmitool sensor list
  return 0
}
