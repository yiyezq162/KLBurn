#!/usr/bin/env bash
# KLBurn 配置一致性核对
#
# 这一块回答的是「**这台机器装的东西对不对、齐不齐、一不一致**」：同一台机器里
# 同规格的部件，型号 / 固件版本 / 颗粒型号是不是一致；整机序列号在 BIOS 和 BMC
# 两处对不对得上；平台的几个关键设置（x2APIC / VT-d / 每路 NUMA 节点数 /
# 板载网卡）现在是什么状态。
#
# ⚠️ **这些是通用能力，不是为某一份验收表定制的。**
# 各家的出厂验收表大同小异，配置检查那一段问的基本都是上面这几件事，所以这里
# 做的是"把这几件事如实测出来、写清楚"，而不是"照着某一份表逐条打钩"。
# 具体某家要求什么值（x2APIC 该开还是该关、内存要哪个 PN），是**那一份订单**
# 的事 —— 我们只负责把实测状态摆出来，让人拿自己的表去对。
#
# ================================================================
# 三条贯穿本文件的定性，改之前先读：
#
# 1. **一致性不符一律判 WARN，不判 FAIL。**
#    混插的内存、两批不同固件的网卡，都是**配置问题**，不是"这台机器坏了"。
#    出货前该确认，但不该拦住整机结论 —— 这正是 WARN 的语义
#    （报告抬头会单独列一块"建议出货前确认"）。
#
# 2. **平台设置（BIOS 那几项）只记录、不判定。**
#    "x2APIC 该开还是该关"是**每一份订单各自的要求**，不是硬件好坏；而这张盘
#    是插上就跑、无人值守的，现场没有人、也没有地方去填"这台机器该配成什么样"。
#    凭空写一个期望值进来，等于我们替客户定了一个他没定过的标准。
#    **如实读出来、写清楚，剩下的交给拿订单的人去对。**
#
# 3. **读不到 = SKIP，永远不是 FAIL。**
#    BIOS 没填 PN、机器没有 BMC、内核没打开 EDAC —— 都是"这一格没数据"，
#    跟机器好不好毫无关系。
#
# 判读逻辑一律抽成纯函数（只吃文件路径、只吐字符串），
# 好拿真机样本脱机回归，见 tests/test-hw-checks.sh。
# ================================================================

# ---------------------------------------------------------------- 通用小工具
#
# uniq_values —— 从 stdin 读若干行，去掉空行和占位符，输出去重后的值。
#
# ⚠️ 必须过掉占位符再去重。BIOS 没填 PN 的那几条读回来全是
# "Not Specified" / "<BAD INDEX>"，照单去重就会得到 {真PN, Not Specified}
# 两个值，然后报"内存型号不一致" —— 一台内存完全一致的机器被判成混插。
# 占位符名单和 core.sh 的 _serial_is_bogus 是同一套判据（§6-1"读不出来的
# 标记不是内容"），这里复用它，不再单独维护第二份。
uniq_values() {
  local line
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    _serial_is_bogus "$line" && continue
    printf '%s\n' "$line"
  done | sort -u
}

# count_uniq —— 上面那个的计数版本，保证输出是个干净的整数
count_uniq() { uniq_values | grep -c . || true; }

# join_cn <分隔符> —— 从 stdin 读若干行，拼成一行。给中文文案用。
# 空输入输出空串（调用点全都用 [[ -n ]] 判过再拼句子）。
join_cn() {
  local sep="${1:-、}"
  awk -v s="$sep" 'NF{printf "%s%s", (n++ ? s : ""), $0} END{printf ""}'
}

# ---------------------------------------------------------------- DMI 内存字段
# dmi_dimm_field <dmidecode -t memory 的文件> <字段名> -> 每条**已装**内存一行
#
# 只输出真的插了条的槽位：`Size: No Module Installed` 的空槽跳过。
#
# ⚠️ 判"这是第几行 Size"不能用正则去躲 `Volatile Size`（DDR5 每条会多打一行）。
#    这里按**整段**（dmidecode 的块之间是空行）处理，段内只认行首制表符紧跟
#    字段名的那一行，用 substr 精确比对，不做正则转义 —— 字段名里带空格
#    （"Part Number"）时正则很容易写错，而这个函数错了的表现是
#    "每台机器都说内存不一致"。
dmi_dimm_field() {
  local f="${1:-}" field="${2:-}"
  [[ -f "$f" && -n "$field" ]] || return 0
  awk -v want="$field" '
    BEGIN { RS = ""; FS = "\n" }
    {
      size = ""; val = ""
      sp = "\tSize: "; wp = "\t" want ": "
      for (i = 1; i <= NF; i++) {
        line = $i
        sub(/\r$/, "", line)
        if (size == "" && substr(line, 1, length(sp)) == sp)
          size = substr(line, length(sp) + 1)
        if (val == "" && substr(line, 1, length(wp)) == wp)
          val = substr(line, length(wp) + 1)
      }
      if (size == "" || size ~ /No Module Installed/) next
      if (val != "") print val
    }' "$f" 2>/dev/null
}

