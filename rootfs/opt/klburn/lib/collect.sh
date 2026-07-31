#!/usr/bin/env bash
# KLBurn 硬件信息采集
#
# 原则：全部原样落盘到 raw/，解析交给 report/generate_report.py。
# 采集失败不中断流程，只记录状态。

# ---------------------------------------------------------------- 主板 / BIOS / CPU / 内存
collect_system() {
  info "Collecting system / board / CPU / memory ..."

  capture "dmidecode.txt"        dmidecode
  capture "dmidecode-memory.txt" dmidecode -t memory
  capture "dmidecode-system.txt" dmidecode -t system -t baseboard -t bios
  capture "dmidecode-psu.txt"    dmidecode -t 39
  capture "lscpu.json"           lscpu -J
  capture "lscpu.txt"            lscpu
  capture "meminfo.txt"          cat /proc/meminfo
  capture "cpuinfo.txt"          cat /proc/cpuinfo
  capture "numactl.txt"          numactl --hardware
  capture "uname.txt"            uname -a

  # lshw 只作为原始留档（报告生成器和判定逻辑都不读它），所以宁可它超时也
  # 不能让它拖时间：
  #   -disable network  网口探测是 lshw 里最容易卡住的一环，而且我们的网卡数据
  #                     早就从 ethtool + lspci 拿全了（型号/驱动/固件/速率/链路），
  #                     lshw 这份是纯冗余。0.3.0 把联网校时挪到采集之前以后，
  #                     lshw 是在网口已经 up 的状态下跑的，实测就卡在这里被
  #                     强杀了两次，白等 200 秒。
  #   超时从 90s 收到 45s：留档数据不值得让现场干等。
  # 45s -> 20s。0.6.0 现场那台机器（阵列卡故障）两次都跑满 45 秒被强杀，白等 90 秒。
  # 这份数据纯粹是留档，报告生成器和判定逻辑一行都不读，不值得让现场干等。
  capture -t 20 "lshw.json" lshw -json -quiet -disable network
  capture -t 20 "lshw.txt"  lshw -short -quiet -disable network

  # lspci 也得上超时。默认 120 秒是按"正常机器毫秒级返回"想当然定的，
  # 而故障设备不响应配置空间读取时，内核要等 PCIe 完成超时，lspci 会一直卡着 ——
  # 0.3.0 现场 `lspci -nn` 实测卡了 94 秒，恰好卡到内核打出
  # "Reset failed, killing adapter" 那一刻才返回。两条加起来能白等四分钟，
  # 屏幕上一动不动，看着就像死机了。
  #
  # 超时了拿到的是半截文件，但半截也够用：网卡型号反查、PCIe 链路校验、
  # 阵列卡型号识别都是按行匹配的，缺几行不影响已经采到的那部分。
  info "Enumerating PCI devices (may take a while on machines with a faulty card) ..."
  capture -t 60 "lspci.txt"     lspci -nn
  capture -t 60 "lspci-vv.txt"  lspci -vv -nn
  capture -t 30 "lsusb.txt"     lsusb

  if [[ -s "$RAW_DIR/dmidecode.txt" ]] && ! grep -qi 'permission denied\|command not found' "$RAW_DIR/dmidecode.txt"; then
    result_add "collect_system" "硬件信息采集" "$ST_PASS" "主板/BIOS/CPU/内存信息采集完成" "raw/dmidecode.txt"
  else
    result_add "collect_system" "硬件信息采集" "$ST_FAIL" "dmidecode 读取失败，无法获取主板信息" "raw/dmidecode.txt"
  fi
}

# ---------------------------------------------------------------- 内存容量核对
# DMI 里内存条容量之和（MB）。读的是已经落盘的 dmidecode -t memory。
#
# 只认行首带制表符的 "Size:"：DDR5 的每条内存还会多打一行
# "Volatile Size: 16 GB"，一起累加的话容量会翻倍。
dmi_installed_mem_mb() {
  local f="${1:-$RAW_DIR/dmidecode-memory.txt}"
  [[ -f "$f" ]] || { printf '0'; return; }
  awk '
    /^\tSize:[[:space:]]/ {
      if ($2 ~ /^[0-9]+$/) {
        if      ($3 == "GB") s += $2 * 1024
        else if ($3 == "MB") s += $2
        else if ($3 == "TB") s += $2 * 1048576
      }
    }
    END { printf "%d", s }' "$f"
}

# 系统实际识别的内存（MB）
os_visible_mem_mb() {
  local f="${1:-/proc/meminfo}"
  # 文件不存在时 awk 直接以错误退出、连 END 都不跑，输出会是空字符串，
  # 调用方拿它去做数值比较就全乱了。所以先自己挡一道。
  [[ -f "$f" ]] || { printf '0'; return; }
  awk '/^MemTotal/{printf "%d", $2/1024; found=1} END{if(!found) printf "0"}' "$f"
}

# 装机容量 vs 系统识别容量的允差（MB）：
# 内核和固件本来就会占掉一部分（ACPI/BIOS 保留、显存共享），
# 正常机器差 1~3%，取 6% 或 2GB 里大的那个当界，避免误报。
mem_gap_tolerance_mb() {
  # 注意别写成 `local installed="$1" tol=$(( installed * 6 / 100 ))`：
  # 同一条 local 里的算术展开发生在赋值之前，installed 那时还没有值，
  # set -u 下会直接报 unbound variable，允差就成了空字符串（于是每台机器都判 WARN）。
  local installed="$1"
  local tol=$(( installed * 6 / 100 ))
  (( tol < 2048 )) && tol=2048
  printf '%d' "$tol"
}

