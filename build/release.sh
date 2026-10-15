#!/usr/bin/env bash
# 成对构建与验收 full/mem；在已测试并提交的干净 x86_64 Ubuntu checkout 中执行。
# sudo KLBURN_WORK=/srv/klburn/work ./build/release.sh [--mutate] [--memory-mb 4096]
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PROJ_DIR="$PWD"
MUTATE=0
MEM_MB=4096
while (( $# )); do
  case "$1" in
    --mutate) MUTATE=1; shift ;;
    --memory-mb) MEM_MB="${2:?缺少内存参数}"; shift 2 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$EUID" == 0 && "$(uname -m)" == x86_64 ]] || { echo '需要 x86_64 Ubuntu 与 root'; exit 1; }
[[ "${KLBURN_WORK:-}" == /* && "$KLBURN_WORK" != / ]] || { echo '必须指定绝对路径 KLBURN_WORK'; exit 1; }
[[ "$MEM_MB" =~ ^[0-9]+$ ]] && (( MEM_MB >= 4096 )) || { echo '完整发布验收的 QEMU 内存至少为 4096 MB'; exit 2; }
command -v shellcheck >/dev/null || { echo '缺少 shellcheck，不能把跳过 lint 当成通过'; exit 1; }
for tool in readelf modinfo python3 qemu-system-x86_64; do
  command -v "$tool" >/dev/null || { echo "缺少发布验收工具 $tool"; exit 1; }
done
git_cmd() { git -c "safe.directory=$PROJ_DIR" "$@"; }
COMMIT="$(git_cmd rev-parse HEAD)"
SHORT_COMMIT="$(git_cmd rev-parse --short HEAD)"
clean_source() {
  [[ "$(git_cmd rev-parse HEAD)" == "$COMMIT" && -z "$(git_cmd status --porcelain)" ]] \
    || { echo '源码必须保持已提交且干净，不能边构建边修改'; exit 1; }
}
clean_source
# shellcheck source=config.sh
source build/config.sh
VERSION="$KLBURN_VERSION"
if git_cmd rev-parse --verify "refs/tags/v$VERSION" >/dev/null 2>&1; then
  echo "v$VERSION 已存在，不能覆盖已发布版本"; exit 1
fi
python3 - <<'PY'
import hashlib,pathlib,re
root=pathlib.Path('vendor').resolve();manifest=root/'full-vendor.sha256'
if not manifest.is_file() or not manifest.stat().st_size:
    raise SystemExit('缺少 vendor/full-vendor.sha256；先恢复并核对整机版离线组件')
entries={}
for line in manifest.read_text().splitlines():
    if not line.strip() or line.startswith('#'):continue
    match=re.fullmatch(r'([0-9a-f]{64})  (.+)',line)
    if not match:raise SystemExit('离线组件清单格式无效')
    digest,name=match.groups();path=root/name
    if not path.resolve().is_relative_to(root) or not path.is_file():
        raise SystemExit('离线组件文件缺失或路径无效')
    actual=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):actual.update(chunk)
    if actual.hexdigest()!=digest:raise SystemExit('离线组件校验失败：'+name)
    entries[name]=digest
required=('gpu_burn/gpu_burn','gpu_burn/compare.fatbin','storcli/storcli64',
          'bench/mlc/mlc','bench/linpack/xlinpack_xeon64','bench/cpuflops/klburn_flops',
          'bench/opendcdiag/opendcdiag','bench/cuda-samples/bandwidthTest',
          'bench/cuda-samples/p2pBandwidthLatencyTest',
          'gpu_burn/LICENSE','gpu_burn/SOURCE-COMMIT.txt','bench/cuda-samples/LICENSE',
          'bench/opendcdiag/LICENSE','bench/opendcdiag/LICENSE.3rdparty',
          'bench/opendcdiag/COPYRIGHT.zlib1g','bench/opendcdiag/COPYRIGHT.libzstd1')
if any(name not in entries for name in required):raise SystemExit('整机版工具清单不完整')
drivers=list(root.glob('nvidia/NVIDIA-Linux-x86_64-*.run'))
if len(drivers)!=1 or str(drivers[0].relative_to(root)) not in entries:
    raise SystemExit('发布必须明确且校验唯一 NVIDIA 安装包')
print('整机离线组件校验通过：',len(entries),'个文件')
PY
EVIDENCE="$PROJ_DIR/out/release-$VERSION"
[[ ! -e "$EVIDENCE/manifest.json" ]] || { echo '已有完成的发布收据，不能覆盖'; exit 1; }
mkdir -p "$EVIDENCE"
cp vendor/full-vendor.sha256 "$EVIDENCE/full-vendor.sha256"
./tests/run-all.sh 2>&1 | tee "$EVIDENCE/run-all.log"
if (( MUTATE )); then
  ./tests/mutate.sh 2>&1 | tee "$EVIDENCE/mutate.log"
fi
for edition in full mem; do
  clean_source
  mkdir -p "$EVIDENCE/$edition"
  ./build/build-iso.sh --edition "$edition" 2>&1 | tee "$EVIDENCE/$edition/build.log"
  conf="$KLBURN_WORK/rootfs/opt/klburn/klburn.conf"
  grep -qx "KLBURN_VERSION=\"$VERSION\"" "$conf"
  grep -qx "GIT_COMMIT=\"$SHORT_COMMIT\"" "$conf"
  grep -qx "KLBURN_EDITION=\"$edition\"" "$conf"
  cp "$conf" "$EVIDENCE/$edition/klburn.conf"
  chroot "$KLBURN_WORK/rootfs" dpkg-query -W \
    -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' > "$EVIDENCE/$edition/packages.tsv"
  # 从构建日志取得本轮确切产物，不按 mtime 挑旧 ISO。
  iso_name="$(sed -n 's/^  ISO      : out\///p' "$EVIDENCE/$edition/build.log" | tail -1)"
  iso="$PROJ_DIR/out/$iso_name"
  [[ -n "$iso_name" && -s "$iso" && -s "$iso.sha256" ]]
  printf '%s\n' "$iso_name" > "$EVIDENCE/$edition/iso-name.txt"
  ./tests/check-firmware.sh 2>&1 | tee "$EVIDENCE/$edition/firmware.log"
  ./tests/e2e-qemu.sh --edition "$edition" --iso "$iso" --stage smoke \
    --memory-mb "$MEM_MB" --workdir "$KLBURN_WORK/e2e-$VERSION-$edition-smoke" --keep \
    2>&1 | tee "$EVIDENCE/$edition/smoke.log"
  if [[ "$edition" == full ]]; then
    ./tests/e2e-qemu.sh --iso "$iso" --stage full --disk-stress \
      --memory-mb "$MEM_MB" --workdir "$KLBURN_WORK/e2e-$VERSION-full-disk-stress" --keep \
      2>&1 | tee "$EVIDENCE/full/disk-stress.log"
  fi
done
clean_source
python3 - "$EVIDENCE" "$VERSION" "$COMMIT" "$MEM_MB" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);artifacts={}
for edition in ('full','mem'):
    name=(root/edition/'iso-name.txt').read_text().strip()
    path=root.parent/name
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):digest.update(chunk)
    assert digest.hexdigest()==path.with_suffix('.iso.sha256').read_text().strip()
    artifacts[edition]={'file':name,'bytes':path.stat().st_size,'sha256':digest.hexdigest()}
vendors={line[66:]:line[:64] for line in (root/'full-vendor.sha256').read_text().splitlines()
         if line and not line.startswith('#')}
receipt={'version':sys.argv[2],'commit':sys.argv[3],'qemu_memory_mb':int(sys.argv[4]),
         'vendor_sha256':vendors,
         'artifacts':artifacts,'physical_hardware_acceptance':'NOT_RUN'}
(root/'manifest.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
PY
{
  printf '%s：full/mem 成对构建与真机报告修复\n\n' "$VERSION"
  for log in run-all.log mutate.log full/firmware.log full/smoke.log full/disk-stress.log mem/firmware.log mem/smoke.log; do
    [[ -f "$EVIDENCE/$log" ]] || continue
    printf '%s: ' "$log"
    grep -E '^合计通过 [0-9]+ 项|^通过 [0-9]+ 项|^抓住 [0-9]+ 条' "$EVIDENCE/$log" | tail -1
  done
  printf '\ncommit %s；QEMU %s MB；真机验收 NOT_RUN；明细 out/release-%s\n' "$COMMIT" "$MEM_MB" "$VERSION"
} > "$EVIDENCE/tag-message.txt"
git_cmd tag -a "v$VERSION" -F "$EVIDENCE/tag-message.txt"
printf '完成 v%s；两张 ISO、校验文件和验收收据在 %s/out/\n' "$VERSION" "$PROJ_DIR"
