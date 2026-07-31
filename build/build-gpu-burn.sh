#!/usr/bin/env bash
#
# 在 WSL 里编译 gpu_burn，产物放进 vendor/gpu_burn/ 供 GPU 版 ISO 打包。
#
#   ./build/build-gpu-burn.sh
#
# 不需要 root，也不需要机器上真有 N 卡（只编译，不运行）。
# 需要先装好 CUDA，见 README「加入 GPU 模块」一节。
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_DIR="${KLBURN_WORK:-$HOME/klburn-build}/gpu-burn-src"
TMP_DIR="${KLBURN_WORK:-$HOME/klburn-build}/gpu-burn-static"
OUT_DIR="$PROJ_DIR/vendor/gpu_burn"
GPU_BURN_REPO="https://github.com/wilicc/gpu-burn.git"

# gpu_burn 自己那个 compare 核的 PTX 基线架构。
# 它只负责比对计算结果，真正的算力负载来自 cuBLAS 里的预编译 cubin，
# 所以基线定低不会削弱压测强度，只是让更老的卡也能跑（PTX 向上兼容，由驱动 JIT）。
COMPUTE="${COMPUTE:-75}"

# cuBLAS 静态库里要保留哪几代卡的 cubin。裁掉其余的能省一大半体积。
#   80  = Ampere   A100
#   86  = Ampere   A10 / A6000
#   89  = Ada      RTX 4090 / L20 / L40S
#   90  = Hopper   H100 / H200
#   120 = Blackwell RTX 5090 / RTX PRO 6000
GPU_ARCHS="${GPU_ARCHS:-80 86 89 90 120}"

