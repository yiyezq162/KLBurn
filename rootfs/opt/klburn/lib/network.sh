#!/usr/bin/env bash
# KLBurn 网卡连通性测试
#
# 只做一件事：证明这个网口是通的 —— 拉起链路、DHCP 拿地址、ping 默认网关。
# 不做带宽压测：现场交换机、对端、线序都不可控，压出来的数字没有判定价值，
# 而"能不能拿到地址、能不能 ping 通网关"是硬件通不通的确定性证据。
#
# 为什么一个口一个口地测、测完立刻把地址释放掉：
# 多个口同时 DHCP 会各自装一条默认路由，后装的顶掉先装的，
# ping 就可能从另一个口发出去 —— 那测的是别的网卡，结论是错的。

: "${NET_CARRIER_WAIT:=8}"      # 拉起链路后等载波的秒数（PHY 协商要时间）
: "${NET_DHCP_TIMEOUT:=20}"     # 单口 DHCP 超时
: "${NET_PING_COUNT:=4}"        # 每个口 ping 网关的次数
: "${NET_TIME_SYNC_TIMEOUT:=12}"  # 单次校时尝试的超时（chronyd 一次性模式）
# 校时候选源：国内一个 + 一个全球通用的，两个都够快、都不依赖专门的账号/白名单
#
# 必须写成"没定义过才给默认值"。klburn.conf 是在**本文件之前**被 source 的
# （factory-test.sh 里 core.sh -> klburn.conf -> 其余 lib），上面那几个标量靠
# `: "${VAR:=默认}"` 天然就让现场的覆盖生效了，唯独数组没有对应的写法 ——
# 直接裸赋值的话，现场在 klburn.conf 里换内网 NTP 会被这一行原样顶掉，
# 而且不会有任何报错。数组不能用 `${#arr[@]:-0}` 探测（bash 报 bad substitution，
# 见 architecture.md §11-12），所以用 declare -p 判在不在。
declare -p NET_TIME_SERVERS >/dev/null 2>&1 || \
  NET_TIME_SERVERS=(ntp.aliyun.com cn.pool.ntp.org time.cloudflare.com)

# ================================================================
# 纯函数（不碰硬件，可脱机做回归测试）
# ================================================================

# ping 输出 -> "<发出> <收到> <平均毫秒>"，取不到的位置给 -
#
# 故意不用 gawk 的 match(..., arr) 三参数形式：Ubuntu 默认 awk 是 mawk，
# 不支持第三个参数，真机上会静默返回空。
net_parse_ping() {
  local f="$1" tx rx avg
  tx="$(grep -oE '[0-9]+ packets transmitted' "$f" 2>/dev/null | tail -1 | grep -oE '^[0-9]+')"
  rx="$(grep -oE ', [0-9]+ (packets )?received' "$f" 2>/dev/null | tail -1 | grep -oE '[0-9]+')"
  avg="$(grep -oE 'min/avg/max(/mdev)? = [0-9.]+/[0-9.]+' "$f" 2>/dev/null | tail -1 \
         | awk -F'/' '{print $NF}')"
  printf '%s %s %s' "${tx:--}" "${rx:--}" "${avg:--}"
}

# `ip -4 -o addr show dev X` 的输出 -> 第一个 IPv4 地址（带掩码位），没有则空
net_parse_addr() {
  grep -oE 'inet [0-9]+(\.[0-9]+){3}/[0-9]+' <<<"$1" | head -1 | awk '{print $2}'
}

# 169.254.0.0/16 是**没拿到 DHCP 时自己编的**链路本地地址（RFC 3927），
# 不是一个真的租约：拿着它既不会有网关、也上不了任何网。
# 当成"拿到地址了"会让结论变成"已获取地址，但 DHCP 未下发网关"，
# 把一个"没有 DHCP 服务器"的现场说成了网络配置有问题。
net_addr_is_linklocal() {
  [[ "${1:-}" == 169.254.* ]]
}

# `ip -4 route show ...` 的输出 -> 默认网关，没有则空
net_parse_gateway() {
  grep -oE 'via [0-9]+(\.[0-9]+){3}' <<<"$1" | head -1 | awk '{print $2}'
}

# 单口测试结论 -> 报告里那句中文。报告生成器也认这套 Result 关键字。
net_result_text() {
  case "$1" in
    OK)          printf '已连通' ;;
    NO_LINK)     printf '未连接链路（未接网线）' ;;
    NO_DHCP)     printf '链路已连接，但未获取到 DHCP 地址' ;;
    NO_GATEWAY)  printf '已获取地址，但 DHCP 未下发网关' ;;
    PING_FAIL)   printf '已获取地址，但 ping 网关不通' ;;
    NO_CLIENT)   printf '未测试（当前测试环境不具备该项检测条件）' ;;
    *)           printf '未测试' ;;
  esac
}

# ================================================================
# 硬件操作
# ================================================================

# ---------------------------------------------------------------- 哪些口算数
#
# ⚠️⚠️ **服务器的 BMC 会往系统里插一个 USB 虚拟网口。**
#
# 1.9.7 现场那台 7542 上是这样的：
#     enxbe3af2b6059f   driver rndis_host   bus-info usb-0000:48:00.3-1.1
#     Link detected: yes   IPv4 169.254.3.1/24   Gateway: -   -> NO_GATEWAY
#
# 它是主板上 BMC 通过 USB 暴露给操作系统的**带内管理通道**，不是这台机器
# 要交付给客户的网口。它那头没有 DHCP 服务器，所以永远拿不到网关，自己配一个
# 169.254 的链路本地地址就完事 —— 于是**每一台带 BMC 的机器都会被我们自己
# 刷一条「网卡连通性 WARN」**，还会让"共 N 个物理网口"多数一个。
#
# 判据两条，命中任意一条就不参与判定：
#   1. 挂在 USB 总线上（/sys/class/net/X/device/subsystem -> .../bus/usb）
#   2. 驱动是 RNDIS / CDC 那一族（BMC 虚拟网口、USB 网卡都走这几个驱动）
# 第 2 条是给"读不到 subsystem"的内核兜底的，两条各自都能单独成立。
#
# 出厂测试台上不存在"必须靠 USB 网卡上网"的场景，所以 USB 口一律不参与判定；
# 但它**照样采集、照样进清单**（标注成虚拟口），不然现场会以为我们漏了一个口。
#
# net_iface_is_virtual <总线名> <驱动名> -> 返回 0 = 虚拟口
# 抽成纯函数便于脱机回归测试，见 tests/test-hw-checks.sh
net_iface_is_virtual() {
  local bus="${1:-}" drv="${2:-}"
  [[ "$bus" == "usb" ]] && return 0
  case "$drv" in
    rndis_host|cdc_ether|cdc_ncm|cdc_eem|cdc_subset|cdc_mbim|usbnet|ipheth|qmi_wwan)
      return 0 ;;
  esac
  return 1
}

