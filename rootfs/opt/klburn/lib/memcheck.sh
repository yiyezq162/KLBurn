#!/usr/bin/env bash
# KLBurn 内存专用盘的采集与判定
#
# 这份 lib **只被 memtest.sh 用**（KLBURN_EDITION=mem 的盘），整机全测盘一行都不碰。
#
# ================================================================
# 这张盘只回答两个问题，别往里加第三个：
#
#   1. 这台机器上插着哪几条内存 —— 槽位 / 厂商 / 型号(PN) / **序列号** /
#      容量 / 类型 / 频率。这是买到一批问题内存之后最要紧的东西：
#      能按 SN 把坏条子一条条点出来。
#   2. 这几条内存现在还能不能用 —— 一段短压测 + ECC 计数 + 内核日志。
#
# ⚠️ **不采网卡、不采 PCIe、不采硬盘、不采阵列卡、不采显卡、不采 BMC，
#    不跑任何性能基准。** 被测平台上这些部件可能压根就没有（用户 2026-08-12
#    明确说明：这批机器就是裸平台）。采了也没人看，只会把两分钟拖成十分钟，
#    还得在报告里解释一堆和内存无关的 SKIP。
#
#    网卡**唯一**的用途是联网校时（try_sync_clock_via_network），
#    它的型号、速率、连通性一个字都不进报告，也不产生任何判定。
#
# ================================================================
# 四态语义和整机盘完全一致，一条都不放松：
#   PASS 量到了、没问题        FAIL 内存/内存控制器真的出错了
#   WARN 配置问题（混插）      SKIP 这台机器/这个内核给不了这项数据
#
# 「读不到 ≠ 坏了」这条红线照旧管着**我们这边的能力缺失**：读不到 SPD 原片、
# 内核没有 EDAC 接口，一律 SKIP，绝不是 FAIL。
#
# ⚠️ **但序列号那一条是例外，而且是用户 2026-08-12 当面定的**：
#    这张盘的存在理由就是筛一批假内存，而那批假条子压测全过、只有序列号露馅。
#    所以「序列号重复」和「读不出序列号」都判 FAIL —— 判的是**被测条子自己
#    报出来的数据**，不是"我们没带工具"，和一号红线不冲突。
#    重复那一支没有开关；读不出来那一支留了 MEM_SN_MISSING_IS_FAIL。
#    详见下面 check_dimm_serial 上方那一大段。

# ---------------------------------------------------------------- 采集
#
# 一共五条命令，都是毫秒级返回的本地读取，整段两三秒就过去了。
# 特意不走 collect_system()：那边还带着 lshw / lspci / lsusb，
# 光那三条在故障机上就能白等两三分钟，而它们和内存没有半点关系。
mem_collect() {
  info "Reading memory and platform information ..."

  # 逐条内存的全部 DMI 字段（type 17）+ 内存阵列（type 16）。
  # 报告里那张明细表、容量核对、一致性核对，全部只读这一个文件。
  capture -t 30 "dmidecode-memory.txt" dmidecode -t memory
  # 平台认个大概就够：整机型号 / 主板型号 / BIOS 版本。
  # 用户要的是"知道是什么平台就行"，所以不采 type 3（机箱）之类的东西。
  capture -t 30 "dmidecode-system.txt" dmidecode -t system -t baseboard -t bios
  # CPU 只为了报告抬头和目录名里那个型号，不做任何 CPU 判定。
  capture -t 30 "dmidecode-cpu.txt"    dmidecode -t processor
  capture -t 20 "lscpu.txt"            lscpu
  capture -t 10 "meminfo.txt"          cat /proc/meminfo

  # SPD 原片。DMI 那份是**主板读出来再转述**的，只有 JEDEC 定义的那几格；
  # 条子自己的芯片里还有一片厂商专属区，长号如果在电子记录里只可能在那儿。
  mem_collect_spd

  if [[ -s "$RAW_DIR/dmidecode-memory.txt" ]] \
     && ! grep -qi 'permission denied\|command not found' "$RAW_DIR/dmidecode-memory.txt"; then
    result_add "collect_memory" "内存信息采集" "$ST_PASS" \
      "已读取主板 BIOS 记录的逐条内存明细（槽位、厂商、型号、序列号、容量、频率）" \
      "raw/dmidecode-memory.txt"
  else
    result_add "collect_memory" "内存信息采集" "$ST_FAIL" \
      "未能读取主板 BIOS 记录的内存明细，本次测试无法确认这台机器装了哪几条内存" \
      "raw/dmidecode-memory.txt"
  fi
}

# ---------------------------------------------------------------- 有没有读到内存条
#
# mem_dimm_count [文件] —— 已装内存条数（空槽不算）。保证输出是干净的整数。
mem_dimm_count() {
  local f="${1:-$RAW_DIR/dmidecode-memory.txt}" n
  n="$(dmi_dimm_field "$f" "Locator" | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$n"
}