# 装机内存和系统识别的内存对不上，是出厂测试必须抓住的一类问题：
# 少一条内存 = 少一份钱，而压测只会去压系统认到的那部分，压不出来。
check_memory_capacity() {
  info "Cross-checking installed vs visible memory ..."

  local installed visible tol gap
  installed="$(dmi_installed_mem_mb)"
  visible="$(os_visible_mem_mb)"
  [[ "$installed" =~ ^[0-9]+$ ]] || installed=0
  [[ "$visible"   =~ ^[0-9]+$ ]] || visible=0

  metric_add "mem" "装机容量MB" "$installed"
  metric_add "mem" "系统识别MB" "$visible"

  if (( installed == 0 || visible == 0 )); then
    result_add "check_mem_cap" "内存容量核对" "$ST_SKIP" \
      "未能同时取得 DMI 装机容量和系统识别容量，无法核对" "raw/dmidecode-memory.txt"
    return
  fi

  tol="$(mem_gap_tolerance_mb "$installed")"
  gap=$(( installed - visible ))

  local ig=$(( installed / 1024 )) vg=$(( visible / 1024 ))
  if (( gap > tol )); then
    result_add "check_mem_cap" "内存容量核对" "$ST_WARN" \
      "DMI 显示装机内存 ${ig}GB，系统实际只识别 ${vg}GB，相差约 $(( gap / 1024 ))GB。\
可能原因：有内存条未被 BIOS 识别（插槽接触不良/条子故障），\
或 BIOS 开启了内存镜像(Mirror)/备用(Sparing) 模式。\
注意：内存压测只能覆盖系统识别到的这部分容量。" \
      "raw/dmidecode-memory.txt"
  else
    result_add "check_mem_cap" "内存容量核对" "$ST_PASS" \
      "装机 ${ig}GB，系统识别 ${vg}GB，一致（差值在固件保留的正常范围内）" \
      "raw/dmidecode-memory.txt"
  fi
}