# 从 sysfs 读某个口挂在哪条总线上 / 用的什么驱动，读不到给空串
net_iface_bus() {
  local p; p="$(readlink -f "/sys/class/net/${1:-}/device/subsystem" 2>/dev/null)"
  [[ -n "$p" ]] && basename "$p" || printf ''
}
net_iface_driver() {
  local p; p="$(readlink -f "/sys/class/net/${1:-}/device/driver" 2>/dev/null)"
  [[ -n "$p" ]] && basename "$p" || printf ''
}

# 所有带 device 节点的口（跳过 lo 和 bond/vlan/veth 之类的纯软件口）。
# 虚拟口也在里面 —— 采集要用它，判定不用。
net_all_ifaces() {
  local n ifn
  for n in /sys/class/net/*; do
    [[ -e "$n" ]] || continue
    ifn="$(basename "$n")"
    [[ "$ifn" == "lo" ]] && continue
    [[ -e "$n/device" ]] || continue
    printf '%s\n' "$ifn"
  done
}

# 参与判定的物理网口列表
net_phys_ifaces() {
  local ifn
  while read -r ifn; do
    [[ -n "$ifn" ]] || continue
    net_iface_is_virtual "$(net_iface_bus "$ifn")" "$(net_iface_driver "$ifn")" && continue
    printf '%s\n' "$ifn"
  done < <(net_all_ifaces)
}

# 不参与判定的虚拟口列表（BMC 虚拟网口、USB 网卡），只用来在清单里标注
net_virtual_ifaces() {
  local ifn
  while read -r ifn; do
    [[ -n "$ifn" ]] || continue
    net_iface_is_virtual "$(net_iface_bus "$ifn")" "$(net_iface_driver "$ifn")" \
      && printf '%s\n' "$ifn"
  done < <(net_all_ifaces)
}

# 把所有物理口拉起来，然后统一等一次载波。
#
# 必须在 collect_nic（ethtool 采集）之前调用：口是 down 的时候
# ethtool 报的是 "Speed: Unknown!" / "Link detected: no"，
# 插着网线也一样，采出来的链路状态是假的。
net_link_up_all() {
  info "Bringing up all physical NICs (link check) ..."
  local ifn n=0
  while read -r ifn; do
    [[ -n "$ifn" ]] || continue
    ip link set "$ifn" up 2>/dev/null && n=$((n+1))
    dbg "ip link set $ifn up"
  done < <(net_phys_ifaces)

  (( n == 0 )) && return 0

  # 载波是各口并行协商的，等一次就够，不用逐口等
  local waited=0
  while (( waited < NET_CARRIER_WAIT )); do
    sleep 1
    waited=$((waited+1))
    local any=0
    while read -r ifn; do
      [[ "$(cat "/sys/class/net/$ifn/carrier" 2>/dev/null)" == "1" ]] && any=1
    done < <(net_phys_ifaces)
    (( any )) && break
  done
  dbg "carrier wait finished after ${waited}s"
}

# ---------------------------------------------------------------- LLDP 邻居发现
# 现场排线错误（网线插错交换机口）以前只能靠人对着标签核，现在报告里直接写着
# "eno1 -> switch-A / Gi1/0/12"。
#
# ⚠️ **只用接收模式（-r）。** lldpd 默认会往每个口上发我们自己的 LLDP 通告，
# 而这是在**客户的交换机**上留痕迹 —— 出厂测试是来看这台机器的，
# 不该往别人的网络里写任何东西。-r 只听不说。
#
# 拉起来就不管了：这是 live 系统，测完直接关机。失败一律无声跳过 ——
# 拿不到 LLDP 邻居只是少一份参考数据，跟被测机器好不好毫无关系（二号原则）。
lldp_start() {
  have lldpd || { dbg "lldpd not present, skipping LLDP neighbour discovery"; return 0; }
  pgrep -x lldpd >/dev/null 2>&1 && return 0
  # -r 接收模式；服务本身在构建时是 mask 掉的，这里直接跑二进制
  if lldpd -r >/dev/null 2>&1; then
    info "LLDP neighbour discovery started (receive-only)"
  else
    dbg "lldpd failed to start (non-fatal)"
  fi
  return 0
}

# DHCP 取地址。返回 0 = 拿到，127 = 盘内没有 DHCP 客户端
#
# ${RAW_DIR:-/tmp} 是因为联网校时（try_sync_clock_via_network）在 RUN_DIR
# 建立之前就要用这个函数——那时候 $RAW_DIR 还没定义，日志就先落 /tmp，
# 不影响功能，只是这几行 dhclient 输出不会进最终报告目录。
net_dhcp() {
  # ⚠️ 必须拆成两条 local。同一条 local 里后一个变量看不到前一个刚赋的值
  # （bash 在调用 local 之前就把所有参数展开完了），写成
  #     local ifn="$1" log="...${ifn}..."
  # 时那个 ${ifn} 取到的是**调用方作用域里**碰巧同名的变量 —— 现在两个调用方
  # 的循环变量恰好都叫 ifn，所以一路蒙对；哪天有人把循环变量改个名，
  # 日志就会写成 "-dhcp.log"，或者在 set -u 下直接 unbound variable 崩掉。
  # 同样的坑 mem_gap_tolerance_mb 那里已经栽过一次了。
  local ifn="$1"
  local log="${RAW_DIR:-/tmp}/nic/${ifn}-dhcp.log"
  mkdir -p "$(dirname "$log")" /var/lib/dhcp
  if have dhclient; then
    # -1 = 试一轮拿不到就退出（默认会无限重试，现场没有 DHCP 就卡死在这）。
    #
    # ⚠️ 真机上炸过一次：ISC dhclient 根本没有 `-timeout <秒数>` 这个命令行参数
    # （timeout 只能写在 dhclient.conf 配置文件里当指令用），传了这个参数
    # dhclient 直接打印 usage 报错退出，DHCP 100% 失败——之前"接了网线也测不到
    # 网络"就是栽在这一行。超时完全交给外层的 `timeout` 命令包一层就够了，
    # 不需要也不能再传给 dhclient 本身。
    timeout --kill-after=5s $(( NET_DHCP_TIMEOUT + 5 )) \
      dhclient -4 -1 "$ifn" >>"$log" 2>&1
    return $?
  elif have udhcpc; then
    timeout --kill-after=5s $(( NET_DHCP_TIMEOUT + 5 )) \
      udhcpc -i "$ifn" -n -q -t 4 -T 3 >>"$log" 2>&1
    return $?
  fi
  printf '(no dhcp client on this media)\n' >>"$log"
  return 127
}

# 释放地址，为下一个口让路。
#
# 故意不 down 链路：部分服务器的 BMC 通过 NCSI 共享 LOM 口，
# 把口 down 掉有可能连带影响 BMC 的网络。留着 up 是无害的。
net_release() {
  local ifn="$1"
  have dhclient && timeout 10 dhclient -r "$ifn" >/dev/null 2>&1
  pkill -f "dhclient.*${ifn}" >/dev/null 2>&1
  pkill -f "udhcpc.*${ifn}"   >/dev/null 2>&1
  ip -4 addr flush dev "$ifn" 2>/dev/null || true
}

# ---------------------------------------------------------------- 联网校时
#
# 不少送来测试的机器在仓库里放了很久，主板纽扣电池已经没电，BIOS RTC 会回退到
# 一个很老或者莫名其妙的日期（现场也没人会进 BIOS 手动对时）。等报告都生成
# 完了才发现日期不对就晚了——目录名、meta.json 里的时间戳全部已经写死。
# 所以这一步必须在 factory-test.sh 算 RUN_STAMP 之前调用。
#
# 只要求准到小时级别，不追求 NTP 意义上的精确对时：抓到任意一个能连上的
# 时间源、拨一次就完事，不做后续的漂移矫正。连不上网（现场大多数情况本来
# 就是离线的）就放弃，继续用 BIOS/RTC 现有的时间——没有更好的办法。
#
# 真正用哪个口测连通性、拿哪个口的地址，交给后面 collect_all 里的 net_test()
# 正式再做一遍（那才是写进报告的结论）；这里只是"顺手蹭一次网"，
# 所以拿到时间就退出，不用把每个口都测一遍。

# ---------------------------------------------------------------- 时间源候选
#
# ⚠️⚠️ **只往公网 NTP 拨是不够的 —— 1.9.7 现场那台 7542 就是这么栽的。**
# 那台机器网是通的（eno1 拿到 192.168.110.147、ping 网关 4/4 通、0.525ms），
# 但**那个网出不了公网**，于是 ntp.aliyun.com / cn.pool.ntp.org /
# time.cloudflare.com 三个全部拨不通，报告日期停在一个八个月前的假日期上。
#
# 内网机器才是工厂里的常态，所以候选源按"由近及远"排：
#   0. **klburn.conf 里现场自己填的那个**（KLB_NTP_SERVERS）—— 最优先
#   1. DHCP 下发的 NTP 服务器（option 42）—— 企业网大多配了
#   2. 默认网关自己 —— **这一条只是碰运气**：多数企业网关会应答 NTP，
#      但这不是必然的（用户 2026-08-12 明确指出）。所以它排在①后面，
#      而且绝不能是唯一的内网来源 —— 那正是加第 0 条的理由。
#   3. 配置里那几个公网源 —— 只有真能出公网时才轮得到
# 全都不成还有第 4 条退路，见 sync_clock_from_bmc。
#
# ⚠️ 数组不能裸赋值（klburn.conf 是在本文件**之前**被 source 的，
#    裸赋值会把现场填的值原样顶掉，而且不会有任何报错）——
#    见本文件开头 NET_TIME_SERVERS 那一段。KLB_NTP_SERVERS 是**标量**
#    （空格分隔的一串），所以用 `: "${VAR:=}"` 就够了。
: "${KLB_NTP_SERVERS:=}"
#
# net_dhcp_ntp_servers -> DHCP 租约里带回来的 NTP 服务器，一行一个
# dhclient 的默认 request 列表里本来就有 ntp-servers，不用改配置。
# 抽成纯函数便于脱机回归测试（传文件路径进来），见 tests/test-hw-checks.sh
net_dhcp_ntp_servers() {
  local f="${1:-/var/lib/dhcp/dhclient.leases}"
  [[ -f "$f" ]] || return 0
  # option ntp-servers 10.0.0.1, 10.0.0.2;
  grep -aoE 'option ntp-servers[^;]*' "$f" 2>/dev/null \
    | sed -E 's/option ntp-servers[[:space:]]*//' \
    | tr ',' '\n' | tr -d ' \t' | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u
}

