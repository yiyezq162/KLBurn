#!/usr/bin/env bash
# KLBurn 存储模块
#   1) 找到 U 盘上的 exFAT 数据分区并挂载（报告落这里）
#   2) 枚举可测试的裸盘，把 U 盘自己和任何已挂载的盘排除掉
#
# 这个文件里的排除逻辑是整个项目最要命的部分：一旦漏排，客户的数据盘会被 fio 写穿。

DATA_MOUNT="/mnt/klburn-data"
DATA_LABEL="KLBURN"

# ---------------------------------------------------------------- 工具
# 从一个内核设备名一路往上找到"整盘"。
#
# 为什么要循环而不是查一层：Ventoy 不是把 ISO 直接写进分区，而是用 dm-mapper
# 把 ISO 文件映射成虚拟光驱 /dev/mapper/ventoy。它的父设备是**分区** sda1，
# 再上一层才是整盘 sda。只查一层会得到 "sda1"，跟整盘名对不上，
# 结果就是 U 盘没被排除 —— fio 会去写启动盘自己。
to_whole_disk() {
  local cur="${1:-}" up
  [[ -n "$cur" ]] || return 0
  while :; do
    up="$(lsblk -no PKNAME "/dev/$cur" 2>/dev/null | head -1)"
    [[ -n "$up" && "$up" != "$cur" ]] || break
    cur="$up"
  done
  printf '%s\n' "$cur"
}

parent_disk() {
  to_whole_disk "$(lsblk -no PKNAME "$1" 2>/dev/null | head -1)"
}