# ---------------------------------------------------------------- 硬盘 SMART
# collect_smart <phase>   phase = pre | post
collect_smart() {
  local phase="$1"
  local dir="smart-$phase"
  info "Collecting SMART data ($phase-test) for ${#DISK_SMART[@]} disk(s) ..."

  local dev base rc
  for dev in "${DISK_SMART[@]}"; do
    base="$(basename "$dev")"
    # 先按默认方式读；读不到再试 SAT 透传（常见于阵列卡直通 / USB 桥接）
    capture "$dir/${base}.txt"  smartctl -a "$dev"; rc=$?
    if (( rc & 2 )); then
      capture "$dir/${base}.txt" smartctl -a -d sat "$dev" || true
      capture "$dir/${base}.json" smartctl -a -j -d sat "$dev" || true
    else
      capture "$dir/${base}.json" smartctl -a -j "$dev" || true
    fi
    # 归一化成固定字段，后面 verify.sh / 报告生成器直接读这个，
    # 免得每取一个字段都重跑一遍 smart.jq
    jq -f "$KLB_LIB/smart.jq" "$RAW_DIR/$dir/${base}.json" \
       > "$RAW_DIR/$dir/${base}.norm.json" 2>/dev/null \
       || echo '{}' > "$RAW_DIR/$dir/${base}.norm.json"
  done

  if [[ "$phase" == "pre" ]]; then
    capture "nvme-list.json" nvme list -o json
    capture "nvme-list.txt"  nvme list
    capture "lsblk.txt"      lsblk -o NAME,PATH,SIZE,TYPE,TRAN,ROTA,MODEL,SERIAL,FSTYPE,MOUNTPOINT

    if (( ${#DISK_SMART[@]} == 0 )); then
      result_add "collect_disk" "硬盘信息采集" "$ST_WARN" \
        "本机未安装硬盘（未检测到任何内置存储设备）" ""
    else
      result_add "collect_disk" "硬盘信息采集" "$ST_PASS" \
        "共 ${#DISK_SMART[@]} 块盘，已采集型号/序列号/固件/容量与 SMART 健康状态" "raw/smart-pre/"
    fi
  fi
}

# 在 lspci/storcli 都没找到卡的情况下，看 BMC 有没有为阵列卡/HBA 预留的传感器
# （温度、插槽/Riser 供电）。这类传感器条目是主板设计阶段就定义好的，装不装卡
# 都会出现在 SDR 里，所以"有定义"不能证明"真的装了卡"——但如果定义了却
# 一条读数都没有，至少说明"现在没有任何卡在这些槽位上响应"，值得提一句，
# 免得装了卡但没插到位（松动/转接板没到位）被当成"本来就没装"静默放过。
raid_bmc_hint() {
  RAID_BMC_SILENT=0
  [[ "${IPMI_OK:-0}" == "1" ]] || { printf ''; return; }
  local f="$RAW_DIR/ipmi-sdr.txt"
  [[ -s "$f" ]] || f="$RAW_DIR/ipmi-sensors.txt"
  [[ -s "$f" ]] || { printf ''; return; }

  local lines total populated
  lines="$(grep -iE 'raid|hba|riser|slot[0-9]' "$f" 2>/dev/null || true)"
  [[ -n "$lines" ]] || { printf ''; return; }

  total="$(printf '%s\n' "$lines" | grep -c .)"
  populated="$(printf '%s\n' "$lines" | grep -vciE '\bna\b|no reading')"
  if (( total > 0 && populated == 0 )); then
    # 调用方靠这个标志把结论从 SKIP 抬成 WARN，见 collect_raid
    RAID_BMC_SILENT=1
    printf '；BMC 上为阵列卡/HBA 预留的温度和插槽供电传感器均无读数（板子设计上支持装卡，'
    printf '但这次没读到任何反馈——如果确实装了卡，建议检查卡和转接板/riser 是否插到位）'
  fi
}

# 「lspci 看不到卡」这一种情况的结论：默认 SKIP（真没装卡），
# 但如果 BMC 明明定义了 RAID/HBA 的温度和插槽供电传感器、却一条读数都没有，
# 就抬成 WARN。
#
# 这条是被现场真事逼出来的：同一台机器连着测两次——
#   第一次 阵列卡在 lspci 里还看得见，但 dmesg 里已经是 FW FAULT / reset 三次失败
#          / killing adapter，判 WARN（"检测到阵列卡但没有 storcli64"）
#   第二次 卡坏到连 PCI 枚举都过不去，lspci 里整个消失，判 **SKIP「未安装阵列卡」**
# 两次整机结论都是 PASS。一张物理上插着的卡坏成这样，报告写的是"没装卡"。
#
# 单看一次运行，「主板本来就没装卡」和「卡坏到不枚举」在数据上确实分不开，
# 所以不能判 FAIL（无卡机型会被误杀）。WARN 是折中：报告抬头会单独列出来，
# 提示人工确认，又不拉低整机结论。
raid_absent_status() {
  if (( ${RAID_BMC_SILENT:-0} == 1 )); then
    printf '%s' "$ST_WARN"
  else
    printf '%s' "$ST_SKIP"
  fi
}

# ---------------------------------------------------------------- 阵列卡
collect_raid() {
  info "Collecting RAID controller info ..."

  # lspci 里认不认得到 RAID 控制器
  local raid_pci
  raid_pci="$(grep -iE 'RAID bus controller|Serial Attached SCSI|MegaRAID' "$RAW_DIR/lspci.txt" 2>/dev/null || true)"

  # 必须先算出 hint —— 它同时会设置 RAID_BMC_SILENT，raid_absent_status 要读。
  # 别图省事写成 result_add ... "$(raid_absent_status)" "未安装阵列卡$(raid_bmc_hint)"：
  # bash 从左到右展开参数，状态那个会在 hint 之前算，标志位还没被设上。
  local hint; hint="$(raid_bmc_hint)"
  local absent_st; absent_st="$(raid_absent_status)"

  if [[ -x "$KLB_TOOLS/storcli64" ]]; then
    capture -t 90 "storcli-show.txt"     "$KLB_TOOLS/storcli64" /call show all
    capture -t 90 "storcli-pdlist.txt"   "$KLB_TOOLS/storcli64" /call/eall/sall show all
    capture -t 90 "storcli-vd.txt"       "$KLB_TOOLS/storcli64" /call/vall show all
    capture -t 90 "storcli-events.txt"   "$KLB_TOOLS/storcli64" /call show events type=latest=50

    if grep -qiE 'Controller = [0-9]|Product Name' "$RAW_DIR/storcli-show.txt" 2>/dev/null; then
      result_add "collect_raid" "阵列卡" "$ST_PASS" \
        "已采集阵列卡型号、固件版本与逻辑盘状态。阵列卡不做压力测试。" "raw/storcli-show.txt"
    elif [[ -n "$raid_pci" ]]; then
      # 管理工具在盘里、但这张卡它认不了（型号不在支持列表内）。
      # 同样是环境能力的限制，不是这台机器有问题 -> SKIP，且不提工具名。
      local raid_model2
      raid_model2="$(printf '%s' "$raid_pci" | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$//')"
      result_add "collect_raid" "阵列卡" "$ST_SKIP" \
        "已识别阵列卡型号：${raid_model2:-见原始记录}。\
本次仅采集型号信息，未读取固件版本与逻辑盘状态（当前测试环境的管理工具不支持该型号）。\
阵列卡不做压力测试，此项不影响整机结论。" "raw/lspci.txt"
    else
      result_add "collect_raid" "阵列卡" "$absent_st" "未安装阵列卡${hint}" ""
    fi
  else
    if [[ -n "$raid_pci" ]]; then
      # 文案是给客户看的，不能出现"重新出盘""构建目录"这类只有开发者看得懂的话。
      # 而且这一项**本来就只采集不压测**，读不到固件版本不代表机器有问题，
      # 所以判 SKIP 而不是 WARN —— WARN 会在报告抬头单独列一块，
      # 客户看到"告警"却发现只是少个管理工具，反而显得机器有毛病。
      #
      # 型号是从 PCI 反查的，一样准确，客户关心的"这台机器装了什么卡"照常有。
      local raid_model
      raid_model="$(printf '%s' "$raid_pci" | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$//')"
      result_add "collect_raid" "阵列卡" "$ST_SKIP" \
        "已识别阵列卡型号：${raid_model:-见原始记录}。\
本次仅采集型号信息，未读取固件版本与逻辑盘状态（需要厂商专用管理工具，本测试盘未包含）。\
阵列卡不做压力测试，此项不影响整机结论。" \
        "raw/lspci.txt"
    else
      result_add "collect_raid" "阵列卡" "$absent_st" "未安装阵列卡${hint}" ""
    fi
  fi
}

# ---------------------------------------------------------------- 网卡
# nic_pci_model <ethtool总线地址> <lspci.txt路径> -> 商用型号名，取不到给空
#
# 单独抽成纯函数方便脱机测试（见 tests/test-hw-checks.sh）。
# ethtool -i 给的 bus-info 带 PCI domain 前缀（"0000:27:00.0"），
# lspci.txt 里的地址不带（"27:00.0"），要先去掉再比对；
# 地址里的 "." 在 grep 基础正则里是任意字符通配符，要转义成字面量，
# 不然理论上可能命中别的地址（概率极低，但没道理留这个坑）。
nic_pci_model() {
  local busaddr="${1#0000:}" lspci_file="$2" busaddr_esc
  [[ -n "$busaddr" && -f "$lspci_file" ]] || { printf ''; return; }
  busaddr_esc="${busaddr//./\\.}"
  grep "^${busaddr_esc} " "$lspci_file" 2>/dev/null | head -1 \
    | sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$//'
}

collect_nic() {
  info "Collecting NIC info ..."
  local n count=0
  : > "$RAW_DIR/nic-summary.txt"

  for n in /sys/class/net/*; do
    local ifn; ifn="$(basename "$n")"
    [[ "$ifn" == "lo" ]] && continue
    [[ -e "$n/device" ]] || continue     # 跳过虚拟接口
    count=$((count+1))
    {
      printf '===== %s =====\n' "$ifn"
      printf 'MAC        : %s\n' "$(cat "$n/address" 2>/dev/null)"
      printf 'OperState  : %s\n' "$(cat "$n/operstate" 2>/dev/null)"
      printf 'Speed      : %s Mb/s\n' "$(cat "$n/speed" 2>/dev/null || echo 'n/a')"
      printf '\n'
    } >> "$RAW_DIR/nic-summary.txt"

    capture "nic/${ifn}-ethtool.txt"  ethtool "$ifn"
    capture "nic/${ifn}-driver.txt"   ethtool -i "$ifn"

    # ethtool -i 只给驱动名和固件版本，不给网卡商用型号（比如"Intel X710"）。
    # 型号从 lspci 按总线地址反查回来，追加成 driver.txt 里的一个新字段，
    # 报告生成器已经在读这个文件，加一行最省事。
    #
    # 不走 BMC：BMC 的传感器/FRU 一般只覆盖板载 LOM 口所在的主板本身，
    # 拿不到每个网口具体是什么型号；lspci 反而是最直接可靠的来源，
    # 采集阶段本来就已经落了 raw/lspci.txt，不需要额外查 BMC。
    local busaddr pciname
    busaddr="$(awk -F': ' '/^bus-info:/{print $2}' "$RAW_DIR/nic/${ifn}-driver.txt" 2>/dev/null)"
    pciname="$(nic_pci_model "$busaddr" "$RAW_DIR/lspci.txt")"
    [[ -n "$pciname" ]] && printf 'model: %s\n' "$pciname" >> "$RAW_DIR/nic/${ifn}-driver.txt"
  done

  if (( count > 0 )); then
    result_add "collect_nic" "网卡" "$ST_PASS" "共 ${count} 个物理网口，已采集型号/固件/协商速率/链路状态" "raw/nic-summary.txt"
  else
    result_add "collect_nic" "网卡" "$ST_WARN" "未发现物理网口" ""
  fi
}

# ---------------------------------------------------------------- IPMI / BMC
collect_ipmi() {
  info "Collecting IPMI sensors and SEL ..."

  modprobe ipmi_devintf >/dev/null 2>&1 || true
  modprobe ipmi_si      >/dev/null 2>&1 || true
  sleep 1

  capture -t 60 "ipmi-mcinfo.txt" ipmitool mc info
  local rc=$?

  if (( rc != 0 )); then
    result_add "collect_ipmi" "IPMI/BMC" "$ST_SKIP" "未检测到 BMC（或无 IPMI 接口）" ""
    IPMI_OK=0
    return
  fi

  IPMI_OK=1
  capture -t 60 "ipmi-sensors.txt" ipmitool sensor list
  capture -t 60 "ipmi-sdr.txt"     ipmitool sdr elist all
  capture -t 60 "ipmi-sel-pre.txt" ipmitool sel list
  capture -t 60 "ipmi-fru.txt"     ipmitool fru print

  local selcount
  selcount="$(count_lines "$RAW_DIR/ipmi-sel-pre.txt")"
  result_add "collect_ipmi" "IPMI/BMC" "$ST_PASS" \
    "BMC 在线，已采集传感器读数；测前 SEL 共 ${selcount} 条" "raw/ipmi-sensors.txt"
}

# ---------------------------------------------------------------- 电源
# DMI type 39 -> 每行 "位置|状态"
#
# 用 awk 段落模式（RS=""）按 dmidecode 的空行分块，比在 bash 里逐行攒状态可靠。
dmi_psu_list() {
  local f="${1:-$RAW_DIR/dmidecode-psu.txt}"
  [[ -f "$f" ]] || return 0
  awk 'BEGIN{RS="";FS="\n"}
    /System Power Supply/ {
      loc=""; st="";
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^\tLocation:/)    { sub(/^\tLocation:[ \t]*/,    "", line); loc = line }
        else if (line ~ /^\tStatus:/) { sub(/^\tStatus:[ \t]*/,      "", line); st  = line }
      }
      if (loc != "" || st != "") printf "%s|%s\n", loc, st
    }' "$f"
}