# ---------------------------------------------------------------- 内存一致性
# 常见验收要求：「同一台机器的内存条型号（PN）一致」。
#
# 同时看三样：颗粒型号（Part Number）、厂商、配置频率。三样里任何一样有两种
# 取值就算不一致 —— 混插最常见的形态是"PN 一样但频率被拉低到最慢那条"。
check_dimm_uniform() {
  local f="$RAW_DIR/dmidecode-memory.txt"
  if [[ ! -s "$f" ]]; then
    result_add "check_dimm_uniform" "内存条一致性" "$ST_SKIP" \
      "未能读取主板 BIOS 记录的内存条明细，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  local pn_n mf_n sp_n pn_list sp_list n
  n="$(dmi_dimm_field "$f" "Locator" | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n == 0 )); then
    result_add "check_dimm_uniform" "内存条一致性" "$ST_SKIP" \
      "主板 BIOS 未提供内存条明细，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  pn_n="$(dmi_dimm_field "$f" "Part Number"              | count_uniq)"
  mf_n="$(dmi_dimm_field "$f" "Manufacturer"             | count_uniq)"
  sp_n="$(dmi_dimm_field "$f" "Configured Memory Speed"  | count_uniq)"
  pn_list="$(dmi_dimm_field "$f" "Part Number"             | uniq_values | join_cn '、')"
  sp_list="$(dmi_dimm_field "$f" "Configured Memory Speed" | uniq_values | join_cn '、')"

  metric_add "conform" "内存条数" "$n"
  [[ -n "$pn_list" ]] && metric_add "conform" "内存颗粒型号" "$pn_list"
  [[ -n "$sp_list" ]] && metric_add "conform" "内存运行频率" "$sp_list"

  # 一格都没读出来（BIOS 三样全是占位符）—— 不是不一致，是没数据
  if (( pn_n == 0 && mf_n == 0 && sp_n == 0 )); then
    result_add "check_dimm_uniform" "内存条一致性" "$ST_SKIP" \
      "本机 BIOS 未填写内存条的厂商与颗粒型号，无法核对一致性。此项不影响整机结论。" \
      "raw/dmidecode-memory.txt"
    return 0
  fi

  local bad=""
  (( pn_n > 1 )) && bad="${bad}颗粒型号 ${pn_n} 种（${pn_list}）；"
  (( mf_n > 1 )) && bad="${bad}厂商 ${mf_n} 种；"
  (( sp_n > 1 )) && bad="${bad}运行频率 ${sp_n} 种（${sp_list}）；"

  if [[ -n "$bad" ]]; then
    result_add "check_dimm_uniform" "内存条一致性" "$ST_WARN" \
      "本机装有 ${n} 条内存，规格不完全一致：${bad}混插不影响机器正常工作，\
但整机内存会按最低规格的那一条运行，建议出货前按订单要求确认。" \
      "raw/dmidecode-memory.txt"
  else
    result_add "check_dimm_uniform" "内存条一致性" "$ST_PASS" \
      "${n} 条内存的厂商、颗粒型号与运行频率完全一致${pn_list:+（${pn_list}）}" \
      "raw/dmidecode-memory.txt"
  fi
}

# ---------------------------------------------------------------- 网卡一致性
# 常见验收要求：「同规格网卡的型号与固件版本一致」。
#
# nic_model_fw <nic 采集目录> -> 每行 "<型号>|<固件版本>"
#
# 型号取 collect_nic 追加进 driver.txt 的那一行（从 lspci 按总线地址反查来的
# 商用型号），取不到就退回驱动名 —— 退回驱动名仍然有意义：同一个驱动下的口
# 固件版本本来就该一致。
nic_model_fw() {
  local dir="${1:-}" f model fw drv
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*-driver.txt; do
    [[ -f "$f" ]] || continue
    model="$(awk -F': ' '/^model: /{sub(/^model: /,""); print; exit}' "$f" 2>/dev/null)"
    drv="$(awk -F': ' '/^driver:/{print $2; exit}' "$f" 2>/dev/null)"
    fw="$(awk -F': ' '/^firmware-version:/{sub(/^firmware-version:[[:space:]]*/,""); print; exit}' "$f" 2>/dev/null)"
    [[ -n "$model" ]] || model="$drv"
    [[ -n "$model" ]] || continue
    printf '%s|%s\n' "$model" "${fw:-}"
  done
}

check_nic_uniform() {
  local dir="$RAW_DIR/nic"
  local rows; rows="$(nic_model_fw "$dir")"
  if [[ -z "$rows" ]]; then
    result_add "check_nic_uniform" "网卡固件一致性" "$ST_SKIP" \
      "未采集到网口的型号与固件版本，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  # 按型号分组，看每组里的固件版本有几种
  local models bad="" ok_list="" m fws nfw
  models="$(printf '%s\n' "$rows" | cut -d'|' -f1 | sort -u)"
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    fws="$(printf '%s\n' "$rows" | awk -F'|' -v M="$m" '$1==M{print $2}' | uniq_values)"
    nfw="$(printf '%s\n' "$fws" | grep -c . || true)"
    [[ "$nfw" =~ ^[0-9]+$ ]] || nfw=0
    if (( nfw > 1 )); then
      bad="${bad}${m}：${nfw} 种固件版本（$(printf '%s\n' "$fws" | join_cn '、')）；"
    elif (( nfw == 1 )); then
      ok_list="${ok_list}${m} ${fws}；"
    else
      ok_list="${ok_list}${m}（未上报固件版本）；"
    fi
  done <<< "$models"

  [[ -n "$ok_list" ]] && metric_add "conform" "网卡固件" "${ok_list%；}"

  if [[ -n "$bad" ]]; then
    result_add "check_nic_uniform" "网卡固件一致性" "$ST_WARN" \
      "同型号网卡的固件版本不一致：${bad}建议出货前统一固件版本。" "raw/nic-summary.txt"
  else
    result_add "check_nic_uniform" "网卡固件一致性" "$ST_PASS" \
      "同型号网口的固件版本一致：${ok_list%；}" "raw/nic-summary.txt"
  fi
}

