#!/usr/bin/env bash
#
# 编 KLBurn 自己的 CPU 浮点算力程序，产物放进 vendor/bench/cpuflops/
# 供构建 ISO 时打包。
#
#   ./build/build-cpuflops.sh
#
# 不需要 root。需要 gcc 和 libopenblas-dev：
#
#   sudo apt install gcc libopenblas-dev
#
# ================================================================
# 它解决的问题
# ================================================================
# vendor/bench/linpack/xlinpack_xeon64 是 **Intel 发布的二进制**，在海光 / AMD
# 上第一行就打 "optimized for and runs on only genuine Intel processors"
# 然后退出 —— 非 Intel 机器的「CPU 浮点算力」于是永远测不出来。
# 那不是那台机器算不动，是我们这张盘只带了 Intel 版本。
#
# 算法和口径见 build/src/klburn-flops.c 的文件头：同一套 LU 分解、
# 同一个 (2/3·N³ + 2·N²) / 用时 的公式，所以数字和历史上的 LINPACK 可比。
#
# ================================================================
# 为什么动态链 OpenBLAS，而不是静态链
# ================================================================
# Ubuntu 的 libopenblas 是 **DYNAMIC_ARCH** 构建：同一个 .so 里带着各微架构的
# 核，运行时自己认 Zen / Hygon / Intel，不用按 CPU 分别出包。静态链要么把
# 30MB 的 .a 全塞进来，要么还得连 libgfortran 一起静态化，得不偿失。
#
# ⚠️ 所以**盘里必须有 libopenblas**：build/config.sh 的 PKGS_STRESS 里显式
#    列了 libopenblas0-pthread。改那一行之前先想清楚这一项会不会变成永远 SKIP。
#    编完这里会当场核一遍动态依赖，多出别的库就直接失败。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$SCRIPT_DIR/src/klburn-flops.c"
OUT_DIR="$PROJ_DIR/vendor/bench/cpuflops"
BIN="$OUT_DIR/klburn_flops"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m %s\n' "$*" >&2; exit 1; }

command -v gcc >/dev/null 2>&1 || die "缺 gcc。装一下：sudo apt install gcc"
[[ -f "$SRC" ]] || die "找不到源码：$SRC"

# -dev 包给的是 libopenblas.so（不带版本号的那个软链），链接时要它。
#
# ⚠️ 别用 `ls /usr/lib/*/libopenblas.so /usr/lib/libopenblas.so` 去查 ——
#    两个路径里只要有一个不存在，ls 就返回非零，于是**装了也报没装**。
#    问链接器自己是唯一靠得住的判据。
if ! echo 'int main(void){return 0;}' | gcc -x c - -lopenblas -o /dev/null 2>/dev/null; then
  die "链不上 libopenblas。装一下：sudo apt install libopenblas-dev"
fi

mkdir -p "$OUT_DIR"

log "编译 $SRC"
# -O2 就够：真正干活的是 OpenBLAS 里的核，这个文件只负责造数据和计时，
# 开 -O3 / -march=native 一点用没有，后者还会让产物只能在本机跑。
gcc -O2 -Wall -Wextra -o "$BIN" "$SRC" -lopenblas -lm \
  || die "编译失败"

# ---- 动态依赖自检 ----
# 和 build-opendcdiag.sh 同一个道理：带一个跑不起来的二进制上盘，现场表现是
# "这一项莫名其妙 SKIP"，比不带还难查。
#
# libopenblas 是**故意**允许的（盘里由 PKGS_STRESS 装），
# libgfortran / libgomp / libquadmath 是它自己的依赖，由 apt 一起带进盘。
ALLOW='libc\.so|libm\.so|libgcc_s\.so|libpthread\.so|libdl\.so|librt\.so|ld-linux|linux-vdso|libopenblas\.so|libgfortran\.so|libgomp\.so|libquadmath\.so'
extra="$(ldd "$BIN" 2>/dev/null | awk '{print $1}' | grep -vE "$ALLOW" || true)"
[[ -z "$extra" ]] || die "产物有意料之外的动态依赖：
$extra"

# ---- 当场跑一遍 ----
# 编出来但跑不起来是最难查的一种失败。小规模跑一次，确认它真的出数。
log "自检：跑一次 N=1500"
if ! OPENBLAS_NUM_THREADS="$(nproc)" "$BIN" -n 1500 -r 1 > "$OUT_DIR/.selftest.log" 2>&1; then
  cat "$OUT_DIR/.selftest.log" >&2
  die "自检没跑通"
fi
grep -q '^Best GFlops' "$OUT_DIR/.selftest.log" \
  || { cat "$OUT_DIR/.selftest.log" >&2; die "自检跑完了但没有 Best GFlops 那一行"; }
sed -n '/^Best GFlops/p' "$OUT_DIR/.selftest.log"
rm -f "$OUT_DIR/.selftest.log"

cat > "$OUT_DIR/SOURCE.txt" <<EOF
KLBurn 自研 CPU 浮点算力程序（源码在 build/src/klburn-flops.c，随本仓库）
算法: LU 分解解 N 阶方程组（LAPACK dgesv），口径 (2/3·N^3 + 2·N^2) / 用时
链接: $(ldd "$BIN" | awk '/libopenblas/{print $1, "->", $3}')
编译: $(gcc --version | head -1)，-O2
由 build/build-cpuflops.sh 生成于 $(date '+%Y-%m-%d %H:%M:%S')

⚠ 这一项的数值比 Intel MKL 版本（xlinpack_xeon64）低一到两成，
  是换了测量方法，不是机器变慢了。全系列机器统一用这一个程序，
  代价是绝对值低一点，换来的是**所有平台的数字可比**。
EOF

log "完成：$BIN"