# 某个电源有没有交流输入 -> present | absent | unknown
#
# 判据是 BMC 的输入电压/输入功率传感器，比 DMI 的 Status 靠得住：
# 机型之间 DMI 的 "Present, Critical" 既可能是没插电源线，也可能是真坏了，
# 而 Vin 读不到值或读到 0 V，就是这一路确实没进电。
psu_ac_state() {
  local idx="$1" f="${2:-$RAW_DIR/ipmi-sensors.txt}"
  [[ -f "$f" ]] || { printf 'unknown'; return; }

  local line v
  # 常见命名：PSU1_Vin / PSU1 VIN / PS1 Input Voltage / PSU1_Pin
  line="$(grep -iE "^[[:space:]]*(PSU|PS)_?${idx}[[:space:]_-]*(Vin|VIN|AC[_ ]?In|Input[_ ]?Volt|Pin)" \
          "$f" 2>/dev/null | head -1)"
  [[ -n "$line" ]] || { printf 'unknown'; return; }

  v="$(awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}' <<<"$line")"
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # 输入电压/功率大于 0 就算有电（交流 100~240V，功率几十瓦起）
    awk -v x="$v" 'BEGIN{exit !(x > 1)}' && printf 'present' || printf 'absent'
  else
    # na / no reading = 这个电源模块没在工作
    printf 'absent'
  fi
}