info() { printf '\033[36m[gpu-burn]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[gpu-burn] 警告\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[gpu-burn] ERROR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 找 CUDA
CUDAPATH="${CUDAPATH:-}"
if [[ -z "$CUDAPATH" ]]; then
  for c in /usr/local/cuda /usr/local/cuda-13* /usr/local/cuda-12*; do
    [[ -x "$c/bin/nvcc" ]] && CUDAPATH="$c" && break
  done
fi
[[ -n "$CUDAPATH" && -x "$CUDAPATH/bin/nvcc" ]] \
  || die "找不到 nvcc。请先装 CUDA（见 README），或手动指定:
     CUDAPATH=/usr/local/cuda-12.8 $0"

NVCC_VER="$("$CUDAPATH/bin/nvcc" --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')"
info "CUDA: $CUDAPATH (nvcc $NVCC_VER)"

# sm_120 是 CUDA 12.8 才加进去的，低于它 5090 / RTX PRO 6000 的 cuBLAS 没有原生核
major="${NVCC_VER%%.*}"; minor="$(printf '%s' "$NVCC_VER" | cut -d. -f2)"
if (( major < 12 || (major == 12 && minor < 8) )); then
  warn "CUDA $NVCC_VER 低于 12.8，Blackwell（RTX 5090 / RTX PRO 6000）可能不被支持。"
  printf '            4090 / L20 / H100 不受影响。要测 Blackwell 请升级到 CUDA 12.8+。\n'
fi

command -v g++ >/dev/null || die "缺少 g++，执行: sudo apt-get install -y build-essential"

CUDA_LIB="$CUDAPATH/targets/x86_64-linux/lib"
[[ -d "$CUDA_LIB" ]] || CUDA_LIB="$CUDAPATH/lib64"
[[ -d "$CUDA_LIB" ]] || die "找不到 CUDA 库目录（试过 targets/x86_64-linux/lib 和 lib64）"

# ---------------------------------------------------------------- 取源码
mkdir -p "$(dirname "$SRC_DIR")"
if [[ -d "$SRC_DIR/.git" ]]; then
  info "复用已有源码 $SRC_DIR"
  git -C "$SRC_DIR" pull --ff-only >/dev/null 2>&1 || info "（拉取更新失败，用本地版本继续）"
else
  info "克隆 gpu-burn ..."
  rm -rf "$SRC_DIR"
  git clone --depth 1 "$GPU_BURN_REPO" "$SRC_DIR" \
    || die "克隆失败。可手动下载 https://github.com/wilicc/gpu-burn 解压到 $SRC_DIR 后重跑"
fi

# ---------------------------------------------------------------- 编译
info "编译（COMPUTE=$COMPUTE）..."
make -C "$SRC_DIR" clean >/dev/null 2>&1 || true
make -C "$SRC_DIR" COMPUTE="$COMPUTE" CUDAPATH="$CUDAPATH" \
  || die "编译失败，检查上面的 nvcc/g++ 报错"

# 上游早些年产出的是 compare.ptx，现在换成了 compare.fatbin
# （Makefile 里是 `nvcc -arch=compute_NN -fatbin compare.cu -o compare.fatbin`）。
# 两个名字都认一下，免得上游再改回去或者有人用老版本源码。
COMPARE=""
for c in compare.fatbin compare.ptx; do
  [[ -f "$SRC_DIR/$c" ]] && { COMPARE="$c"; break; }
done
[[ -n "$COMPARE" ]] || die "编译完成但没找到 compare.fatbin / compare.ptx"
[[ -f "$SRC_DIR/gpu_burn-drv.o" ]] || die "编译完成但没找到 gpu_burn-drv.o"

# ---------------------------------------------------------------- 静态链接
#
# 为什么非要静态链接：gpu-burn 的 Makefile 默认动态链 -lcublas -lcudart，
# 而这两个库来自 CUDA Toolkit、**不在显卡驱动里**，测试盘上根本没有；
# 而且它还往二进制里硬编了 -Wl,-rpath=<构建机的CUDA路径>。直接打包出来的盘
# 一跑就是 `error while loading shared libraries: libcublas.so.12`，
# 然后被判成"gpu_burn 异常退出 -> 显卡故障"，纯粹的误杀。
#
# 随盘带 .so 也能解决，但 libcublasLt.so 一个就 717MB。
# 改成"裁剪静态库 + 静态链接"之后是一个 300MB 出头的自包含二进制，
# 少一半体积，还不用操心 rpath。
# libcuda 仍然是动态链接的 —— 它属于显卡驱动，必须用目标机器上那一份。
info "裁剪 cuBLAS 静态库（保留 sm_${GPU_ARCHS// /, sm_}）..."
mkdir -p "$TMP_DIR"
NVPRUNE="$CUDAPATH/bin/nvprune"
ARCH_ARGS=()
for a in $GPU_ARCHS; do ARCH_ARGS+=("--arch=sm_$a"); done

LINK_L="$TMP_DIR"
for a in libcublas_static.a libcublasLt_static.a; do
  [[ -f "$CUDA_LIB/$a" ]] || die "缺少 $CUDA_LIB/$a（需要 libcublas-dev 包）"
  if [[ -x "$NVPRUNE" ]] && "$NVPRUNE" "${ARCH_ARGS[@]}" "$CUDA_LIB/$a" -o "$TMP_DIR/$a" 2>/dev/null; then
    printf '    %-24s %5d MB -> %4d MB\n' "$a" \
      "$(( $(stat -c %s "$CUDA_LIB/$a") / 1048576 ))" \
      "$(( $(stat -c %s "$TMP_DIR/$a") / 1048576 ))"
  else
    warn "$a 裁剪失败，原样使用（二进制会大不少）"
    cp "$CUDA_LIB/$a" "$TMP_DIR/$a"
  fi
done
# cudart_static 只有 1MB，不值得裁；而且 nvprune 会把它的 device code 全剥掉
cp "$CUDA_LIB/libcudart_static.a" "$TMP_DIR/" 2>/dev/null || true

info "静态链接 ..."
g++ -o "$TMP_DIR/gpu_burn" "$SRC_DIR/gpu_burn-drv.o" -O3 \
    -L"$LINK_L" -L"$CUDA_LIB" -L"$CUDA_LIB/stubs" \
    -lcublas_static -lcublasLt_static -lcudart_static -lculibos \
    -lcuda -lpthread -ldl -lrt \
  || die "静态链接失败"
strip "$TMP_DIR/gpu_burn" 2>/dev/null || true

# 自检：除了 libcuda 和系统库，不该再动态依赖任何 CUDA 库，
# 否则出盘照样是 "error while loading shared libraries"。
if ldd "$TMP_DIR/gpu_burn" 2>/dev/null | grep -qE 'libcublas|libcudart'; then
  ldd "$TMP_DIR/gpu_burn" | sed 's/^/    /'
  die "静态链接没生效，二进制仍然动态依赖 cuBLAS/cudart —— 这样出盘一定跑不起来"
fi

# ---------------------------------------------------------------- 安装到 vendor
mkdir -p "$OUT_DIR"
# 先清掉旧产物：以前的版本会往这里放 libcublas*.so，留着白占几百 MB 进 ISO
rm -f "$OUT_DIR"/libcublas*.so* "$OUT_DIR"/libcudart*.so* \
      "$OUT_DIR/gpu_burn" "$OUT_DIR/compare.ptx" "$OUT_DIR/compare.fatbin"
install -m 0755 "$TMP_DIR/gpu_burn"    "$OUT_DIR/gpu_burn"
install -m 0644 "$SRC_DIR/$COMPARE"    "$OUT_DIR/$COMPARE"

info "完成："
ls -la "$OUT_DIR"
printf '\n'
info "compare 文件: $COMPARE"
info "PTX 基线: compute_${COMPUTE}（更新的架构由驱动 JIT）"
info "cuBLAS 保留架构: sm_${GPU_ARCHS// /, sm_}"
info "下一步: sudo ./build/build-iso.sh --with-nvidia"