# ---------------------------------------------------------------- 硬盘一致性
# 常见验收要求：「同规格硬盘的型号一致」。
#
# 规格 = 接口类型 + 容量（同容量同接口的盘才该是同型号）。
# 读的是 scan_disks 已经落盘的 lsblk.json，不额外跑任何命令。
#
# ⚠️⚠️ **比的必须是"这台机器的盘"，而 `.rm` 这个标志判不出这件事。**
#
# 我们自己这根启动 U 盘，在真机上报的是 `tran=usb` 但 **`rm=false`** ——
# `rm` 说的是"介质可不可换"（读卡器那种），不是"它挂在 USB 上"。实测那台
# 「没插硬盘」的机器：lsblk 里唯一一块 disk 就是我们的盘（SA400S37120G，
# rm=false），只按 `.rm` 过滤的话，一台**一块硬盘都没有**的机器会得到一条
# 「硬盘型号一致性 PASS：按接口与容量分为 1 组」—— 而同一份报告里
# 「硬盘信息采集」写的是「本机未安装硬盘」。两句话自相矛盾，而且那一组
# 说的是我们自己的 U 盘。真要撞上同容量不同型号的 USB 盘，还会凭空判出一条
# 「同规格硬盘的型号不一致」并把我们自己那根盘的型号印给客户。
#
# 「哪些盘算这台机器自己的」这件事 `scan_disks` 已经算好了（§8.2 那一整套
# 启动盘反查，`test-disk-exclusion.sh` 守着），结果就在 `DISK_SMART[]` 里。
# **别在这儿重新发明一遍**，直接拿它当范围。`.rm` 那一条留着当第二道防线。
#
# disk_spec_model <lsblk.json> [范围文件] -> 每行 "<接口>_<容量字节>|<型号>"
#   范围文件：每行一个设备名（`sda` 或 `/dev/sda`）。给了就只认这些。
#   **给了路径却没有那个文件时宁可一条都不输出**，绝不悄悄退回全量 ——
#   退回去正是这条 bug 本来的样子。
disk_spec_model() {
  local f="${1:-}" scope="${2:-}"
  [[ -s "$f" ]] || return 0
  local rows
  # ⚠️ `.rm` 在不同 lsblk 版本里既可能是布尔 true/false，也可能是字符串 "1"/"0"。
  #    只判 `!= true` 的话，老版本上可换介质的设备会被当成本机硬盘。一律先 tostring。
  rows="$(jq -r '
    [.blockdevices[]? | recurse(.children[]?)]
    | .[]
    | select(.type == "disk")
    | select((.model // "") != "")
    | select(((.rm // false) | tostring) as $r | $r != "true" and $r != "1")
    | "\(.name)\t\(.tran // "unknown")_\(.size)|\(.model)"
  ' "$f" 2>/dev/null | sed 's/[[:space:]]*$//')"
  [[ -n "$rows" ]] || return 0

  if [[ -n "$scope" ]]; then
    [[ -f "$scope" ]] || return 0
    # ⚠️ **别用 `NR==FNR` 那个惯用法读范围文件。**范围为空是正常情况
    #    （这台机器一块本机硬盘都没有），而第一个文件是空的时候 NR 和 FNR
    #    会在第二个文件里一路相等 —— 整条数据流全被当成"范围行"吃掉。
    #    这里恰好和我们想要的结果一样（空范围 -> 不输出），
    #    **对的结果、错的理由**：改天语义一变就是一个没人看得出来的 bug。
    #    在 BEGIN 里显式读进来，空文件就是空 keep[]，没有任何巧合成分。
    printf '%s\n' "$rows" | awk -F'\t' -v scopefile="$scope" '
      BEGIN {
        while ((getline line < scopefile) > 0) {
          gsub(/[[:space:]]/, "", line); sub(/^\/dev\//, "", line)
          if (line != "") keep[line] = 1
        }
        close(scopefile)
      }
      ($1 in keep) { print $2 }'
  else
    printf '%s\n' "$rows" | cut -f2-
  fi
}

# 这台机器"自己的盘" —— 直接取 scan_disks 的结果，每行一个设备名。
# DISK_SMART = 可压测的 + 因已挂载而不压测的真实盘；U 盘和虚拟设备不在里面。
disk_uniform_scope() {
  local p
  for p in "${DISK_SMART[@]:-}"; do
    [[ -n "$p" ]] || continue
    printf '%s\n' "${p##*/}"
  done
}

check_disk_uniform() {
  local f="$RAW_DIR/lsblk.json"
  # 范围文件也留在 raw/ 里：日后有人问"为什么只比了两块盘"，这就是答案
  local scope="$RAW_DIR/disk-uniform-scope.txt"
  disk_uniform_scope > "$scope"
  local rows; rows="$(disk_spec_model "$f" "$scope")"
  if [[ -z "$rows" ]]; then
    result_add "check_disk_uniform" "硬盘型号一致性" "$ST_SKIP" \
      "未采集到可比对的硬盘型号，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  local specs bad="" ok_n=0 s models nm
  specs="$(printf '%s\n' "$rows" | cut -d'|' -f1 | sort -u)"
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    models="$(printf '%s\n' "$rows" | awk -F'|' -v S="$s" '$1==S{print $2}' | uniq_values)"
    nm="$(printf '%s\n' "$models" | grep -c . || true)"
    [[ "$nm" =~ ^[0-9]+$ ]] || nm=0
    if (( nm > 1 )); then
      # 分组键是给我们看的（sata_960197124096），不能原样印给客户 ——
      # 客户看到的应该是"同为 SATA 接口、894GB 的这几块盘"
      local tran cap human
      tran="${s%%_*}"; cap="${s##*_}"
      human="$(numfmt --to=iec --suffix=B "${cap:-0}" 2>/dev/null || printf '%s' "$cap")"
      bad="${bad}同为 ${tran} 接口、容量 ${human} 的硬盘有 ${nm} 种型号（$(printf '%s\n' "$models" | join_cn '、')）；"
    else
      ok_n=$(( ok_n + 1 ))
    fi
  done <<< "$specs"

  if [[ -n "$bad" ]]; then
    result_add "check_disk_uniform" "硬盘型号一致性" "$ST_WARN" \
      "同规格硬盘的型号不一致：${bad}混用不影响机器正常工作，\
但性能与寿命表现会不同，建议出货前按订单要求确认。" "raw/lsblk.txt"
  else
    result_add "check_disk_uniform" "硬盘型号一致性" "$ST_PASS" \
      "按接口与容量分为 ${ok_n} 组，每组内的硬盘型号一致" "raw/lsblk.txt"
  fi
}

# ---------------------------------------------------------------- 显卡一致性
# 常见验收要求：「同一台机器里各张显卡的品牌、型号、VBIOS 版本一致」。
#
# gpu_uniform_scan <逐卡一行的 "型号, VBIOS" 文件> -> "<型号种数> <VBIOS种数>"
gpu_uniform_scan() {
  local f="${1:-}"
  [[ -s "$f" ]] || { printf '0 0'; return; }
  local nn vv
  nn="$(awk -F, 'NF>=2{print $1}' "$f" | count_uniq)"
  vv="$(awk -F, 'NF>=2{print $2}' "$f" | count_uniq)"
  [[ "$nn" =~ ^[0-9]+$ ]] || nn=0
  [[ "$vv" =~ ^[0-9]+$ ]] || vv=0
  printf '%s %s' "$nn" "$vv"
}

check_gpu_uniform() {
  if (( ${GPU_USABLE:-0} == 0 )); then
    # 没卡 / 驱动没就绪，gpu_detect 已经把原因记过一次，这里不重复刷一条
    return 0
  fi
  # 不走 capture()：这一份要在落盘前把逗号周围的空格压掉（后面按 CSV 逐列取值）。
  # timeout 是必须的 —— 卡卡死在总线上时 nvidia-smi 会一直挂着不返回。
  local f="$RAW_DIR/gpu-uniform.txt"
  timeout 60 nvidia-smi --query-gpu=name,vbios_version --format=csv,noheader 2>/dev/null \
    | sed 's/[[:space:]]*,[[:space:]]*/,/g' > "$f"

  local nn vv
  read -r nn vv < <(gpu_uniform_scan "$f")
  if (( nn == 0 )); then
    result_add "check_gpu_uniform" "显卡一致性" "$ST_SKIP" \
      "未能读取显卡型号与显示 BIOS 版本，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  local names vbios
  names="$(awk -F, '{print $1}' "$f" | uniq_values | join_cn '、')"
  vbios="$(awk -F, 'NF>=2{print $2}' "$f" | uniq_values | join_cn '、')"
  metric_add "conform" "显卡型号" "$names"
  [[ -n "$vbios" ]] && metric_add "conform" "显卡显示BIOS版本" "$vbios"

  local bad=""
  (( nn > 1 )) && bad="${bad}型号 ${nn} 种（${names}）；"
  (( vv > 1 )) && bad="${bad}显示 BIOS 版本 ${vv} 种（${vbios}）；"

  if [[ -n "$bad" ]]; then
    result_add "check_gpu_uniform" "显卡一致性" "$ST_WARN" \
      "本机 ${GPU_USABLE} 张显卡的配置不完全一致：${bad}建议出货前确认是否符合订单要求。" \
      "raw/gpu-smi-full.txt"
  else
    result_add "check_gpu_uniform" "显卡一致性" "$ST_PASS" \
      "${GPU_USABLE} 张显卡的型号与显示 BIOS 版本完全一致（${names}${vbios:+，${vbios}}）" \
      "raw/gpu-smi-full.txt"
  fi
}

# ---------------------------------------------------------------- 显卡显存 ECC
# 常见验收要求：「显存 ECC 错误计数为 0」。
#
# gpu_ecc_scan <csv 文件> -> "<有效卡数> <可纠正总数> <不可纠正总数>"
#
# nvidia-smi 对不支持 ECC 的卡（消费级卡全都不支持）在这几列里给的是
# "[N/A]" 或 "[Not Supported]"，**那不是 0**，照单当 0 加起来就等于
# 报告上写"ECC 全部正常"——一张压根没有 ECC 的卡被说成 ECC 没问题。
# 所以只统计真的读到数字的那些卡，一张都没读到就是 SKIP。
gpu_ecc_scan() {
  local f="${1:-}"
  [[ -s "$f" ]] || { printf '0 0 0'; return; }
  awk -F, '
    {
      ce = $2; ue = $3
      gsub(/[[:space:]]/, "", ce); gsub(/[[:space:]]/, "", ue)
      if (ce ~ /^[0-9]+$/ && ue ~ /^[0-9]+$/) { n++; c += ce; u += ue }
    }
    END { printf "%d %d %d", n+0, c+0, u+0 }' "$f" 2>/dev/null
}

check_gpu_ecc() {
  (( ${GPU_USABLE:-0} > 0 )) || return 0
  local f="$RAW_DIR/gpu-ecc.csv"
  # volatile = 本次上电以来；aggregate = 出厂以来累计。判定看的是 volatile，
  # aggregate 一并落进 raw/gpu-ecc.csv 存档 —— 内部报告不单独解析它，
  # 但「原始文件索引」那一节指得到这个文件、并写明了五列各是什么
  # （generate_internal.py 的 RAW_INDEX）。**别把它写进交付报告**：
  # "出厂以来累计"讲的是这台机器过去经历了什么，不是这一轮测出了什么（§11-50）。
  timeout 60 nvidia-smi \
    --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total \
    --format=csv,noheader,nounits > "$f" 2>/dev/null || true

  local n ce ue
  read -r n ce ue < <(gpu_ecc_scan "$f")
  if (( n == 0 )); then
    result_add "check_gpu_ecc" "显卡显存 ECC" "$ST_SKIP" \
      "本机显卡不提供显存 ECC 计数（该型号不支持或未开启 ECC），本项未做核对。\
此项不影响整机结论。" ""
    return 0
  fi

  metric_add "gpu" "显存ECC可纠正" "$ce"
  metric_add "gpu" "显存ECC不可纠正" "$ue"

  if (( ue > 0 )); then
    result_add "check_gpu_ecc" "显卡显存 ECC" "$ST_FAIL" \
      "${n} 张显卡本次上电以来累计出现 ${ue} 次不可纠正的显存 ECC 错误。\
不可纠正错误意味着该处显存的数据已经出错且无法自动修复，属于显存故障，需检修后复测。" \
      "raw/deep/nvidia-ecc.txt"
  elif (( ce > 0 )); then
    result_add "check_gpu_ecc" "显卡显存 ECC" "$ST_WARN" \
      "${n} 张显卡本次上电以来累计出现 ${ce} 次可纠正的显存 ECC 错误（已被硬件自动纠正，\
数据未受影响）。偶发数次属正常；数量偏大时建议出货前复测确认。" \
      "raw/deep/nvidia-ecc.txt"
  else
    result_add "check_gpu_ecc" "显卡显存 ECC" "$ST_PASS" \
      "${n} 张显卡本次上电以来的显存 ECC 错误计数均为 0" "raw/deep/nvidia-ecc.txt"
  fi
}

# ---------------------------------------------------------------- 显存行重映射
# 常见验收要求：「显存行重映射无异常」。
#
# 数据中心卡（A100/H100 及以后）用"行重映射"把出问题的显存行整行换掉。
# 三个信号的含义完全不同，不能混：
#   failure = Yes      重映射**失败** —— 备用行用完了，这张卡按 NVIDIA 的口径要返修
#   uncorrectable > 0  已经因为不可纠正错误换掉过行 —— 卡还能用，但有过硬故障
#   pending = Yes      有行等着重映射，需要复位/重启才生效
#
# gpu_remap_scan <csv> -> "<有效卡数> <uncorrectable总数> <pending卡数> <failure卡数>"
gpu_remap_scan() {
  local f="${1:-}"
  [[ -s "$f" ]] || { printf '0 0 0 0'; return; }
  awk -F, '
    {
      unc = $3; pend = $4; fail = $5
      gsub(/[[:space:]]/, "", unc); gsub(/[[:space:]]/, "", pend); gsub(/[[:space:]]/, "", fail)
      if (unc !~ /^[0-9]+$/) next
      n++
      u += unc
      if (pend == "Yes" || pend == "yes") p++
      if (fail == "Yes" || fail == "yes") f++
    }
    END { printf "%d %d %d %d", n+0, u+0, p+0, f+0 }' "$f" 2>/dev/null
}

check_gpu_remap() {
  (( ${GPU_USABLE:-0} > 0 )) || return 0
  local f="$RAW_DIR/gpu-remapped-rows.csv"
  timeout 60 nvidia-smi \
    --query-remapped-rows=index,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure \
    --format=csv,noheader,nounits > "$f" 2>/dev/null || true

  local n unc pend failn
  read -r n unc pend failn < <(gpu_remap_scan "$f")
  if (( n == 0 )); then
    result_add "check_gpu_remap" "显存行重映射" "$ST_SKIP" \
      "本机显卡不提供显存行重映射状态（该型号无此机制），本项未做核对。\
此项不影响整机结论。" ""
    return 0
  fi

  metric_add "gpu" "显存重映射不可纠正行" "$unc"

  if (( failn > 0 )); then
    result_add "check_gpu_remap" "显存行重映射" "$ST_FAIL" \
      "有 ${failn} 张显卡的显存行重映射已失败 —— 备用显存行已经用尽，\
后续出现的显存错误将无法再被屏蔽。这属于显存硬件故障，需更换或返修后复测。" \
      "raw/gpu-remapped-rows.csv"
  elif (( unc > 0 )); then
    result_add "check_gpu_remap" "显存行重映射" "$ST_WARN" \
      "${n} 张显卡累计有 ${unc} 行显存因不可纠正错误被永久屏蔽（已成功替换为备用行，\
当前功能与容量不受影响）。这说明这些显存曾出现过硬故障，建议出货前确认是否接受。" \
      "raw/gpu-remapped-rows.csv"
  elif (( pend > 0 )); then
    result_add "check_gpu_remap" "显存行重映射" "$ST_WARN" \
      "有 ${pend} 张显卡存在等待生效的显存行重映射，需重启后才会应用。\
建议出货前重启一次并复测确认。" "raw/gpu-remapped-rows.csv"
  else
    result_add "check_gpu_remap" "显存行重映射" "$ST_PASS" \
      "${n} 张显卡均无被屏蔽的显存行，也无待生效的重映射" "raw/gpu-remapped-rows.csv"
  fi
}

# ---------------------------------------------------------------- 平台设置
# 常见验收要求：「BIOS 配置与订单要求一致」（点名的多是 x2APIC / VT-d / SNC 这几项）。
#
# 这三项都能**从操作系统里读出来**，不需要任何厂商 BIOS 管理工具：
#   x2APIC  -> 内核启动时会明说是开是关
#   VT-d    -> 开了才会有 /sys/class/iommu 下的设备；内核也会打 DMAR 日志
#   SNC     -> 开了之后每颗 CPU 会被拆成 2/4 个 NUMA 节点，数一数就知道
#
# 三个判读都是纯函数，样本取自真机 dmesg，见 tests/test-hw-checks.sh。

# bios_x2apic_state <dmesg 文件> -> enabled | disabled | unknown
#
# ⚠️ 不能拿 /proc/cpuinfo 的 x2apic 标志位判：那个标志的意思是"这颗 CPU
#    **支持** x2APIC"，BIOS 里关掉之后它照样在。唯一可信的是内核自己的原话。
bios_x2apic_state() {
  local f="${1:-}"
  [[ -f "$f" ]] || { printf 'unknown'; return; }
  # 关掉的说法几代内核都在变，但都带 "disable"；先查关、再查开，
  # 因为"enabled by BIOS"这种句子里也含 BIOS 二字，顺序反了会互相误伤。
  if grep -aqiE 'x2apic.*(disabled|not enabled)|(disabled|not enabling).*x2apic' "$f" 2>/dev/null; then
    printf 'disabled'; return
  fi
  if grep -aqiE 'x2apic (enabled|mode)|enabled x2apic|switching to (cluster |physical )?x2apic|APIC routing to (cluster |physical )?x2apic' "$f" 2>/dev/null; then
    printf 'enabled'; return
  fi
  printf 'unknown'
}

# bios_vtd_state <dmesg 文件> <iommu sysfs 目录> -> enabled | disabled | unknown
#
# sysfs 是第一判据（有设备就是真的在工作），dmesg 只在 sysfs 读不到时兜底。
# 传目录参数是为了能脱机测（现场就是 /sys/class/iommu）。
bios_vtd_state() {
  local f="${1:-}" iommu_dir="${2:-/sys/class/iommu}"
  if [[ -d "$iommu_dir" ]]; then
    if compgen -G "$iommu_dir/*" >/dev/null 2>&1; then printf 'enabled'; return; fi
    # 目录在但空的 = 内核有这套框架、没有任何 IOMMU 被启用。
    # ⚠️ **到这儿就是答案了，不要再往下去翻内核日志。**
    #    原来这里写的是"没有 dmesg 才认 disabled"，于是有 dmesg 时会掉进下面
    #    那两条 grep，两条都没命中就报 unknown —— 把一个**已经确定的 disabled**
    #    换成了"读不到"。sysfs 是活的状态，它说空的就是空的。
    printf 'disabled'; return    # sysfs 说了算，不往下走
  fi
  [[ -f "$f" ]] || { printf 'unknown'; return; }
  # 先查"关"（"enabled by BIOS" 这类句子里也带 BIOS 二字，顺序反了会互相误伤）
  if grep -aqiE 'DMAR: (Disabling IOMMU|IOMMU disabled)|Intel-IOMMU: disabled|DMAR: No DMAR devices found|AMD-Vi: (Disabled|not supported)' "$f" 2>/dev/null; then
    printf 'disabled'; return
  fi
  # ⚠️ 下面这几条是**照着真机日志**写的，别按印象改。
  #    十份真机 run-dir 实测：原来那两条 `DMAR: IOMMU enabled` /
  #    `AMD-Vi: Found IOMMU` **一台都没命中过** —— 6.8 内核根本不打这两句。
  #    真正打出来的是：
  #      Intel / 澜起：DMAR: Intel(R) Virtualization Technology for Directed I/O
  #      海光（AMD 系）：iommu: Default domain type: Translated
  #    最后那条来自通用 iommu 层，只有真的有 IOMMU 驱动注册上来才会打，
  #    所以拿它当"开着"的正面证据是站得住的（Passthrough 也算开着 ——
  #    那是 iommu=pt，BIOS 里的 VT-d 仍然是开的）。
  if grep -aqiE 'DMAR: Intel\(R\) Virtualization Technology for Directed I/O|DMAR: (IOMMU|Intel-IOMMU).*(enabled|hardware identity mapping)|AMD-Vi: (Interrupt remapping enabled|Found IOMMU)|iommu: Default domain type:' "$f" 2>/dev/null; then
    printf 'enabled'; return
  fi
  printf 'unknown'
}

# numa_per_socket <NUMA 节点数> <物理插槽数> -> 每路几个节点，算不出来给 0
numa_per_socket() {
  local nodes="${1:-0}" sockets="${2:-0}"
  [[ "$nodes"   =~ ^[0-9]+$ ]] || nodes=0
  [[ "$sockets" =~ ^[0-9]+$ ]] || sockets=0
  (( sockets > 0 && nodes > 0 )) || { printf '0'; return; }
  (( nodes % sockets != 0 )) && { printf '0'; return; }
  printf '%s' $(( nodes / sockets ))
}

# snc_state <每路节点数> -> disabled | SNC2 | SNC4 | unknown
#
# 每路 1 个节点 = 没开子 NUMA 划分；2 个 = SNC2；4 个 = SNC4。
# AMD 平台上同一个位置叫 NPS，含义一样（每路被拆成几个内存域）。
snc_state() {
  case "${1:-0}" in
    1) printf 'disabled' ;;
    2) printf 'SNC2' ;;
    4) printf 'SNC4' ;;
    *) printf 'unknown' ;;
  esac
}

# 板载网卡。常见验收要求：「按订单决定板载网口是否在 BIOS 中禁用」。
#
# DMI type 41（Onboard Device Extended Information）里列着主板上焊死的设备
# 及其 PCI 总线地址。地址还能在 /sys/class/net/*/device 下找到 = 这个口在系统里
# 是活的 = BIOS 里没禁用。
#
# ⚠️ **不少主板的 type 41 里根本没填真地址，一律写 `0000:00:00.0`。**
#    那是主桥（host bridge）的地址，任何网卡都不可能在那儿。照着它去匹配，
#    结果必然一个都对不上 —— 海光那台就因此在报告里写着"板载网口共 2 个，
#    其中 0 个在系统中可用"，而那两个口当轮明明采到了型号、固件、还跑了自检。
#    这类地址标成 unknown（读不出来），绝不能算成"BIOS 里禁用了"。
#    读不出来的标记不是内容（docs/report-policy.md）。
#
# onboard_nic_scan <dmidecode -t 41 文件> <在用网口的 PCI 地址列表文件>
#   -> 每行 "<PCI 地址> <active|inactive|unknown>"
onboard_nic_scan() {
  local f="${1:-}" busfile="${2:-}"
  [[ -f "$f" ]] || return 0
  local addrs; addrs=""
  [[ -f "$busfile" ]] && addrs="$(tr -d ' \t' < "$busfile" | tr '[:upper:]' '[:lower:]')"
  awk '
    BEGIN { RS = ""; FS = "\n" }
    {
      isnet = 0; bus = ""
      for (i = 1; i <= NF; i++) {
        line = $i; sub(/\r$/, "", line)
        if (line ~ /^\tType: Ethernet$/) isnet = 1
        if (line ~ /^\tBus Address: /)   bus = substr(line, length("\tBus Address: ") + 1)
      }
      if (isnet && bus != "") print bus
    }' "$f" 2>/dev/null \
  | while IFS= read -r bus; do
      local short lower
      lower="$(printf '%s' "$bus" | tr '[:upper:]' '[:lower:]')"
      short="${lower#0000:}"
      # 占位地址：主桥 00:00.0，或者干脆全 0。这两种都是"主板没填"，不是"禁用了"。
      if [[ "$short" == "00:00.0" || "$lower" =~ ^0+:0+:0+\.0+$ ]]; then
        printf '%s unknown\n' "$bus"
      elif [[ -n "$addrs" ]] && printf '%s\n' "$addrs" | grep -qF -e "$lower" -e "$short"; then
        printf '%s active\n' "$bus"
      else
        printf '%s inactive\n' "$bus"
      fi
    done
}

# 在用网口的 PCI 总线地址（每行一个），给上面那个函数当第二个参数
net_pci_addresses() {
  local n dev
  for n in /sys/class/net/*; do
    [[ -e "$n/device" ]] || continue
    dev="$(readlink -f "$n/device" 2>/dev/null)" || continue
    printf '%s\n' "${dev##*/}"
  done
}

check_bios_profile() {
  local dmesg_f="$RAW_DIR/dmesg-pre.txt"
  # dmesg-pre 是 collect_all 末尾才落的；这一项排在它后面调用，正常都有。
  # 万一没有就现取一次，读不到就一律 unknown（绝不猜）。
  if [[ ! -s "$dmesg_f" ]]; then
    dmesg_f="$RAW_DIR/dmesg-boot-for-profile.txt"
    capture -t 30 "$(basename "$dmesg_f")" dmesg -T >/dev/null 2>&1 || true
  fi

  local x2 vtd nodes sockets per snc
  x2="$(bios_x2apic_state "$dmesg_f")"
  vtd="$(bios_vtd_state "$dmesg_f" "${KLBURN_IOMMU_DIR:-/sys/class/iommu}")"

  nodes=0
  local nd
  for nd in "${KLBURN_NODE_DIR:-/sys/devices/system/node}"/node[0-9]*; do
    [[ -d "$nd" ]] && nodes=$(( nodes + 1 ))
  done
  sockets="$(awk -F': ' '/^Socket\(s\)/{gsub(/ /,"",$2); print $2; exit}' "$RAW_DIR/lscpu.txt" 2>/dev/null)"
  [[ "$sockets" =~ ^[0-9]+$ ]] || sockets=0
  per="$(numa_per_socket "$nodes" "$sockets")"
  snc="$(snc_state "$per")"

  # 板载网卡
  local t41="$RAW_DIR/deep/dmidecode-onboard.txt"
  capture -t 30 "deep/dmidecode-onboard.txt" dmidecode -t 41 >/dev/null 2>&1 || true
  local busf="$RAW_DIR/net-pci-addresses.txt"
  net_pci_addresses > "$busf"
  local onboard_rows onboard_total onboard_active onboard_unknown onboard_state
  onboard_rows="$(onboard_nic_scan "$t41" "$busf")"
  onboard_total="$(printf '%s\n' "$onboard_rows" | grep -c . || true)"
  onboard_active="$(printf '%s\n' "$onboard_rows" | grep -c ' active$' || true)"
  onboard_unknown="$(printf '%s\n' "$onboard_rows" | grep -c ' unknown$' || true)"
  [[ "$onboard_total"   =~ ^[0-9]+$ ]] || onboard_total=0
  [[ "$onboard_active"  =~ ^[0-9]+$ ]] || onboard_active=0
  [[ "$onboard_unknown" =~ ^[0-9]+$ ]] || onboard_unknown=0
  if (( onboard_total == 0 )); then
    onboard_state="unknown"
  elif (( onboard_active > 0 )); then
    onboard_state="enabled"
  elif (( onboard_unknown >= onboard_total )); then
    # 主板一个有效地址都没给 —— 我们无从判断它们是开着还是被禁了
    onboard_state="unknown"
  else
    onboard_state="disabled"
  fi

  # ---- 实测状态先原样记下来（不管判不判定，这几格都要进报告）----
  local -A cn=(
    [enabled]="已启用" [disabled]="已关闭" [unknown]="未能读取"
    [SNC2]="每路 2 个（SNC2）" [SNC4]="每路 4 个（SNC4）"
  )
  local snc_cn
  case "$snc" in
    disabled) snc_cn="每路 1 个（未启用子 NUMA 划分）" ;;
    SNC2|SNC4) snc_cn="${cn[$snc]}" ;;
    *) snc_cn="未能读取" ;;
  esac
  metric_add "platform" "处理器 x2APIC" "${cn[$x2]:-未能读取}"
  metric_add "platform" "IO 虚拟化（VT-d/IOMMU）" "${cn[$vtd]:-未能读取}"
  metric_add "platform" "每路 NUMA 节点数" "$snc_cn"
  local onboard_txt="主板未上报板载网口信息"
  if (( onboard_total > 0 )); then
    if (( onboard_unknown >= onboard_total )); then
      onboard_txt="$(printf '主板上报 %d 个板载网口，但未提供有效的总线地址，无法核对其启用状态' "$onboard_total")"
    else
      onboard_txt="$(printf '共 %d 个，其中 %d 个在系统中可用' "$onboard_total" "$onboard_active")"
    fi
  fi
  metric_add "platform" "板载网口" "$onboard_txt"

  # 真读到了几项（判定行里报个数就够，值在表里）
  local nread=0
  [[ "$x2"  != "unknown" ]] && nread=$(( nread + 1 ))
  [[ "$vtd" != "unknown" ]] && nread=$(( nread + 1 ))
  [[ "$snc" != "unknown" ]] && nread=$(( nread + 1 ))
  [[ "$onboard_state" != "unknown" ]] && nread=$(( nread + 1 ))

  # 一项都没读出来 = 这台机器/这个内核不提供这些信息
  if [[ "$x2" == "unknown" && "$vtd" == "unknown" && "$snc" == "unknown" && "$onboard_state" == "unknown" ]]; then
    result_add "check_bios_profile" "平台关键设置" "$ST_SKIP" \
      "本机未提供可读取的平台设置状态，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi

  # ⚠️ **只报实测状态，不判对错。**
  #
  # "x2APIC 该开还是该关"是**每一份订单各自的要求**，不是硬件好坏，而这张盘是
  # 无人值守跑的 —— 现场没有人、也没有地方去填"这台机器该配成什么样"。
  # 我们负责把这几项现在是什么状态如实读出来、写清楚，让做验收的人拿自己的
  # 那份要求去对。
  # ⚠️ 这句**故意不把四个值再列一遍**：它们已经作为 metric 进了报告里
  # 「平台关键设置」那张表，判定行再抄一份，同一页上同一个值出现两次 ——
  # 那不是排版，是堆砌。判定行只说"读到了、这类项目是什么性质"。
  result_add "check_bios_profile" "平台关键设置" "$ST_PASS" \
    "已读取本机 ${nread} 项平台关键设置的实际状态（见下方「平台关键设置」）。\
这几项是主板设置，与硬件好坏无关，可对照订单要求逐项核对。" "raw/lscpu.txt"
}