# sync_clock_now [服务器...] —— 拿给定的服务器拨一次。不给就用配置里那几个。
sync_clock_now() {
  have chronyd || { dbg "clock sync: no chronyd on this media"; return 1; }

  # ⚠️ 每条 server 指令必须是**一个独立的命令行参数**。
  #
  # chronyd 的用法是 `chronyd [OPTION]... [DIRECTIVE]...`，一个参数就是一条指令。
  # 0.4.0 之前是把三个服务器拼成一个三行的字符串塞进去，chronyd 直接
  #     Fatal error : Could not parse server directive at line 1
  # 秒退——也就是说校时**从来就没跑起来过**，现场日志里那句"1 秒就放弃"
  # 不是网络不通，是这里参数传错了。（在 WSL 里两种写法对比实测过。）
  local cand=("$@")
  (( ${#cand[@]} == 0 )) && cand=("${NET_TIME_SERVERS[@]}")
  (( ${#cand[@]} == 0 )) && return 1

  local args=() srv
  for srv in "${cand[@]}"; do
    args+=("server $srv iburst maxsamples 1")
  done

  # 输出不要再往 /dev/null 里扔了：校时失败时现场和报告里都得看得到原因，
  # 否则下次还是只能靠猜。RUN_DIR 这时候还没建立，先落 /tmp，
  # 由 factory-test.sh 在 RUN_DIR 就绪后搬进 raw/。
  local log="${KLB_CLOCK_LOG:-/tmp/klburn-clocksync.log}"
  {
    printf '=== %s try sync via %s ===\n' "$(date '+%F %T')" "${cand[*]}"
  } >> "$log" 2>/dev/null
  timeout "$NET_TIME_SYNC_TIMEOUT" chronyd -q "${args[@]}" >> "$log" 2>&1
}

# ---------------------------------------------------------------- 退到 BMC 的时钟
#
# 一根网线都没接的机器（工厂里大多数）永远走不到 NTP 那一步，但**机器上还有
# 一个一直在走的时钟：BMC**。它自带电池、独立于主板 RTC，绝大多数机器上
# 装机时就对过一次，比一个"每次开机都回退到同一个时间点"的死 RTC 靠谱得多。
#
# ⚠️ 但它也**不保证准**（客户从没配过 BMC 时间的机器也见得到），所以：
#   * 只在网络校时失败之后才用
#   * 明显不合理的值一律不采信 —— 比这张介质的构建日期还早的时间，
#     和现在这个坏 RTC 一样没有价值，采信了反而更坏事：
#     一个"看着像正经日期"的错时间，比一个一眼假的错时间更难被发现
#   * 用了就把来源记下来（CLOCK_SOURCE），报告里如实写明
sync_clock_from_bmc() {
  have ipmitool || { dbg "clock sync: no ipmitool on this media"; return 1; }
  local log="${KLB_CLOCK_LOG:-/tmp/klburn-clocksync.log}" raw ts now_epoch min_epoch

  # ⚠️ 这一步跑在 collect_ipmi **之前**（校时必须在算 RUN_STAMP 之前做），
  #    那两个模块还没人加载过 —— 不在这儿自己 modprobe 一次的话，
  #    ipmitool 一定报 "Could not open device at /dev/ipmi0"，这条退路等于没写。
  modprobe ipmi_devintf >/dev/null 2>&1 || true
  modprobe ipmi_si      >/dev/null 2>&1 || true

  raw="$(timeout 20 ipmitool sel time get 2>/dev/null | tr -d '\r' | head -1)"
  printf '=== %s BMC clock reads: %s ===\n' "$(date '+%F %T')" "${raw:-<none>}" \
    >> "$log" 2>/dev/null
  [[ -n "$raw" ]] || return 1

  # ipmitool 给的是 "MM/DD/YYYY HH:MM:SS"，date 认不了这个顺序，转成 ISO 再喂
  ts="$(printf '%s' "$raw" | awk '
    match($0, /[0-9]{2}\/[0-9]{2}\/[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}/) {
      s = substr($0, RSTART, RLENGTH)
      split(s, a, " "); split(a[1], d, "/")
      printf "%s-%s-%s %s", d[3], d[1], d[2], a[2]
    }')"
  [[ -n "$ts" ]] || return 1

  now_epoch="$(date -d "$ts" +%s 2>/dev/null)" || return 1
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1
  # 比介质构建日期还早的一律不采信（判据和 factory-test.sh 里那条一致）
  min_epoch="$(date -d "${BUILD_DATE:-2020-01-01}" +%s 2>/dev/null || echo 0)"
  if [[ "$min_epoch" =~ ^[0-9]+$ ]] && (( now_epoch < min_epoch )); then
    printf '    rejected: BMC clock is older than this media build date\n' >> "$log" 2>/dev/null
    return 1
  fi

  date -s "$ts" >> "$log" 2>&1 || return 1
  hwclock -w >/dev/null 2>&1 || true
  return 0
}

try_sync_clock_via_network() {
  # 这一轮的时间是从哪来的，报告里要如实写明。取值：
  #   network / bmc / rtc
  CLOCK_SOURCE="rtc"

  local ifn total=0
  while read -r ifn; do [[ -n "$ifn" ]] && total=$((total+1)); done < <(net_phys_ifaces)

  local synced=0
  if (( total == 0 )); then
    dbg "clock sync: no physical NIC, skip to BMC"
  else
    info "Checking for network access to sync the clock (best-effort) ..."
    net_link_up_all

    while read -r ifn; do
      [[ -n "$ifn" ]] || continue
      net_iface_has_carrier "$ifn" || continue
      net_dhcp "$ifn" || { net_release "$ifn"; continue; }

      # 候选源由近及远，见 net_dhcp_ntp_servers 上面那段说明。
      # 一次只拨一档：拨得通就收工，省得在没有公网的现场白等三次超时。
      local cand=() gw srv
      # ① 现场在 klburn.conf 里填的那个，排第一
      for srv in ${KLB_NTP_SERVERS}; do [[ -n "$srv" ]] && cand+=("$srv"); done
      # ② DHCP 下发的
      while read -r srv; do [[ -n "$srv" ]] && cand+=("$srv"); done \
        < <(net_dhcp_ntp_servers)
      # ③ 默认网关（碰运气，见上面说明）
      gw="$(net_parse_gateway "$(ip -4 route show default dev "$ifn" 2>/dev/null)")"
      [[ -n "$gw" ]] && cand+=("$gw")
      # ④ 公网
      cand+=("${NET_TIME_SERVERS[@]}")

      for srv in "${cand[@]}"; do
        if sync_clock_now "$srv"; then synced=1; CLOCK_SOURCE="network"; break; fi
      done

      net_release "$ifn"
      (( synced )) && break
    done < <(net_phys_ifaces)
  fi

  # 一根网线都没接、或者内网也没有任何 NTP —— 还有 BMC 那个一直在走的时钟
  if (( synced == 0 )) && sync_clock_from_bmc; then
    synced=1
    CLOCK_SOURCE="bmc"
  fi

  case "$CLOCK_SOURCE" in
    network) ok "System clock synced from network: $(date '+%Y-%m-%d %H:%M %Z')" ;;
    bmc)     ok "System clock taken from the BMC: $(date '+%Y-%m-%d %H:%M %Z')" ;;
    *)       warn "No usable time source - keeping BIOS/RTC clock as-is." ;;
  esac
  return $(( synced ? 0 : 1 ))
}

# ---------------------------------------------------------------- 协商速率达标
# 一个万兆口协商成了千兆（线序不对 / 光模块不对 / 对端口不对 / 线缆质量差），
# 连通性测试照样全绿——能拿到 DHCP 地址、也 ping 得通网关，只是慢了十倍。
# ethtool 的 "Supported link modes"（这块网卡的额定能力）和 "Speed"（实际协商结果）
# 采集阶段早就落盘了，只差比对这一步。
#
# 只比协商速率，不做吞吐测试：那需要对端再架一台机器打流，出厂测试台上没有这个条件。
#
# nic_supported_max_mbps <ethtool输出文件> -> 支持的最高速率(Mb/s)，取不到给 0
# "Supported link modes" 可能跨多行，后续行没有字段名、只是缩进：
#     Supported link modes:   1000baseT/Full
#                             10000baseT/Full
# 所以要一直吃到下一个 "字段名:" 出现为止。
nic_supported_max_mbps() {
  local f="${1:-}"
  [[ -f "$f" ]] || { printf '0'; return; }
  awk '
    /Supported link modes:/ { inblock = 1 }
    inblock {
      # 碰到下一个字段名就收工（"Supported link modes:" 那行自己不算）
      if ($0 !~ /Supported link modes:/ && $0 ~ /^[[:space:]]*[A-Za-z][A-Za-z0-9 \/()-]*:/) {
        inblock = 0
        next
      }
      line = $0
      # 一行里可能有多个模式，全都抠出来取最大：10000baseT/Full 25000baseCR/Full ...
      while (match(line, /[0-9]+base/)) {
        v = substr(line, RSTART, RLENGTH - 4) + 0
        if (v > max) max = v
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END { printf "%d", max + 0 }
  ' "$f"
}

# nic_current_mbps <ethtool输出文件> -> 当前协商速率(Mb/s)，取不到给 0
# 没插线时 ethtool 报的是 "Speed: Unknown!"，必须当成"读不到"而不是 0 速率。
nic_current_mbps() {
  local f="${1:-}"
  [[ -f "$f" ]] || { printf '0'; return; }
  awk '
    /^[[:space:]]*Speed:/ {
      s = $0
      sub(/^[[:space:]]*Speed:[[:space:]]*/, "", s)
      sub(/Mb\/s.*$/, "", s)
      if (s ~ /^[0-9]+$/) { printf "%d", s; found = 1 }
      exit
    }
    END { if (!found) printf "0" }
  ' "$f"
}

# 只判"已接网线"的口。没插线的口 ethtool 报的速率是假的，绝不能参与判定
# （这正是 collect_all 里要先 net_link_up_all 再 collect_nic 的原因）。
# ---------------------------------------------------------------- 网卡自检
#
# **让网卡自己查一遍。**现在网卡这一块的判定全都依赖"有没有插网线"：
# 没插线就只能 SKIP，而工厂里绝大多数机器就是没插线的。网卡自己的
# offline 自检**不需要对端、不需要网线**，查的是寄存器、回环、中断、
# EEPROM 这些从外面完全看不到的东西。
#
# ⚠️ **必须排在 net_link_up_all 之前跑**：offline 自检会把链路踢下去，
#    排在后面的话后面那步 DHCP 拿到的是一个刚被自己踢掉的链路。
#
# ⚠️ 结论是**网卡自己给的**（`The test result is PASS/FAIL`），我们不定判据。
#    驱动不实现自检的很常见（virtio、部分国产卡），一律 SKIP —— 那是
#    驱动的能力问题，不是这块卡坏了（一号红线）。
#
# ⚠️⚠️ **总结论是所有子项的"与"，而其中的「链路」子项依赖网线。**
#    没插网线的口，Link test 必然不通过，于是总结论就是 FAIL —— 而真正查
#    卡上硬件的那几项（寄存器 / EEPROM / 中断 / 回环）全是 0（通过）。
#    1.9.2 现场那台 6530 就是这么被判成"该网口存在硬件故障，需更换或返修"的：
#
#        ens9f1（没插网线）        ens9f0（插着网线）
#        The test result is FAIL   The test result is PASS
#        Register test  (offline) 0    Register test  (offline) 0
#        Eeprom test    (offline) 0    Eeprom test    (offline) 0
#        Interrupt test (offline) 0    Interrupt test (offline) 0
#        Loopback test  (offline) 0    Loopback test  (offline) 0
#        Link test   (on/offline) 1    Link test   (on/offline) 0
#                                 ^ 唯一不同的就是这一项
#
#    所以这里必须把子项拆开看：**只有非「网线相关」子项不通过才算硬件故障**。
#    「现场没接网线」是二号红线点名的场景，判 FAIL 就是把好机器拦在出货前。
#
# ⚠️⚠️⚠️ **1.9.7 现场又栽了一次，同一个坑的第二个入口。**
#    那台 7542 上的 ConnectX-5（mlx5_core）两个口都没插网线，报告写着
#    「2 个网口自带的自检未通过，说明该网口存在硬件故障，需更换或返修」，
#    直接卡住出货。mlx5 的子项名字和 Intel 完全不一样：
#
#        Link Test        1   ← 名字里有 link，1.9.2 认得
#        Speed Test       1   ← **名字里没有 link，被当成了硬件故障**
#        Health Test      0
#        Loopback Test  -95   ← 驱动返回 -EOPNOTSUPP，非 0，也被当成了失败
#
#    内核里 mlx5e_test_link_speed() 头一句就是 `if (!netif_carrier_ok()) return 1`
#    —— 它和 Link Test 一样是**没插网线必然不通过**的。所以这一版做了四件事，
#    每一件单独都能挡住这次的误判，四件一起是为了下一个厂家的下一个名字：
#
#      1. 名字里带 link / speed / cable 的，一律归到「网线相关」那一档
#      2. **负数一律当成"驱动跑不了这一子项"**，不是失败（一号红线：
#         能力缺失 ≠ 硬件故障）。ethtool 直接把驱动的返回码填进结果数组，
#         -95 是 EOPNOTSUPP、-22 是 EINVAL，都是"没做这项"而不是"这项没过"
#      3. 自检前先把网口 up 起来（见 check_nic_selftest）—— mlx5 的回环自检
#         在口 down 的时候压根不跑，直接返回 -EOPNOTSUPP
#      4. 兜底：**没插网线的口，任何情况下都不判 FAIL**（见 check_nic_selftest）
#
# nic_selftest_subtests <ethtool -t 的输出文件>
#   -> "<硬件子项失败数> <网线相关子项失败数> <驱动跑不了的子项数>"
#
# 子项明细的格式各家驱动不完全一样，共同点是"名字在前、数值在最后一个字段，
# 0 表示这一项通过"：
#     Register test  (offline)\t 0     ← intel ixgbe / igb / i40e / e1000e
#     Link Test                  0     ← mlx5 / bnxt 这类不带括号的
# 所以按"最后一个字段是数值"来认。
nic_selftest_subtests() {
  local f="${1:-}"
  [[ -s "$f" ]] || { printf '0 0 0'; return; }
  awk '
    /[Tt]he test extra info/ { inx = 1; next }
    !inx { next }
    {
      line = $0
      sub(/\r$/, "", line)
      gsub(/\t/, " ", line)
      gsub(/^ +| +$/, "", line)
      if (line == "" || line !~ / /) next
      v = line; sub(/^.* /, "", v)
      if (v !~ /^-?[0-9]+$/) next          # 读不出数值的行让开，不猜
      if (v + 0 == 0) next                 # 0 = 这一子项通过
      if (v + 0 <  0) { nosup++; next }    # 负数 = 驱动没跑这一项，不是失败
      name = line; sub(/ [^ ]*$/, "", name)
      # 这三个词都是"要有网线、有对端才能过"的子项。mlx5 的 Speed Test
      # 在没有载波时和 Link Test 一样直接返回 1，见上面那段说明。
      if (tolower(name) ~ /link|speed|cable/) link++; else hw++
    }
    END { printf "%d %d %d", hw + 0, link + 0, nosup + 0 }
  ' "$f" 2>/dev/null
}

# nic_selftest_verdict <ethtool -t 的输出文件>
#   -> pass | fail | link_only | nosupport_only | unknown_fail | unsupported
#
#   fail            确实有硬件子项没过
#   link_only       只有网线相关子项没过 = 没插网线，卡本身是好的
#   nosupport_only  没过的全是驱动跑不了的子项 = 能力缺失，不是故障
#   unknown_fail    卡自己说 FAIL，但一条子项明细都拆不出来 —— 拆不开就
#                   **不知道**是网线还是硬件，交给调用方按有没有载波来定
nic_selftest_verdict() {
  local f="${1:-}"
  [[ -s "$f" ]] || { printf 'unsupported'; return; }
  # 先认 FAIL：`The test result is FAIL` 里也有 "test result is"，
  # 顺序反了会把失败读成通过。
  if grep -aqiE 'The test result is[[:space:]]+FAIL' "$f" 2>/dev/null; then
    local hw_bad link_bad nosup
    read -r hw_bad link_bad nosup < <(nic_selftest_subtests "$f")
    [[ "$hw_bad"   =~ ^[0-9]+$ ]] || hw_bad=0
    [[ "$link_bad" =~ ^[0-9]+$ ]] || link_bad=0
    [[ "$nosup"    =~ ^[0-9]+$ ]] || nosup=0
    (( hw_bad   > 0 )) && { printf 'fail'; return; }
    (( link_bad > 0 )) && { printf 'link_only'; return; }
    (( nosup    > 0 )) && { printf 'nosupport_only'; return; }
    printf 'unknown_fail'; return
  fi
  if grep -aqiE 'The test result is[[:space:]]+PASS' "$f" 2>/dev/null; then
    printf 'pass'; return
  fi
  printf 'unsupported'
}

# 这个口现在有没有载波（插没插网线）。读不到一律当"没插"—— 保守的那一边
# 是"不判故障"，正好是二号红线要的方向。
net_iface_has_carrier() {
  [[ "$(cat "/sys/class/net/${1:-}/carrier" 2>/dev/null)" == "1" ]]
}

check_nic_selftest() {
  local ifaces=() ifn
  while read -r ifn; do [[ -n "$ifn" ]] && ifaces+=("$ifn"); done < <(net_phys_ifaces)

  if ! have ethtool || (( ${#ifaces[@]} == 0 )); then
    result_add "check_nic_selftest" "网卡自检" "$ST_SKIP" \
      "未发现物理网口，本项未做核对。此项不影响整机结论。" ""
    return
  fi

  info "Running on-NIC self-test on ${#ifaces[@]} port(s) ..."
  mkdir -p "$RAW_DIR/nic" 2>/dev/null || true

  # ⚠️ 先把口 up 起来再自检。**口是 down 的时候，回环这类自检根本不跑** ——
  # mlx5 直接返回 -EOPNOTSUPP，一整条子项白丢。这里只 up、不等载波
  # （等载波是 net_link_up_all 的事，它在自检之后还会再跑一遍）。
  for ifn in "${ifaces[@]}"; do ip link set "$ifn" up 2>/dev/null || true; done
  sleep 2

  local n_pass=0 n_fail=0 n_unsup=0 n_link=0 n_retest=0
  local bad="" nolink="" retest="" v f
  for ifn in "${ifaces[@]}"; do
    f="$RAW_DIR/nic/${ifn}-selftest.txt"
    # 有的驱动只实现 online 自检；offline 不支持时退一步再试一次。
    # 两次都不行就是这个驱动不提供自检。
    { timeout 90 ethtool -t "$ifn" offline 2>&1 || true; } > "$f"
    if [[ "$(nic_selftest_verdict "$f")" == "unsupported" ]]; then
      { printf '(offline unsupported, retrying online)\n'
        timeout 90 ethtool -t "$ifn" online 2>&1 || true; } >> "$f"
    fi
    v="$(nic_selftest_verdict "$f")"

    # ⚠️⚠️ **最后一道兜底：没插网线的口，不判 FAIL。**
    #
    # 上面已经按子项名字把"网线相关"的挑出去了，但那份名单是按我们见过的
    # 驱动列的 —— 下一个厂家换一个名字（"Cable Test"？"PHY Test"？）
    # 我们又会把一台好机器判成"需更换或返修"。而"没插网线"是工厂里的常态，
    # 误判的代价是拦住一整批出货，漏判的代价只是少查一个没接线的口。
    #
    # 所以：口上没有载波时，把 fail / unknown_fail 一律降级成"要接线复测"。
    # 这不是把结论藏起来 —— 报告里照样写明是哪个口、请接上网线重测一次。
    if [[ "$v" == "fail" || "$v" == "unknown_fail" ]] && ! net_iface_has_carrier "$ifn"; then
      printf '\n(no carrier on this port - verdict not conclusive, see lib/network.sh)\n' >> "$f"
      v="retest"
    fi
    [[ "$v" == "unknown_fail" ]] && v="fail"   # 有载波还说不清，照卡自己的结论走

    case "$v" in
      pass)      n_pass=$(( n_pass + 1 )) ;;
      link_only) n_link=$(( n_link + 1 )); nolink="${nolink}${nolink:+、}${ifn}" ;;
      retest)    n_retest=$(( n_retest + 1 )); retest="${retest}${retest:+、}${ifn}" ;;
      fail)      n_fail=$(( n_fail + 1 )); bad="${bad}${bad:+、}${ifn}" ;;
      *)         n_unsup=$(( n_unsup + 1 )) ;;
    esac
  done

  local extra=""
  (( n_unsup > 0 )) && extra="；另有 ${n_unsup} 个网口的驱动不提供自检功能，不影响整机结论"

  if (( n_fail > 0 )); then
    result_add "check_nic_selftest" "网卡自检" "$ST_FAIL" \
      "${n_fail} 个网口自带的自检未通过（${bad}）。这是网卡自身给出的结论，\
该口已接网线、未通过的也不是依赖网线的检查项，说明该网口存在硬件故障，需更换或返修后复测。" "raw/nic/"
  elif (( n_retest > 0 )); then
    # 卡自己说没过，但那个口没接网线 —— 拆不出是网线还是卡的问题。
    # 判 WARN 不判 FAIL：拦住一整批好机器，比漏查一个没接线的口糟得多。
    result_add "check_nic_selftest" "网卡自检" "$ST_WARN" \
      "${n_retest} 个网口（${retest}）的自检未通过，但这几个口**现场没有接网线**。\
网卡自检里有若干项要靠网线与对端设备才能完成，没接线时必然不通过，\
无法据此判断网卡本身好坏。如需确认，请给这几个口接上网线后重测一次${extra}" "raw/nic/"
  elif (( n_link > 0 )); then
    # 卡上的硬件项全过了，只有依赖网线的那几个子项没过 = 那个口没接网线。
    # 二号红线：现场没接网线不是硬件故障。
    result_add "check_nic_selftest" "网卡自检" "$ST_PASS" \
      "$(( n_pass + n_link )) 个网口的卡上自检项（寄存器 / EEPROM / 中断 / 回环）全部通过，\
未发现硬件故障。其中 ${n_link} 个网口（${nolink}）的「链路 / 协商速率」子项未通过 —— \
这几项查的是网线与对端设备，现场未接网线时必然不通过，与网卡本身好坏无关${extra}" \
      "raw/nic/"
  elif (( n_pass > 0 )); then
    result_add "check_nic_selftest" "网卡自检" "$ST_PASS" \
      "${n_pass} 个网口自带的自检全部通过（由网卡自身完成并给出结论，不依赖网线与对端设备）${extra}" \
      "raw/nic/"
  else
    result_add "check_nic_selftest" "网卡自检" "$ST_SKIP" \
      "本机网口的驱动不提供自检功能，本项未做核对。此项不影响整机结论。" "raw/nic/"
  fi
}

check_nic_speed() {
  info "Checking NIC negotiated link speed ..."

  local ifaces=() ifn
  while read -r ifn; do [[ -n "$ifn" ]] && ifaces+=("$ifn"); done < <(net_phys_ifaces)

  if (( ${#ifaces[@]} == 0 )); then
    result_add "check_nic_speed" "网卡协商速率" "$ST_SKIP" "未发现物理网口" ""
    return
  fi

  local checked=0 slow=() f cur max
  for ifn in "${ifaces[@]}"; do
    f="$RAW_DIR/nic/${ifn}-ethtool.txt"
    [[ -f "$f" ]] || continue
    # 没接网线的口不参与判定
    grep -qE '^[[:space:]]*Link detected:[[:space:]]*yes' "$f" 2>/dev/null || continue

    max="$(nic_supported_max_mbps "$f")"
    cur="$(nic_current_mbps "$f")"
    [[ "$max" =~ ^[0-9]+$ ]] || max=0
    [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
    # 两个数任一读不到就整条让开——读不到数据绝不能当成故障
    (( max > 0 && cur > 0 )) || continue

    checked=$((checked+1))
    metric_add "nic" "${ifn} 协商速率Mb/s" "$cur"
    if (( cur < max )); then
      slow+=("${ifn}：实际 ${cur}Mb/s，额定 ${max}Mb/s")
    fi
  done

  if (( checked == 0 )); then
    result_add "check_nic_speed" "网卡协商速率" "$ST_SKIP" \
      "现场没有接网线的网口（或网卡未上报协商速率），无法核对协商速率" "raw/nic-summary.txt"
  elif (( ${#slow[@]} > 0 )); then
    result_add "check_nic_speed" "网卡协商速率" "$ST_WARN" \
      "$(printf '%s；' "${slow[@]}")共核对 ${checked} 个已接网线的网口。\
协商速率没跑到网卡额定值，常见原因：网线规格不够（万兆要 Cat6A 以上）、光模块型号不匹配、\
对端交换机口速率不够或被锁死。注意这只反映本次接入的对端条件，不一定是网卡本身的问题。" \
      "raw/nic-summary.txt"
  else
    result_add "check_nic_speed" "网卡协商速率" "$ST_PASS" \
      "${checked} 个已接网线的网口均协商到网卡额定速率" "raw/nic-summary.txt"
  fi
}

# ---------------------------------------------------------------- 主流程
net_test() {
  info "Testing NIC connectivity (DHCP + ping gateway) ..."
  mkdir -p "$RAW_DIR/nic"
  : > "$RAW_DIR/nic-test.txt"

  local ifaces=()
  local ifn
  while read -r ifn; do [[ -n "$ifn" ]] && ifaces+=("$ifn"); done < <(net_phys_ifaces)

  if (( ${#ifaces[@]} == 0 )); then
    result_add "test_nic" "网卡连通性" "$ST_SKIP" "未发现物理网口" ""
    return
  fi

  local linked=0 okcnt=0
  local problems=() nolink=()

  for ifn in "${ifaces[@]}"; do
    local carrier res ip4 gw ping_txt tx rx avg
    res=""; ip4=""; gw=""; ping_txt=""

    carrier="$(cat "/sys/class/net/$ifn/carrier" 2>/dev/null || echo 0)"
    if [[ "$carrier" != "1" ]]; then
      res="NO_LINK"
      nolink+=("$ifn")
    else
      linked=$((linked+1))
      if net_dhcp "$ifn"; then
        ip4="$(net_parse_addr "$(ip -4 -o addr show dev "$ifn" 2>/dev/null)")"
        gw="$(net_parse_gateway "$(ip -4 route show default dev "$ifn" 2>/dev/null)")"
        # 有些 DHCP 只给地址不给默认路由，再从该口的普通路由里找一次
        [[ -n "$gw" ]] || gw="$(net_parse_gateway "$(ip -4 route show dev "$ifn" 2>/dev/null)")"

        # 自己编的 169.254 地址不算拿到租约，见 net_addr_is_linklocal
        net_addr_is_linklocal "${ip4%%/*}" && ip4=""

        if [[ -z "$ip4" ]]; then
          res="NO_DHCP"
        elif [[ -z "$gw" ]]; then
          res="NO_GATEWAY"
        else
          capture "nic/${ifn}-ping.txt" \
            ping -c "$NET_PING_COUNT" -W 2 -I "$ifn" "$gw"
          read -r tx rx avg < <(net_parse_ping "$RAW_DIR/nic/${ifn}-ping.txt")
          if [[ "$rx" =~ ^[0-9]+$ ]] && (( rx > 0 )); then
            res="OK"
            okcnt=$((okcnt+1))
            ping_txt="${rx}/${tx} 通，平均 ${avg}ms"
          else
            res="PING_FAIL"
            ping_txt="0/${tx} 通"
          fi
        fi
      else
        local rc=$?
        (( rc == 127 )) && res="NO_CLIENT" || res="NO_DHCP"
      fi
      net_release "$ifn"
    fi

    [[ "$res" == "OK" || "$res" == "NO_LINK" ]] || problems+=("${ifn}: $(net_result_text "$res")")

    # 报告生成器读这个文件补齐网卡表格的后三列
    {
      printf 'Interface : %s\n' "$ifn"
      printf 'Carrier   : %s\n' "$([[ "$carrier" == "1" ]] && echo yes || echo no)"
      printf 'IPv4      : %s\n' "${ip4:--}"
      printf 'Gateway   : %s\n' "${gw:--}"
      printf 'Ping      : %s\n' "${ping_txt:--}"
      printf 'Result    : %s\n' "$res"
    } > "$RAW_DIR/nic/${ifn}-test.txt"
    cat "$RAW_DIR/nic/${ifn}-test.txt" >> "$RAW_DIR/nic-test.txt"
    printf '\n' >> "$RAW_DIR/nic-test.txt"

    info "  $ifn: $res${ip4:+  ip=$ip4}${gw:+  gw=$gw}"
  done

  local total="${#ifaces[@]}"
  local nolink_txt=""
  (( ${#nolink[@]} > 0 )) && nolink_txt="；未接网线 ${#nolink[@]} 个（${nolink[*]}）"

  if (( ${#problems[@]} > 0 )); then
    result_add "test_nic" "网卡连通性" "$ST_WARN" \
      "$(printf '%s；' "${problems[@]}")共 ${total} 个网口，${okcnt} 个 ping 通网关${nolink_txt}" \
      "raw/nic-test.txt"
  elif (( linked == 0 )); then
    # 一根网线都没接是出厂测试的常态，不算不合格
    result_add "test_nic" "网卡连通性" "$ST_SKIP" \
      "共 ${total} 个网口，现场均未接网线，未做连通性测试（型号/固件已采集）" "raw/nic-test.txt"
  else
    result_add "test_nic" "网卡连通性" "$ST_PASS" \
      "共 ${total} 个网口，已接网线的 ${linked} 个全部取得 DHCP 地址并 ping 通网关${nolink_txt}" \
      "raw/nic-test.txt"
  fi
}
