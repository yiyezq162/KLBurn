#!/usr/bin/env bash
# KLBurn 性能基准（performance baseline）
#
# 和 lib/stress.sh 的分工，一句话说清：
#
#   压测（stress.sh）    机器**扛不扛得住**满载 —— 跑很久，看有没有报错/超温
#   基准（本文件）        机器**跑得有多快** —— 跑几十秒，量一个数字出来
#
# 各家验收要看的那些数（带宽 GB/s、算力 GFlops、读写 MB/s）全都属于后者：
# 它们是**性能数值**，不是"有没有出错"，所以必须在机器空闲时测 ——
# 和满载压测同时跑，量出来的数字没有任何意义。
# 因此基准阶段排在老化压测**之前**单独跑（factory-test.sh 的 PHASE 2/5）。
#
# ================================================================
# 两条定性，改之前先读：
#
# 1. **这里只量数，不判合格。**
#
#    ⚠️⚠️ **本文件里不许出现任何"门槛/阈值/参考值/预期值"。**
#
#    这张盘是插上就跑、无人值守的：现场没有人、也没有地方去填"这台机器的带宽
#    应该是多少"。凭空写一个数进来，等于我们替客户定了一个他没定过的标准，
#    然后拿它去判一台机器合不合格 —— 那个数字从哪来的谁也说不清。
#
#    各家的验收要求不一样，同一个数字换个机型可能高得离谱也可能低得可笑。
#    **谁做验收，谁拿自己的标准去对我们报出来的实测值。**
#    我们的责任到"把数量准、写清楚"为止。
#
#    所以这几项的状态只有两种：
#      量到了   -> PASS，文案里就是那个实测值
#      量不到   -> SKIP（没带程序 / 没有显卡 / 程序没返回有效结果）
#    **没有 WARN，也没有 FAIL。**整机结论只回答"硬件有没有毛病"，
#    而性能数字回答不了这个问题 —— 真正的硬件原因（PCIe 掉到 x8、内存只插了
#    半通道）另有专门的判定去抓（check_pcie_link / check_dimm_uniform）。
#
# 2. **没带基准程序 = SKIP，永远不是 FAIL。**
#    bandwidthTest / xlinpack_xeon64 / mlc 这几个都是第三方发布的二进制，
#    不在 Ubuntu 源里，要构建时手工放进 vendor/bench/。没放就是**我们这张盘**
#    的能力缺口，跟被测机器好不好毫无关系（README 的一号红线）。
#
# 判读逻辑一律抽成纯函数（只吃文件路径、只吐字符串），
# 好拿真实日志脱机回归，见 tests/test-log-parsing.sh。
# ================================================================

BENCH_LOG_DIR=""

bench_init() {
  BENCH_LOG_DIR="$RAW_DIR/bench"
  mkdir -p "$BENCH_LOG_DIR"
}