# ---------------------------------------------------------------- 运行环境自检
#
# ⚠️ **这一项判的是"我们这轮测试跑在什么上面"，不是"客户装完系统之后有没有
#    虚拟设备"。别把两件事混了。**
#
# 有些验收单上有一条「操作系统内无虚拟设备」。那条说的是**客户自己装的那套
# 系统**里不该出现虚拟网卡/虚拟磁盘 —— 而我们跑的是自己的测试系统，
# 看到什么都代表不了客户那套系统将来长什么样。**那条我们测不了，也不该假装能测。**
#
# 我们能答、而且必须答的是另一个问题：**这份报告里的硬件数据，是不是从一台
# 真的物理机上采的？**跑在虚拟机里的话，报告上的 CPU / 内存 / 硬盘全是
# 虚拟出来的，整份数据都不能当出厂依据 —— 那才是这一项存在的理由。
#
# 两类证据：
#   整机本身跑在虚拟化里（CPU 的 hypervisor 位、主板厂商是 VMware/QEMU/…）
#   出现了只有虚拟化环境才有的块设备或网口（virtio / vmxnet / hv_netvsc）
#
# virtual_device_scan <cpuinfo 文件> <dmidecode-system 文件> <lsblk.json> <网口驱动清单文件>
#   -> 每行 "<类别>|<说明>"，一行都没有就是干净的
virtual_device_scan() {
  local cpuinfo="${1:-}" dmisys="${2:-}" lsblkj="${3:-}" nicdrv="${4:-}"

  [[ -f "$cpuinfo" ]] && grep -qw hypervisor "$cpuinfo" 2>/dev/null \
    && printf '整机|处理器上报了虚拟化标志，本机运行在虚拟机中\n'

  if [[ -f "$dmisys" ]]; then
    local vend
    vend="$(grep -aiE '^[[:space:]]*(Manufacturer|Vendor|Product Name):' "$dmisys" 2>/dev/null \
            | grep -aiE 'vmware|qemu|kvm|xen|virtualbox|innotek|bochs|parallels|microsoft corporation virtual|hyper-v' \
            | head -2 | sed 's/^[[:space:]]*//' | join_cn '；')"
    [[ -n "$vend" ]] && printf '整机|主板信息显示为虚拟平台（%s）\n' "$vend"
  fi

  if [[ -s "$lsblkj" ]]; then
    local vdisk
    vdisk="$(jq -r '[.blockdevices[]? | recurse(.children[]?)]
                    | .[] | select(.type == "disk")
                    | select((.name // "") | test("^vd"))
                    | .name' "$lsblkj" 2>/dev/null | join_cn '、')"
    [[ -n "$vdisk" ]] && printf '硬盘|存在虚拟磁盘设备（%s）\n' "$vdisk"
  fi

  if [[ -f "$nicdrv" ]]; then
    local vnic
    vnic="$(grep -aiE '\|(virtio_net|vmxnet3|hv_netvsc|xen-netfront|veth)$' "$nicdrv" 2>/dev/null \
            | cut -d'|' -f1 | join_cn '、')"
    [[ -n "$vnic" ]] && printf '网卡|存在虚拟网卡设备（%s）\n' "$vnic"
  fi
  return 0
}

check_virtual_dev() {
  # 网口 -> 驱动 的清单，给纯函数当输入
  local nicdrv="$RAW_DIR/nic-drivers.txt"
  local n ifn drv
  : > "$nicdrv"
  for n in /sys/class/net/*; do
    ifn="$(basename "$n")"
    [[ "$ifn" == "lo" ]] && continue
    drv="$(basename "$(readlink -f "$n/device/driver" 2>/dev/null)" 2>/dev/null)"
    [[ -n "$drv" && "$drv" != "." ]] || drv="unknown"
    printf '%s|%s\n' "$ifn" "$drv" >> "$nicdrv"
  done

  local hits
  hits="$(virtual_device_scan "$RAW_DIR/cpuinfo.txt" "$RAW_DIR/dmidecode-system.txt" \
                              "$RAW_DIR/lsblk.json"  "$nicdrv")"
  if [[ -z "$hits" ]]; then
    result_add "check_virtual_dev" "运行环境核对" "$ST_PASS" \
      "本次测试在物理服务器上进行，未发现虚拟化痕迹，报告中的硬件数据均取自实机" \
      "raw/lsblk.txt"
    return 0
  fi

  local text
  text="$(printf '%s\n' "$hits" | cut -d'|' -f2 | join_cn '；')"
  # 判 WARN 而不是 FAIL：机器本身没坏，是这份数据的**采集环境**不对。
  # 文案的落点是"这份报告能不能当依据"，不是"这台机器有问题"。
  result_add "check_virtual_dev" "运行环境核对" "$ST_WARN" \
    "本次测试检测到虚拟化环境：${text}。虚拟机中读到的处理器、内存与硬盘信息\
均由虚拟化层提供，不能代表实际硬件，因此本报告中的硬件数据仅供参考、\
不适合作为出厂依据。如需出具正式报告，请在物理服务器上重新测试。" "raw/lsblk.txt"
}

# ---------------------------------------------------------------- 序列号一致性
# 常见验收要求：「系统内、BMC、BIOS 及机身标签上的序列号一致」。
#
# 我们能自动比的是其中两处：BIOS（DMI）和 BMC（FRU）。物理标签只能人工核对，
# 所以文案里要把"我们比了哪两处"说清楚，不能让客户以为四处都比过了。
#
# fru_serial <ipmitool fru print 的文件> -> 整机序列号，读不到给空
#
# FRU 里可能同时有 Chassis / Board / Product 三组序列号，优先级按
# "整机 > 主板"：Product Serial 才是贴在机器上那个 SN。
fru_serial() {
  local f="${1:-}" v key
  [[ -f "$f" ]] || return 0
  for key in "Product Serial" "Chassis Serial" "Board Serial"; do
    v="$(awk -F': ' -v K="$key" '
           index($0, K) == 1 || index($0, " " K) > 0 {
             sub(/^[^:]*:[[:space:]]*/, ""); print; exit
           }' "$f" 2>/dev/null)"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    if [[ -n "$v" ]] && ! _serial_is_bogus "$v"; then printf '%s' "$v"; return 0; fi
  done
  return 0
}

