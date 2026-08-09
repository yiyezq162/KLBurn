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
bench_skip_no_tool() {
  result_add "$1" "$2" "$ST_SKIP" \
    "本次测试环境未包含${3}基准测试程序，本项未做测试。此项不影响整机结论。" ""
}

# ================================================================
# 显卡：主机与显卡之间、以及显卡内部的数据传输带宽
# ================================================================
#
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
  local log="$BENCH_LOG_DIR/gpu-bandwidth.log"
  : > "$log"

  # **逐卡跑，取最差的那张**。
  # 不用 --device=all 有两个原因：一是不同 CUDA 版本对"多卡时怎么汇总"的处理
  # 不一样（有的给一行合计，有的逐卡分块），解析口径不稳；二是验收要的是
  # 逐卡的数才有意义，把八张卡混成一个数字的话，一张慢卡会被另外七张平均掉。
  local idx h2d d2h d2d mh="" md="" mdd=""
  for (( idx = 0; idx < GPU_USABLE; idx++ )); do
    local one="$BENCH_LOG_DIR/gpu-bandwidth-${idx}.log"
    # --dtod 才会跑显卡内部（Device to Device）那一段；不加的话只有 H2D/D2H。
    bench_run "$one" "$exe" "--device=$idx" --memory=pinned --mode=quick --htod --dtoh --dtod || true
    { printf '===== GPU %d =====\n' "$idx"; cat "$one"; printf '\n'; } >> "$log"
    read -r h2d d2h d2d < <(bw_parse_bandwidthtest "$one")
    [[ "$h2d" == "0.00" && "$d2h" == "0.00" && "$d2d" == "0.00" ]] && continue
    if [[ -z "$mh"  ]] || num_ge "$mh"  "$h2d"; then mh="$h2d";  fi
    if [[ -z "$md"  ]] || num_ge "$md"  "$d2h"; then md="$d2h";  fi
    if [[ -z "$mdd" ]] || num_ge "$mdd" "$d2d"; then mdd="$d2d"; fi
  done
  h2d="${mh:-0.00}"; d2h="${md:-0.00}"; d2d="${mdd:-0.00}"

  if [[ "$h2d" == "0.00" && "$d2h" == "0.00" && "$d2d" == "0.00" ]]; then
    result_add "bench_gpu_bw" "显卡数据传输带宽" "$ST_SKIP" \
      "本次未能测得显卡的数据传输带宽（测试程序未返回有效结果）。此项不影响整机结论。" \
      "raw/bench/gpu-bandwidth.log"
    return 0
  fi

  metric_add "bench" "主机到显卡带宽（GB/s，取最低的一张卡）" "$h2d"
  metric_add "bench" "显卡到主机带宽（GB/s，取最低的一张卡）" "$d2h"
  metric_add "bench" "显存内部带宽（GB/s，取最低的一张卡）"   "$d2d"

  local scope="逐卡测量、取其中最低的一张"
  (( GPU_USABLE == 1 )) && scope="本机唯一一张显卡"
  # 三个方向各报一条：它们的瓶颈完全不同（前两个看 PCIe 链路，
  # 第三个看显存），合成一条的话看报告的人不知道是哪一段的数。
  bench_report "bench_gpu_bw_h2d" "显卡数据传输带宽（主机→显卡）" \
    "$h2d" "GB/s" \
    "主机内存到显存的数据传输带宽（${scope}）" "raw/bench/gpu-bandwidth.log"
  bench_report "bench_gpu_bw_d2h" "显卡数据传输带宽（显卡→主机）" \
    "$d2h" "GB/s" \
    "显存到主机内存的数据传输带宽（${scope}）" "raw/bench/gpu-bandwidth.log"
  bench_report "bench_gpu_bw_d2d" "显存内部带宽" \
    "$d2d" "GB/s" \
    "显卡内部显存之间的数据传输带宽（${scope}）" "raw/bench/gpu-bandwidth.log"
}

# ================================================================
# 显卡：卡与卡之间的互联带宽（P2P）
# ================================================================
#
# p2p_parse_min_bw <日志> -> 开启双向 P2P 后，所有**不同卡之间**的带宽最小值（GB/s）
#
# ⚠️ 对角线（自己到自己）必须排掉：那是显存内部带宽，动辄是卡间带宽的几十倍，
#    混进去取最小值虽然不受影响，但取平均/最大就会得到一个完全失真的数字，
#    而且一张卡的机器会误以为"P2P 带宽 1300 GB/s"。
p2p_parse_min_bw() {
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
        if (min == "" || $i + 0 < min) min = $i + 0
      }
    }
    END { if (min != "") printf "%.2f", min }
  ' "$log" 2>/dev/null
}

