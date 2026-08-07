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

# ---------------------------------------------------------------- 阵列卡后端的物理盘
#
# 阵列卡工作在 RAID 模式时，/dev/sdX 是**逻辑盘**，物理盘根本不在 /dev 下。
# 直接 `smartctl -a /dev/sda` 读到的是逻辑盘，没有任何 SMART 属性 ——
# 于是"测前测后 SMART 对比"这一项在带阵列卡的机器上是**空跑**的：
# 报告里写着 PASS，实际一块物理盘都没查过。这台机器最可能坏的那几块盘，
# 恰恰一块都没被覆盖到。
#
# smartctl 提供了透传：`smartctl -a -d megaraid,<设备号> /dev/sda`。
# 难点只在"设备号是多少"。两条路，先走便宜的：
#   1. sysfs：megaraid_sas 会把物理盘也注册进 SCSI 层，只是不给它们块设备。
#      同一个 host 下"有 SCSI 设备、但没有 block 目录"的那些，target id 就是设备号。
#   2. 有界试探：sysfs 什么都没给出来时（不同固件行为不一样）从 0 开始试，
#      连续失败若干次就收工 —— 现场不能为了扫一圈设备号白等几分钟。
#
# 两条路都只在确认了 host 驱动是 megaraid_sas 之后才走，
# **没有阵列卡的机器一分钱开销都没有**。
#
# 抽成一组小的纯函数（sysfs 根目录可传参）以便脱机回归测试，
# 见 tests/test-hw-checks.sh 里「阵列卡后端物理盘」那组。
: "${MEGARAID_SCAN_MAX:=32}"     # 有界试探的上限
: "${MEGARAID_SCAN_MISS:=12}"    # 连续失败多少次就收工（设备号常见从 8 开始，别定太小）

# disk_scsi_host <块设备名> [sysfs根] -> SCSI host 号
disk_scsi_host() {
  local base="${1:-}" sysroot="${2:-/sys}" hctl
  [[ -n "$base" ]] || return 0
  hctl="$(basename "$(readlink -f "$sysroot/block/$base/device" 2>/dev/null)" 2>/dev/null)"
  [[ "$hctl" =~ ^([0-9]+):[0-9]+:[0-9]+:[0-9]+$ ]] || return 0
  printf '%s' "${BASH_REMATCH[1]}"
}

# scsi_host_driver <host号> [sysfs根] -> 驱动名（megaraid_sas / mpt3sas / ahci ...）
scsi_host_driver() {
  local h="${1:-}" sysroot="${2:-/sys}"
  [[ -n "$h" ]] || return 0
  cat "$sysroot/class/scsi_host/host${h}/proc_name" 2>/dev/null
}

# megaraid_pd_candidates <host号> [sysfs根] -> sysfs 里看到的候选设备号
megaraid_pd_candidates() {
  local h="${1:-}" sysroot="${2:-/sys}" d name t
  [[ -n "$h" ]] || return 0
  for d in "$sysroot"/class/scsi_device/"${h}":*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    # 有块设备的是逻辑盘本身，不是卡后面的物理盘
    [[ -d "$d/device/block" ]] && continue
    t="$(cut -d: -f3 <<<"$name")"
    [[ "$t" =~ ^[0-9]+$ ]] && printf '%s\n' "$t"
  done | sort -un
}

# megaraid_pd_probe <设备> <设备号> -> 0 = 这个设备号真的能读到一块盘
# 光有候选还不够：sysfs 的 target id 和阵列卡的设备号不是所有固件都一一对应，
# 必须真读一次才算数。
megaraid_pd_probe() {
  local dev="$1" n="$2" out
  out="$(timeout 10 smartctl -i -d "megaraid,$n" "$dev" 2>/dev/null)" || true
  grep -qiE '^(Device Model|Model Number|Product|Serial Number|Vendor):' <<<"$out"
}