# 同样是"上溯到整盘"，但完全走 sysfs，不依赖 lsblk，也不依赖 /dev 下的名字。
#   dm 设备 -> <sysfs>/slaves/ 里是它的下层设备
#   分区    -> 上一级目录就是整盘
#
# 参数可以是 "MAJ:MIN"、/dev 路径、或内核设备名。
#
# ⚠️ 为什么一定要支持 MAJ:MIN：
# Ventoy 把 ISO 用 dm-mapper 映射成虚拟光驱，/proc/mounts 里记的来源是
# "/dev/mapper/ventoy"，但 Ventoy 禁掉了 udev 规则，**这个路径在运行的系统里
# 根本不存在**（/dev/mapper 下只有 control）。拿路径去 readlink 什么也查不到，
# 于是 U 盘漏排、被当成可测试的空盘列出来。
# 而 /sys/dev/block/<maj>:<min> 对任何活着的设备都必然存在，与命名无关。
resolve_disk_sysfs() {
  local arg="${1:-}" depth="${2:-0}" dir="" s hmaj hmin
  [[ -n "$arg" ]] || return 0
  (( depth > 8 )) && return 0          # 防环

  if [[ "$arg" =~ ^[0-9]+:[0-9]+$ ]]; then
    dir="$(readlink -f "/sys/dev/block/$arg" 2>/dev/null)"
  elif [[ -b "$arg" ]]; then
    # 有真实设备节点：仍然按设备号查，避开各种符号链接和命名差异。
    # 必须加 -L：stat 默认是 lstat 不跟随符号链接，而 [[ -b ]] 跟随，
    # 两者不一致会导致 /dev/mapper/xxx 这类符号链接被读成设备号 0:0。
    read -r hmaj hmin < <(stat -L -c '%t %T' "$arg" 2>/dev/null)
    if [[ -n "${hmaj:-}" && -n "${hmin:-}" && "$hmaj$hmin" != "00" ]]; then
      dir="$(readlink -f "/sys/dev/block/$((16#$hmaj)):$((16#$hmin))" 2>/dev/null)"
    fi
  else
    dir="$(readlink -f "/sys/class/block/$(basename "$arg")" 2>/dev/null)"
  fi
  [[ -n "$dir" && -d "$dir" ]] || return 0

  # dm / md 这类堆叠设备，往下层走
  if [[ -d "$dir/slaves" ]]; then
    for s in "$dir"/slaves/*; do
      [[ -e "$s" ]] || continue
      resolve_disk_sysfs "$(basename "$s")" $(( depth + 1 ))
      return 0
    done
  fi
  # 分区：父目录即整盘
  if [[ -f "$dir/partition" ]]; then
    basename "$(dirname "$dir")"
    return 0
  fi
  basename "$dir"
}

# 返回承载 live 介质（U 盘）的整盘名字，可能多个，每行一个
live_media_disks() {
  {
    # casper 把 ISO 挂在 /cdrom。两条独立路径都算一遍，取并集。
    # 注意用 MAJ:MIN 而不是 SOURCE —— Ventoy 下 SOURCE 是个并不存在的路径。
    local mp src mm pk
    for mp in /cdrom /run/live/medium /isodevice /media/cdrom; do
      [[ -d "$mp" ]] || continue
      src="$(findmnt -n -o SOURCE --target "$mp" 2>/dev/null | head -1)"
      mm="$(findmnt -n -o MAJ:MIN --target "$mp" 2>/dev/null | head -1)"
      if [[ -n "$src" ]]; then
        pk="$(parent_disk "$src")"
        [[ -n "$pk" ]] && printf '%s\n' "$pk"
      fi
      [[ -n "$mm" ]] && resolve_disk_sysfs "$mm"
    done

    # 任何 iso9660 设备所在的盘（同样要一路上溯到整盘，
    # Ventoy 场景下这里拿到的是 dm 设备的父分区）
    local p
    while read -r p; do
      [[ -n "$p" ]] && to_whole_disk "$p"
    done < <(lsblk -rno NAME,FSTYPE,PKNAME 2>/dev/null \
             | awk '$2=="iso9660" && $3!="" {print $3}')

    # 报告数据分区所在的盘（Ventoy 场景下这就是 U 盘本身）
    if [[ -n "${DATA_DEV:-}" ]]; then
      parent_disk "$DATA_DEV"
      resolve_disk_sysfs "$DATA_DEV"
    fi

    # 总兜底：凡是当前有文件系统挂在上面的盘，一律不碰。
    #
    # 这条是 Ventoy 逼出来的。Ventoy 用 dm-mapper 把 ISO 和 exFAT 分区包了一层，
    # 而它的 dm 设备 udev 不处理、lsblk 完全看不见，导致上面所有基于 lsblk 的
    # 线索（iso9660 分区、rm 可移动标志、分区挂载状态）**全部落空**，
    # U 盘会被当成可测试的空盘列出来。
    # 走 sysfs 的 slaves 链不受 udev 影响，是唯一还认得出来的路径。
    # 同样按设备号取，不看 SOURCE 路径
    local mm2
    while read -r mm2; do
      [[ "$mm2" =~ ^[0-9]+:[0-9]+$ ]] || continue
      resolve_disk_sysfs "$mm2"
    done < <(findmnt -rno MAJ:MIN 2>/dev/null | sort -u)

    # 兜底：所有可移动盘
    local d
    for d in /sys/block/*; do
      [[ -f "$d/removable" ]] || continue
      if [[ "$(cat "$d/removable" 2>/dev/null)" == "1" ]]; then
        basename "$d"
      fi
    done
  } | sort -u | grep -v '^$'
}

# ---------------------------------------------------------------- dm 设备枚举
# 列出所有 device-mapper 设备的 /dev 路径，缺设备节点就补建。
#
# ⚠️ 这是 0.6.0 现场翻车的根因。
#
# Ventoy 用 dm-mapper 把 ISO 和 exFAT 分区各包一层，**能挂上的是 dm 映射**
# （历史数据里 data_partition 一直是 /dev/dm-1 或 /dev/dm-2），底下那个真实分区
# sdb1 被 device-mapper 以 FMODE_EXCL 独占持有，直接挂只会得到
#     /dev/sdb1: Can't open blockdev
#
# 而候选列表原先全靠 blkid 枚举 —— blkid 只扫 /dev 下**真实存在**的节点，
# 可 Ventoy 禁掉了 udev 规则，/dev/mapper 下只有 control，有时连 /dev/dm-N
# 都不会被创建。于是唯一能挂的那个候选凭空消失，只剩挂不上的 sdb1，
# 报告落 /tmp，关机就没了。
#
# /sys/block/dm-* 不受 udev 影响：任何活着的 dm 设备都必然在那里。
#
# 拆成两层：
#   dm_device_list  纯函数，只读 sysfs，输出 "dm-N 主:次"，不碰 /dev、不需要 root
#                   -> 能脱机做回归测试
#   dm_device_nodes 在它基础上补建缺失的设备节点，输出可用的 /dev 路径
# 参数 sysroot/devroot 只为测试用，现场永远走默认的 /sys 和 /dev。

# dm_device_list [sysfs根] -> 每行 "dm-N 主:次"
dm_device_list() {
  local sysroot="${1:-/sys}"
  local d name devno maj min
  for d in "$sysroot"/block/dm-*; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    [[ -r "$d/dev" ]] || continue
    devno="$(<"$d/dev")"
    IFS=: read -r maj min <<<"$devno"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || continue
    printf '%s %s:%s\n' "$name" "$maj" "$min"
  done
}

# dm_device_nodes [sysfs根] [dev根] -> 每行一个可用的 /dev 路径
dm_device_nodes() {
  local sysroot="${1:-/sys}" devroot="${2:-/dev}"
  local name devno maj min
  while read -r name devno; do
    [[ -n "$name" ]] || continue
    if [[ ! -b "$devroot/$name" ]]; then
      IFS=: read -r maj min <<<"$devno"
      # 节点不存在就自己造一个。设备号是从 sysfs 读出来的，不会造错。
      # 造不出来（没权限）就跳过——反正也用不了。
      mknod "$devroot/$name" b "$maj" "$min" 2>/dev/null || {
        dbg "cannot create $devroot/$name ($devno), skipping"
        continue
      }
      dbg "created missing device node $devroot/$name ($devno)"
    fi
    printf '%s\n' "$devroot/$name"
  done < <(dm_device_list "$sysroot")
}

# ---------------------------------------------------------------- 数据分区
# 成功: DATA_OK=1, RESULT_ROOT 指向 U 盘目录
# 失败: DATA_OK=0, RESULT_ROOT=/tmp/klburn-reports
mount_data_partition() {
  DATA_OK=0
  DATA_DEV=""
  RESULT_ROOT="/tmp/klburn-out"

  modprobe exfat      >/dev/null 2>&1 || true
  modprobe vfat       >/dev/null 2>&1 || true
  udevadm settle --timeout=10 >/dev/null 2>&1 || true

  local -a cands=()
  local dev d media

  # 候选一律用 blkid 枚举：Ventoy 的 dm 设备 lsblk 完全看不见，blkid 看得见。
  #
  # 不要试图"挑一个最合适的"再挂 —— 挑不准。
  # Ventoy 下 exFAT 分区会同时以真实分区(sdb1)和 dm 映射(dm-1)两种身份出现，
  # 而真实分区被 device-mapper 以 FMODE_EXCL 独占持有，直接挂会报
  # "Can't open blockdev"，只有挂 dm 映射才行。Rufus 场景下则相反。
  # 所以：把所有候选收集起来，逐个真去挂，谁能挂上且可写就用谁。

  # 来源 0：所有 dm 设备里文件系统是 exfat 的（Ventoy 唯一挂得上的那一个）。
  #
  # 必须排在最前面：Ventoy 下 sdb1 被 dm 独占，永远挂不上，先试它只是白等；
  # Rufus 场景下压根没有 dm 设备，这一轮直接是空的，不影响。
  #
  # 用 blkid -p（低层探测）而不是普通 blkid：普通模式走 /etc/blkid.tab 缓存，
  # 而这些 dm 设备刚被 mknod 出来、缓存里根本没有它们。
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    if [[ "$(blkid -p -s TYPE -o value "$dev" 2>/dev/null)" == "exfat" ]]; then
      cands+=("$dev")
      dbg "dm candidate: $dev (exfat)"
    fi
  done < <(dm_device_nodes)

  # 来源 1：卷标就叫 KLBURN
  while read -r dev; do
    [[ -n "$dev" ]] && cands+=("$dev")
  done < <(blkid -t "LABEL=$DATA_LABEL" -o device 2>/dev/null)

  # 来源 2：live 介质那块盘上的 exFAT
  #   Rufus  -> U 盘的第二分区
  #   Ventoy -> 放 ISO 的那个大 exFAT 分区
  media=" $(live_media_disks | tr '\n' ' ') "
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    d="$(resolve_disk_sysfs "$dev")"
    [[ -n "$d" && "$media" == *" $d "* ]] && cands+=("$dev")
  done < <(blkid -t TYPE=exfat -o device 2>/dev/null)

  # 来源 3：任何可移动盘上的 exFAT
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    d="$(resolve_disk_sysfs "$dev")"
    [[ -n "$d" ]] || continue
    [[ "$(cat "/sys/block/$d/removable" 2>/dev/null)" == "1" ]] && cands+=("$dev")
  done < <(blkid -t TYPE=exfat -o device 2>/dev/null)

  if (( ${#cands[@]} == 0 )); then
    warn "No exFAT partition found on the USB stick."
    return 1
  fi

  local tried=" "
  for dev in "${cands[@]}"; do
    [[ "$tried" == *" $dev "* ]] && continue      # 去重
    tried+="$dev "
    if _try_mount_data "$dev"; then
      return 0
    fi
  done

  warn "Found exFAT partition(s) [${tried# }] but none could be mounted read-write."
  # 一次都挂不上的时候，把现场原样记下来。0.6.0 那次现场只留下一张照片，
  # 光看 "Can't open blockdev" 猜不出到底有哪些块设备、dm 层长什么样。
  _dump_storage_diag
  return 1
}

# 把和"报告落哪"有关的现场信息全部倒进日志。只在挂载失败时调用。
_dump_storage_diag() {
  dbg "--- storage diagnostics begin ---"
  local line
  while read -r line; do dbg "  lsblk: $line"; done \
    < <(lsblk -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null)
  while read -r line; do dbg "  blkid: $line"; done < <(blkid 2>/dev/null)
  while read -r line; do dbg "  /sys/block: $line"; done \
    < <(for d in /sys/block/*; do
          [[ -r "$d/dev" ]] && printf '%s %s\n' "$(basename "$d")" "$(cat "$d/dev")"
        done 2>/dev/null)
  while read -r line; do dbg "  dm slaves: $line"; done \
    < <(for d in /sys/block/dm-*; do
          [[ -d "$d" ]] || continue
          printf '%s -> %s\n' "$(basename "$d")" "$(ls "$d/slaves" 2>/dev/null | tr '\n' ' ')"
        done 2>/dev/null)
  while read -r line; do dbg "  /dev/mapper: $line"; done < <(ls -la /dev/mapper 2>/dev/null)
  while read -r line; do dbg "  dm probe: $line"; done \
    < <(for d in $(dm_device_nodes); do
          printf '%s type=%s\n' "$d" "$(blkid -p -s TYPE -o value "$d" 2>/dev/null || echo '?')"
        done 2>/dev/null)
  dbg "--- storage diagnostics end ---"
}

# 试挂一个候选，成功且可写才算数
_try_mount_data() {
  local dev="$1"
  mkdir -p "$DATA_MOUNT"
  umount "$DATA_MOUNT" 2>/dev/null

  if ! mount -t exfat -o rw,uid=0,gid=0,umask=000 "$dev" "$DATA_MOUNT" 2>/dev/null; then
    if ! mount "$dev" "$DATA_MOUNT" 2>/dev/null; then
      dbg "mount $dev failed"
      return 1
    fi
  fi

  # 真写一下确认可写（只读挂载 / 满盘 都要在这里暴露）
  if ! touch "$DATA_MOUNT/.klburn-write-test" 2>/dev/null; then
    dbg "$dev mounted read-only or full"
    umount "$DATA_MOUNT" 2>/dev/null || true
    return 1
  fi
  rm -f "$DATA_MOUNT/.klburn-write-test"

  DATA_DEV="$dev"
  DATA_OK=1
  RESULT_ROOT="$DATA_MOUNT/out"
  mkdir -p "$RESULT_ROOT"
  ok "Data partition: $dev -> $DATA_MOUNT ($(df -h "$DATA_MOUNT" | awk 'NR==2{print $4}') free)"
  return 0
}

unmount_data_partition() {
  [[ "${DATA_OK:-0}" == "1" ]] || return 0
  sync
  umount "$DATA_MOUNT" 2>/dev/null || umount -l "$DATA_MOUNT" 2>/dev/null || true
}

# ---------------------------------------------------------------- 候选盘枚举
# 结果放进全局数组 DISK_CAND[] (path)、DISK_INFO[] (给人看的一行)
# 被排除的放 DISK_EXCLUDED[]（报告里也要说明为什么排除）
scan_disks() {
  DISK_CAND=(); DISK_INFO=(); DISK_EXCLUDED=()
  # DISK_SMART: 要采 SMART 的盘 = 可压测的 + 因已挂载而不压测的真实盘。
  # U 盘和虚拟设备不进这个列表。
  DISK_SMART=()

  lsblk -J -b -O > "$RAW_DIR/lsblk.json" 2>/dev/null || echo '{"blockdevices":[]}' > "$RAW_DIR/lsblk.json"

  local media_list
  media_list="$(live_media_disks | tr '\n' ' ')"
  dbg "live media disks: $media_list"

  local name path size model serial rota tran rm pttype mounted
  while IFS=$'\t' read -r name path size model serial rota tran rm pttype mounted; do
    [[ -n "$name" ]] || continue

    # 排除原因用英文：这些是要打在控制台上的，中文会显示成方块
    local why=""
    case "$name" in
      loop*|ram*|zram*|sr*|fd*|dm-*|md*) why="virtual / software RAID device" ;;
    esac
    [[ -z "$why" && " $media_list " == *" $name "* ]] && why="the KLBurn USB stick itself"
    [[ -z "$why" && "$rm" == "1" ]]                   && why="removable device (USB)"
    [[ -z "$why" && "$mounted" != "0" ]]              && why="has a mounted partition"
    [[ -z "$why" && ( -z "$size" || "$size" == "0" || "$size" == "-" ) ]] && why="zero capacity"

    local human_size
    human_size="$(numfmt --to=iec --suffix=B "${size:-0}" 2>/dev/null || echo "$size")"

    if [[ -n "$why" ]]; then
      DISK_EXCLUDED+=("$path|$human_size|$model|$why")
      dbg "exclude $path: $why"
      # 已挂载的是真实盘，不压测但报告里要有它的 SMART
      [[ "$why" == "has a mounted partition" ]] && DISK_SMART+=("$path")
    else
      DISK_CAND+=("$path")
      DISK_INFO+=("$path|$human_size|$model|$serial|$rota|$tran|$pttype")
      DISK_SMART+=("$path")
    fi
  done < <(jq -r -f "$KLB_LIB/disks.jq" "$RAW_DIR/lsblk.json" 2>/dev/null)

  info "Disks: ${#DISK_CAND[@]} testable, ${#DISK_EXCLUDED[@]} excluded"
}

# ---------------------------------------------------------------- 破坏性写确认
# 返回 0 = 用户确认，可以写；返回 1 = 跳过硬盘压测
confirm_disk_write() {
  local timeout="${1:-120}"

  if (( ${#DISK_CAND[@]} == 0 )); then
    return 1
  fi

  section "DISK STRESS TEST  (OPTIONAL, DESTRUCTIVE)"
  printf '  Disk %sinventory%s (model / capacity / serial / firmware / SMART health)\n' "$C_GRN" "$C_RST"
  printf '  has %salready been collected%s and will appear in the report either way.\n\n' "$C_GRN" "$C_RST"
  printf '%s' "$C_RED$C_BLD"
  printf '  The optional STRESS test makes fio write RANDOM DATA directly to the\n'
  printf '  RAW DEVICES listed below. ALL DATA ON THEM WOULD BE DESTROYED.\n'
  printf '%s' "$C_RST"
  printf '  %sDefault is to SKIP. Only continue if you really mean to wipe these disks.%s\n\n' "$C_YEL" "$C_RST"

  printf '  %-14s %10s  %-26s %-20s %s\n' "DEVICE" "SIZE" "MODEL" "SERIAL" "PARTITION TABLE"
  hr2
  local rec path size model serial rota tran pttype
  for rec in "${DISK_INFO[@]}"; do
    IFS='|' read -r path size model serial rota tran pttype <<< "$rec"
    local flag="none (looks blank)"
    if [[ "$pttype" != "none" && "$pttype" != "-" ]]; then
      flag="${C_YEL}${pttype} -- HAS EXISTING DATA${C_RST}"
    fi
    printf '  %-14s %10s  %-26.26s %-20.20s %b\n' "$path" "$size" "$model" "$serial" "$flag"
  done
  hr2

  if (( ${#DISK_EXCLUDED[@]} )); then
    printf '  %sExcluded (will NOT be touched):%s\n' "$C_GRN" "$C_RST"
    local e epath esize emodel ewhy
    for e in "${DISK_EXCLUDED[@]}"; do
      IFS='|' read -r epath esize emodel ewhy <<< "$e"
      printf '    %-14s %10s  %s\n' "$epath" "$esize" "$ewhy"
    done
    printf '\n'
  fi

  # ---------------- 第 1 关：必须原样打出 yes 再回车 ----------------
  printf '  %sType  yes  and press ENTER to continue to the final confirmation.%s\n' "$C_BLD" "$C_RST"
  printf '  %sENTER alone, any other text (typo included), or %ds timeout  ->  SKIP.%s\n\n' \
    "$C_GRY" "$timeout" "$C_RST"

  local answer=""
  if ! read_line_countdown answer "$timeout" "  Type yes to continue >"; then
    warn "No input for ${timeout}s - skipping disk stress test."
    DISK_SKIP_REASON="等待 ${timeout}s 无人确认，按默认跳过（硬盘信息已采集）"
    return 1
  fi

  # 去掉空格再比。只认 yes（不分大小写），打成 yea / y / YES! 之类一律跳过。
  local norm="${answer//[[:space:]]/}"
  if [[ "${norm,,}" != "yes" ]]; then
    if [[ -z "$norm" ]]; then
      info "Skipped by operator (ENTER)."
      DISK_SKIP_REASON="现场选择跳过（直接回车），硬盘信息已采集"
    else
      warn "Input was '${answer}', not 'yes' - skipping disk stress test."
      DISK_SKIP_REASON="现场输入的是 '${answer}' 而非 yes，按默认跳过（硬盘信息已采集）"
    fi
    return 1
  fi

  # ---------------- 第 2 关：最终警告面板 ----------------
  printf '\n%s' "$C_RED$C_BLD"
  printf '  +==========================================================+\n'
  printf '  |                    F I N A L   W A R N I N G             |\n'
  printf '  +==========================================================+\n'
  printf '  |  These disks are about to be OVERWRITTEN with random data|\n'
  printf '  |  This CANNOT be undone.                                  |\n'
  printf '  +==========================================================+\n'
  printf '%s' "$C_RST"
  local rec path size model serial rota tran pttype
  for rec in "${DISK_INFO[@]}"; do
    IFS='|' read -r path size model serial rota tran pttype <<< "$rec"
    printf '  %s   %-14s %10s  %-24.24s%s\n' "$C_RED$C_BLD" "$path" "$size" "$model" "$C_RST"
  done
  printf '\n'
  printf '  %s[y]%s  YES - erase and stress-test these disks\n' "$C_BLD" "$C_RST"
  printf '  %s[n]%s  No  - skip  (default; any other key also skips)\n\n' "$C_BLD" "$C_RST"

  local key="" start now remaining final_timeout=60
  start=$(date +%s)
  while :; do
    now=$(date +%s); remaining=$(( final_timeout - (now - start) ))
    if (( remaining <= 0 )); then
      printf '\n'
      warn "Final confirmation timed out - skipping disk stress test."
      DISK_SKIP_REASON="最终确认面板等待 ${final_timeout}s 无响应，自动跳过（硬盘信息已采集）"
      return 1
    fi
    printf '\r\033[K  %sPress y to ERASE, anything else to skip  [%2ds]%s ' \
      "$C_RED$C_BLD" "$remaining" "$C_RST"
    if IFS= read -r -s -t 1 -n 1 key; then
      printf '\n'
      if [[ "$key" == "y" || "$key" == "Y" ]]; then
        ok "Disk stress test confirmed by operator."
        return 0
      fi
      info "Skipped at final confirmation."
      DISK_SKIP_REASON="现场在最终确认面板选择了跳过（硬盘信息已采集）"
      return 1
    fi
  done
}