# ---------------------------------------------------------------- 找基准程序
# bench_tool <候选名...> -> 打印可执行文件的完整路径；一个都没有返回 1
#
# 搜索顺序：
#   1. /opt/klburn/tools/bench/<任意子目录>/<名字>
#      —— 构建时把 vendor/bench/<子目录>/ 整个铺进来，因为有的程序要带自己的
#         .so（xlinpack_xeon64 要 libiomp5.so）和数据文件，只捞一个可执行文件
#         出来是跑不起来的
#   2. /opt/klburn/tools/<名字>
#   3. PATH
bench_tool() {
  local name p
  for name in "$@"; do
    for p in "$KLB_TOOLS"/bench/*/"$name" "$KLB_TOOLS/$name"; do
      [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    if have "$name"; then command -v "$name"; return 0; fi
  done
  return 1
}

# bench_run <日志文件> <可执行文件> [参数...]
#
# 带上程序自己那个目录的 LD_LIBRARY_PATH 再执行：有的基准程序依赖同目录下的
# 运行库，不设这个变量的话是 "error while loading shared libraries" ——
# 而那个报错落在日志里，看着像"这台机器有问题"。
#
# ⚠️ **超时必须卡得比"现场愿意等的时间"短。**
#
# 一开始这里给的是 1800 秒。1.9.0 实测在 QEMU 里踩到：内存带宽那一步挂住之后，
# 整轮测试硬生生停在那儿 —— 采集做完了、算力也测完了，就是出不了报告。
# 一个插上就跑、无人值守的工具，**绝不能因为一项基准卡住而拖垮整台机器的产出**。
# 基准程序本来就是"几十秒量一个数"的东西，跑到五分钟就已经不正常了。
#
# 超时之后**日志照常解析**：被 kill 之前已经打出来的数还在，能捞到就捞
# （内存带宽那次就是 ALL Reads 已经打完了才挂的）；捞不到就干净地 SKIP。
bench_run() {
  local log="$1" exe="$2"; shift 2
  local dir; dir="$(dirname "$exe")"
  dbg "bench_run: $exe $*"
  ( cd "$dir" && LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" \
      timeout --kill-after=20s "${BENCH_TIMEOUT:-300}" "$exe" "$@" ) \
    > "$log" 2>&1
}
#
# bench_run_numa <NUMA 节点或空> <日志文件> <可执行文件> [参数...]
#
# 主机到显卡的带宽受锁页内存所在 NUMA 节点影响。能从 PCIe sysfs 读到显卡
# 所在节点时，把测试进程和主机缓冲区绑到同一节点；读不到拓扑时退回普通
# bench_run。这里改变的是内存放置，不是读数或判定口径。
bench_run_numa() {
  local node="$1" log="$2" exe="$3"; shift 3
  if [[ "$node" =~ ^[0-9]+$ ]] && have numactl; then
    local dir; dir="$(dirname "$exe")"
    dbg "bench_run: $exe (NUMA node $node) $*"
    ( cd "$dir" && LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" \
        timeout --kill-after=20s "${BENCH_TIMEOUT:-300}" \
        numactl --cpunodebind="$node" --membind="$node" "$exe" "$@" ) \
      > "$log" 2>&1
  else
    bench_run "$log" "$exe" "$@"
  fi
}

# mlc_buffer_kib —— 给 MLC 算一个**安全的**每线程缓冲区大小（KiB）。
#
# ⚠️ **必须显式给 `-b`，不能让 MLC 自己挑。**
#
# 1.9.0 实测：一台 4GB 内存、4 线程的机器上，MLC 自己挑了
#     Using buffer size of 732.422MiB/thread for reads and an additional 732.422MiB/thread
# 也就是 732 × 4 × 2 ≈ **5.8GB**，而整机只有 4GB —— 打完第一行 ALL Reads
# 就开始抖，整轮测试卡在那儿再也没出来。
#
# 它挑多大是按缓存/平台推的，和这台机器还剩多少内存没关系，所以只能我们来定：
# 总占用（线程数 × 2 × 本值）压在可用内存的四分之一以内。
# 下限 64MiB —— 缓冲区必须明显大于最后一级缓存，否则量到的是缓存不是内存；
# 上限 512MiB —— 再大对结果没有帮助，只是多占内存。
# 两个参数只为脱机回归用（tests/test-log-parsing.sh），现场不传、自己去读。
mlc_buffer_kib() {
  local avail="${1:-}" threads="${2:-}"
  [[ "$avail" =~ ^[0-9]+$ ]] || \
    avail="$(awk '/MemAvailable/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$avail" =~ ^[0-9]+$ ]] || avail=2097152          # 读不到就当 2GB，保守
  [[ "$threads" =~ ^[0-9]+$ ]] || threads="$(nproc 2>/dev/null)"
  [[ "$threads" =~ ^[0-9]+$ ]] && (( threads > 0 )) || threads=4
  awk -v a="$avail" -v t="$threads" 'BEGIN{
    b = int(a * 0.25 / (t * 2))
    if (b < 65536)  b = 65536
    if (b > 524288) b = 524288
    printf "%d", b
  }'
}

# ---------------------------------------------------------------- 数值比较
# 带宽/算力全是浮点（55.6 GB/s、3712.1 GFlops），bash 的 (( )) 只会整数，
# 一律用 awk 比。**别改回 (( ))** —— 整数截断会让 54.9 和 54.1 变成同一个数，
# 逐卡取最低值时就会挑错卡。
#
# num_ge <甲> <乙> -> 甲 >= 乙 返回 0。只用来在多张卡之间挑最低的那个读数，
# **不用来判合格**（本文件里没有合格线，见文件头第 1 条）。
num_ge() {
  awk -v a="${1:-}" -v b="${2:-}" '
    BEGIN {
      if (a !~ /^-?[0-9.]+$/ || b !~ /^-?[0-9.]+$/) exit 2
      exit (a + 0 >= b + 0) ? 0 : 1
    }'
}

# num_fmt <数值> [小数位] -> 规整成人能看的写法；不是数字就原样输出
num_fmt() {
  awk -v v="${1:-}" -v d="${2:-1}" '
    BEGIN { if (v ~ /^-?[0-9.]+$/) printf "%.*f", d, v+0; else printf "%s", v }'
}

# bench_report <id> <显示名> <实测值> <单位> <这一项测的是什么> [证据文件]
#
# 五个基准项共用的出口：**只报实测值，不下合格与否的结论**（见文件头第 1 条）。
# 统一在一处，免得五处各写一遍再各自跑偏 —— 措辞跑偏比逻辑跑偏更难发现。
bench_report() {
  local id="$1" name="$2" got="$3" unit="$4" what="$5" ref="${6:-}"
  result_add "$id" "$name" "$ST_PASS" \
    "${what}实测 $(num_fmt "$got") ${unit}。" "$ref"
}

# 统一的"没带这个程序"文案。**不许出现程序名**（§6-2：盘里带了什么工具是内部实现）。
#
# origin=self：这是**我们这张盘**的能力缺口，跟被测机器毫无关系，
# 所以这一行不进交付报告（留在 results.jsonl 和内部报告里）。见 core.sh 的 result_add。
bench_skip_no_tool() {
  result_add "$1" "$2" "$ST_SKIP" \
    "本次测试环境未包含${3}基准测试程序，本项未做测试。此项不影响整机结论。" "" "self"
}

# 同上，另一半："程序带了，但这一轮没给出有效结果"。
# 原因可能是参数不合、平台不支持（Intel 的 LINPACK 在非 Intel CPU 上直接罢工）、
# 被超时打断 —— 每一种都是我们这边的事，同样不该印给客户看。
bench_skip_no_result() {
  result_add "$1" "$2" "$ST_SKIP" \
    "本次未能测得${3}（测试程序未返回有效结果）。此项不影响整机结论。" "${4:-}" "self"
}

# ================================================================
# 显卡：主机与显卡之间、以及显卡内部的数据传输带宽
# ================================================================
#
# ⚠️⚠️ **绝不能用 bandwidthTest 的 `--mode=quick`（32MB）去量显存带宽。**
#
# 1.9.3 真机踩到：一台 RTX 4090 的「显存内部带宽」报出 **3622.7 GB/s**，
# 而这张卡标称的显存带宽是 1008 GB/s —— 报出来的数是标称值的三倍半。
# 两个原因叠在一起：
#
#   1. **32MB 装得进显卡的末级缓存。** AD102（4090）有 72MB L2，
#      源、目标两块缓冲区加起来 64MB，整个拷贝根本没碰到 GDDR ——
#      量到的是 L2 带宽，不是显存带宽。
#   2. bandwidthTest 的 D2D 那一格算的是 `2 × 块大小 / 用时`：一次拷贝
#      要读一遍、写一遍，它报的是**读写合计的显存流量**。这个口径本身没错
#      （显卡标称的显存带宽就是总线峰值，同样是读写合计），
#      但前提是这些流量真的走到了显存上。
#
# ⚠️⚠️ **而"块开大一点就行了"是靠不住的。**
#
# 第一版这里钉的是"256MiB 起、512MiB 封顶，因为目前最大的显卡末级缓存是
# Blackwell 的 126MB"。那是拿**今天的卡**去赌明天的卡，赌输了不会报错 ——
# 只会再印一个高得离谱的数出去，和 1.9.3 一模一样。
# 而且 AMD 那边已经有 256MB 的 Infinity Cache 了（MI300X），
# NVIDIA 下一代堆到 256MB 以上完全不需要什么想象力。
#
# 所以块大小不是判据，**曲线压没压平才是**：
# 同一张卡量两个块大小（S 和 2S）。缓存放得下的时候小块必然明显更快；
# 两个数贴在一起，才说明流量真的落到显存上了。
# 压不平就**这一项不出数**（见 bench_gpu_bandwidth 里的 d2d_trustworthy）——
# 宁可不报，也不能报一个比标称值高几倍的数。
# 这条判据不看卡的型号、不看缓存多大，以后出什么卡都成立。

# gpu_bw_bytes <显存MiB> [可用主机内存KiB] -> H2D/D2H 用多大的块（字节）
#
# 这两个方向的瓶颈是 PCIe 链路，32MB 就已经跑到平台期了，块大小几乎不影响结果。
# 这里唯一要当心的是**锁页主机内存**：申请不下来的话整个 bandwidthTest 直接失败，
# 连带 H2D/D2H 一起没有。所以压在可用内存的八分之一以内，并且封顶 256MiB。
# 两个参数只为脱机回归用（tests/test-log-parsing.sh），现场不传、自己去读。
gpu_bw_bytes() {
  local vram_mib="${1:-}" avail_kib="${2:-}"
  [[ "$vram_mib" =~ ^[0-9]+$ ]] || vram_mib=0
  [[ "$avail_kib" =~ ^[0-9]+$ ]] || \
    avail_kib="$(awk '/MemAvailable/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$avail_kib" =~ ^[0-9]+$ ]] || avail_kib=0
  awk -v vm="$vram_mib" -v ak="$avail_kib" 'BEGIN{
    MiB = 1048576
    s = 256 * MiB
    if (ak > 0 && s > ak * 1024 * 0.125) s = ak * 1024 * 0.125   # 锁页主机内存
    if (vm > 0 && s > vm * MiB * 0.25)   s = vm * MiB * 0.25     # 显存那一头
    if (s < 32 * MiB) s = 32 * MiB               # 兜底：quick 档就是 32MB，够用
    printf "%d", int(s / MiB) * MiB              # 取整到 MiB，日志好认
  }'
}

# gpu_d2d_bytes <显存MiB> -> "<小块> <大块>"（字节）；显存太小给不出就打印空
#
# **只受显存约束**，和主机内存无关 —— D2D 的两块缓冲区都在显卡上。
# 第一版把这两件事混在一个尺寸里算，于是一台可用内存紧张的机器会把块压小，
# 把好不容易避开的缓存又踩回去，而且**一声不响**。分开算就没有这条暗路。
#
# 大块取显存的八分之一（D2D 要两块，合起来占到显存四分之一为止）、**封顶 1GiB**；
# 小块正好是大块的一半 —— 两个点就够判断曲线压没压平了。
#
# ⚠️⚠️ **封顶绝不能到 2GiB，那正好踩爆 bandwidthTest 的 32 位参数解析。**
#
# 1.9.4~1.9.8 这里写的是 `2048 * MiB` = 2147483648 = 2^31 —— 恰好比
# 32 位有符号整数的上限（2147483647）大 1。CUDA Samples 的 bandwidthTest
# 用 `getCmdLineArgumentInt()` 读 --start/--end/--increment，返回的是 **int**，
# 传进去直接溢出成负数，程序打一行
#     Illegal argument - end must be greater than zero
#     Result = FAIL
# 就退出了。后果是**每一张 16GiB 以上显存的卡（也就是所有正经的卡）
# 显存读写带宽这一项永远测不到**，报告里恒定是
# 「本次未能测得显存的读写带宽（测试程序未返回有效结果）」——
# 而现场看到的是日志里一行红色的 `Result = FAIL`。
# 1.9.7 的现场数据里 RTX 4090（24G）和 RTX A6000（48G）两台**全中**。
#
# 这也是一次"能力缺失被写成机器读不出来"的教训：判定文案说的是
# "测试程序未返回有效结果"，听起来像卡的问题，实际是我们自己传错了参数。
#
# 1GiB 的块 = 2GiB 的工作集，仍然是目前**所有**显卡末级缓存
# （最大的是 AMD MI300X 的 256MB）的八倍，判"曲线压没压平"绰绰有余；
# 而 1073741824 离 2^31 还有整整一倍的余量，再也踩不到那条线。
gpu_d2d_bytes() {
  local vram_mib="${1:-}"
  [[ "$vram_mib" =~ ^[0-9]+$ ]] || return 0
  (( vram_mib > 0 )) || return 0
  awk -v vm="$vram_mib" 'BEGIN{
    MiB = 1048576
    big = vm * MiB * 0.125
    if (big > 1024 * MiB) big = 1024 * MiB       # 见上面：绝不能到 2GiB
    big = int(big / (128 * MiB)) * 128 * MiB     # 取整到 128MiB，日志好认
    # 小块要留得住意义：再小就和 quick 档没区别，两点比对也就失去了分辨力
    if (big < 128 * MiB) exit 0
    printf "%d %d", big / 2, big
  }'
}

# gpu_vram_mib <卡号> -> 这张卡的显存容量（MiB）；读不到打印空
gpu_vram_mib() {
  local idx="${1:-0}" v
  v="$(timeout 30 nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
       -i "$idx" 2>/dev/null | tr -d ' \r')"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
}

# gpu_numa_node <卡号> -> PCIe 所在 NUMA 节点；读不到时空
#
# 只用于主机↔显卡传输基准的内存放置。跨 NUMA 节点的锁页内存会让 D2H
# 读数显著低于同一张卡的 H2D；绑定到 PCIe 根端所在节点能减少这个额外
# 的系统拓扑干扰，但不会改变带宽计算或筛选口径。
gpu_numa_node() {
  local idx="${1:-0}" bus node
  bus="$(timeout 30 nvidia-smi --query-gpu=pci.bus_id \
         --format=csv,noheader,nounits -i "$idx" 2>/dev/null \
         | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  # nvidia-smi prints an eight-digit domain (00000000:27:00.0), while sysfs
  # names the same PCI function with a four-digit domain (0000:27:00.0).
  [[ "$bus" =~ ^[0-9a-f]{8}: ]] && bus="0000:${bus#*:}"
  [[ "$bus" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] || return 0
  node="$(cat "/sys/bus/pci/devices/$bus/numa_node" 2>/dev/null || true)"
  [[ "$node" =~ ^[0-9]+$ ]] && printf '%s' "$node"
}

# bw_parse_d2d_curve <日志> -> "<最小块的带宽> <最大块的带宽>"，GB/s；读不到打印空
#
# 专给上面那条"曲线压没压平"的判据用，所以**必须按传输块大小取**，
# 不能像 bw_parse_bandwidthtest 那样取最大值 —— 取最大值的话，
# 挑中的正好是被缓存喂出来的那个小块，等于这道判据白做。
#
# 数据行长这样（第一个数是块大小，最后一个数是带宽）：
#     268435456			3622.7
bw_parse_d2d_curve() {
  local log="${1:-}"
  [[ -f "$log" ]] || return 0
  awk '
    /Device to Device Bandwidth/ { ind = 1; next }
    /Host to Device Bandwidth/   { ind = 0; next }
    /Device to Host Bandwidth/   { ind = 0; next }
    /Bandwidth\(MB\/s\)/         { div = 1000; next }
    /Bandwidth\(GB\/s\)/         { div = 1;    next }
    ind && div != "" {
      if ($1 !~ /^[0-9]+$/) next
      v = ""
      for (i = NF; i >= 2; i--) if ($i ~ /^[0-9]+\.?[0-9]*$/) { v = $i; break }
      if (v == "") next
      sz = $1 + 0; bw = v / div
      if (lo == "" || sz < lo) { lo = sz; lobw = bw }
      if (hi == "" || sz > hi) { hi = sz; hibw = bw }
    }
    END { if (hi != "") printf "%.2f %.2f", lobw, hibw }
  ' "$log" 2>/dev/null
}

# bw_parse_bandwidthtest <日志> -> "<H2D> <D2H> <D2D>"，单位 GB/s，缺的给 0
#
# ⚠️ 单位随版本变：老版本表头是 Bandwidth(MB/s)，新版本是 Bandwidth(GB/s)。
#    照数字抄就会在报告上印出一个 55000 GB/s 的荒唐数字（或者反过来小一千倍）。
#    所以必须跟着**当前小节的表头**换算，不能全局假定一个单位。
bw_parse_bandwidthtest() {
  local log="${1:-}"
  # ⚠️ 格式必须和 awk 那条出口**一模一样**（两位小数）。调用方是拿
  #    `[[ "$h2d" == "0.00" ]]` 判"一个方向都没测出来"的 —— 这里给 "0"
  #    的话那个判断永远不成立，于是日志根本不存在时反而报出一条
  #    "实测 0 GB/s" 的 PASS。
  [[ -f "$log" ]] || { printf '0.00 0.00 0.00'; return; }
  awk '
    /Host to Device Bandwidth/   { sec = "h2d"; next }
    /Device to Host Bandwidth/   { sec = "d2h"; next }
    /Device to Device Bandwidth/ { sec = "d2d"; next }
    /Bandwidth\(MB\/s\)/         { div = 1000; next }
    /Bandwidth\(GB\/s\)/         { div = 1;    next }
    sec != "" && div != "" {
      # 数据行长这样： "   32000000			55.6"
      # 取**最后一个**浮点数当带宽（第一个是传输块大小）
      v = ""
      for (i = NF; i >= 1; i--) if ($i ~ /^[0-9]+\.?[0-9]*$/) { v = $i; break }
      if (v == "" || NF < 2) next
      g = v / div
      if (g > best[sec]) best[sec] = g
    }
    END { printf "%.2f %.2f %.2f", best["h2d"]+0, best["d2h"]+0, best["d2d"]+0 }
  ' "$log" 2>/dev/null
}

bench_gpu_bandwidth() {
  (( ${GPU_USABLE:-0} > 0 )) || return 0
  local exe
  if ! exe="$(bench_tool bandwidthTest)"; then
    bench_skip_no_tool "bench_gpu_bw" "显卡数据传输带宽" "显卡数据传输"
    return 0
  fi

  info "[BENCH] GPU host/device transfer bandwidth on $GPU_USABLE card(s) ..."
  # 这一段会把每张卡的 PCIe 链路真跑满 —— 登记一下，好让 check_pcie_link
  # 知道它读到的速率不是空闲读数（见 collect.sh 里 PCIE_LOADED_BDFS 那段）。
  pcie_mark_gpus_loaded
  local log="$BENCH_LOG_DIR/gpu-bandwidth.log"
  : > "$log"
  # 不一样（有的给一行合计，有的逐卡分块），解析口径不稳；二是验收要的是
  # 逐卡的数才有意义，把八张卡混成一个数字的话，一张慢卡会被另外七张平均掉。
  #
  # **H2D/D2H 和 D2D 分两次跑**，因为约束完全不同：
  #   H2D/D2H  受**主机锁页内存**限制，块大小对结果几乎没有影响（瓶颈在 PCIe）
  #   D2D      受**显存**限制，块大小直接决定量到的是显存还是显卡缓存
  # d2d_ok：这一轮的显存数**可不可信**。只要有一张卡判不出可信，
  # 显存那一项整项就不报 —— 宁可不报，也不能报一个比标称值高几倍的数出去。
  local idx h2d d2h d2d mh="" md="" mdd="" d2d_ok=1
  for (( idx = 0; idx < GPU_USABLE; idx++ )); do
    local one="$BENCH_LOG_DIR/gpu-bandwidth-${idx}.log"
    local vram; vram="$(gpu_vram_mib "$idx")"
    local numa; numa="$(gpu_numa_node "$idx")"
    local bytes; bytes="$(gpu_bw_bytes "$vram")"
    dbg "gpu $idx host<->device transfer size: $bytes bytes"
    # --mode=range 三个参数取同一个值 = 只跑这一个块大小（--increment 不能是 0，
    # 它是 for 循环的步进，给 0 就是死循环）。
    bench_run_numa "$numa" "$one" "$exe" "--device=$idx" --memory=pinned \
      --mode=range "--start=$bytes" "--end=$bytes" --increment=1 \
      --htod --dtoh || true
    read -r h2d d2h _ < <(bw_parse_bandwidthtest "$one")
    if [[ "$h2d" == "0.00" && "$d2h" == "0.00" ]]; then
      # 这个版本的 bandwidthTest 不认上面那组参数，或者锁页内存申请不下来。
      # 退回快速档 —— 这两个方向的瓶颈是 PCIe 链路，32MB 已经跑到平台期，
      # 块大小对它们没有影响，退回去不损失准确性。
      dbg "gpu $idx: range mode gave nothing for h2d/d2h, falling back to quick"
      bench_run_numa "$numa" "$one" "$exe" "--device=$idx" --memory=pinned --mode=quick \
        --htod --dtoh || true
      read -r h2d d2h _ < <(bw_parse_bandwidthtest "$one")
    fi
    { printf '===== GPU %d  host<->device (transfer size %s bytes) =====\n' "$idx" "$bytes"
      cat "$one"; printf '\n'; } >> "$log"

    # ---- 显存内部 ----
    # 两个块大小各量一次，靠"曲线压没压平"判这个数可不可信（见文件上面那段）。
    d2d="0.00"
    # ⚠️ 这几个纯函数都是 `printf` 不带换行的（全项目统一），所以
    #    **不能拿 `read` 的退出码当判据** —— 它读到了内容照样因为 EOF 返回 1。
    #    先整串接下来，再看串是不是空的。
    local sizes dsmall dbig ddlog="$BENCH_LOG_DIR/gpu-bandwidth-${idx}-d2d.log"
    sizes="$(gpu_d2d_bytes "$vram")"
    if [[ -n "$sizes" ]]; then
      read -r dsmall dbig <<<"$sizes"
      dbg "gpu $idx d2d transfer sizes: $dsmall / $dbig bytes"
      bench_run "$ddlog" "$exe" "--device=$idx" --memory=pinned \
        --mode=range "--start=$dsmall" "--end=$dbig" "--increment=$dsmall" --dtod || true
      { printf '===== GPU %d  device<->device (transfer sizes %s / %s bytes) =====\n' \
          "$idx" "$dsmall" "$dbig"; cat "$ddlog"; printf '\n'; } >> "$log"
      local curve lobw hibw
      curve="$(bw_parse_d2d_curve "$ddlog")"
      if [[ -n "$curve" ]]; then
        read -r lobw hibw <<<"$curve"
        # ⚠️ 这**不是合格线**（本文件里没有合格线，见文件头第 1 条）。
        #    它判的是"这个读数本身算不算数"，和"程序没返回有效结果"同一类：
        #    块加倍之后带宽掉了一大截 = 小块那次是显卡缓存在帮忙，
        #    说明连大块都还没完全跳出缓存，这张卡的数不能用。
        #    真的落到显存上时，两个块大小的读数只差百分之几。
        if num_ge "$hibw" "$(awk -v v="$lobw" 'BEGIN{printf "%.4f", v * 0.9}')"; then
          d2d="$hibw"
        else
          dbg "gpu $idx: d2d curve not flat ($lobw -> $hibw), still cache-resident; dropping"
          d2d_ok=0
        fi
      else
        d2d_ok=0
      fi
    else
      dbg "gpu $idx: vram too small (${vram:-?} MiB) for a cache-proof d2d buffer"
      d2d_ok=0
    fi

    [[ "$h2d" == "0.00" && "$d2h" == "0.00" && "$d2d" == "0.00" ]] && continue
    if [[ -z "$mh"  ]] || num_ge "$h2d" "$mh";  then mh="$h2d";  fi
    if [[ -z "$md"  ]] || num_ge "$d2h" "$md";  then md="$d2h";  fi
    if [[ "$d2d" != "0.00" ]] && { [[ -z "$mdd" ]] || num_ge "$d2d" "$mdd"; }; then
      mdd="$d2d"
    fi
  done
  h2d="${mh:-0.00}"; d2h="${md:-0.00}"; d2d="${mdd:-0.00}"
  [[ "$d2d" == "0.00" ]] && d2d_ok=0

  if [[ "$h2d" == "0.00" && "$d2h" == "0.00" && "$d2d" == "0.00" ]]; then
    bench_skip_no_result "bench_gpu_bw" "显卡数据传输带宽" "显卡的数据传输带宽" \
      "raw/bench/gpu-bandwidth.log"
    return 0
  fi

  metric_add "bench" "主机到显卡带宽（GB/s，取最高的一张卡）" "$h2d"
  metric_add "bench" "显卡到主机带宽（GB/s，取最高的一张卡）" "$d2h"
  (( d2d_ok == 1 )) && metric_add "bench" "显存读写带宽（GB/s，取最高的一张卡）" "$d2d"

  local best_scope="逐卡测量、取其中最高的一张"
  (( GPU_USABLE == 1 )) && best_scope="本机唯一一张显卡"
  # 三个方向各报一条：它们的瓶颈完全不同（前两个看 PCIe 链路，
  # 第三个看显存），合成一条的话看报告的人不知道是哪一段的数。
  bench_report "bench_gpu_bw_h2d" "显卡数据传输带宽（主机→显卡）" \
    "$h2d" "GB/s" \
    "主机内存到显存的数据传输带宽（${best_scope}）" "raw/bench/gpu-bandwidth.log"
  bench_report "bench_gpu_bw_d2h" "显卡数据传输带宽（显卡→主机）" \
    "$d2h" "GB/s" \
    "显存到主机内存的数据传输带宽（${best_scope}）" "raw/bench/gpu-bandwidth.log"
  if (( d2d_ok == 1 )); then
    # ⚠️ **必须写明"读写合计"**。这个数是显存拷贝时读、写两个方向的流量之和 ——
    #    显卡规格书上的"显存带宽"也是这个口径（总线峰值），两边能直接对。
    bench_report "bench_gpu_bw_d2d" "显存读写带宽" \
      "$d2d" "GB/s" \
      "显卡内部显存到显存拷贝时的读写合计带宽（与显卡规格书标称的显存带宽同口径，\
${best_scope}）" "raw/bench/gpu-bandwidth.log"
  else
    # 退回快速档了：块大小小到装得进显卡缓存，量出来的不是显存带宽。
    # **宁可这一项不出数，也不能报一个比标称值高几倍的数。**
    bench_skip_no_result "bench_gpu_bw_d2d" "显存读写带宽" "显存的读写带宽" \
      "raw/bench/gpu-bandwidth.log"
  fi
}

# ================================================================
# 显卡：卡与卡之间的互联带宽（P2P）
# ================================================================
# p2p_parse_max_bw <日志> -> 开启双向 P2P 后，所有**不同卡之间**的带宽最大值（GB/s）
#
# ⚠️ 对角线（自己到自己）必须排掉：那是显存内部带宽，动辄是卡间带宽的几十倍，
#    混进去取最大值会得到一个完全失真的数字，而且一张卡的机器会误以为
#    "P2P 带宽 1300 GB/s"。
p2p_parse_max_bw() {
  local log="${1:-}"
  [[ -f "$log" ]] || return 0
  awk '
    /Bidirectional P2P=Enabled Bandwidth.*Matrix/ { inmat = 1; hdr = 0; next }
    inmat && /^[[:space:]]*D\\D/ { hdr = 1; next }
    inmat && hdr {
      # 行首是卡号，后面每一列对应一张卡
      if ($1 !~ /^[0-9]+$/) { inmat = 0; next }
      r = $1 + 0
      for (i = 2; i <= NF; i++) {
        if ($i !~ /^[0-9]+\.?[0-9]*$/) continue
        c = i - 2
        if (c == r) continue                 # 对角线：自己到自己
        if (max == "" || $i + 0 > max) max = $i + 0
      }
    }
    END { if (max != "") printf "%.2f", max }
  ' "$log" 2>/dev/null
}

bench_gpu_p2p() {
  # 一张卡都没有：整台机器没有显卡，性能基准里连显卡这一段都不该出现。
  (( ${GPU_USABLE:-0} > 0 )) || return 0

  # 只有一张卡时没有"卡间"可言。**但这一项仍然要出现在报告里** ——
  # 整项消失的话，看报告的人分不清是"这台机器不需要测"还是"我们漏测了"，
  # 而多卡机器的验收单上就有这一条。所以照实写：本机只有一张卡。
  if (( GPU_USABLE == 1 )); then
    result_add "bench_gpu_p2p" "显卡间互联带宽" "$ST_SKIP" \
      "本机只安装了 1 张显卡，没有卡与卡之间的互联通道可测（此项测的是多张显卡\
两两直连时显存到显存的传输带宽），本项未做测试。此项不影响整机结论。" ""
    return 0
  fi
  local exe
  if ! exe="$(bench_tool p2pBandwidthLatencyTest)"; then
    bench_skip_no_tool "bench_gpu_p2p" "显卡间互联带宽" "显卡间互联"
    return 0
  fi

  info "[BENCH] GPU peer-to-peer bandwidth on $GPU_USABLE cards ..."
  local log="$BENCH_LOG_DIR/gpu-p2p.log"
  bench_run "$log" "$exe" || true

  local maxbw; maxbw="$(p2p_parse_max_bw "$log")"
  if [[ -z "$maxbw" ]]; then
    bench_skip_no_result "bench_gpu_p2p" "显卡间互联带宽" "显卡之间的互联带宽" \
      "raw/bench/gpu-p2p.log"
    return 0
  fi

  metric_add "bench" "显卡间双向带宽（GB/s，全部组合中最高的一组）" "$maxbw"
  bench_report "bench_gpu_p2p" "显卡间互联带宽" \
    "$maxbw" "GB/s" \
    "${GPU_USABLE} 张显卡两两之间开启双向直连后，显存到显存的传输带宽，\
取全部卡对组合中最高的一组" \
    "raw/bench/gpu-p2p.log"
}

# ================================================================
# CPU：浮点算力（LINPACK）
# ================================================================
#
# linpack_parse <日志> -> "<Average 列的最大值 GFlops> <实际跑了几次>"
#
# ⚠️ 这份日志里有**两张表头长得几乎一样**的表，认错了会得到一个完全不相干的数字：
#
#     Size   LDA    Align. Time(s)    GFlops   Residual ...     <- 逐次计时，第 4 列是**秒**
#     40000  40000  4      141.703    3011.99  ...
#
#     Size   LDA    Align.  Average  Maximal                    <- 汇总，第 4 列才是 GFlops
#     40000  40000  4       3030.12  3043.77
#
# 按固定列号取第 4 列的话，报告上印的就是"141.7 GFlops" —— 差了二十几倍。
# 所以这里**从表头里认列名**：哪一列叫 Average 就取哪一列；
# 顺便用带 Time(s) 的那张表数"实际跑了几次"，用来核对 run_times 够不够。
linpack_parse() {
  local log="${1:-}"
  [[ -f "$log" ]] || { printf '0 0'; return; }
  awk '
    /^[[:space:]]*Size[[:space:]]+LDA/ {
      avgcol = 0; timing = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "Average") avgcol = i
        if ($i ~ /^Time/)    timing = 1
      }
      insum = (avgcol > 0); intime = (timing && !avgcol)
      next
    }
    (insum || intime) && $1 !~ /^[0-9]+$/ { insum = 0; intime = 0; next }
    insum && avgcol > 0 && $avgcol ~ /^[0-9]+\.?[0-9]*$/ {
      if ($avgcol + 0 > best) best = $avgcol + 0
    }
    intime { n++ }
    END { printf "%.4f %d", best+0, n+0 }
  ' "$log" 2>/dev/null
}

# LINPACK 的问题规模。太小测不出峰值算力，太大要跑到天亮（耗时按 N³ 涨）。
#
# 取"内存的 25%"和"上限 40000"里的小者：40000 阶要 12.8GB 内存、
# 单次约十几秒，四次一分钟出头，足够压出峰值又不会拖住现场。
# 现场想测更大的规模就在 klburn.conf 里写 BENCH_LINPACK_N。
linpack_problem_size() {
  local total_kb n
  total_kb="$(awk '/MemTotal/{print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$total_kb" =~ ^[0-9]+$ ]] || total_kb=0
  # N = sqrt(0.25 * 总字节 / 8)，取整到千位
  n="$(awk -v kb="$total_kb" 'BEGIN{
         b = kb * 1024 * 0.25 / 8
         n = int(sqrt(b) / 1000) * 1000
         if (n > 40000) n = 40000
         if (n < 5000)  n = 5000
         printf "%d", n }')"
  printf '%s' "$n"
}

# flops_parse <日志> -> "<最好成绩GFlops> <成功跑完的次数>"
#
# 认两个地方，哪个大取哪个：
#   1. 末尾那行 `Best GFlops   : 1234.567`
#   2. 逐次那张表的 GFlops 列
#
# ⚠️ **不能只认第 1 行。**那一行是程序跑完才打的，而 bench_run 的超时是硬的
#    （无人值守的工具里任何外部程序都必须短得住）—— 被打断时前面几次的成绩
#    已经打出来了，只认末行就等于把已经量到的数扔掉，白白判一个 SKIP。
flops_parse() {
  local log="${1:-}"
  [[ -f "$log" ]] || { printf '0 0'; return; }
  awk '
    /^Best GFlops[[:space:]]*:/ { if ($NF + 0 > v) v = $NF + 0 }
    # 逐次那张表：第一列是次数，第三列是 GFlops。求解失败的那几行第三列是
    # "-"，正则挑不中，所以 n 数的是**真的出了数**的次数。
    $1 ~ /^[0-9]+$/ && NF >= 4 && $3 ~ /^[0-9]+\.?[0-9]*$/ {
      if ($3 + 0 > v) v = $3 + 0
      n++
    }
    END { printf "%.4f %d", v + 0, n + 0 }
  ' "$log" 2>/dev/null
}

# 这一轮的算力是拿哪套程序量的。**只进 meta.json（内部），不进交付报告** ——
# 客户报告里不许出现工具名（§6-2）。留着它是为了日后有人拿新旧报告对比、
# 发现数字对不上时能解释得清楚。
BENCH_FLOPS_METHOD="none"

# ---------------------------------------------------------------- CPU 浮点算力
#
# Intel 机器优先使用验收资料指定的 Intel LINPACK；其它平台优先使用
# 全平台可运行的 OpenBLAS 版本。两种方法都把原始日志和实际方法留档，
# 交付报告只写实测值，不把方法差异伪装成同一个硬件结论。
#
#   xlinpack_xeon64  Intel 发布的二进制，Intel 平台的首选
#   klburn_flops     我们自己编的 OpenBLAS 版本，非 Intel 平台的首选
cpu_is_intel() {
  grep -qiE '^vendor_id[[:space:]]*:[[:space:]]*GenuineIntel' /proc/cpuinfo 2>/dev/null
}

bench_cpu_flops() {
  local exe
  if cpu_is_intel && exe="$(bench_tool xlinpack_xeon64 linpack_xeon64)"; then
    BENCH_FLOPS_METHOD="intel-linpack"
    _bench_cpu_flops_intel "$exe"
    return 0
  fi
  if exe="$(bench_tool klburn_flops)"; then
    BENCH_FLOPS_METHOD="openblas-dgesv"
    _bench_cpu_flops_openblas "$exe"
    return 0
  fi
  if exe="$(bench_tool xlinpack_xeon64 linpack_xeon64)"; then
    BENCH_FLOPS_METHOD="intel-linpack"
    _bench_cpu_flops_intel "$exe"
    return 0
  fi
  bench_skip_no_tool "bench_cpu_flops" "CPU 浮点算力" "CPU 浮点算力"
}

_bench_cpu_flops_openblas() {
  local exe="$1" n runs
  n="${BENCH_LINPACK_N:-$(linpack_problem_size)}"
  runs="${BENCH_LINPACK_RUNS:-4}"
  info "[BENCH] CPU floating-point throughput, problem size $n, $runs run(s) ..."

  local log="$BENCH_LOG_DIR/cpu-linpack.log"
  local dir; dir="$(dirname "$exe")"
  # 线程数显式给：OpenBLAS 自己挑的不一定是全核（容器 / cgroup 限制下尤其），
  # 而这一项量的就是**全核**算力。
  ( cd "$dir" && LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" \
      OPENBLAS_NUM_THREADS="$(nproc)" \
      timeout --kill-after=20s "${BENCH_LINPACK_TIMEOUT:-600}" \
      "$exe" -n "$n" -r "$runs" ) > "$log" 2>&1 || true

  local gflops nruns
  read -r gflops nruns < <(flops_parse "$log")
  if [[ "$gflops" == "0.0000" ]]; then
    # 一次都没出数：内存要不起、被超时打断、或者残差大到结果不可信。
    # 每一种都是我们这边的事，不该去染客户的结论 —— origin=self，不进交付报告。
    bench_skip_no_result "bench_cpu_flops" "CPU 浮点算力" "CPU 的浮点算力" \
      "raw/bench/cpu-linpack.log"
    return 0
  fi

  metric_add "bench" "CPU 浮点算力（GFlops）" "$(num_fmt "$gflops")"
  metric_add "bench" "算力测试问题规模（阶）" "$n"
  bench_report "bench_cpu_flops" "CPU 浮点算力" \
    "$gflops" "GFlops" \
    "全核浮点矩阵运算（问题规模 ${n} 阶，重复 ${nruns} 次取最好成绩）的平均算力" \
    "raw/bench/cpu-linpack.log"
}

_bench_cpu_flops_intel() {
  local exe="$1"

  local n runs
  n="${BENCH_LINPACK_N:-$(linpack_problem_size)}"
  runs="${BENCH_LINPACK_RUNS:-4}"
  info "[BENCH] CPU floating-point throughput, problem size $n, $runs run(s) ..."

  # 输入文件自己生成：随包附带的样例规模是按几年前的机器定的，
  # 在今天的服务器上小到测不出峰值。
  local inp="$BENCH_LOG_DIR/linpack-input.txt"
  cat > "$inp" <<EOF
KLBurn generated input
LINPACK data
1                 # number of tests
$n                # problem size
$n                # leading dimension
$runs             # trials to run
4                 # alignment in KB
EOF

  local log="$BENCH_LOG_DIR/cpu-linpack.log"
  # 这个程序从 stdin 读输入文件，不接受文件名参数，所以不走 bench_run，
  # 超时也就单独给一个 —— 它是几项里最重的（问题规模按 N³ 涨），
  # 但同样必须有界：无人值守的工具不能因为一项基准把整台机器拖住。
  local dir; dir="$(dirname "$exe")"
  ( cd "$dir" && LD_LIBRARY_PATH="$dir:${LD_LIBRARY_PATH:-}" \
      timeout --kill-after=20s "${BENCH_LINPACK_TIMEOUT:-600}" "$exe" < "$inp" ) \
    > "$log" 2>&1 || true

  local gflops nruns
  read -r gflops nruns < <(linpack_parse "$log")
  if [[ "$gflops" == "0.0000" ]]; then
    # ⚠️ 非 Intel 的 CPU 会**每一台都走到这里**：手上这个 xlinpack_xeon64 是
    #    Intel 发布的二进制，在海光/AMD 上第一行就打
    #    "optimized for and runs on only genuine Intel processors" 然后退出。
    #    那是**我们这张盘**只带了 Intel 版本，不是那台机器算不动 ——
    #    所以 origin=self，这一行不进交付报告。
    bench_skip_no_result "bench_cpu_flops" "CPU 浮点算力" "CPU 的浮点算力" \
      "raw/bench/cpu-linpack.log"
    return 0
  fi

  metric_add "bench" "CPU 浮点算力（GFlops）" "$(num_fmt "$gflops")"
  metric_add "bench" "算力测试问题规模（阶）" "$n"
  bench_report "bench_cpu_flops" "CPU 浮点算力" \
    "$gflops" "GFlops" \
    "全核浮点矩阵运算（问题规模 ${n} 阶，重复 ${runs} 次取最好成绩）的平均算力" \
    "raw/bench/cpu-linpack.log"
}

# ================================================================
# 内存：读取带宽
# ================================================================
#
# mlc_parse_all_reads <日志> -> "ALL Reads" 那一行的数值（MB/s）
mlc_parse_all_reads() {
  local log="${1:-}"
  [[ -f "$log" ]] || return 0
  awk -F: '
    /^[[:space:]]*ALL Reads/ {
      v = $2; gsub(/[^0-9.]/, "", v)
      if (v ~ /^[0-9]+\.?[0-9]*$/ && v + 0 > best) best = v + 0
    }
    END { if (best > 0) printf "%.1f", best }
  ' "$log" 2>/dev/null
}

# 已装内存实际在跑的频率（MT/s）。多种频率并存时取**最低**那个 ——
# 混插时整机就是按最慢那条跑的，所以报出去的必须是最慢那个 —— 报最高的就是虚高。
dmi_mem_speed_mts() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  dmi_dimm_field "$f" "Configured Memory Speed" \
    | grep -oE '^[0-9]+' | sort -n | head -1
}

# 已装内存占用了几个内存通道。
#
# 两条路，按可靠性排序：
#   1. Bank Locator 里带 "Channel<N>"（Supermicro / Intel 参考设计常见）——
#      直接数不同的 (节点, 通道) 组合
#   2. Locator 形如 CPU0_DIMMA0 / P1-DIMMB1 / DIMM_C2 —— 数 DIMM 后面那个字母，
#      配上前面的插槽标识
# 两条都认不出来就返回 0，调用方据此在报告里不写通道数（**绝不猜**）。
dmi_channel_count() {
  local f="${1:-}" n
  [[ -f "$f" ]] || { printf '0'; return; }

  n="$(awk '
        BEGIN { RS = ""; FS = "\n" }
        {
          size = ""; bank = ""
          sp = "\tSize: "; bp = "\tBank Locator: "
          for (i = 1; i <= NF; i++) {
            line = $i; sub(/\r$/, "", line)
            if (size == "" && substr(line, 1, length(sp)) == sp) size = substr(line, length(sp)+1)
            if (bank == "" && substr(line, 1, length(bp)) == bp) bank = substr(line, length(bp)+1)
          }
          if (size == "" || size ~ /No Module Installed/) next
          if (bank ~ /[Cc]hannel/) {
            key = bank
            sub(/[_-]?[Dd][Ii][Mm][Mm].*$/, "", key)   # 去掉尾部的 DIMM 序号，只留到通道
            print key
          }
        }' "$f" 2>/dev/null | sort -u | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  (( n > 0 )) && { printf '%s' "$n"; return; }

  n="$(dmi_dimm_field "$f" "Locator" | awk '
        {
          s = toupper($0)
          # CPU0_DIMMA0 / P1-DIMMB1 / DIMM_C2  ->  A / B / C
          if (match(s, /DIMM[_-]?[A-Z]+/)) {
            t = substr(s, RSTART, RLENGTH)
            gsub(/^DIMM[_-]?/, "", t)
            if (t != "") { print t; next }
          }
          # 退到最朴素的 A1 / B2 这种写法
          if (match(s, /^[A-Z]+[0-9]+$/)) { gsub(/[0-9]+$/, "", s); print s }
        }' | sort -u | grep -c . || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  # 上面那条只数出"字母有几种"，多路机器每颗 CPU 的字母是重复的，
  # 要乘回插槽数才是整机通道数。
  if (( n > 0 )); then
    local sockets
    sockets="$(awk -F': ' '/^Socket\(s\)/{gsub(/ /,"",$2); print $2; exit}' "$RAW_DIR/lscpu.txt" 2>/dev/null)"
    [[ "$sockets" =~ ^[0-9]+$ ]] && (( sockets > 1 )) && n=$(( n * sockets ))
  fi
  printf '%s' "$n"
}

# MLC 要的大页。**AMD 平台上不给它就一个数都出不来。**（1.10.1）
#
# 1.9.9 / 1.10.0 那台 EPYC 7542 的日志全文只有这几行，然后程序就退了：
#     *** Hugepages need to be allocated using /proc/sys/vm/nr_hugepages
#     *** We need at least 1000 2M pages per numa node
#     *** echo 4000 > /proc/sys/vm/nr_hugepages
# 于是报告里恒定写着「本次未能测得内存的读取带宽（测试程序未返回有效结果）」——
# **每一台 AMD 机器这一项都测不到**，而那句文案听起来像是机器读不出来。
# 同一类错（能力缺失被写成机器的毛病）1.9.9 在显存带宽上刚踩过一次。
#
# 按它自己那句提示分配，跑完原样还原：
#   * 只在跑 MLC 的这几十秒里占着，之后立刻放回去
#   * 分配不成功（内存碎片化到凑不出连续 2M 页）就照跑 —— Intel 平台上
#     没有大页也能出结果，那种情况下少一点精度总比一个数都没有强
#
# ⚠️ 还原必须无条件做。这一段中途 return 的话大页就一直占着
#    （4000 × 2M = 8 GB），后面的内存压测会少覆盖那么多。
mlc_hugepages_setup() {
  local f=/proc/sys/vm/nr_hugepages nodes want
  MLC_HP_SAVED=""
  [[ -w "$f" ]] || return 0
  MLC_HP_SAVED="$(cat "$f" 2>/dev/null)"
  [[ "$MLC_HP_SAVED" =~ ^[0-9]+$ ]] || { MLC_HP_SAVED=""; return 0; }
  # 它要的是"每个 NUMA 节点至少 1000 个 2M 页"
  local d
  nodes=0
  for d in /sys/devices/system/node/node[0-9]*; do
    [[ -d "$d" ]] && nodes=$(( nodes + 1 ))
  done
  (( nodes > 0 )) || nodes=1
  want=$(( nodes * 1000 ))
  (( want > MLC_HP_SAVED )) || { MLC_HP_SAVED=""; return 0; }
  printf '%s' "$want" > "$f" 2>/dev/null || true
  dbg "mlc hugepages: $MLC_HP_SAVED -> $(cat "$f" 2>/dev/null) (${nodes} numa node(s))"
}

mlc_hugepages_restore() {
  [[ -n "${MLC_HP_SAVED:-}" ]] || return 0
  printf '%s' "$MLC_HP_SAVED" > /proc/sys/vm/nr_hugepages 2>/dev/null || true
  dbg "mlc hugepages restored to $MLC_HP_SAVED"
  MLC_HP_SAVED=""
}

bench_mem_bandwidth() {
  local exe
  if ! exe="$(bench_tool mlc_avx512 mlc)"; then
    bench_skip_no_tool "bench_mem_bw" "内存读取带宽" "内存带宽"
    return 0
  fi

  info "[BENCH] Memory read bandwidth ..."
  # ⚠️ 排在 MLC 之前把页缓存放掉、把空闲页整理一遍。
  #    见 bench_all 顶上那段：全量档量出来的数只有内存档的六成，
  #    根子是内存脏了之后每线程 391 MiB 的缓冲区落到了别的 NUMA 节点上。
  #    两条都是"尽力而为"，失败了不影响后面。
  sync 2>/dev/null || true
  [[ -w /proc/sys/vm/drop_caches ]]    && printf '3' > /proc/sys/vm/drop_caches 2>/dev/null
  [[ -w /proc/sys/vm/compact_memory ]] && printf '1' > /proc/sys/vm/compact_memory 2>/dev/null
  local log="$BENCH_LOG_DIR/mem-bandwidth.log"

  # ⚠️ 先把 msr 模块加载上。没有它 MLC 改不了硬件预取器，会打
  #     *** Unable to modify prefetchers (try executing 'modprobe msr')
  #     *** So, enabling random access for latency measurements
  # 然后**换一套测法**继续跑 —— 数字照样出得来，但和"预取器可控"那次不是
  # 同一个口径，报出去的数字就不是可比的。实测确认过这条提示。
  modprobe msr >/dev/null 2>&1 || true

  # AVX-512 那个开关（-Z）**故意不加**：不是每颗 CPU 都有 AVX-512，
  # 加了在没有的平台上直接跑不出结果。不加时 MLC 自己会挑一套能跑的指令集，
  # 报告里如实写它测出来的数就行。
  #
  # `-b` 必须显式给，理由见 mlc_buffer_kib（不给的话它会挑一个超过整机内存的值）。
  # 只跑峰值注入带宽那一组：完整跑一遍要十几分钟，而我们要的就是 ALL Reads。
  local bufkib; bufkib="$(mlc_buffer_kib)"
  dbg "mlc buffer: ${bufkib} KiB/thread"
  # ⚠️ 大页要在 mlc_buffer_kib 之后再分配：那个函数按**当前可用内存**算缓冲区
  #    大小，先占掉 8GB 大页的话它会算小一档，测出来的数就不是同一个口径了。
  mlc_hugepages_setup
  bench_run "$log" "$exe" --peak_injection_bandwidth "-b${bufkib}" || true
  mlc_hugepages_restore

  local got; got="$(mlc_parse_all_reads "$log")"
  if [[ -z "$got" ]]; then
    bench_skip_no_result "bench_mem_bw" "内存读取带宽" "内存的读取带宽" \
      "raw/bench/mem-bandwidth.log"
    return 0
  fi
  metric_add "bench" "内存读取带宽（MB/s）" "$got"

  # 内存自身的规格（运行频率、插了几个通道）是**实测到的事实**，一并记下来 ——
  # 拿带宽数字去对任何标准的人，都需要知道这两个前提。
  # ⚠️ 但**只报事实，不要拿它们去算一个"应该达到多少"的数**（见文件头第 1 条）。
  local speed ch
  speed="$(dmi_mem_speed_mts "$RAW_DIR/dmidecode-memory.txt")"
  ch="$(dmi_channel_count "$RAW_DIR/dmidecode-memory.txt")"
  [[ "$speed" =~ ^[0-9]+$ ]] && metric_add "bench" "内存运行频率（MT/s）" "$speed"
  [[ "$ch" =~ ^[0-9]+$ ]] && (( ch > 0 )) && metric_add "bench" "内存通道数" "$ch"

  local basis=""
  if [[ "$speed" =~ ^[0-9]+$ ]] && [[ "$ch" =~ ^[0-9]+$ ]] && (( ch > 0 )); then
    basis="（本机内存运行频率 ${speed} MT/s，已装满 ${ch} 个通道）"
  fi
  result_add "bench_mem_bw" "内存读取带宽" "$ST_PASS" \
    "内存满负载读取带宽实测 $(num_fmt "$got") MB/s${basis}。" "raw/bench/mem-bandwidth.log"
}

# ================================================================
# 硬盘：顺序读写带宽（按验收单的口径）
# ================================================================
#
# 验收单点名的是 libaio、128k 块、SATA 队列深度 32 / NVMe 队列深度 128、单线程。
# 这和 stress_disk 里那两轮（1M 顺序写看持续带宽、4K 随机看 IOPS 和稳定性）
# 是**两回事**：那两轮是老化压测，这一轮是量一个可以和订单对表的带宽数字。
#
# ⚠️ 读和写的破坏性完全不同，所以**分开对待**：
#      读 —— 只从裸设备读，一个字节都不写，任何时候都能跑
#      写 —— 直接往裸设备写，和 stress_disk 一样必须经现场确认
#    这不是省事，是"能白拿的数据就别让客户少拿"。

# disk_queue_depth <设备路径> -> 该盘按验收口径应该用的队列深度
disk_queue_depth() {
  local dev="${1:-}" base
  base="$(basename "$dev")"
  if [[ "$base" == nvme* ]]; then
    printf '%s' "${BENCH_DISK_QD_NVME:-128}"
  else
    printf '%s' "${BENCH_DISK_QD_SATA:-32}"
  fi
}

# fio_job_bw_mbs <fio 的 json> <jobname> <read|write> -> 带宽 MB/s
#
# 优先使用 fio 直接给出的 bw_bytes（byte/s），按十进制 1 MB = 1,000,000 bytes
# 换算。老 fio 没有 bw_bytes 时，再把 bw 的 KiB/s 乘 1024 后换算。
fio_job_bw_mbs() {
  local f="${1:-}" job="${2:-}" rw="${3:-read}"
  [[ -s "$f" ]] || return 0
  jq -r --arg j "$job" --arg rw "$rw" \
     '[.jobs[]? | select(.jobname == $j)
       | if ((.[$rw].bw_bytes // 0) > 0)
         then .[$rw].bw_bytes
         else ((.[$rw].bw // 0) * 1024)
         end] | add // empty
      | select(. > 0) | . / 1000000 | (. * 10 | round) / 10' "$f" 2>/dev/null
}

# bench_disk_one <设备> <read|write> <秒数> -> 打印 MB/s（跑不出来打印空）
bench_disk_one() {
  local dev="$1" rw="$2" secs="$3"
  local qd; qd="$(disk_queue_depth "$dev")"
  local job="libaio_${rw}_128k_${qd}_1"
  local base; base="$(basename "$dev")"
  local jf="$BENCH_LOG_DIR/fio-${base}-${rw}.job"
  local out="$RAW_DIR/bench/fio-${base}-${rw}.json"

  # job 名就是验收单上那个命名（libaio_read_128k_32_1），照抄不改 ——
  # 客户拿两边的报告对照时，名字对得上比什么都省事。
  {
    printf '[global]\nioengine=libaio\ndirect=1\nbs=128k\niodepth=%s\nnumjobs=1\n' "$qd"
    printf 'rw=%s\ntime_based=1\nruntime=%s\nramp_time=5\ngroup_reporting=0\nthread=1\n\n' \
           "$( [[ "$rw" == "write" ]] && printf 'write' || printf 'read' )" "$secs"
    printf '[%s]\nfilename=%s\n' "$job" "$dev"
  } > "$jf"

  fio --output-format=json --output="$out" "$jf" \
      > "$BENCH_LOG_DIR/fio-${base}-${rw}.log" 2>&1 || true
  fio_job_bw_mbs "$out" "$job" "$rw"
}

bench_disk_bandwidth() {
  local write_ok="${1:-0}"
  if (( ${#DISK_CAND[@]} == 0 )); then
    result_add "bench_disk_bw" "硬盘读写带宽" "$ST_SKIP" \
      "未发现可测试的本机硬盘，本项未做测试。此项不影响整机结论。" ""
    return 0
  fi
  if ! have fio; then
    bench_skip_no_tool "bench_disk_bw" "硬盘读写带宽" "硬盘带宽"
    return 0
  fi

  local secs="${BENCH_DISK_SECS:-20}"
  info "[BENCH] Disk sequential 128k bandwidth, ${secs}s per pass ..."

  local dev base rbw wbw n=0
  for dev in "${DISK_CAND[@]}"; do
    base="$(basename "$dev")"
    n=$(( n + 1 ))

    rbw="$(bench_disk_one "$dev" read "$secs")"
    [[ -n "$rbw" ]] && metric_add "bench" "${base} 顺序读带宽（MB/s）" "$(num_fmt "$rbw")"

    if (( write_ok == 1 )); then
      wbw="$(bench_disk_one "$dev" write "$secs")"
      [[ -n "$wbw" ]] && metric_add "bench" "${base} 顺序写带宽（MB/s）" "$(num_fmt "$wbw")"
    fi
  done

  # ⚠️ 后半句是**指路**，指向报告里那张逐盘表的小节标题。而那个标题是跟着
  #    "这次到底测了哪几个方向"动的（现场没确认破坏性写入时只测得到读，
  #    写那一列整个不画，标题也就只写「顺序读」）—— 两边用同一个判据拼，
  #    否则这句话会指向一个报告里根本不存在的小节。
  #    tests/test-report-render.sh 有一条"每个「见下方「X」」都得有对应标题"钉着。
  # ⚠️ 括号里那句耗时也得跟着方向数走。只测了读的时候写「每块每个方向各 20 秒」，
  #    同一句话里前半句说只测了顺序读、后半句冒出个"每个方向"，自相矛盾
  #    （1.9.7 那份硬盘专项报告里就是这样印出去的）。
  local scope="顺序读" secname="硬盘顺序读带宽" how="每块 ${secs} 秒"
  if (( write_ok == 1 )); then
    scope="顺序读与顺序写"; secname="硬盘顺序读写带宽"; how="每块每个方向各 ${secs} 秒"
  fi
  local detail="对 ${n} 块硬盘逐块测量 128KB 大块${scope}带宽（${how}），\
逐盘数值见下方「${secname}」"

  if (( write_ok == 1 )); then
    result_add "bench_disk_bw" "硬盘读写带宽" "$ST_PASS" "${detail}。" "raw/bench/"
  else
    # 现场没确认破坏性写入 —— 这一轮**一个字节都没往盘里写**。
    # 这句话要写死在结论里：客户看到"硬盘带宽"四个字，第一个念头就是
    # "你们是不是把我盘上的数据冲了"，等他打电话来问就晚了。
    result_add "bench_disk_bw" "硬盘读写带宽" "$ST_PASS" \
      "${detail}。本次未进行破坏性写入测试，全程只从硬盘读取、未向硬盘写入任何数据，\
盘上原有数据不受影响；因此本项只测量了读带宽。" "raw/bench/"
  fi
}

# ================================================================
# 汇总入口
# ================================================================
# <写盘是否已确认>：只影响硬盘那一项要不要测写带宽，其余不受影响。
#
# 每一项都受本轮**测试范围**管（KLB_SCOPE，见 core.sh 的 scope_runs）：
# 范围之外的**整项不跑，也不产生结论行** —— 不是"跑了再藏起来"。
#
# ⚠️ 「仅导出报告」那一档（info）这五项**全都跑**：每项几十秒，而且一个字节
#    都不往盘上写（bench_disk_bandwidth 在没确认写盘时是 rw=read + direct=1）。
#    它跳过的是老化压测和专项验证，不是基准。
# ⚠️⚠️ **内存带宽必须排在第一个。**（1.10.1）
#
# 1.9.9 和 1.10.0 两版现场数据里，同一台 6133、同一个工具、同样的 buffer、
# 同样 2666 MT/s，两个范围量出来差 65%：
#     全量档   78650.8 MB/s   （1.9.9: 78833.5）
#     内存档  129522.0 MB/s   （1.9.9: 129299.3）
# 区别只有一个：全量档里内存带宽排在 CPU 算力后面跑，而那一步是 40000 阶的
# 矩阵（约 12.8 GB），跑完释放掉之后空闲页被打散；MLC 要给每个线程各分
# 391 MiB，这时候拿到的页很可能落在**别的 NUMA 节点**上，双路机器于是
# 整条测量都在跨 UPI，正好腰斩。内存档里它是第一个跑的，内存还是干净的。
#
# 两台机器的报告里，出货主报告（全量档）印的一直是低的那个数。
# 性能数字只报不判（四号红线），但**报一个错的数字仍然是错的** ——
# 客户拿它去对验收单，对不上的是我们量错的那一半。
#
# 所以：内存带宽排到最前面，并且在它之前把页缓存放掉、把空闲页整理一遍。
bench_all() {
  local write_ok="${1:-0}"
  bench_init
  scope_runs bench_mem  && bench_mem_bandwidth
  if scope_runs bench_gpu; then
    bench_gpu_bandwidth
    bench_gpu_p2p
  fi
  scope_runs bench_cpu  && bench_cpu_flops
  scope_runs bench_disk && bench_disk_bandwidth "$write_ok"
  # 上面几条是 `判断 && 命令` 的形式，最后一条不成立时整个函数会返回非零。
  # 主流程没开 set -e，所以不会中断，但返回码会误导调用方 —— 显式收口。
  return 0
}