# megaraid_pd_ids <块设备> -> 确认可读的物理盘设备号，每行一个
megaraid_pd_ids() {
  local dev="${1:-}" base h drv n miss=0 cands=()
  [[ -n "$dev" ]] || return 0
  have smartctl || return 0

  base="$(basename "$dev")"
  h="$(disk_scsi_host "$base")"
  [[ -n "$h" ]] || return 0
  [[ "$(scsi_host_driver "$h")" == "megaraid_sas" ]] || return 0

  while read -r n; do [[ -n "$n" ]] && cands+=("$n"); done < <(megaraid_pd_candidates "$h")

  if (( ${#cands[@]} > 0 )); then
    dbg "megaraid: sysfs candidates for $dev: ${cands[*]}"
    for n in "${cands[@]}"; do
      megaraid_pd_probe "$dev" "$n" && printf '%s\n' "$n"
    done
    return 0
  fi

  dbg "megaraid: no sysfs candidates for $dev, falling back to bounded scan"
  for (( n = 0; n < MEGARAID_SCAN_MAX; n++ )); do
    if megaraid_pd_probe "$dev" "$n"; then
      printf '%s\n' "$n"
      miss=0
    else
      miss=$(( miss + 1 ))
      (( miss >= MEGARAID_SCAN_MISS )) && break
    fi
  done
  return 0
}

# ---------------------------------------------------------------- 硬盘 SMART
# 要采 SMART 的对象。每项格式： <文件名key>|<smartctl 目标设备>|<-d 类型，空=自动>
#   sda|/dev/sda|                 普通盘 / 逻辑盘
#   sda-pd8|/dev/sda|megaraid,8   阵列卡后面那块物理盘
SMART_TARGETS=()

smart_targets_build() {
  SMART_TARGETS=()
  local dev base n
  for dev in "${DISK_SMART[@]:-}"; do
    [[ -n "$dev" ]] || continue
    base="$(basename "$dev")"
    SMART_TARGETS+=("${base}|${dev}|")
    while read -r n; do
      [[ -n "$n" ]] || continue
      info "  physical disk behind RAID controller: $dev -> megaraid,$n"
      SMART_TARGETS+=("${base}-pd${n}|${dev}|megaraid,${n}")
    done < <(megaraid_pd_ids "$dev")
  done
}

# 采集目标的 key 列表。verify.sh 用它做前后对比，别再各自去 basename。
smart_target_keys() {
  local item dev
  # ⚠️ 不能写 ${#SMART_TARGETS[@]:-0} —— 取长度和 :- 默认值不能连用，
  # bash 直接报 "bad substitution"，而这条路径上的报错会被吞掉，
  # 表现成"所有盘的 SMART 复查都变 SKIP"。数组在文件顶部已经声明过，直接取长度。
  if (( ${#SMART_TARGETS[@]} > 0 )); then
    for item in "${SMART_TARGETS[@]}"; do
      [[ -n "$item" ]] && printf '%s\n' "${item%%|*}"
    done
    return 0
  fi
  # 兜底：SMART_TARGETS 还没建立时（单元测试直接塞 DISK_SMART 的场景）
  for dev in "${DISK_SMART[@]:-}"; do
    [[ -n "$dev" ]] && basename "$dev"
  done
}

# collect_smart <phase>   phase = pre | post
collect_smart() {
  local phase="$1"
  local dir="smart-$phase"

  # 采集目标只在测前建立一次，测后原样复用：前后必须**逐项对齐**，
  # 否则"压测前后对比"就成了拿不同的盘互相比。
  if [[ "$phase" == "pre" ]] || (( ${#SMART_TARGETS[@]} == 0 )); then
    smart_targets_build
  fi

  info "Collecting SMART data ($phase-test) for ${#SMART_TARGETS[@]} device(s) ..."

  local item key dev dtype rc types t
  for item in "${SMART_TARGETS[@]:-}"; do
    [[ -n "$item" ]] || continue
    IFS='|' read -r key dev dtype <<< "$item"

    # 依次试几种设备类型，第一个读得通的就用它：
    #   普通盘     先自动识别，不行再试 SAT（阵列卡直通 / USB 桥接常见）
    #   阵列卡后端 先 megaraid 透传，SATA 盘还要再套一层 sat
    if [[ -n "$dtype" ]]; then
      types=("$dtype" "sat+$dtype")
    else
      types=("" "sat")
    fi

    for t in "${types[@]}"; do
      if [[ -n "$t" ]]; then
        capture "$dir/${key}.txt" smartctl -a -d "$t" "$dev"; rc=$?
      else
        capture "$dir/${key}.txt" smartctl -a "$dev"; rc=$?
      fi
      (( rc & 2 )) || break      # bit1 = 设备打不开，换下一种类型再试
    done

    if [[ -n "$t" ]]; then
      capture "$dir/${key}.json" smartctl -a -j -d "$t" "$dev" || true
    else
      capture "$dir/${key}.json" smartctl -a -j "$dev" || true
    fi

    # 归一化成固定字段，后面 verify.sh / 报告生成器直接读这个，
    # 免得每取一个字段都重跑一遍 smart.jq
    jq -f "$KLB_LIB/smart.jq" "$RAW_DIR/$dir/${key}.json" \
       > "$RAW_DIR/$dir/${key}.norm.json" 2>/dev/null \
       || echo '{}' > "$RAW_DIR/$dir/${key}.norm.json"
  done

  if [[ "$phase" == "pre" ]]; then
    capture "nvme-list.json" nvme list -o json
    capture "nvme-list.txt"  nvme list
    capture "lsblk.txt"      lsblk -o NAME,PATH,SIZE,TYPE,TRAN,ROTA,MODEL,SERIAL,FSTYPE,MOUNTPOINT

    local n_pd=0
    for item in "${SMART_TARGETS[@]:-}"; do
      [[ "$item" == *"|megaraid,"* ]] && n_pd=$(( n_pd + 1 ))
    done

    if (( ${#SMART_TARGETS[@]} == 0 )); then
      result_add "collect_disk" "硬盘信息采集" "$ST_WARN" \
        "本机未安装硬盘（未检测到任何内置存储设备）" ""
    elif (( n_pd > 0 )); then
      result_add "collect_disk" "硬盘信息采集" "$ST_PASS" \
        "共 ${#SMART_TARGETS[@]} 块盘，其中 ${n_pd} 块为阵列卡后端的物理盘（已通过阵列卡读取其 SMART）；\
已采集型号/序列号/固件/容量与 SMART 健康状态" "raw/smart-pre/"
    else
      result_add "collect_disk" "硬盘信息采集" "$ST_PASS" \
        "共 ${#SMART_TARGETS[@]} 块盘，已采集型号/序列号/固件/容量与 SMART 健康状态" "raw/smart-pre/"
    fi
  fi
}

# 在 lspci/storcli 都没找到卡的情况下，看 BMC 有没有为阵列卡/HBA 预留的传感器
# （温度、插槽/Riser 供电）。这类传感器条目是主板设计阶段就定义好的，装不装卡
# 都会出现在 SDR 里，所以"有定义"不能证明"真的装了卡"——但如果定义了却
# 一条读数都没有，至少说明"现在没有任何卡在这些槽位上响应"，值得提一句，
# 免得装了卡但没插到位（松动/转接板没到位）被当成"本来就没装"静默放过。
# ⚠️ 1.7.7 在这里修了两件事，一起看：
#
# 1. **它以前设的标志位根本传不出去。** 调用方写的是
#        hint="$(raid_bmc_hint)"
#    命令替换是**子 shell**，里面 `RAID_BMC_SILENT=1` 出了子 shell 就没了，
#    `raid_absent_status` 永远读到 0、永远返回 SKIP —— 那条"抬成 WARN"的折中
#    从上线起一次都没生效过。测试没抓住，因为它把两半**分开**测：一边验提示
#    文本、一边手工 `RAID_BMC_SILENT=1` 再验状态，**中间那根线一次都没测过**。
#    现在改成直接设全局、不经过命令替换，测试也改成验标志位本身。
#    （现场证据：海光那台 1.7.6 的报告里提示文本在，状态却是 SKIP。）
#
# 2. **但这条提示不再进客户报告，也不再抬 WARN。** 接线修好之后才看清后果：
#    海光那台真没装阵列卡、机器完全正常，却会因此在交付报告上多一条告警。
#    这个判据**分不开「本来就没装」和「卡坏到 PCI 都枚举不到」** ——
#    分不开的东西不该去染客户的结论（§2-2：把好机器拦在出货前，比漏判更糟）。
#    改成：现场屏幕和 klburn.log 上照常提示操作员去看一眼，
#    raw/raid-bmc-note.txt 留档给内部报告，客户报告里只写「未安装阵列卡」。
#    那次"卡坏到不枚举"的教训没有丢，只是换了个不会误伤客户的出口。
raid_bmc_hint() {
  RAID_BMC_SILENT=0
  [[ "${IPMI_OK:-0}" == "1" ]] || return 0
  local f="$RAW_DIR/ipmi-sdr.txt"
  [[ -s "$f" ]] || f="$RAW_DIR/ipmi-sensors.txt"
  [[ -s "$f" ]] || return 0

  local lines total populated
  lines="$(grep -iE 'raid|hba|riser|slot[0-9]' "$f" 2>/dev/null || true)"
  [[ -n "$lines" ]] || return 0

  total="$(printf '%s\n' "$lines" | grep -c .)"
  populated="$(printf '%s\n' "$lines" | grep -vciE '\bna\b|no reading')"
  if (( total > 0 && populated == 0 )); then
    RAID_BMC_SILENT=1
  fi
  return 0
}

# 「lspci 看不到卡」时那条提示往哪儿走。
#
# 背景是现场真事：同一台机器连着测两次——
#   第一次 阵列卡在 lspci 里还看得见，但 dmesg 里已经是 FW FAULT / reset 三次失败
#          / killing adapter
#   第二次 卡坏到连 PCI 枚举都过不去，lspci 里整个消失，判「未安装阵列卡」
# 一张物理上插着的卡坏成这样，报告写的是"没装卡"。
#
# 1.7.0 的对策是"BMC 传感器全哑就抬成 WARN"，但那条线因为子 shell 从没接通
# （见上面 raid_bmc_hint 的说明）。接通之后才看清：**这个判据分不开
# 「本来就没装」和「卡坏到不枚举」**，于是每台没装卡的好机器都会吃一条告警。
#
# 所以现在的出口是「说给人听，不写进客户结论」：
#   现场屏幕 + klburn.log    -> 操作员当场看得到，可以立刻去摸一把卡
#   raw/raid-bmc-note.txt    -> 内部工程报告留档，日后复盘查得到
#   客户报告                 -> 只写「未安装阵列卡」，状态 SKIP，不影响整机结论
raid_bmc_note() {
  (( ${RAID_BMC_SILENT:-0} == 1 )) || return 0
  warn "No RAID/HBA card on the PCI bus, and every BMC RAID/HBA/riser sensor is silent."
  info "  -> If a card IS installed, check the card and its riser are fully seated."
  {
    printf 'BMC 上为阵列卡/HBA 预留的温度和插槽供电传感器均无读数。\n'
    printf '板子设计上支持装卡，本次一条反馈都没读到。\n\n'
    printf '「本来就没装卡」和「卡坏到 PCI 都枚举不到」在数据上分不开，\n'
    printf '所以这条只作留档：不进客户报告，也不改变整机结论。\n'
    printf '如果这台机器确实装了阵列卡，去现场确认卡和转接板/riser 是否插到位。\n'
  } > "$RAW_DIR/raid-bmc-note.txt"
}

# ---------------------------------------------------------------- 阵列卡
# 内核驱动 in-tree 全都有（megaraid_sas / mpt3sas / mpi3mr / smartpqi / aacraid /
# hpsa），盘认得到、SMART 也读得到。缺的是**读阵列卡自己的固件版本和逻辑盘状态**
# 的那个闭源 CLI —— 各家一个，都有授权限制，不进版本库，构建时从 vendor/ 拿。
#
# 一条铁律：**盘里没带工具、或者带了但认不了这张卡，一律 SKIP，绝不 FAIL。**
# 那是我们这边环境的限制，跟被测机器好不好毫无关系（二号原则）。
# 客户可见文案里也绝不许出现工具名 —— 那是内部实现细节，见 report-policy.md。
#
# 顺序就是试的顺序，命中即用。storcli64 不在这张表里，它在 collect_raid 里
# **单独先试**：报告生成器是按 storcli-show.txt 这个固定文件名去读并嵌进报告的，
# 那条路径不能动。
# arcconf（Microchip / Adaptec）不在这张表里：它按控制器系列分版本，
# 手上没有对应的卡就无从判断该备哪一个。真遇到 Adaptec 卡时，这里和
# build/chroot-setup.sh 的 VENDOR_RAID_TOOLS 各加一行、再补一个 case 分支即可。
RAID_TOOL_ORDER=(perccli64 ssacli sas3ircu)

# raid_tool_run <工具名> -> 0 = 这张卡它认得（原始输出已落 raw/raid/）
#
# 判据只问一件事："它到底看没看到控制器"。看不到有两种可能——没装卡、
# 或者这个牌子的工具认不了别家的卡——两种都不是机器的问题，都往 SKIP 走。
raid_tool_run() {
  local t="$1" bin="$KLB_TOOLS/$1"
  [[ -x "$bin" ]] || return 1
  case "$t" in
    perccli64)
      # Dell PERC。它就是 storcli 换的皮，子命令一模一样 —— 但**版本对不上会
      # 认不到卡**（storcli 认不了 PERC、perccli 认不了原厂 MegaRAID），
      # 所以两个都带、都试。
      capture -t 90 "raid/${t}-show.txt"   "$bin" /call show all
      capture -t 90 "raid/${t}-pdlist.txt" "$bin" /call/eall/sall show all
      capture -t 90 "raid/${t}-vd.txt"     "$bin" /call/vall show all
      capture -t 90 "raid/${t}-enclosure.txt" "$bin" /call/eall show all
      grep -qiE 'Controller = [0-9]|Product Name' "$RAW_DIR/raid/${t}-show.txt" 2>/dev/null
      ;;
    arcconf)
      # Microchip / Adaptec（smartpqi、aacraid）
      # ⚠️ 这个分支当前**走不到** —— arcconf 不在 RAID_TOOL_ORDER 里（见上面的说明）。
      # 故意留着：真拿到 Adaptec 卡时，把它加回那张表就能直接用。
      capture -t 90 "raid/${t}-list.txt"   "$bin" LIST
      capture -t 90 "raid/${t}-config.txt" "$bin" GETCONFIG 1
      grep -qiE 'Controller [0-9]|Controllers found' "$RAW_DIR/raid/${t}-list.txt" 2>/dev/null
      ;;
    ssacli)
      # HPE Smart Array
      capture -t 90 "raid/${t}-ctrl.txt" "$bin" ctrl all show config detail
      grep -qiE 'Smart Array|in Slot' "$RAW_DIR/raid/${t}-ctrl.txt" 2>/dev/null
      ;;
    sas3ircu)
      # LSI/Broadcom HBA 的非 RAID（IT）模式 —— 这类卡 storcli 是不管的
      capture -t 60 "raid/${t}-list.txt"    "$bin" LIST
      capture -t 60 "raid/${t}-display.txt" "$bin" 0 DISPLAY
      grep -qiE 'Controller Type|SAS[0-9]{4}' "$RAW_DIR/raid/${t}-list.txt" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

# raid_unbound_devices <lspci-vv 文件> -> 每行 "<BDF>\t<型号>"
#
# 挑出**驱动本该管得了、却没管上**的阵列卡 / HBA。
#
# 1.8.1 现场那台 Supermicro（Montage Jintide C5218R）逼出来的：
# 一张 MegaRAID SAS-3 3108 固件挂在 FAULT state，驱动连试两次都没能接管，
# 整张卡不可用、后面的盘一块都看不到 —— 而「阵列卡」那一项报的是
#   SKIP  ...未读取固件版本与逻辑盘状态（当前测试环境的管理工具不支持该型号）
# 把**一张坏卡**说成了**我们的工具不行**，还附赠一句"此项不影响整机结论"。
#
# 这是 §2-2 那条红线的反面，而且更危险：「能力缺失 ≠ 硬件故障」要防的是
# 误伤好机器，**反过来把硬件故障粉饰成能力缺失，是把坏机器放出厂**。
#
# 判据要两条同时成立，缺一不可：
#   有 "Kernel modules: xxx"     内核里确实带了这张卡的驱动
#   没有 "Kernel driver in use"  但它没能接管这张卡
#
# 为什么必须两条都要：
#   - 两条都没有 = 内核里压根没有这张卡的驱动。那是**我们**的能力缺失，
#     判故障就是把好卡说成坏卡，正是 §2-2 要挡的那种误判。
#   - 有 driver in use = 驱动接管了，只是管理工具读不到详情 -> 那才是工具的事，
#     照旧 SKIP。
#
# 抽成纯函数以便脱机回归，见 tests/test-hw-checks.sh
raid_unbound_devices() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  awk '
    function flush() {
      if (bdf != "" && israid && mods && !inuse) printf "%s\t%s\n", bdf, name
    }
    # 设备块开头形如 "86:00.0 Serial Attached SCSI controller [0107]: Broadcom ..."
    # 域号可有可无（0000:86:00.0），两种都要认。
    /^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F] / {
      flush()
      bdf = $1; israid = 0; mods = 0; inuse = 0
      israid = ($0 ~ /RAID bus controller|Serial Attached SCSI controller/)
      name = $0
      sub(/^[^ ]+ [^:]*: /, "", name)              # 去掉 BDF 和类别
      sub(/ \[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\].*$/, "", name)   # 去掉厂商:设备 ID 及其后
      next
    }
    /Kernel driver in use:/ { inuse = 1 }
    /Kernel modules:/       { mods  = 1 }
    END { flush() }
  ' "$f" 2>/dev/null
}

collect_raid() {
  info "Collecting RAID controller info ..."

  # lspci 里认不认得到 RAID 控制器
  local raid_pci
  raid_pci="$(grep -iE 'RAID bus controller|Serial Attached SCSI|MegaRAID' "$RAW_DIR/lspci.txt" 2>/dev/null || true)"

  # ⚠️ **直接调用，绝不能写成 `x="$(raid_bmc_hint)"`。** 命令替换是子 shell，
  # 它设的 RAID_BMC_SILENT 出了子 shell 就没了 —— 1.7.0~1.7.6 就是这么让
  # 整条线变成死代码的（详见 raid_bmc_hint 上面那段）。
  raid_bmc_hint

  # ---- 先试 storcli64 ----
  # 它单独一段、raw/ 文件名写死不动：报告生成器是按 storcli-show.txt 这个名字
  # 去读、去嵌进报告的，改名等于把那一块从报告里抹掉，而且不会有任何报错。
  local hit=0 ref="raw/lspci.txt"
  if [[ -x "$KLB_TOOLS/storcli64" ]]; then
    capture -t 90 "storcli-show.txt"     "$KLB_TOOLS/storcli64" /call show all
    capture -t 90 "storcli-pdlist.txt"   "$KLB_TOOLS/storcli64" /call/eall/sall show all
    capture -t 90 "storcli-vd.txt"       "$KLB_TOOLS/storcli64" /call/vall show all
    capture -t 90 "storcli-events.txt"   "$KLB_TOOLS/storcli64" /call show events type=latest=50
    # 背板（机框）：这条给的是**每个背板有几个盘位**（Number of Slots）。
    # 只进内部报告，用来回档"这台机器当初是 12 盘位还是 4 盘位×3"。
    capture -t 90 "storcli-enclosure.txt" "$KLB_TOOLS/storcli64" /call/eall show all
    if grep -qiE 'Controller = [0-9]|Product Name' "$RAW_DIR/storcli-show.txt" 2>/dev/null; then
      hit=1; ref="raw/storcli-show.txt"
    fi
  fi

  # ---- storcli 没命中，再挨个试别家的 ----
  # 场景很实在：Dell PERC 要 perccli、HPE Smart Array 要 ssacli、
  # Adaptec/Microchip 要 arcconf、IT 模式的 LSI HBA 要 sas3ircu —— 一张卡只有
  # 对得上的那个工具认得。以前盘里只带 storcli64，于是所有非 Broadcom 的阵列卡
  # 都只能报一个 PCI 型号，固件版本和逻辑盘状态一概读不到。
  if (( ! hit )); then
    local t
    for t in "${RAID_TOOL_ORDER[@]}"; do
      if raid_tool_run "$t"; then hit=1; ref="raw/raid/"; break; fi
    done
  fi

  if (( hit )); then
    result_add "collect_raid" "阵列卡" "$ST_PASS" \
      "已采集阵列卡型号、固件版本与逻辑盘状态。阵列卡不做压力测试。" "$ref"
  elif [[ -n "$raid_pci" ]]; then
    # 卡在机器里，但盘里没有对得上的管理工具（或者带了却认不了这个型号）。
    # 文案是给客户看的，不能出现"重新出盘""构建目录"这类只有开发者看得懂的话。
    # 而且这一项**本来就只采集不压测**，读不到固件版本不代表机器有问题，
    # 所以判 SKIP 而不是 WARN —— WARN 会在报告抬头单独列一块，
    # 客户看到"告警"却发现只是少个管理工具，反而显得机器有毛病。
    #
    # 型号是从 PCI 反查的，一样准确，客户关心的"这台机器装了什么卡"照常有。
    local raid_model
    raid_model="$(printf '%s' "$raid_pci" | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\].*$//')"

    # 读不到详情有两种完全不同的原因，判定和文案都不能混：
    #   驱动没能接管这张卡 -> 卡本身有问题，判 FAIL
    #   驱动接管了、只是没有对得上的管理工具 -> 我们的能力缺失，判 SKIP
    local unbound; unbound="$(raid_unbound_devices "$RAW_DIR/lspci-vv.txt")"
    if [[ -n "$unbound" ]]; then
      local ub_n ub_model ub_ref="raw/lspci-vv.txt"
      ub_n="$(printf '%s\n' "$unbound" | grep -c .)"
      ub_model="$(printf '%s' "$unbound" | head -1 | cut -f2)"
      # 开机日志里通常有对应的固件故障链，有就指过去，那份更能说明问题
      [[ -s "$RAW_DIR/dmesg-errors-boot.txt" ]] && ub_ref="raw/dmesg-errors-boot.txt"
      result_add "collect_raid" "阵列卡" "$ST_FAIL" \
        "检测到阵列卡：${ub_model:-${raid_model:-见原始记录}}。\
该卡在系统中可见，但**驱动未能接管它**（本机已带有该型号的驱动），因此这张卡当前不可用，\
挂在它后面的硬盘在操作系统里也看不到。常见原因是阵列卡固件异常或卡本身故障，\
建议检修或更换后复测。${ub_n:+（共 ${ub_n} 张卡处于此状态）}" \
        "$ub_ref"
      return
    fi

    # 卡在机器里、驱动也接管了，只是盘里没有对得上的管理工具。
    # 文案是给客户看的，不能出现"重新出盘""构建目录"这类只有开发者看得懂的话。
    # 这一项**本来就只采集不压测**，读不到固件版本不代表机器有问题，
    # 所以判 SKIP 而不是 WARN —— WARN 会在报告抬头单独列一块，
    # 客户看到"告警"却发现只是少个管理工具，反而显得机器有毛病。
    result_add "collect_raid" "阵列卡" "$ST_SKIP" \
      "已识别阵列卡型号：${raid_model:-见原始记录}。\
本次仅采集型号信息，未读取固件版本与逻辑盘状态（当前测试环境的管理工具不支持该型号）。\
阵列卡不做压力测试，此项不影响整机结论。" \
      "raw/lspci.txt"
  else
    # BMC 全哑那条提示走屏幕 + klburn.log + raw 留档，不进这句客户可见的文案
    raid_bmc_note
    result_add "collect_raid" "阵列卡" "$ST_SKIP" "未安装阵列卡" ""
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

# ---------------------------------------------------------------- 清 BMC 事件日志
#
# 现场诉求：机器拷完机之后，BMC 里往往还压着一堆装机阶段留下的报错
# （拔插硬盘、电源没插好、反复上下电……）。那些事件跟这台机器出厂后的状态
# 没关系，留着只会让客户开机一看 SEL 全是红的。
#
# ⚠️ 名字必须老老实实叫「事件日志(SEL)」，不能叫「所有日志」：
#    IPMI 标准里能清的只有 SEL 这一个。不少厂商 BMC 另有独立的审计日志 /
#    操作日志 / 诊断快照，那些要走各家私有接口或 Redfish，ipmitool 够不着。
#    现场要是以为"点一下全清干净了"，反而会漏掉真正该清的地方。
#
# 只动日志，不动任何设置：`ipmitool sel clear` 就是清事件记录这一件事，
# 网络配置、用户、传感器阈值、启动项一概不碰。
#
# **故意不放进自动流程**，只挂在收尾菜单上手动触发：
# 清日志是不可逆的，而 SEL 恰恰是我们判定 verify_sel 的依据 ——
# 自动清就等于把自己的证据先销毁掉。
bmc_clear_sel() {
  if ! have ipmitool; then
    printf '  %sipmitool not available - cannot talk to the BMC.%s\n' "$C_YEL" "$C_RST"
    return 1
  fi

  # 先确认 BMC 真的在，别让操作员对着一台没有 BMC 的机器等超时
  if ! timeout 60 ipmitool mc info >/dev/null 2>&1; then
    printf '  %sNo BMC detected on this machine (no IPMI interface).%s\n' "$C_YEL" "$C_RST"
    return 1
  fi

  local before after
  before="$(timeout 60 ipmitool sel list 2>/dev/null | grep -c .)"
  [[ "$before" =~ ^[0-9]+$ ]] || before=0

  printf '\n'
  printf '  %s+----------------------------------------------------------+%s\n' "$C_YEL$C_BLD" "$C_RST"
  printf '  %s|  CLEAR BMC EVENT LOG (SEL)                               |%s\n' "$C_YEL$C_BLD" "$C_RST"
  printf '  %s+----------------------------------------------------------+%s\n' "$C_YEL$C_BLD" "$C_RST"
  printf '  Entries currently in the SEL : %s%s%s\n' "$C_BLD" "$before" "$C_RST"
  printf '  This erases the BMC EVENT LOG ONLY.\n'
  printf '  BMC settings (network, users, thresholds) are %sNOT%s touched.\n' "$C_BLD" "$C_RST"
  printf '  %sThis cannot be undone.%s\n' "$C_RED$C_BLD" "$C_RST"
  printf '  %sNote: vendor-specific audit/operation logs are not covered by IPMI.%s\n\n' "$C_GRY" "$C_RST"

  # 和硬盘破坏性写用同一道门槛：必须原样打出 yes。
  # 打错 / 直接回车 / 超时，一律当成不清。
  local answer=""
  if ! read_line_countdown answer 60 "  Type yes to clear the SEL >"; then
    printf '  %sNo input - SEL left untouched.%s\n' "$C_GRY" "$C_RST"
    return 1
  fi
  local norm="${answer//[[:space:]]/}"
  if [[ "${norm,,}" != "yes" ]]; then
    printf '  %sNot confirmed - SEL left untouched.%s\n' "$C_GRY" "$C_RST"
    return 1
  fi

  printf '  Clearing ...\n'
  if ! timeout 120 ipmitool sel clear >/dev/null 2>&1; then
    printf '  %sSEL clear command failed (BMC refused or timed out).%s\n' "$C_RED" "$C_RST"
    return 1
  fi

  # BMC 清 SEL 是异步的，清完立刻读往往还是旧数字。等一下再复核。
  sleep 3
  after="$(timeout 60 ipmitool sel list 2>/dev/null | grep -c .)"
  [[ "$after" =~ ^[0-9]+$ ]] || after=0

  if (( after == 0 )); then
    printf '  %sSEL cleared: %s entries -> 0.%s\n' "$C_GRN$C_BLD" "$before" "$C_RST"
    return 0
  fi
  # 清了但没清空：有些 BMC 会立刻补一条"SEL 被清空"的记录，那是正常的。
  printf '  %sSEL now has %s entries (was %s).%s\n' "$C_YEL" "$after" "$before" "$C_RST"
  printf '  %sSome BMCs immediately log a "Log Area Reset" entry - that is normal.%s\n' \
    "$C_GRY" "$C_RST"
  return 0
}

# ---------------------------------------------------------------- 电源
# DMI type 39 -> 每行 "位置|状态"
#
# 用 awk 段落模式（RS=""）按 dmidecode 的空行分块，比在 bash 里逐行攒状态可靠。
#
# 第三个字段是"这一位到底有没有真的插着电源"。**空的电源位，BIOS 照样报
# `Present, OK`** —— 6530 那台的 PSU4 就是：厂商/型号/序列号全是
# `To Be Filled By O.E.M.`，额定功率 0 W，可状态写着在位。照单全收的话报告上
# 会写「共 4 个电源模块在位」，实际只有 3 个，客户一数电源就发现对不上。
#
# 判据要三个条件**同时**成立才算幽灵：
#   1. Max Power Capacity 那行**显式存在**，而且值是 0
#   2. 厂商/型号/序列号里**至少有一个字段存在**
#   3. 存在的那些身份字段**全是占位符**
#
# 三条缺一不可，每一条都对着一种会误杀真电源的写法：
#   只看功率     -> 有些 BIOS 对真电源也不填额定功率
#   只看身份     -> 6530 的 PSU3 厂商是占位符，但序列号和 2700W 都是真的
#   **字段缺失当占位符** -> 最小 DMI（只有 Location + Status）的真电源会被整条吃掉。
#     这条是写完第一版被测试当场抓住的：字段"没写"和字段"写了个占位符"
#     是两件事，前者只是 BIOS 懒，后者才是空槽位。
dmi_psu_list() {
  local f="${1:-$RAW_DIR/dmidecode-psu.txt}"
  [[ -f "$f" ]] || return 0
  awk 'BEGIN{RS="";FS="\n"}
    function junk(s) {
      s = tolower(s); gsub(/^[ \t]+|[ \t]+$/, "", s)
      return (s == "" || s == "to be filled by o.e.m." || s == "not specified" \
              || s == "default string" || s == "unknown" || s == "n/a" \
              || s == "none" || s == "not present" || s == "o.e.m.")
    }
    /System Power Supply/ {
      loc=""; st=""; cap=""; capseen=0; idseen=0; idreal=0
      for (i = 1; i <= NF; i++) {
        line = $i
        if (line ~ /^\tLocation:/)    { sub(/^\tLocation:[ \t]*/,    "", line); loc = line }
        else if (line ~ /^\tStatus:/) { sub(/^\tStatus:[ \t]*/,      "", line); st  = line }
        else if (line ~ /^\tMax Power Capacity:/) {
          sub(/^\tMax Power Capacity:[ \t]*/, "", line); cap = line; capseen = 1
        }
        else if (line ~ /^\t(Manufacturer|Name|Serial Number|Model Part Number):/) {
          sub(/^\t[^:]*:[ \t]*/, "", line); idseen = 1
          if (!junk(line)) idreal = 1
        }
      }
      real = (capseen && cap + 0 == 0 && idseen && !idreal) ? 0 : 1
      if (loc != "" || st != "") printf "%s|%s|%s\n", loc, st, real
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

  # 上报了、但每一条都是空槽位（占位符 + 未在位）。和"压根没上报"是两回事，
  # 得分开说：前者是 BIOS 把表填满了占位符，后者是根本没这张表。
  # 两种都判 SKIP —— 我们确实没有可用的电源数据，说不出这台机器电源好不好。
  local usable=0
  for line in "${psus[@]}"; do
    local _st="${line#*|}"; _st="${_st%%|*}"
    local _real="${line##*|}"
    [[ "$_real" == "1" ]] || continue
    [[ "$_st" == *"Present"* && "$_st" != *"Not Present"* ]] || continue
    usable=$((usable+1))
  done
  if (( usable == 0 )); then
    result_add "check_psu" "电源" "$ST_SKIP" \
      "BIOS 上报的电源槽位均标记为未在位、且没有型号或序列号，据此无法判定电源状态\
（部分机型的 BIOS 不填这张表）。此项不影响整机结论。" "raw/dmidecode-psu.txt"
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
    local loc="${line%%|*}" rest="${line#*|}"
    local st="${rest%%|*}" real="${rest##*|}"
    [[ -n "$loc" ]] || loc="PSU${idx}"

    # 幽灵槽位（0 W + 身份全是占位符）整条不算 —— 不进总数，也不进"在位"数
    [[ "$real" == "1" ]] || { dbg "psu $loc 判为空槽位（额定 0W 且无身份信息），不计入"; continue; }
    total=$((total+1))

    # 位置名里带编号就用它（PSU2 -> 2），否则按出现顺序当编号
    local n; n="$(printf '%s' "$loc" | grep -oE '[0-9]+' | head -1)"
    [[ -n "$n" ]] || n="$idx"

    # ⚠️ **`Not Present` 里含有 `Present` 子串。** 原来写的是
    #       [[ "$st" == *"Present"* ]] || continue
    #    于是槽位明写 "Not Present" 也被算成在位 —— 海光那台两个槽位 DMI 全是
    #    `Status: Not Present` / `Plugged: No`，报告却打出「共 2 个电源模块在位，
    #    交流输入与模块状态均正常」PASS。判错的方向还是最糟的那个：
    #    真缺一路电源的机器会被说成正常。这就是一号红线（拿关键字当判定）
    #    在电源这条路上的同款。
    [[ "$st" == *"Present"* && "$st" != *"Not Present"* ]] || continue
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

# ---------------------------------------------------------------- 板载 vs 插槽
#
# 1.7.4 那台海光：板载千兆口协商到 x2（额定 x4），报告里报了个 WARN。
# **那条 WARN 没有意义。** 板载设备的通道数是主板厂商的走线设计，现场既拔不下来
# 也插不进去，客户看到只会以为机器有毛病。而插在真插槽上的卡降速是**能修的**
# （没插到底、插错槽、riser 信号差），那个必须照报。
#
# 判据是 SMBIOS Type 9（System Slot）的 Bus Address。两种填法都见过，都要认，
# 而且**不能靠猜，要去 lspci 里查这个地址到底是什么**：
#
#   地址在 lspci 里是端点   -> "填卡自己"（Intel 6530：RAID_Slot1 -> 28:00.0）
#                              同一张卡的别的功能号也算在槽里
#   地址在 lspci 里是桥     -> "填插槽那个桥"（6530 空槽：RAID_Slot1 -> 26:05.0）
#                              桥的 secondary..subordinate 总线范围内的都算在槽里
#   地址在 lspci 里查不到   -> 空槽/被固件藏了，**什么都不匹配**
#
# ⚠️ 「填卡自己」那种要比到 bus:dev 就停，**不能带功能号**：DMI 只列 function 0，
#    而双口网卡的 27:00.1、显卡的 c8:00.1（HDMI 音频）是同一块板子上的别的功能。
#    带着功能号比，插在槽上的卡降了速也不报 —— 恰好是这次要修的反面。
#    这条有成对断言钉着。
# ⚠️ 「填桥」那种反过来**必须带功能号**：00:01.1 / 00:01.4 / 00:01.6 是三个
#    互不相干的 root port，砍掉功能号会把三个槽混成一个。
#
# pcie_slot_map [dmidecode文件] [lspci-vv文件] -> 每行 "BDF|slot|插槽名" / "BDF|onboard|"
# 抽成纯函数便于脱机回归测试，见 tests/test-hw-checks.sh
pcie_slot_map() {
  local dmi="${1:-$RAW_DIR/dmidecode.txt}" vv="${2:-$RAW_DIR/lspci-vv.txt}"
  [[ -f "$dmi" && -f "$vv" ]] || return 0
  # 盘里是 mawk，不能用 gawk 才有的 strtonum()，所以自己转十六进制
  awk '
    function hex2dec(s,   i, c, v, r) {
      r = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1)); v = index("0123456789abcdef", c) - 1
        if (v < 0) return -1
        r = r * 16 + v
      }
      return r
    }
    function devof(b) { sub(/\.[0-9a-f]+$/, "", b); return b }

    # ---- 第一遍：dmidecode 的 System Slot ----
    NR == FNR {
      if ($0 ~ /^System Slot Information/) { insl = 1; desig = ""; next }
      if (insl && $0 ~ /Designation:/) { sub(/^[^:]*: */, ""); desig = $0; next }
      if (insl && $0 ~ /Bus Address:/) {
        sub(/^[^:]*: */, ""); a = $0; sub(/^0000:/, "", a)
        if (a ~ /^[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+$/) { slotdesig[a] = desig; slots[++ns] = a }
        insl = 0; next
      }
      if ($0 ~ /^Handle /) insl = 0
      next
    }

    # ---- 第二遍：lspci -vv ----
    # 认桥用**类号 0604**，不用 "PCI bridge" 这个名字 —— 名字来自 pci.ids，
    # 换一版库或换个 locale 就可能不一样；类号是 PCI 规范定死的。
    /^[0-9a-f]+:[0-9a-f]+\.[0-9a-f] / {
      bdf = $1
      order[++n] = bdf
      present[bdf] = 1
      isbridge[bdf] = ($0 ~ /\[0604\]: /) ? 1 : 0
      next
    }
    # 注意别写成 /^\tBus: primary=/ —— lspci 这几行是**两个 tab** 缩进
    /Bus: primary=/ {
      if (match($0, /secondary=[0-9a-f]+/))   brsec[bdf] = substr($0, RSTART + 10, RLENGTH - 10)
      if (match($0, /subordinate=[0-9a-f]+/)) brsub[bdf] = substr($0, RSTART + 12, RLENGTH - 12)
      next
    }

    END {
      # 固件压根没给插槽表 -> **一行都不输出**。
      # 这时候把所有设备标成 "onboard" 是在撒谎：我们不是判定它板载，
      # 是根本分不清。调用方按"表是空的"走 SKIP，别让它和"插槽都空着"混起来。
      if (ns == 0) exit

      # 每个 DMI 插槽地址先定性：端点式 / 桥式 / 查不到
      for (i = 1; i <= ns; i++) {
        a = slots[i]
        if (!(a in present)) continue                 # 空槽，什么都不盖
        if (isbridge[a]) { brslot[a] = 1 }            # 桥式：按总线范围盖
        else             { devslot[devof(a)] = slotdesig[a] }   # 端点式：按 bus:dev 盖
      }
      for (i = 1; i <= n; i++) {
        b = order[i]
        if (isbridge[b]) continue                     # 桥自己不参与（见 pcie_link_scan 的说明）
        where = "onboard"; label = ""
        k = devof(b)
        if (k in devslot) { where = "slot"; label = devslot[k] }
        else {
          split(b, p, ":"); mybus = hex2dec(p[1])
          for (a in brslot) {
            if (brsec[a] == "" || brsub[a] == "") continue
            if (hex2dec(brsec[a]) <= mybus && mybus <= hex2dec(brsub[a])) {
              where = "slot"; label = slotdesig[a]; break
            }
          }
        }
        printf "%s|%s|%s\n", b, where, label
      }
    }
  ' "$dmi" "$vv"
}

# 判 WARN 不判 FAIL，两个理由：
#   1. 空闲时降速是正常的电源管理行为 —— N 卡尤其明显，没负载时会自己掉到
#      Gen1，一加载就回满。采集是在空闲状态做的，判 FAIL 会误杀一大片。
#   2. x16 的卡插在 x8 槽上有时是机器设计如此（槽位本来就只有 x8 电气通道），
#      不一定是装配错误。
# WARN 会在报告抬头单独列一块，该看见的看得见，又不会把好机器拦在出货前。
#
# **只判插槽上的扩展卡**（1.7.5 起）。板载的照样采、照样落进 raw/pcie-link.txt
# 供工程排查，但不进客户报告 —— 理由见上面 pcie_slot_map 那一段。
check_pcie_link() {
  info "Checking PCIe link width/speed ..."

  local rows; rows="$(pcie_link_scan)"
  if [[ -z "$rows" ]]; then
    result_add "check_pcie_link" "PCIe 链路" "$ST_SKIP" \
      "未能从 lspci -vv 解析到任何端点设备的链路能力信息" "raw/lspci-vv.txt"
    return
  fi

  # BDF -> slot/onboard。取不到插槽信息时整张表是空的，下面按"分不清"处理。
  local -A slot_of=() slot_name=()
  local sb sw sn
  while IFS='|' read -r sb sw sn; do
    [[ -n "$sb" ]] || continue
    slot_of["$sb"]="$sw"; slot_name["$sb"]="$sn"
  done < <(pcie_slot_map)

  local slot_total=0 board_total=0 degraded=() board_degraded=()
  local bdf name capsp capw stasp staw
  : > "$RAW_DIR/pcie-link.txt"
  while IFS='|' read -r bdf name capsp capw stasp staw; do
    [[ -n "$bdf" ]] || continue
    local where="${slot_of[$bdf]:-unknown}"
    local why=""
    # 宽度是整数，直接比；速率带小数（2.5），交给 awk 比
    if [[ "$staw" =~ ^[0-9]+$ && "$capw" =~ ^[0-9]+$ ]] && (( staw < capw )); then
      why="宽度 x${staw}（额定 x${capw}）"
    fi
    if awk -v a="$stasp" -v b="$capsp" 'BEGIN{exit !(a+0 < b+0 && a+0 > 0)}'; then
      [[ -n "$why" ]] && why="${why}、"
      why="${why}速率 ${stasp}GT/s（额定 ${capsp}GT/s）"
    fi

    printf '%-12s %-8s %-22s cap=x%-3s %-6sGT/s  sta=x%-3s %-6sGT/s  %s\n' \
      "$bdf" "$where" "${slot_name[$bdf]:--}" "$capw" "$capsp" "$staw" "$stasp" \
      "${why:-满足额定值}" >> "$RAW_DIR/pcie-link.txt"

    if [[ "$where" == "slot" ]]; then
      slot_total=$((slot_total+1))
      if [[ -n "$why" ]]; then
        degraded+=("${bdf} ${name}：${why}")
        # metric 会进客户报告的「其他实测指标」，所以只记插槽上的
        metric_add "pcie" "${bdf} 链路" "x${staw} ${stasp}GT/s / 额定 x${capw} ${capsp}GT/s"
      fi
    else
      board_total=$((board_total+1))
      [[ -n "$why" ]] && board_degraded+=("${bdf}")
    fi
  done <<< "$rows"

  # 固件没给插槽表 -> 分不清板载和插槽。宁可不判，也不要拿板载走线去吓客户。
  if (( ${#slot_of[@]} == 0 )); then
    result_add "check_pcie_link" "PCIe 链路" "$ST_SKIP" \
      "本机固件未提供 PCIe 插槽信息，无法区分板载集成设备与插槽上的扩展卡\
（部分平台与虚拟机不提供）。此项不影响整机结论。" "raw/pcie-link.txt"
    return
  fi

  if (( ${#degraded[@]} > 0 )); then
    result_add "check_pcie_link" "PCIe 链路" "$ST_WARN" \
      "$(printf '%s；' "${degraded[@]}")共检查 ${slot_total} 张插槽上的扩展卡。\
链路没跑到额定值会直接砍掉一半带宽，常见原因：卡没插到底、插在了电气通道更少的槽位、\
转接板/riser 信号质量不好。注意空闲状态下部分设备（尤其是显卡）会主动降速省电，\
加载后会自动回满，这种属于正常现象——请对照该设备满载时的读数确认。\
（板载集成设备的链路宽度由主板走线决定，不属于装配问题，不参与本项判定。）" \
      "raw/pcie-link.txt"
  elif (( slot_total == 0 )); then
    result_add "check_pcie_link" "PCIe 链路" "$ST_SKIP" \
      "本机 PCIe 插槽上未安装扩展卡，没有需要判定的链路\
（板载集成设备的链路宽度由主板走线决定，不参与本项判定）。此项不影响整机结论。" \
      "raw/pcie-link.txt"
  else
    result_add "check_pcie_link" "PCIe 链路" "$ST_PASS" \
      "${slot_total} 张插槽上的扩展卡，链路宽度与速率均达到额定值\
（板载集成设备的链路宽度由主板走线决定，不参与本项判定）。" "raw/pcie-link.txt"
  fi
}

# ================================================================
# 计数器快照（压测前后各一次，判定看的是**差值**）
# ================================================================
#
# 这一组是 1.7.0 的重点：出厂老化真正该抓的东西，光看"压测跑完没报错"是看不到的。
#
#   ECC        内存的早期退化。一条内存开始出可纠正错误时，机器照样能跑、
#              压测照样过，但它在客户机房里会越来越频繁，最后变成不可纠正。
#   热节流     散热不行、但温度**没到阈值**的机器，就是靠这个看出来的：
#              CPU 自己在降频保护，温度曲线反而好看。
#   PCIe AER   链路层的错误计数。偶发可纠正很常见，压测期间新增就值得查。
#
# 三条都是**内核自带的 sysfs 计数器**，不依赖任何额外工具 —— 盘里带了
# ras-mc-ctl / edac-util 是为了多一份人可读的原始记录，判定不靠它们。
# 这很要紧：工具没带 = 能力缺失，不能因此判故障（二号原则）。
#
# 三个 *_snapshot 都吃一个 sysfs 根目录参数（默认 /sys），
# 这样 tests/test-hw-checks.sh 能搭一棵假树喂它们。

# ecc_snapshot [sysfs根] -> 每行 "ECC <位置标签> <可纠正数> <不可纠正数>"
#
# 逐条 DIMM 归位靠 dimm_label（BIOS 给的插槽名，形如 CPU0_DIMM_A1）。
# 老内核只有 csrow/rank 的粒度，两种目录名都认。
ecc_snapshot() {
  local sysroot="${1:-/sys}" d label ce ue
  for d in "$sysroot"/devices/system/edac/mc/mc[0-9]*/dimm[0-9]* \
           "$sysroot"/devices/system/edac/mc/mc[0-9]*/rank[0-9]*; do
    [[ -d "$d" ]] || continue
    ce=""; ue=""
    [[ -r "$d/dimm_ce_count" ]] && ce="$(<"$d/dimm_ce_count")"
    [[ -r "$d/dimm_ue_count" ]] && ue="$(<"$d/dimm_ue_count")"
    [[ "$ce" =~ ^[0-9]+$ && "$ue" =~ ^[0-9]+$ ]] || continue
    label=""
    [[ -r "$d/dimm_label" ]] && label="$(<"$d/dimm_label")"
    # 标签可能是空的（BIOS 没填）。退回用 sysfs 路径当标签 ——
    # 不好看，但至少前后两次快照能对得上，差值算得出来。
    [[ -n "${label// /}" ]] || label="$(basename "$(dirname "$d")")/$(basename "$d")"
    printf 'ECC %s %s %s\n' "${label// /_}" "$ce" "$ue"
  done
}

# throttle_snapshot [sysfs根] -> 每行 "THROTTLE <cpu> <core计数> <package计数>"
throttle_snapshot() {
  local sysroot="${1:-/sys}" d n core pkg
  for d in "$sysroot"/devices/system/cpu/cpu[0-9]*/thermal_throttle; do
    [[ -d "$d" ]] || continue
    n="$(basename "$(dirname "$d")")"
    core=0; pkg=0
    [[ -r "$d/core_throttle_count" ]]    && core="$(<"$d/core_throttle_count")"
    [[ -r "$d/package_throttle_count" ]] && pkg="$(<"$d/package_throttle_count")"
    [[ "$core" =~ ^[0-9]+$ ]] || core=0
    [[ "$pkg"  =~ ^[0-9]+$ ]] || pkg=0
    printf 'THROTTLE %s %s %s\n' "$n" "$core" "$pkg"
  done
}

# aer_snapshot [sysfs根] -> 每行 "AER <BDF> <可纠正> <不可纠正致命> <不可纠正非致命>"
#
# aer_dev_* 是逐项计数的文本表，最后一行是 TOTAL_ERR_COR / TOTAL_ERR_FATAL 之类，
# 只取总数就够 —— 逐项明细留在 raw/ 里给人看。
aer_snapshot() {
  local sysroot="${1:-/sys}" d bdf cor fat nfat
  for d in "$sysroot"/bus/pci/devices/*; do
    [[ -d "$d" ]] || continue
    [[ -r "$d/aer_dev_correctable" ]] || continue
    bdf="$(basename "$d")"
    cor="$(awk '/^TOTAL_ERR_COR/{print $2; exit}'   "$d/aer_dev_correctable" 2>/dev/null)"
    fat="$(awk '/^TOTAL_ERR_FATAL/{print $2; exit}' "$d/aer_dev_fatal"       2>/dev/null)"
    nfat="$(awk '/^TOTAL_ERR_FATAL/{print $2; exit}' "$d/aer_dev_nonfatal"   2>/dev/null)"
    [[ "$cor"  =~ ^[0-9]+$ ]] || cor=0
    [[ "$fat"  =~ ^[0-9]+$ ]] || fat=0
    [[ "$nfat" =~ ^[0-9]+$ ]] || nfat=0
    printf 'AER %s %s %s %s\n' "$bdf" "$cor" "$fat" "$nfat"
  done
}

# counters_snapshot <phase>  —— 三份快照落到 raw/counters-<phase>.txt
collect_counters() {
  # 分两条 local：同一条里后一个看不到前一个刚赋的值（§11-8），
  # 写成一行的话 $phase 是空的、文件名会变成 counters-.txt。
  local phase="$1"
  local f="$RAW_DIR/counters-${phase}.txt"
  {
    printf '# KLBurn counter snapshot (%s)\n' "$phase"
    ecc_snapshot
    throttle_snapshot
    aer_snapshot
  } > "$f" 2>/dev/null

  # 人可读的那几份原始记录（有工具才有，没有就是没有，不影响上面的判定）
  if [[ "$phase" == "pre" ]] || [[ "$phase" == "post" ]]; then
    capture -t 30 "counters/ras-mc-ctl-${phase}.txt"  ras-mc-ctl --error-count
    capture -t 30 "counters/ras-summary-${phase}.txt" ras-mc-ctl --summary
    capture -t 30 "counters/edac-util-${phase}.txt"   edac-util -v
  fi
}

# counters_delta <字段前缀> <pre文件> <post文件> -> 每行 "<键> <前> <后> <增量>"
# 只输出**增量大于 0** 的行 —— 判定要的就是"压测把什么逼出来了"。
#
# 抽成纯函数便于脱机回归测试：喂两份手写的快照就能验差值算得对不对。
counters_delta() {
  local kind="$1" pre="$2" post="$3"
  [[ -f "$pre" && -f "$post" ]] || return 0
  awk -v kind="$kind" '
    FNR==NR { if ($1 == kind) { for (i = 3; i <= NF; i++) a[$2 "\t" i] = $i }; next }
    $1 == kind {
      for (i = 3; i <= NF; i++) {
        k = $2 "\t" i
        # 前一次没有这一项（热插拔/枚举变了）就当基线为 0，不要算成负数
        b = (k in a) ? a[k] : 0
        d = $i - b
        if (d > 0) printf "%s %d %d %d %d\n", $2, i - 2, b, $i, d
      }
    }' "$pre" "$post"
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
  # 走 SMART_TARGETS 而不是 DISK_SMART：阵列卡后面的物理盘也要留一份 -x，
  # 那上面才有完整的属性表和自检日志，事后回查最值钱的就是它。
  local item key dev dtype
  for item in "${SMART_TARGETS[@]:-}"; do
    [[ -n "$item" ]] || continue
    IFS='|' read -r key dev dtype <<< "$item"
    if [[ -n "$dtype" ]]; then
      capture -t 60 "deep/smart-x-${key}.txt" smartctl -x -d "$dtype" "$dev"
    else
      capture -t 60 "deep/smart-x-${key}.txt" smartctl -x "$dev"
    fi
    if [[ "$key" == nvme* ]]; then
      capture -t 30 "deep/nvme-id-ctrl-${key}.txt"   nvme id-ctrl "$dev"
      capture -t 30 "deep/nvme-smart-log-${key}.txt" nvme smart-log "$dev"
      capture -t 30 "deep/nvme-error-log-${key}.txt" nvme error-log "$dev"
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

  # ---- 全机固件版本清单 ----
  # 离线可用（不联网只是查不到"有没有新版"，本机现有版本照样读得到）。
  # 内部报告里做成一张表，核对"这批机器的固件版本齐不齐"非常实用。
  capture -t 60 "deep/fwupd-devices.txt" fwupdmgr get-devices --no-unreported-check
  capture -t 30 "deep/fwupd-devices.json" fwupdmgr get-devices --json --no-unreported-check

  # ---- CPU 特性位 / MSR ----
  capture -t 30 "deep/cpuid.txt" cpuid -1
  modprobe msr >/dev/null 2>&1 || true
  # MSR_PKG_ENERGY_STATUS(0x611) / MSR_TEMPERATURE_TARGET(0x1a2) / MSR_PKG_POWER_LIMIT(0x610)
  # 只读不写。读不到（AMD 平台 MSR 号不同、或者内核禁了 msr）就是读不到，不影响任何判定。
  capture -t 20 "deep/msr-power.txt" rdmsr -a 0x611
  capture -t 20 "deep/msr-tjmax.txt" rdmsr -a 0x1a2
  capture -t 20 "deep/msr-pkg-power-limit.txt" rdmsr 0x610

  # ---- 迈络思网卡的固件版本 / PSID ----
  # ethtool -i 在 mlx5 上给的固件版本串信息量很少，mstflint 才有 PSID 和 PXE 版本。
  local mlx
  while read -r mlx; do
    [[ -n "$mlx" ]] || continue
    capture -t 30 "deep/mstflint-${mlx//:/_}.txt" mstflint -d "$mlx" q
  done < <(awk '/Mellanox|ConnectX/{print $1}' "$RAW_DIR/lspci.txt" 2>/dev/null | head -8)

  # ---- 机框 / 背板（SES）----
  # 盘位、风扇、温度、电源在背板上的状态。存储机上这份最值钱。
  #
  # 两页都要，缺一不可：
  #   -p es (enclosure status)        每个元件当下的状态
  #   -p cf (configuration)           背板**有几个盘位**、厂商型号
  # 「几盘位」这个数只在 cf 页里（"number of possible elements"），
  # es 页给不出来。内部报告的背板一节就是靠 cf 页出的。
  local ses
  while read -r ses; do
    [[ -n "$ses" ]] || continue
    capture -t 30 "deep/sg_ses-$(basename "$ses").txt"    sg_ses -p es "$ses"
    capture -t 30 "deep/sg_ses-cf-$(basename "$ses").txt" sg_ses -p cf "$ses"
  done < <(lsscsi -g 2>/dev/null | awk '/enclosu/{print $NF}' | head -8)

  # ---- NVMe 厂商扩展 SMART 页 ----
  # nvme-cli 自带各厂商插件，厂商专有的健康度/寿命字段是**白捡的**，
  # 不需要任何闭源工具。认不了这块盘的插件会直接报错，capture 记下来就行。
  local item key dev dtype vend
  for item in "${SMART_TARGETS[@]:-}"; do
    [[ -n "$item" ]] || continue
    IFS='|' read -r key dev dtype <<< "$item"
    [[ "$key" == nvme* ]] || continue
    for vend in intel wdc micron seagate samsung sndk; do
      capture -t 20 "deep/nvme-${vend}-smart-${key}.txt" nvme "$vend" smart-log-add "$dev"
    done
  done

  # ---- LLDP 邻居：这个口接在哪台交换机的哪个口 ----
  # lldpd 是在 net_link_up_all 之后以**接收模式**拉起来的（见 lib/network.sh），
  # 到这里已经过了整个采集阶段，足够收到一轮通告（交换机一般 30 秒发一次）。
  capture -t 30 "deep/lldp-neighbors.txt" lldpctl
  capture -t 30 "deep/lldp-neighbors.json" lldpctl -f json

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
  # LLDP 邻居要有 daemon 在收才有。**必须排在 net_link_up_all 之后**
  # （口是 down 的时候收不到任何通告），而且要尽早起 —— 交换机一般 30 秒
  # 才发一次，起晚了到 collect_deep 那一步还没收到东西。
  lldp_start          # 定义在 lib/network.sh
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
  # 计数器基线。**必须在压测开始之前取**，测后减它才是"压测逼出来的"。
  # 三样都是内核自带的 sysfs 计数器，不依赖任何工具。
  collect_counters "pre"
  capture "dmesg-pre.txt" dmesg -T
  # 定义在 lib/verify.sh，但故意在这里（PHASE 1 末尾）调用而不是放进 verify_all：
  # 它扫的就是上面这份 dmesg-pre，而且现场应该在开始压测之前就知道机器有没有硬伤，
  # 不该白等 30 分钟跑完才看到。
  verify_dmesg_boot
}