# 电源在位与供电检查。
#
# 只接了一半电源线在测试台上是常态，所以"没进电"判 WARN 而不是 FAIL；
# 但如果 BMC 明明读到有交流输入、DMI 又报 Critical/Failed，那就是模块本身坏了，判 FAIL。
check_psu() {
  info "Checking power supplies ..."

  local psus=() line
  while IFS= read -r line; do [[ -n "$line" ]] && psus+=("$line"); done < <(dmi_psu_list)

  if (( ${#psus[@]} == 0 )); then
    result_add "check_psu" "电源" "$ST_SKIP" \
      "BIOS 未上报电源信息（部分机型不提供 DMI type 39）" ""
    return
  fi

  # BMC 历史事件里的电源相关记录，单独摘一份出来存证
  local sel_psu=0
  if [[ -f "$RAW_DIR/ipmi-sel-pre.txt" ]]; then
    grep -iE 'Power Supply|PSU|Power Unit' "$RAW_DIR/ipmi-sel-pre.txt" \
      > "$RAW_DIR/ipmi-sel-psu.txt" 2>/dev/null || true
    sel_psu="$(count_lines "$RAW_DIR/ipmi-sel-psu.txt")"
  fi

  local total=0 present=0 idx=0
  local noac=() broken=() suspect=()
  for line in "${psus[@]}"; do
    idx=$((idx+1))
    total=$((total+1))
    local loc="${line%%|*}" st="${line#*|}"
    [[ -n "$loc" ]] || loc="PSU${idx}"

    # 位置名里带编号就用它（PSU2 -> 2），否则按出现顺序当编号
    local n; n="$(printf '%s' "$loc" | grep -oE '[0-9]+' | head -1)"
    [[ -n "$n" ]] || n="$idx"

    [[ "$st" == *"Present"* ]] || continue      # 槽位空着，不算
    present=$((present+1))

    local ac; ac="$(psu_ac_state "$n")"
    dbg "psu $loc status='$st' ac=$ac"

    if [[ "$ac" == "absent" ]]; then
      noac+=("$loc")
    elif [[ "$st" =~ (Critical|Failed|Non-recoverable) ]]; then
      # 判 FAIL 的前提是"BMC 确认这一路有交流输入、模块却还报异常"——那才是模块坏了。
      #
      # ac=unknown（没有 BMC，或者 BMC 上没有这个编号的 Vin 传感器）时不能判 FAIL：
      # 测试台上只接一半电源线是常态，而没有 BMC 的机器上 DMI 对"没插线"和
      # "模块坏了"报的都是 Present, Critical，光看 DMI 分不出来。
      # 这种情况下判 FAIL 会把一台好机器拦在出货前，属于误杀。
      if [[ "$ac" == "present" ]]; then
        broken+=("${loc}（${st}）")
      else
        suspect+=("${loc}（${st}）")
      fi
    fi
  done

  local sel_txt=""
  (( sel_psu > 0 )) && sel_txt="；BMC 历史事件中有 ${sel_psu} 条电源相关记录"
  local ref="raw/dmidecode-psu.txt"
  (( sel_psu > 0 )) && ref="raw/ipmi-sel-psu.txt"

  if (( ${#broken[@]} > 0 )); then
    result_add "check_psu" "电源" "$ST_FAIL" \
      "$(printf '%s、' "${broken[@]}")交流输入正常但模块状态异常，判定为电源模块故障${sel_txt}" "$ref"
  elif (( ${#suspect[@]} > 0 )); then
    result_add "check_psu" "电源" "$ST_WARN" \
      "$(printf '%s、' "${suspect[@]}")BIOS 报告状态异常，但本机读不到该路的交流输入传感器\
（没有 BMC，或 BMC 未提供对应编号的 Vin），无法区分是没接电源线还是模块本身故障，\
请人工确认电源线是否插好；共 ${present} 个电源模块在位${sel_txt}" "$ref"
  elif (( ${#noac[@]} > 0 )); then
    result_add "check_psu" "电源" "$ST_WARN" \
      "共 ${present} 个电源模块在位，其中 ${noac[*]} 未检测到交流输入（未接电源线，或该路市电/线缆异常），\
当前不具备电源冗余${sel_txt}" "$ref"
  else
    result_add "check_psu" "电源" "$ST_PASS" \
      "共 ${present} 个电源模块在位，交流输入与模块状态均正常${sel_txt}" "$ref"
  fi
}

# ---------------------------------------------------------------- PCIe 链路
# x16 的卡插在 x8 的槽上、或者链路只训练到 Gen1，机器照样能开机能跑，
# 性能砍一半，而出厂测试在这之前完全看不出来。lspci -vv 里其实一直有
# LnkCap（这个设备/槽位的额定能力）和 LnkSta（实际协商结果）两行，只是没人解析。
#
# ⚠️ 只查端点设备，绝对不能查 PCI bridge —— 这是拿现场数据验出来的：
#   c8:00.0 RTX 4090（端点）      LnkCap 16GT/s x16  LnkSta 16GT/s x16  ← 满速
#   27:00.0 82599 网卡（端点）    LnkCap  5GT/s x8   LnkSta  5GT/s x8   ← 满速
#   26:01.0 PCI bridge            LnkCap 32GT/s x8   LnkSta  5GT/s x8   ← 正常降速
#   00:0f.0 PCI bridge            LnkCap  8GT/s x1   LnkSta  5GT/s x1   ← 正常降速
# 桥的 LnkCap 是**槽位**的能力、LnkSta 是和对端设备协商的结果，对端是张老卡
# 就必然降下来，这是设计如此。把桥一起判，每台机器都会冒一堆告警。
#
# pcie_link_scan <lspci-vv文件> -> 每行 "BDF|设备名|额定速率|额定宽度|实际速率|实际宽度"
# 抽成纯函数便于脱机回归测试，见 tests/test-hw-checks.sh
pcie_link_scan() {
  local f="${1:-$RAW_DIR/lspci-vv.txt}"
  [[ -f "$f" ]] || return 0
  awk '
    function flush() {
      # 两条都拿到才输出；拿不到 LnkCap 的设备（板载集成的居多）直接不参与判定
      if (bdf != "" && capsp != "" && stasp != "")
        printf "%s|%s|%s|%s|%s|%s\n", bdf, name, capsp, capw, stasp, staw
      bdf=""; name=""; capsp=""; capw=""; stasp=""; staw=""
    }
    # 设备头行：顶格，形如 "c8:00.0 VGA compatible controller [0300]: NVIDIA ..."
    /^[0-9a-f]+:[0-9a-f]+\.[0-9a-f] / {
      flush()
      # 只挑这些端点类。故意用白名单而不是"排除桥"：
      # 白名单漏掉一类顶多少查一个设备，黑名单漏掉一类就是满屏误报。
      #   0200 以太网  0207 InfiniBand  0280 其它网络
      #   0300 VGA     0302 3D(计算卡)
      #   0104 RAID    0106 SATA  0107 SAS  0108 NVMe
      #   0c04 光纤通道
      if ($0 !~ /\[(0200|0207|0280|0300|0302|0104|0106|0107|0108|0c04)\]: /) next
      cur=$1
      # 设备名取 "[类号]: " 之后、" [厂商:设备]" 之前那一段
      line=$0
      sub(/^.*\[[0-9a-f]{4}\]: /, "", line)
      sub(/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$/, "", line)
      bdf=cur; name=line
      next
    }
    # 注意必须匹配 "LnkCap:" 带冒号 —— 还有一行 LnkCap2:（支持的速率列表），
    # 不带冒号地匹配会把那行也吃进来，取出来的数字完全不是一回事。
    bdf != "" && /LnkCap:/ {
      if (match($0, /Speed [0-9.]+GT\/s/)) { s=substr($0,RSTART+6,RLENGTH-6); sub(/GT\/s/,"",s); capsp=s }
      if (match($0, /Width x[0-9]+/))      { w=substr($0,RSTART+7,RLENGTH-7); capw=w }
      next
    }
    bdf != "" && /LnkSta:/ {
      if (match($0, /Speed [0-9.]+GT\/s/)) { s=substr($0,RSTART+6,RLENGTH-6); sub(/GT\/s/,"",s); stasp=s }
      if (match($0, /Width x[0-9]+/))      { w=substr($0,RSTART+7,RLENGTH-7); staw=w }
      next
    }
    END { flush() }
  ' "$f"
}

# 判 WARN 不判 FAIL，两个理由：
#   1. 空闲时降速是正常的电源管理行为 —— N 卡尤其明显，没负载时会自己掉到
#      Gen1，一加载就回满。采集是在空闲状态做的，判 FAIL 会误杀一大片。
#   2. x16 的卡插在 x8 槽上有时是机器设计如此（槽位本来就只有 x8 电气通道），
#      不一定是装配错误。
# WARN 会在报告抬头单独列一块，该看见的看得见，又不会把好机器拦在出货前。
check_pcie_link() {
  info "Checking PCIe link width/speed ..."

  local rows; rows="$(pcie_link_scan)"
  if [[ -z "$rows" ]]; then
    result_add "check_pcie_link" "PCIe 链路" "$ST_SKIP" \
      "未能从 lspci -vv 解析到任何端点设备的链路能力信息" "raw/lspci-vv.txt"
    return
  fi

  local total=0 degraded=() line bdf name capsp capw stasp staw
  while IFS='|' read -r bdf name capsp capw stasp staw; do
    [[ -n "$bdf" ]] || continue
    total=$((total+1))
    local why=""
    # 宽度是整数，直接比；速率带小数（2.5），交给 awk 比
    if [[ "$staw" =~ ^[0-9]+$ && "$capw" =~ ^[0-9]+$ ]] && (( staw < capw )); then
      why="宽度 x${staw}（额定 x${capw}）"
    fi
    if awk -v a="$stasp" -v b="$capsp" 'BEGIN{exit !(a+0 < b+0 && a+0 > 0)}'; then
      [[ -n "$why" ]] && why="${why}、"
      why="${why}速率 ${stasp}GT/s（额定 ${capsp}GT/s）"
    fi
    if [[ -n "$why" ]]; then
      degraded+=("${bdf} ${name}：${why}")
      metric_add "pcie" "${bdf} 链路" "x${staw} ${stasp}GT/s / 额定 x${capw} ${capsp}GT/s"
    fi
  done <<< "$rows"

  if (( ${#degraded[@]} > 0 )); then
    result_add "check_pcie_link" "PCIe 链路" "$ST_WARN" \
      "$(printf '%s；' "${degraded[@]}")共检查 ${total} 个端点设备。\
链路没跑到额定值会直接砍掉一半带宽，常见原因：卡没插到底、插在了电气通道更少的槽位、\
转接板/riser 信号质量不好。注意空闲状态下部分设备（尤其是显卡）会主动降速省电，\
加载后会自动回满，这种属于正常现象——请对照该设备满载时的读数确认。" \
      "raw/lspci-vv.txt"
  else
    result_add "check_pcie_link" "PCIe 链路" "$ST_PASS" \
      "${total} 个端点设备的链路宽度与速率均达到额定值" "raw/lspci-vv.txt"
  fi
}

# ---------------------------------------------------------------- 深度留档
# 这一整块只往 raw/ 里落原始数据，**不产生任何判定、不进客户报告**。
#
# 目的是"日后回档能查得更细"：机器发出去半年后客户反馈某个问题，
# 我们翻出当初的工程目录，能看到当时的固件版本、光模块型号、中断分布、
# NVMe 控制器参数……这些东西当时不看，出事时千金难买。
#
# ISO 和工程目录都只留在内部，所以这里可以放开采，唯一的约束是别拖慢现场：
# 每条都带超时，失败一律不影响流程。
collect_deep() {
  info "Collecting extended diagnostics for archival ..."

  # ---- CPU / 内存 / 主板的细节 ----
  capture -t 30 "deep/lscpu-extended.txt"  lscpu -e
  capture -t 30 "deep/cpuid-microcode.txt" cat /proc/cpuinfo
  capture -t 30 "deep/cmdline.txt"         cat /proc/cmdline
  capture -t 30 "deep/modules.txt"         cat /proc/modules
  capture -t 30 "deep/interrupts.txt"      cat /proc/interrupts
  capture -t 30 "deep/vmstat.txt"          cat /proc/vmstat
  capture -t 30 "deep/zoneinfo.txt"        cat /proc/zoneinfo
  capture -t 30 "deep/mtrr.txt"            cat /proc/mtrr
  capture -t 60 "deep/dmidecode-slots.txt" dmidecode -t 9
  capture -t 60 "deep/dmidecode-cache.txt" dmidecode -t 7
  capture -t 60 "deep/dmidecode-array.txt" dmidecode -t 16
  capture -t 60 "deep/dmidecode-oem.txt"   dmidecode -t 11
  capture -t 30 "deep/efibootmgr.txt"      efibootmgr -v

  # ---- 传感器原始读数（-u 是机器可读格式，好做趋势分析）----
  capture -t 30 "deep/sensors-raw.txt"     sensors -u

  # ---- 存储：扩展 SMART / NVMe 控制器细节 ----
  local dev base
  for dev in "${DISK_SMART[@]:-}"; do
    [[ -n "$dev" ]] || continue
    base="$(basename "$dev")"
    capture -t 60 "deep/smart-x-${base}.txt" smartctl -x "$dev"
    if [[ "$base" == nvme* ]]; then
      capture -t 30 "deep/nvme-id-ctrl-${base}.txt"   nvme id-ctrl "$dev"
      capture -t 30 "deep/nvme-smart-log-${base}.txt" nvme smart-log "$dev"
      capture -t 30 "deep/nvme-error-log-${base}.txt" nvme error-log "$dev"
    fi
  done
  capture -t 30 "deep/lsblk-all.txt" lsblk -O

  # ---- 网卡：统计计数器 + 光模块信息 ----
  # ethtool -m 能读出 SFP/QSFP 模块的厂商、型号、波长、收发光功率 ——
  # 光口机器出问题时这份数据最值钱，而且只有插着模块的时候才读得到。
  local n ifn
  for n in /sys/class/net/*; do
    ifn="$(basename "$n")"
    [[ "$ifn" == "lo" ]] && continue
    [[ -e "$n/device" ]] || continue
    capture -t 20 "deep/nic-${ifn}-stats.txt"  ethtool -S "$ifn"
    capture -t 20 "deep/nic-${ifn}-module.txt" ethtool -m "$ifn"
    capture -t 20 "deep/nic-${ifn}-ring.txt"   ethtool -g "$ifn"
    capture -t 20 "deep/nic-${ifn}-pause.txt"  ethtool -a "$ifn"
  done
  capture -t 20 "deep/ip-link-detail.txt" ip -d -s link show

  # ---- BMC 细节 ----
  if [[ "${IPMI_OK:-0}" == "1" ]]; then
    capture -t 60 "deep/ipmi-chassis.txt"  ipmitool chassis status
    capture -t 60 "deep/ipmi-lan.txt"      ipmitool lan print
    capture -t 60 "deep/ipmi-mc-getsysinfo.txt" ipmitool mc getsysinfo
  fi

  # ---- GPU 细节（有卡且驱动可用时才有意义）----
  if (( ${GPU_USABLE:-0} > 0 )) && have nvidia-smi; then
    capture -t 60 "deep/nvidia-topo.txt"     nvidia-smi topo -m
    capture -t 60 "deep/nvidia-ecc.txt"      nvidia-smi -q -d ECC
    capture -t 60 "deep/nvidia-clocks.txt"   nvidia-smi -q -d CLOCK
    capture -t 60 "deep/nvidia-power.txt"    nvidia-smi -q -d POWER
    capture -t 60 "deep/nvidia-perf.txt"     nvidia-smi -q -d PERFORMANCE
    # 逐卡一行的清单：序列号、VBIOS、显存、PCIe 额定/实际代数与宽度。
    # PCIe 那几列是"加载状态下"读的才准（空闲时 N 卡会主动降到 Gen1 省电），
    # 所以压测结束后 verify 阶段还会再采一次做对比。
    capture -t 60 "deep/nvidia-inventory.csv" \
      nvidia-smi --query-gpu=index,name,uuid,serial,vbios_version,driver_version,memory.total,pcie.link.gen.max,pcie.link.gen.current,pcie.link.width.max,pcie.link.width.current \
      --format=csv
  fi

  # ---- 完整的本次开机日志 ----
  capture -t 60 "deep/journal-boot.txt" journalctl -b --no-pager

  # 这一项永远是 PASS：它只留档，不判定。放进结果列表是为了让报告里
  # 有一行说明"这些数据已经存下来了"，但不影响整机结论。
  result_add "collect_deep" "扩展信息留档" "$ST_PASS" \
    "已完整保存本机的固件版本、插槽、传感器、存储与网络设备的详细参数，供日后追溯。" ""
}

# ---------------------------------------------------------------- 温度传感器
collect_sensors() {
  # 常见 CPU 温度驱动，先尝试加载
  modprobe coretemp >/dev/null 2>&1 || true   # Intel
  modprobe k10temp  >/dev/null 2>&1 || true   # AMD
  modprobe nct6775  >/dev/null 2>&1 || true
  sleep 1
  capture "sensors.txt"  sensors
  capture "sensors.json" sensors -j
}

# ---------------------------------------------------------------- 汇总入口
collect_all() {
  section "PHASE 1/4  HARDWARE INVENTORY"
  collect_system
  check_memory_capacity
  check_pcie_link     # 读的是 collect_system 落下的 lspci-vv.txt，必须排在它后面
  collect_sensors
  collect_smart "pre"
  # 顺序有讲究：网口是 down 的时候 ethtool 报的速率/链路状态是假的
  # （插着网线也报 Unknown!/no），所以先把口拉起来再采集，最后才做连通性测试。
  net_link_up_all     # 定义在 lib/network.sh
  collect_nic
  check_nic_speed     # 读的是 collect_nic 落下的 ethtool 输出，必须排在它后面
  net_test
  collect_ipmi
  # collect_raid 和 check_psu 都要用 collect_ipmi 采到的 BMC 传感器数据交叉验证，
  # 必须放在它后面
  collect_raid
  check_psu
  gpu_detect          # 定义在 lib/gpu.sh
  # 深度留档放在最后：它要用到前面所有阶段的结果（DISK_SMART / IPMI_OK / GPU_USABLE），
  # 而且只往 raw/ 里落数据、不产生判定，排在末尾对流程没有任何影响。
  collect_deep
  capture "dmesg-pre.txt" dmesg -T
  # 定义在 lib/verify.sh，但故意在这里（PHASE 1 末尾）调用而不是放进 verify_all：
  # 它扫的就是上面这份 dmesg-pre，而且现场应该在开始压测之前就知道机器有没有硬伤，
  # 不该白等 30 分钟跑完才看到。
  verify_dmesg_boot
}
