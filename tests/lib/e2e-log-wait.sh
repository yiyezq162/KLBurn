#!/usr/bin/env bash
# Read completed log anchors from an image without mounting a running VM's disk.
image_has() {
  # 二进制镜像没有可靠行边界；分块扫描避免 grep -a 为长行分配 GB 内存。
  python3 - "$IMG" "$1" <<'PY'
import sys
needle=sys.argv[2].encode();tail=b''
with open(sys.argv[1],'rb') as stream:
    for chunk in iter(lambda:stream.read(1024*1024),b''):
        data=tail+chunk
        if needle in data:sys.exit(0)
        tail=data[-(len(needle)-1):] if len(needle)>1 else b''
sys.exit(1)
PY
}

require_absent_log_anchor() {
  if image_has "$1"; then
    info '完成信号在启动前已存在，拒绝把旧字节当成本轮完成'
    return 1
  fi
}

wait_for_log() {
  local needle="$1" limit="$2" label="${3:-$1}" start now
  start="$(date +%s)"
  while :; do
    now="$(date +%s)"
    (( now - start >= limit )) && break
    kill -0 "$QEMU_PID" 2>/dev/null || { info "等「$label」时虚拟机已经退出"; return 1; }
    if image_has "$needle"; then
      info "看到「$label」（第 $(( now - start ))s）"
      return 0
    fi
    sleep 3
  done
  info "等了 ${limit}s 也没等到「$label」"
  return 1
}

wait_for_mem_report() {
  local limit="${1:-900}"
  if wait_for_log 'Report PDF written' "$limit" '内存压测及 HTML/CSV/PDF 报告生成完成'; then
    ok '内存盘实际写出 PDF 后才结束等待（仍须检查全部报告与判定）'
    shot 'mem-complete'
  else
    bad '内存报告完成信号未出现；保留现场，不能把固定等待时长当成完成'
    return 1
  fi
}