# 一条都没读到 = 这一轮什么都没测成，**不是**"这台机器没内存"。
#
# ⚠️ 判 FAIL，含义是「本轮作废」而不是「硬件坏了」—— 和整机盘上
#    「选了显卡专测却没有显卡」走的是同一套语义（factory-test.sh 里那段）。
#    没有内存的机器开不了机，所以走到这儿一定是 dmidecode 没读出来
#    （权限 / BIOS 没填 / 虚拟机），一个字都不能往硬件头上扣。
mem_require_dimms() {
  local n; n="$(mem_dimm_count)"
  (( n > 0 )) && return 0

  result_add "mem_no_data" "本轮测试未执行" "$ST_FAIL" \
    "未能从主板 BIOS 读取到任何一条内存的明细信息，本次测试**未执行**。\
这不是内存故障 —— 请确认本机 BIOS 是否正常记录了内存信息，或换一台机器复测，\
重新测试后以新报告为准。" "raw/dmidecode-memory.txt"
  return 1
}

# ================================================================
# SPD 原片：读内存条自己的芯片
# ================================================================
#
# `dmidecode -t 17` 给的是**主板读出 SPD 之后再转述的那几格**，只有 JEDEC
# 定义的标准字段。而 SPD 芯片本身还有一片**厂商专属数据区**（DDR4 是
# 偏移 353~381 共 29 字节），JEDEC 不管里面放什么，各家自己用。
#
# 现场 2026-08-12 问的就是这件事：内存条标签上印着 `HOPA00030844522378`
# 这样十几位的长号，而报告里的序列号只有 8 位十六进制。
#
# ⚠️ **那 8 位不是被截断的，它就是完整的。** JEDEC 规定 DDR4 的模组序列号
#    字段只有 4 个字节（偏移 325~328），dmidecode 把它按十六进制打出来就是
#    8 个字符。标签上那串长号是厂商自己的**生产追溯号**，印在标签和二维码上，
#    不在标准序列号字段里。
#
#    所以要拿到它只有一条路：**把 SPD 整片读下来，看厂商专属区里有没有。**
#    有没有取决于厂商，我们能做的是**如实把那片字节读出来摆着** ——
#    读到了就写进报告，读不到就说读不到，绝不编。
#
# ⚠️⚠️ 三条安全边界，改这段之前先读：
#
#   1. **只读，绝不写。** 往 SPD 写一个字节就能把一条好内存变成砖。
#      这里从头到尾只 `dd if=<sysfs eeprom>`，没有任何写入路径。
#   2. **绝不做 i2cdetect 盲扫。** 那会往未知的 i2c 地址发起事务，
#      服务器的 SMBus 上还挂着 BMC、风扇控制器、背板 —— 扫到不该扫的
#      能让机器当场挂掉。这里只读**内核驱动已经建好的** eeprom 节点，
#      也就是内核自己认定"这是一片 SPD"的那些。
#   3. **读不到一律 SKIP，永远不是 FAIL**（一号红线）。服务器上 SMBus 常常
#      归 BMC 管、或者被 BIOS 锁了，主机侧根本读不到 —— 那是平台的事，
#      跟这条内存好不好毫无关系。
mem_collect_spd() {
  local d name n=0
  mkdir -p "$RAW_DIR/spd"

  # SPD 芯片要有驱动才会出现 eeprom 节点。装不上的一律忽略：
  #   i2c-i801 / i2c-piix4  南桥的 SMBus 控制器（Intel / AMD）
  #   ee1004                DDR4 的 SPD EEPROM
  #   at24                  DDR3 及更早
  #   spd5118               DDR5 的 SPD hub（内核 6.10 才有，本盘是 6.8，
  #                         所以 **DDR5 平台上这一段大概率读不到** —— 那是
  #                         已知边界，不是故障）
  local m
  for m in i2c-dev i2c-smbus i2c-i801 i2c-piix4 ee1004 at24 spd5118; do
    modprobe "$m" >/dev/null 2>&1 || true
  done
  udevadm settle --timeout=5 >/dev/null 2>&1 || true

  # ---------------------------------------------------------------- 诊断留档
  #
  # ⚠️ **只写文件，不产生任何判定、不进任何报告。**加它的唯一理由是：
  #    现场问过两次「能不能读到内存条标签上那串十几位的长号」，而我们至今
  #    只答得出「读不到」，答不出**为什么**读不到 —— 那三种原因的处置完全不同：
  #
  #      a) 驱动压根没装上         -> 是我们的盘缺东西，能修
  #      b) 驱动装上了、总线没出来  -> SMBus 被 BIOS 锁了 / 归 BMC 管，主机侧无解
  #      c) 总线出来了、后面没 EEPROM -> SPD 挂在 mux 后面，或这一代要 spd5118
  #
  #    这三种在 `decode-dimms` 眼里都是同一句 `No EEPROM found`。
  #    现在把判据落到盘里：下一轮**任何一次**跑完，答案就在 raw/spd-probe.txt 里，
  #    不用为它专门再上一次机器。
  #
  # ⚠️ 全程只读 sysfs，**绝不做 i2cdetect 盲扫**（那会往未知地址发事务，
  #    服务器 SMBus 上还挂着 BMC、风扇控制器、背板，扫到不该扫的能让机器当场挂掉）。
  {
    printf '# SPD 读取诊断（只留档，不参与任何判定）\n'
    printf '# 内核: %s\n\n' "$(uname -r 2>/dev/null)"

    printf '## 内核模块装上了没有\n'
    for m in i2c_dev i2c_smbus i2c_i801 i2c_piix4 ee1004 at24 spd5118; do
      if grep -qE "^${m}\b" /proc/modules 2>/dev/null; then
        printf '  已加载   %s\n' "$m"
      elif [[ -d "/sys/module/${m}" ]]; then
        # 编进内核的（比如 CONFIG_I2C_CHARDEV=y）不会出现在 /proc/modules
        printf '  内建     %s\n' "$m"
      else
        printf '  没有     %s\n' "$m"
      fi
    done

    printf '\n## 出现了哪些 i2c 总线（没有 = SMBus 控制器没起来）\n'
    local a nm found=0
    for a in /sys/class/i2c-adapter/*; do
      [[ -e "$a" ]] || continue
      found=1
      nm="$(cat "$a/name" 2>/dev/null)"
      printf '  %-12s %s\n' "$(basename "$a")" "$nm"
    done
    (( found == 1 )) || printf '  （一条都没有）\n'

    printf '\n## 这些总线上挂了什么（有 eeprom 的才读得到 SPD）\n'
    found=0
    for a in /sys/bus/i2c/devices/*; do
      [[ -e "$a" ]] || continue
      found=1
      printf '  %-16s driver=%s%s\n' "$(basename "$a")" \
        "$(basename "$(readlink -f "$a/driver" 2>/dev/null)" 2>/dev/null)" \
        "$([[ -e "$a/eeprom" ]] && printf '  <- 有 eeprom')"
    done
    (( found == 1 )) || printf '  （一个设备都没有）\n'
  } > "$RAW_DIR/spd-probe.txt" 2>/dev/null || true

  for d in /sys/bus/i2c/devices/*/eeprom; do
    [[ -r "$d" ]] || continue
    name="$(basename "$(dirname "$d")")"
    # bs=1 count=1024 而不是一次读完：有的平台上这块 eeprom 读到末尾会报错，
    # 分块读能把已经读到的部分留下来。1KB 足够覆盖 DDR4(512B) 和 DDR5(1KB)。
    timeout 20 dd if="$d" of="$RAW_DIR/spd/${name}.bin" bs=128 count=8 \
      >/dev/null 2>&1 || true
    if [[ -s "$RAW_DIR/spd/${name}.bin" ]]; then
      n=$(( n + 1 ))
    else
      rm -f "$RAW_DIR/spd/${name}.bin" 2>/dev/null || true
    fi
  done

  # 人可读的一份，有工具就留档（判定不靠它）
  have decode-dimms && capture -t 60 "spd-decode.txt" decode-dimms

  metric_add "mem" "读到SPD原片数" "$n"
  if (( n > 0 )); then
    ok "[SPD] read $n module EEPROM(s)"
  else
    dbg "[SPD] no SPD EEPROM readable on this platform"
  fi
  return 0
}

# SPD 整片指纹。两条内存的 SPD **逐字节完全相同** = SPD 被整片克隆过，
# 比序列号重复还硬 —— 序列号还只是一格，整片相同连制造日期、追溯区都一样。
#
# 输出每行 "<i2c地址> <sha256>"。没有 sha256sum 或没读到 SPD 时什么都不输出。
mem_spd_fingerprints() {
  local dir="${1:-$RAW_DIR/spd}" f
  have sha256sum || return 0
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/*.bin; do
    [[ -s "$f" ]] || continue
    printf '%s %s\n' "$(basename "$f" .bin)" "$(sha256sum "$f" | awk '{print $1}')"
  done
}

check_spd_clone() {
  local n dup_n=0 dup_text="" h cnt who
  n="$(mem_spd_fingerprints | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0

  if (( n < 2 )); then
    # 一片都没读到、或只读到一片 —— 没有可比的对象。
    # **SKIP，不是 FAIL**：读不到 SPD 是平台的事（SMBus 归 BMC 管 /
    # 被 BIOS 锁了 / DDR5 在这个内核上还没有驱动），不是内存的毛病。
    result_add "check_spd_clone" "内存芯片信息比对" "$ST_SKIP" \
      "本机未能读取到内存条自身芯片中的完整出厂记录（部分服务器平台不向操作系统开放该通道），\
本项未做核对。此项不影响整机结论，序列号核对不受影响。" ""
    return
  fi

  while read -r h cnt who; do
    [[ -n "$h" ]] || continue
    dup_n=$(( dup_n + 1 ))
    dup_text="${dup_text}${cnt} 条内存（${who}）的出厂记录完全相同；"
  done < <(mem_spd_fingerprints | awk '
    { cnt[$2]++; if (who[$2] == "") { who[$2] = $1; ord[++m] = $2 } else who[$2] = who[$2] "," $1 }
    END { for (i = 1; i <= m; i++) if (cnt[ord[i]] > 1) printf "%s %d %s\n", ord[i], cnt[ord[i]], who[ord[i]] }')

  metric_add "mem" "SPD整片重复组数" "$dup_n"

  if (( dup_n > 0 )); then
    result_add "check_spd_clone" "内存芯片信息比对" "$ST_FAIL" \
      "${dup_text}内存条芯片中记录的出厂信息（序列号、生产日期、追溯码等）\
是逐条唯一的，**两条正品内存的这段记录不可能完全一样**。\
出现完全相同说明这些内存条的出厂记录被整片复制过，属于**假冒产品**，不应装机出货。" \
      "raw/spd/"
  else
    result_add "check_spd_clone" "内存芯片信息比对" "$ST_PASS" \
      "已读取 ${n} 条内存芯片中的出厂记录，逐条互不相同" "raw/spd/"
  fi
}

# ================================================================
# 序列号核对：查假条子
# ================================================================
#
# 现场 2026-08-12 买到一批假内存，特征是**好几条的序列号一模一样**。
#
# 为什么重复就是铁证：内存条的序列号写在**条子自己的 SPD 芯片**里
# （DMI type 17 的 Serial Number 是主板从 SPD 读出来的，不是主板自己编的），
# JEDEC 规定它由厂商唯一分配。两条真条子的序列号撞在一起，概率不是"小"，
# 是**不存在** —— 只可能是 SPD 被人改写过，也就是翻新或假冒。
#
# ⚠️ 所以这一条判 **FAIL**，而且是这张盘上唯一一条"不用压测就能判死"的。
#    它和一号红线（能力缺失 ≠ 硬件故障）不冲突：这里判的是**被测条子自己
#    报出来的数据**，不是"我们没带工具"。
#
# 读不到序列号同样判 FAIL，理由是一样的：正品的 SPD 里有这一格，读不到属于异常。
# **但这一支留了开关** —— 万一以后遇到确实存在的空 SPD 正品（很老的模组、
# 某些 OEM 定制条），在 klburn.conf 里把它改成 0，那一支就退回 WARN。
# 重复那一支**没有开关**，那个没有任何正当解释。
: "${MEM_SN_MISSING_IS_FAIL:=1}"

# mem_sn_pairs [文件] -> 每行 "<槽位>|<序列号>"，**只出已装的槽位**，
# 序列号读不出来（BIOS 占位符）时第二段留空。
#
# 为什么不用 dmi_dimm_field 各取一列再 paste：那个函数只输出"这一格有值"的行，
# 一条内存缺了序列号就整行不出，两列的行数对不上、槽位和序列号就错位了 ——
# 而错位的表现是"报告说 A1 槽的条子是假的"，指着一条好内存。所以按整段一次出两列。
mem_sn_pairs() {
  local f="${1:-$RAW_DIR/dmidecode-memory.txt}"
  [[ -f "$f" ]] || return 0
  awk '
    BEGIN { RS = ""; FS = "\n" }
    function get(line, key,   p) {
      p = "\t" key ": "
      if (substr(line, 1, length(p)) == p) return substr(line, length(p) + 1)
      return ""
    }
    {
      size=""; loc=""; sn=""
      for (i = 1; i <= NF; i++) {
        line = $i; sub(/\r$/, "", line)
        if (size == "") { v = get(line, "Size");          if (v != "") size = v }
        if (loc  == "") { v = get(line, "Locator");       if (v != "") loc  = v }
        if (sn   == "") { v = get(line, "Serial Number"); if (v != "") sn   = v }
      }
      if (size == "" || size ~ /No Module Installed/) next
      if (loc == "") loc = "(未知槽位)"
      print loc "|" sn
    }' "$f" 2>/dev/null
}

# 把占位符（Not Specified / NO DIMM / <BAD INDEX>…）当成"没读到"。
# 判据复用 core.sh 的 _serial_is_bogus，不另开第二份名单。
mem_sn_valid_pairs() {
  local loc sn
  while IFS='|' read -r loc sn; do
    [[ -n "$loc" ]] || continue
    _serial_is_bogus "$sn" && continue
    printf '%s|%s\n' "$loc" "$sn"
  done < <(mem_sn_pairs "${1:-}")
}

# mem_sn_dups [文件] -> 每行 "<序列号> <重复条数> <槽位1,槽位2,...>"
# 只输出真的重复了的那些。
mem_sn_dups() {
  mem_sn_valid_pairs "${1:-}" | awk -F'|' '
    { cnt[$2]++; if (locs[$2] == "") { locs[$2] = $1; ord[++m] = $2 } else locs[$2] = locs[$2] "," $1 }
    END { for (i = 1; i <= m; i++) if (cnt[ord[i]] > 1) printf "%s %d %s\n", ord[i], cnt[ord[i]], locs[ord[i]] }'
}

check_dimm_serial() {
  local f="$RAW_DIR/dmidecode-memory.txt"
  local n_total n_have n_missing dup_n dup_mods dup_text
  n_total="$(mem_dimm_count "$f")"
  if (( n_total == 0 )); then
    result_add "check_dimm_serial" "内存序列号核对" "$ST_SKIP" \
      "未读到任何内存条明细，本项未做核对。此项不影响整机结论。" ""
    return
  fi

  n_have="$(mem_sn_valid_pairs "$f" | grep -c . || true)"
  [[ "$n_have" =~ ^[0-9]+$ ]] || n_have=0
  n_missing=$(( n_total - n_have ))

  # 重复的组数、涉及的条数、给人看的那句话
  dup_n=0; dup_mods=0; dup_text=""
  local sn cnt locs
  while read -r sn cnt locs; do
    [[ -n "$sn" ]] || continue
    dup_n=$(( dup_n + 1 ))
    dup_mods=$(( dup_mods + cnt ))
    dup_text="${dup_text}序列号 ${sn} 出现在 ${cnt} 条内存上（${locs}）；"
  done < <(mem_sn_dups "$f")

  metric_add "mem" "内存条数" "$n_total"
  metric_add "mem" "读到序列号条数" "$n_have"
  metric_add "mem" "序列号重复组数" "$dup_n"
  metric_add "mem" "序列号重复条数" "$dup_mods"

  # 判定顺序：重复 > 读不到 > 正常。重复排在前面 ——
  # 一批条子里既有重复又有读不到时，重复才是那句要说的话。
  if (( dup_n > 0 )); then
    result_add "check_dimm_serial" "内存序列号核对" "$ST_FAIL" \
      "本机 ${n_total} 条内存中，有 ${dup_mods} 条的序列号互相重复（${dup_n} 组）：${dup_text}\
内存条的序列号写在条子自身的存储芯片里，由厂商唯一分配，**两条正品内存不可能出现相同的序列号**。\
出现重复说明这些内存条的出厂信息被改写过，属于**翻新或假冒产品**，\
应逐条核对来源，不建议装机出货。" "raw/dmidecode-memory.txt"

  elif (( n_missing > 0 )); then
    local who="${n_missing} 条"
    (( n_missing == n_total )) && who="全部 ${n_total} 条"
    if [[ "$MEM_SN_MISSING_IS_FAIL" == "1" ]]; then
      result_add "check_dimm_serial" "内存序列号核对" "$ST_FAIL" \
        "本机 ${n_total} 条内存中，${who}读不出序列号。\
正品内存条的序列号写在条子自身的存储芯片里，正常情况下都能读到；\
读不出来说明这几条内存的出厂信息不完整或已被清除，**无法确认其来源与真伪**，\
建议逐条核对后再决定是否装机。" "raw/dmidecode-memory.txt"
    else
      result_add "check_dimm_serial" "内存序列号核对" "$ST_WARN" \
        "本机 ${n_total} 条内存中，${who}读不出序列号，无法据此逐条追溯来源。\
其余各项检测不受影响。" "raw/dmidecode-memory.txt"
    fi

  else
    result_add "check_dimm_serial" "内存序列号核对" "$ST_PASS" \
      "${n_total} 条内存的序列号全部读到，且互不重复" "raw/dmidecode-memory.txt"
  fi
}

# ---------------------------------------------------------------- 压测进度
#
# ⚠️ **故意不用整机盘那块仪表盘（dash_burn）。**
#    那块面板要读逐颗 CPU 频率/温度、网口状态、显卡状态（gpu_status_rows），
#    等于把这张盘刚刚砍掉的东西又拉回来一遍；而且它是"每 2 秒整屏重绘"，
#    前提是把别的写入源全部掐干净（console_quiet_on / 子进程重定向）——
#    为了一段两分钟的压测背这一整套约束不划算。
#
#    这里就是每 10 秒**追加打印一行**：普通滚动输出，没有光标跳转、
#    没有整屏重绘，任何别的东西往控制台上写都顶不花它（§11-14）。
#
# mem_progress <被测进程pid> <总秒数>
mem_progress() {
  local pid="$1" total="$2"
  local start now elapsed used tot ce ue
  start="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    kill -0 "$pid" 2>/dev/null || break
    now="$(date +%s)"; elapsed=$(( now - start ))
    (( elapsed > total )) && elapsed="$total"
    read -r used tot < <(mem_used_total_mb)
    read -r ce ue < <(mem_ecc_counts)
    printf '  [MEM] %s / %s   used %s/%s MB   ECC CE=%s UE=%s\n' \
      "$(fmt_hms "$elapsed")" "$(fmt_hms "$total")" \
      "${used:-?}" "${tot:-?}" "${ce:-?}" "${ue:-?}"
  done
}

# ---------------------------------------------------------------- 内核日志复查（只看内存）
#
# 整机盘的 verify_dmesg 扫的是**全部**硬件错误族（PCIe / 阵列卡 / 硬盘 /
# 显卡掉总线……）。这张盘**绝不能那么干**。
#
# ⚠️⚠️ 这张盘的判定口径是用户当面定死的（2026-08-12）：
#      **内存坏了才 FAIL。网卡坏了、阵列卡坏了，只要内存本身能正常读写，
#      就是 PASS。** 那些部件不归这张盘管，也不该干扰这份报告。
#
# 所以这个模式只收**明确指向内存**的原话，一条都不许再宽：
#   EDAC MC<n>: <n> CE/UE ...   内核内存控制器报的可纠正/不可纠正内存错误，
#                               后面还带着具体是哪个通道哪条 DIMM
#   EDAC <驱动名> ...           某些平台的 EDAC 驱动直接用自己的名字打
#   mce: [Hardware Error]: ...memory...   机器检查异常里明确说了是内存的那些
#   Memory failure: 0x...       内核把某个物理页标记成坏页
#   Corrupted low memory        低端内存被写坏
#
# ⚠️ **以下几个词看着像该收、其实一个都不能收**，收了就会把坏阵列卡/坏网卡
#    算到内存头上（正是上面那条口径要挡的事）：
#      uncorrectable / Uncorrected   PCIe AER 的严重级别就叫这两个词
#                                    （"PCIe Bus Error: severity=Uncorrected"）
#      Hardware Error（裸的）        AER、CPER、各种 GHES 报错都带这个前缀
#      Machine Check（裸的）         Bank 号不解码的话根本不知道是不是内存
#      I/O error / medium error      那是硬盘
#
# 判据仍然是「压测**新增**的」：开机阶段就有的那些是这台机器原本的状态，
# 由 mem_verify_dmesg_boot 单独说，不混进压测结论里。
mem_dmesg_pattern() {
  local pat='EDAC MC[0-9]+: [0-9]+ (CE|UE)'
  pat+='|EDAC (sbridge|skx|i10nm|igen6|amd64|ie31200|pnd2|thunderx) '
  pat+='|mce: \[Hardware Error\]: [^ ]* ?[Mm]emory'
  pat+='|Memory failure: 0x'
  pat+='|Corrupted low memory'
  printf '%s' "$pat"
}

# mem_dmesg_new <压测前的 dmesg> <压测后的 dmesg> <输出文件> -> 新增的错误行数
#
# 抽成纯函数（只吃文件路径、只吐数字）好脱机回归，见 tests/test-mem-edition.sh。
mem_dmesg_new() {
  local pre="${1:-}" post="${2:-}" out="${3:-}" pat n tmp
  pat="$(mem_dmesg_pattern)"
  : > "$out"
  [[ -f "$post" ]] || { printf '0'; return; }

  # 按**整行**取差集。dmesg -T 把时间戳打在同一行里，所以压测期间新打的那些行
  # 和压测前那份必然不同 —— 不会被误当成旧行滤掉；反过来开机阶段那些行两份里
  # 一字不差，会被干净地减掉，这正是我们要的（那些由 mem_verify_dmesg_boot
  # 单独说，不算到压测头上）。
  #
  # ⚠️ 空的模式文件（压测前一条内存错误都没有 —— 也就是**绝大多数好机器**）
  #    在 `grep -vxF -f` 下的行为是"没有任何模式"，于是 -v 把输入原样放行。
  #    这正确。别改成 `grep -vxF -f <(...)` 之外的写法之前先想清楚这一支：
  #    弄反了的话，健康机器上压出来的真错误会被整段吞掉。
  tmp="$(mktemp)" || { printf '0'; return; }
  grep -aE "$pat" "$pre" > "$tmp" 2>/dev/null || true
  grep -aE "$pat" "$post" 2>/dev/null | grep -avxF -f "$tmp" > "$out" 2>/dev/null || true
  rm -f "$tmp"

  n="$(count_lines "$out")"
  printf '%s' "$n"
}

# 压测**之前**就有的内存错误。单独说一句，别混进压测结论里 ——
# 开机就在报 ECC 错的机器，和"压了两分钟才压出来"是两回事。
mem_verify_dmesg_boot() {
  local f="$RAW_DIR/dmesg-pre.txt" out="$RAW_DIR/dmesg-mem-boot.txt" n
  [[ -f "$f" ]] || return 0
  grep -aE "$(mem_dmesg_pattern)" "$f" > "$out" 2>/dev/null || true
  n="$(count_lines "$out")"
  if (( n > 0 )); then
    result_add "mem_dmesg_boot" "开机日志内存错误" "$ST_FAIL" \
      "**在压力测试开始之前**，本机内核日志中已经存在 ${n} 条与内存相关的错误记录。\
也就是说这台机器在空闲状态下就已经在报内存错误，问题不是压出来的。" \
      "raw/dmesg-mem-boot.txt"
  else
    result_add "mem_dmesg_boot" "开机日志内存错误" "$ST_PASS" \
      "压力测试开始之前，内核日志中没有任何内存相关的错误记录" ""
  fi
}

mem_verify_dmesg() {
  local pre="$RAW_DIR/dmesg-pre.txt" post="$RAW_DIR/dmesg-post.txt"
  local out="$RAW_DIR/dmesg-mem-new.txt" n
  if [[ ! -f "$post" ]]; then
    result_add "mem_dmesg" "压测期间内核日志" "$ST_SKIP" \
      "未能读取本次压力测试期间的内核日志，本项未做核对。此项不影响整机结论。" ""
    return
  fi
  n="$(mem_dmesg_new "$pre" "$post" "$out")"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  metric_add "mem" "压测期间内核内存错误行数" "$n"

  if (( n > 0 )); then
    result_add "mem_dmesg" "压测期间内核日志" "$ST_FAIL" \
      "压力测试期间内核新报出 ${n} 条与内存相关的错误记录（ECC 错误 / 机器检查异常 / 坏页）。\
这类记录由 CPU 和内存控制器直接产生，是内存或内存控制器出问题的直接证据。" \
      "raw/dmesg-mem-new.txt"
  else
    result_add "mem_dmesg" "压测期间内核日志" "$ST_PASS" \
      "压力测试期间内核日志没有出现任何内存相关的错误记录" ""
  fi
}

# ---------------------------------------------------------------- 工程文件（CSV）
#
# 用户要的"工程文件"只要两样：**主板信息 + 每条内存的容量**。
# 这里在此之上多带了型号 / 序列号 / 频率 —— 这张盘存在的理由就是按 SN
# 点出坏条子，少了 SN 那一列，这份 CSV 拿到手上没法用。
#
# 一台机器一行是不行的（一台机器有 N 条内存），所以是**一条内存一行**，
# 主板那几列在每一行上重复 —— 这样多台机器的 CSV 直接首尾相接就能拼成
# 一张总表，Excel 里按 SN 或按型号一排序，坏的那批立刻聚到一起。
#
# ⚠️ 用 UTF-8 **带 BOM** 写：这份 CSV 是给人在 Windows 的 Excel 里双击打开的，
#    不带 BOM 的话 Excel 按本地代码页解，中文表头全是乱码。
#    （仓库里的 .sh/.conf 绝不许带 BOM，那是被 source 的；这里是产出的数据文件，
#    两回事 —— tests/lint.sh 那条 BOM 守卫扫的是源码树，不扫这里。）
mem_export_csv() {
  local out="$1" f="$RAW_DIR/dmidecode-memory.txt" sysf="$RAW_DIR/dmidecode-system.txt"
  local board_mf board_pn board_sn sys_pn

  board_mf="$(dmi_sys_field "$sysf" "Base Board Information" "Manufacturer")"
  board_pn="$(dmi_sys_field "$sysf" "Base Board Information" "Product Name")"
  board_sn="$(dmi_sys_field "$sysf" "Base Board Information" "Serial Number")"
  sys_pn="$(dmi_sys_field   "$sysf" "System Information"     "Product Name")"

  # 逐条内存的六个字段。dmi_dimm_field 每个字段各出一列，行序一致
  # （它按 DMI 段顺序输出，同一台机器上各字段的第 N 行就是同一条内存），
  # 但**只对"每条都有值"的字段成立** —— BIOS 没填 SN 的槽位会整行缺失，
  # 于是各列行数不等、错位。所以这里不做 paste，改成一次 awk 出全部列。
  {
    printf '\xEF\xBB\xBF'
    printf '整机型号,主板厂商,主板型号,主板序列号,槽位,容量,类型,厂商,型号,序列号,生产日期,Rank,总位宽,数据位宽,配置频率,最高频率\n'
    awk -v spn="$sys_pn" -v bmf="$board_mf" -v bpn="$board_pn" -v bsn="$board_sn" '
      BEGIN { RS = ""; FS = "\n" }
      function get(line, key,   p) {
        p = "\t" key ": "
        if (substr(line, 1, length(p)) == p) return substr(line, length(p) + 1)
        return ""
      }
      function q(s) {
        if (s == "") return ""
        gsub(/"/, "\"\"", s)
        # 逗号在内存型号里很常见（"M393A2K43DB3-CWE, 16GB"），不引起来整张表就错列
        if (s ~ /[",]/) return "\"" s "\""
        return s
      }
      {
        size=""; loc=""; mf=""; pn=""; sn=""; ty=""; cs=""; ms=""
        at=""; rk=""; tw=""; dw=""; dt=""
        for (i = 1; i <= NF; i++) {
          line = $i; sub(/\r$/, "", line)
          if (size == "") { v = get(line, "Size");                   if (v != "") size = v }
          if (loc  == "") { v = get(line, "Locator");                if (v != "") loc  = v }
          if (mf   == "") { v = get(line, "Manufacturer");           if (v != "") mf   = v }
          if (pn   == "") { v = get(line, "Part Number");            if (v != "") pn   = v }
          if (sn   == "") { v = get(line, "Serial Number");          if (v != "") sn   = v }
          if (ty   == "") { v = get(line, "Type");                   if (v != "") ty   = v }
          if (cs   == "") { v = get(line, "Configured Memory Speed");if (v != "") cs   = v }
          if (ms   == "") { v = get(line, "Speed");                  if (v != "") ms   = v }
          if (at   == "") { v = get(line, "Asset Tag");              if (v != "") at   = v }
          if (rk   == "") { v = get(line, "Rank");                   if (v != "") rk   = v }
          if (tw   == "") { v = get(line, "Total Width");            if (v != "") tw   = v }
          if (dw   == "") { v = get(line, "Data Width");             if (v != "") dw   = v }
        }
        if (size == "" || size ~ /No Module Installed/) next
        # 生产日期有两条来路，都拿不到就留空、绝不硬猜。
        #
        # ① Asset Tag 后面括号里的 date:YY/WW（AMI 系 BIOS 的私有写法）：
        #        P1-DIMMA1_AssetTag (date:22/51)  ->  2022-W51
        if (match(at, /date:[ ]*[0-9][0-9]\/[0-9][0-9]/)) {
          d = substr(at, RSTART + 5, RLENGTH - 5)
          gsub(/ /, "", d)
          split(d, p2, "/")
          if (p2[2] + 0 >= 1 && p2[2] + 0 <= 53) dt = "20" p2[1] "-W" p2[2]
        }
        # ② 18 位序列号里自带的那两个字节。
        #    JEDEC 的「模组唯一标识」是 9 字节：厂商(2)+产地(1)+日期(2)+序号(4)，
        #    有的 BIOS 把整个 9 字节抄进 Serial Number，有的只抄后面 4 字节 ——
        #    所以现场会看到 8 位和 18 位两种长度，**两种都正常**。
        #        80AD01233537A7DDDD -> SK Hynix / 地点1 / 2023-W35 / 37A7DDDD
        #    （拿 EPYC 7542 那台实测对过：和它 Asset Tag 里的 date:23/35 一致。）
        if (dt == "" && sn ~ /^[0-9A-Fa-f][0-9A-Fa-f]{17}$/) {
          yy = substr(sn, 7, 2); ww = substr(sn, 9, 2)
          # 十六进制里的 BCD：直接当十进制两位读，超出 1~53 就不是日期
          if (yy ~ /^[0-9][0-9]$/ && ww ~ /^[0-9][0-9]$/ \
              && ww + 0 >= 1 && ww + 0 <= 53) dt = "20" yy "-W" ww
        }
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
          q(spn), q(bmf), q(bpn), q(bsn),
          q(loc), q(size), q(ty), q(mf), q(pn), q(sn), q(dt), q(rk), q(tw), q(dw), q(cs), q(ms)
      }' "$f" 2>/dev/null
  } > "$out"
}

# ---------------------------------------------------------------- DMI 小工具
# dmi_sys_field <dmidecode 输出文件> <段名> <字段名> -> 值（取不到输出空）
#
# 只认**行首无缩进**的段名行 + 段内行首制表符紧跟字段名的那一行，
# 和 conformance.sh 的 dmi_dimm_field 同一套写法（substr 精确比对，不用正则 ——
# 字段名里带空格时正则太容易写错，而写错的表现是整格空白）。
dmi_sys_field() {
  local f="${1:-}" sect="${2:-}" field="${3:-}"
  [[ -f "$f" && -n "$sect" && -n "$field" ]] || return 0
  awk -v sect="$sect" -v want="$field" '
    BEGIN { RS = ""; FS = "\n" }
    {
      hit = 0
      wp = "\t" want ": "
      for (i = 1; i <= NF; i++) {
        line = $i; sub(/\r$/, "", line)
        if (line == sect) { hit = 1; continue }
        if (hit && substr(line, 1, length(wp)) == wp) {
          print substr(line, length(wp) + 1); exit
        }
      }
    }' "$f" 2>/dev/null
}

# ---------------------------------------------------------------- 报告目录名
#
# 用户指定的格式：**日期_时间_内存容量_CPU_MEMSP**
#   20260812_171151_32GB_2x-INTEL-XEON-GOLD-6530_MEMSP
#
# 注意和整机盘的 get_machine_tag **不一样**：那边是 日期_CPU_内存_范围。
# 这边照用户给的顺序（容量在前），后缀 `MEMSP` 标明这是内存专用盘出的报告。
#
# ⚠️ **1.10.1 起整个目录名是纯 ASCII 的。**（用户 2026-08-13 指定）
#    1.10.0 用的是中文前缀 `内存测试_…`，出发点是"在 Windows 上一眼认得出"，
#    代价是：这个名字要打在 **Linux 文本控制台**上（现场那块屏没有中文字体，
#    整段显示成方块）、要当 exFAT 目录名、还要进 SHA256SUMS 和批次汇总工具。
#    一个跨三种环境的标识串，值不上那点可读性 —— 后缀 MEMSP 一样认得出，
#    而且哪儿都不会出问题。
#
# ⚠️ 后缀留成变量是为了让 tests 直接断言这张表，**不是**给现场改的开关；
#    改它会让历史报告和新报告对不上账。
: "${MEM_DIR_SUFFIX:=MEMSP}"

mem_run_tag() {
  local stamp="${1:-$(date '+%Y%m%d_%H%M%S')}"
  printf '%s_%s_%s_%s' "$stamp" "$(get_mem_gb)" "$(get_cpu_tag)" "$MEM_DIR_SUFFIX"
}