check_sn_consistency() {
  local dmi_sn=""
  if have dmidecode; then
    dmi_sn="$(dmidecode -s system-serial-number 2>/dev/null | grep -v '^#' | head -1)"
  fi
  local bmc_sn; bmc_sn="$(fru_serial "$RAW_DIR/ipmi-fru.txt")"

  local dmi_ok=1 bmc_ok=1
  _serial_is_bogus "$dmi_sn" && dmi_ok=0
  [[ -z "$bmc_sn" ]] && bmc_ok=0

  if (( dmi_ok == 0 && bmc_ok == 0 )); then
    result_add "check_sn_consistency" "序列号一致性" "$ST_SKIP" \
      "主板 BIOS 与管理控制器均未记录整机序列号，本项未做核对。此项不影响整机结论。" ""
    return 0
  fi
  if (( bmc_ok == 0 )); then
    result_add "check_sn_consistency" "序列号一致性" "$ST_SKIP" \
      "本机未提供可读取的管理控制器序列号，无法与主板 BIOS 记录的序列号（${dmi_sn}）比对。\
请人工核对机身标签。此项不影响整机结论。" "raw/ipmi-fru.txt"
    return 0
  fi
  if (( dmi_ok == 0 )); then
    result_add "check_sn_consistency" "序列号一致性" "$ST_WARN" \
      "主板 BIOS 未填写整机序列号，管理控制器记录为 ${bmc_sn}。\
建议出货前在 BIOS 中补写，使系统内、管理控制器与机身标签三处一致。" "raw/ipmi-fru.txt"
    return 0
  fi

  metric_add "conform" "序列号（主板 BIOS）" "$dmi_sn"
  metric_add "conform" "序列号（管理控制器）" "$bmc_sn"

  if [[ "$dmi_sn" == "$bmc_sn" ]]; then
    result_add "check_sn_consistency" "序列号一致性" "$ST_PASS" \
      "主板 BIOS 与管理控制器记录的整机序列号一致（${dmi_sn}）。机身物理标签请人工核对。" \
      "raw/ipmi-fru.txt"
  else
    result_add "check_sn_consistency" "序列号一致性" "$ST_WARN" \
      "整机序列号在两处记录不一致：主板 BIOS 为 ${dmi_sn}，管理控制器为 ${bmc_sn}。\
建议出货前统一，并核对机身物理标签。" "raw/ipmi-fru.txt"
  fi
}

# ---------------------------------------------------------------- 汇总入口
# 排在 collect_all 之后调用：一致性比对读的全是采集阶段已经落盘的文件
# （dmidecode-memory / nic/ / lsblk.json / ipmi-fru / dmesg-pre），
# 排在它前面就是拿空文件去比。
#
# ⚠️ "不跑任何命令"是**不准确**的说法，别照着它去掉超时：显存那三项要现问
#    显卡驱动（各一次 nvidia-smi），平台设置要读 DMI type 41、序列号要读
#    system-serial-number。它们都是秒级的、而且**每一条都带 timeout** ——
#    这一整段的契约是"几秒钟就过去，绝不拖住整轮测试"，不是"一条命令都不跑"。
conformance_all() {
  info "Cross-checking configuration consistency ..."
  check_dimm_uniform
  check_nic_uniform
  check_disk_uniform
  check_gpu_uniform
  check_gpu_ecc
  check_gpu_remap
  check_bios_profile
  check_virtual_dev
  check_sn_consistency
}