bench_gpu_p2p() {
  (( ${GPU_USABLE:-0} > 1 )) || {
    # 只有一张卡时根本没有"卡间"可言。这不是缺陷，也不该刷一条 SKIP 让客户去猜，
    # 所以只在有多张卡时才记这一项。
    return 0
  }
  local exe
  if ! exe="$(bench_tool p2pBandwidthLatencyTest)"; then
    bench_skip_no_tool "bench_gpu_p2p" "显卡间互联带宽" "显卡间互联"
    return 0
  fi

  info "[BENCH] GPU peer-to-peer bandwidth on $GPU_USABLE cards ..."
  local log="$BENCH_LOG_DIR/gpu-p2p.log"
  bench_run "$log" "$exe" || true

  local minbw; minbw="$(p2p_parse_min_bw "$log")"
  if [[ -z "$minbw" ]]; then
    result_add "bench_gpu_p2p" "显卡间互联带宽" "$ST_SKIP" \
      "本次未能测得显卡之间的互联带宽（测试程序未返回有效结果）。此项不影响整机结论。" \
      "raw/bench/gpu-p2p.log"
    return 0
  fi

  metric_add "bench" "显卡间双向带宽（GB/s，全部组合中最低的一组）" "$minbw"
  bench_report "bench_gpu_p2p" "显卡间互联带宽" \
    "$minbw" "GB/s" \
    "${GPU_USABLE} 张显卡两两之间开启双向直连后，全部组合中最低的一组带宽" \
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

bench_cpu_linpack() {
  local exe
  if ! exe="$(bench_tool xlinpack_xeon64 linpack_xeon64)"; then
    bench_skip_no_tool "bench_cpu_flops" "CPU 浮点算力" "CPU 浮点算力"
    return 0
  fi

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
    result_add "bench_cpu_flops" "CPU 浮点算力" "$ST_SKIP" \
      "本次未能测得 CPU 的浮点算力（测试程序未返回有效结果）。此项不影响整机结论。" \
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

bench_mem_bandwidth() {
  local exe
  if ! exe="$(bench_tool mlc_avx512 mlc)"; then
    bench_skip_no_tool "bench_mem_bw" "内存读取带宽" "内存带宽"
    return 0
  fi

  info "[BENCH] Memory read bandwidth ..."
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
  bench_run "$log" "$exe" --peak_injection_bandwidth "-b${bufkib}" || true

  local got; got="$(mlc_parse_all_reads "$log")"
  if [[ -z "$got" ]]; then
    result_add "bench_mem_bw" "内存读取带宽" "$ST_SKIP" \
      "本次未能测得内存的读取带宽（测试程序未返回有效结果）。此项不影响整机结论。" \
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
# fio 的 bw 字段单位是 KiB/s。除以 1024 得到 MiB/s —— 验收单写的是 MB/s，
# 两者差 4.8%，**故意不做十进制换算**：换算过去反而会让实测数字虚高，
# 报出去的数字宁可保守一点，也不要虚高。
fio_job_bw_mbs() {
  local f="${1:-}" job="${2:-}" rw="${3:-read}"
  [[ -s "$f" ]] || return 0
  jq -r --arg j "$job" --arg rw "$rw" \
     '[.jobs[]? | select(.jobname == $j) | (.[$rw].bw // 0)] | add // empty
      | select(. > 0) | . / 1024 | (. * 10 | round) / 10' "$f" 2>/dev/null
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

  local scope="顺序读"
  (( write_ok == 1 )) && scope="顺序读与顺序写"
  local detail="对 ${n} 块硬盘逐块测量 128KB 大块${scope}带宽（每块每个方向各 ${secs} 秒），\
逐盘数值见下方「硬盘顺序读写带宽」"

  if (( write_ok == 1 )); then
    result_add "bench_disk_bw" "硬盘读写带宽" "$ST_PASS" "${detail}。" "raw/bench/"
  else
    result_add "bench_disk_bw" "硬盘读写带宽" "$ST_PASS" \
      "${detail}。本次未进行破坏性写入测试，因此只测量了读带宽。" "raw/bench/"
  fi
}

# ================================================================
# 汇总入口
# ================================================================
# <写盘是否已确认>：只影响硬盘那一项要不要测写带宽，其余不受影响。
bench_all() {
  local write_ok="${1:-0}"
  bench_init
  bench_gpu_bandwidth
  bench_gpu_p2p
  bench_cpu_linpack
  bench_mem_bandwidth
  bench_disk_bandwidth "$write_ok"
}
