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
    NO_CLIENT)   printf '未测试（盘内缺少 DHCP 客户端）' ;;
    *)           printf '未测试' ;;
  esac
}

# ================================================================
# 硬件操作
# ================================================================

# 物理网口列表（跳过 lo 和 bond/vlan/veth 之类没有 device 节点的虚拟口）
net_phys_ifaces() {
  local n ifn
  for n in /sys/class/net/*; do
    [[ -e "$n" ]] || continue
    ifn="$(basename "$n")"
    [[ "$ifn" == "lo" ]] && continue
    [[ -e "$n/device" ]] || continue
    printf '%s\n' "$ifn"
  done
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

# DHCP 取地址。返回 0 = 拿到，127 = 盘内没有 DHCP 客户端
#
# ${RAW_DIR:-/tmp} 是因为联网校时（try_sync_clock_via_network）在 RUN_DIR
# 建立之前就要用这个函数——那时候 $RAW_DIR 还没定义，日志就先落 /tmp，
# 不影响功能，只是这几行 dhclient 输出不会进最终报告目录。
net_dhcp() {
  local ifn="$1" log="${RAW_DIR:-/tmp}/nic/${ifn}-dhcp.log"
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
# 不少送来测试的机器是库存/二手件，主板纽扣电池已经没电，BIOS RTC 会回退到
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
sync_clock_now() {
  have chronyd || return 1
  local cfg="" srv
  for srv in "${NET_TIME_SERVERS[@]}"; do
    cfg+="server $srv iburst maxsamples 1
"
  done
  timeout "$NET_TIME_SYNC_TIMEOUT" chronyd -q "$cfg" >/dev/null 2>&1
}

try_sync_clock_via_network() {
  local ifn total=0
  while read -r ifn; do [[ -n "$ifn" ]] && total=$((total+1)); done < <(net_phys_ifaces)
  if (( total == 0 )); then
    dbg "clock sync: no physical NIC, skip"
    return 1
  fi

  info "Checking for network access to sync the clock (best-effort) ..."
  net_link_up_all

  local synced=0
  while read -r ifn; do
    [[ -n "$ifn" ]] || continue
    [[ "$(cat "/sys/class/net/$ifn/carrier" 2>/dev/null)" == "1" ]] || continue

    if net_dhcp "$ifn" && sync_clock_now; then
      synced=1
    fi
    net_release "$ifn"
    (( synced )) && break
  done < <(net_phys_ifaces)

  if (( synced )); then
    ok "System clock synced via network: $(date '+%Y-%m-%d %H:%M %Z')"
  else
    warn "No network time source reached - keeping BIOS/RTC clock as-is."
  fi
  return $(( synced ? 0 : 1 ))
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
