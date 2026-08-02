#!/usr/bin/env bash
#
# 压测日志判读的回归测试。不需要任何硬件，随时可跑：
#
#     ./tests/test-log-parsing.sh
#
# 为什么专门给这块写测试：
# stressapptest / stress-ng / gpu_burn 正常跑完的日志里，本身就含有
#   "Found 0 hardware incidents"、"errors: 0"、"failed: 0"
# 这些字样。早期版本用 grep -q '关键字' 判定，结果是**每一台好机器都被判 FAIL**，
# 而且只有在真机上跑满一轮才会发现。下面的样本全部取自真实日志。
#
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rootfs/opt/klburn/lib" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 这两个文件里除了纯函数还有依赖运行时全局变量的代码，
# 但 source 时不会执行到那些地方，可以安全引入。
RAW_DIR="$TMP"; RUN_DIR="$TMP"
# shellcheck source=/dev/null
source "$LIB/stress.sh"
# shellcheck source=/dev/null
source "$LIB/gpu.sh"

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n     期望 [%s] 实际 [%s]\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); }
check(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$2" "$3"; }

# 断言函数名打错不能静悄悄地过去（§11-13"断言悄悄停止计数"的同款病）：
# 本脚本不开 set -e，`xxx: command not found` 只往 stderr 打一行就没了，
# PASS/FAIL 都不动 —— 屏幕照样"全部通过"，只是少跑了几条。实测踩到过一次。
command_not_found_handle() {
  # ⚠️ 这里**不能**写 FAIL=$((FAIL+1))。bash 是在 fork 出来的子进程里执行这个
  #    handler 的，加了也加不到父进程头上 —— 屏幕上红一条，最后那行汇总却还是
  #    "失败 0 项"，正好是本项目最恨的那种"屏幕全绿"。（实测踩过。）
  #    所以直接把整个套件干掉，让退出码非零、run-all 能看见。
  printf "  \033[31mFAIL\033[0m 调用了不存在的命令 %s —— 多半是断言函数名打错了，\n" "$1"
  printf "       这条断言根本没跑。中止本套件。\n"
  kill -TERM $$
  return 127
}

# ================================================================
echo "=== stressapptest 日志判读 ==="

cat > "$TMP/sat-pass.log" <<'EOF'
2026/07/29-11:19:33(UTC) Log: Region mask: 0x1
2026/07/29-11:22:33(UTC) Stats: Found 0 hardware incidents
2026/07/29-11:22:33(UTC) Stats: Completed: 6046110.00M in 180.02s 33585.68MB/s, with 0 hardware incidents, 0 errors
2026/07/29-11:22:33(UTC) Stats: Memory Copy: 6046110.00M at 33588.47MB/s
2026/07/29-11:22:33(UTC) Status: PASS - please verify no corrected errors
EOF
check "正常跑完（含 'Found 0 hardware incidents' 字样）应判 PASS" \
      "0 0 PASS" "$(mem_parse_stressapptest "$TMP/sat-pass.log")"

cat > "$TMP/sat-fail.log" <<'EOF'
2026/07/29-11:20:01(UTC) Hardware Error: miscompare on CPU 3(0x12345): read:0xffff, reread:0xffff expected:0x0000
2026/07/29-11:22:33(UTC) Stats: Found 7 hardware incidents
2026/07/29-11:22:33(UTC) Stats: Completed: 6046110.00M in 180.02s 33585.68MB/s, with 7 hardware incidents, 3 errors
2026/07/29-11:22:33(UTC) Status: FAIL - errors detected
EOF
check "真有内存错误应判出 7 异常 / 3 错误 / FAIL" \
      "7 3 FAIL" "$(mem_parse_stressapptest "$TMP/sat-fail.log")"

cat > "$TMP/sat-trunc.log" <<'EOF'
2026/07/29-11:19:33(UTC) Log: Starting
EOF
check "日志被截断（进程被杀）不应误判出错误数" \
      "0 0 UNKNOWN" "$(mem_parse_stressapptest "$TMP/sat-trunc.log")"

: > "$TMP/sat-empty.log"
check "空日志不崩、全部归零" \
      "0 0 UNKNOWN" "$(mem_parse_stressapptest "$TMP/sat-empty.log")"

# ================================================================
echo
echo "=== stress-ng 日志判读 ==="

cat > "$TMP/ng-pass.log" <<'EOF'
stress-ng: info:  [1387] dispatching hogs: 4 cpu
stress-ng: info:  [1387] passed: 4: cpu (4)
stress-ng: info:  [1387] failed: 0
stress-ng: info:  [1387] metrics untrustworthy: 0
stress-ng: info:  [1387] successful run completed in 4 mins, 0.01 secs
EOF
check "正常跑完（含 'failed: 0' 字样）应判出 0" \
      "0" "$(ng_parse_failed "$TMP/ng-pass.log")"

cat > "$TMP/ng-fail.log" <<'EOF'
stress-ng: info:  [1387] passed: 2: cpu (2)
stress-ng: info:  [1387] failed: 2: cpu (2)
EOF
check "真有压测项失败应判出 2" \
      "2" "$(ng_parse_failed "$TMP/ng-fail.log")"

# ================================================================
echo
echo "=== gpu_burn 日志判读 ==="

cat > "$TMP/burn-ok.log" <<'EOF'
Burning for 360 seconds.
10.0%  proc'd: 1024 (12345 Gflop/s) - 1024 (12300 Gflop/s)   errors: 0 - 0   temps: 62 C - 64 C
50.0%  proc'd: 5120 (12350 Gflop/s) - 5120 (12310 Gflop/s)   errors: 0 - 0   temps: 71 C - 73 C
100.0%  proc'd: 10240 (12340 Gflop/s) - 10240 (12305 Gflop/s)   errors: 0 - 0   temps: 74 C - 76 C
Killing processes.. done
Tested 2 GPUs:
	GPU 0: OK
	GPU 1: OK
EOF
check "两张好卡（每行都带 'errors: 0'）应判出 0 故障 0 错误" \
      "0 0" "$(gpu_parse_burn_log "$TMP/burn-ok.log")"

cat > "$TMP/burn-bad.log" <<'EOF'
100.0%  proc'd: 10240 (12340 Gflop/s) - 10240 (11000 Gflop/s)   errors: 0 - 14   temps: 74 C - 88 C
Killing processes.. done
Tested 2 GPUs:
	GPU 0: OK
	GPU 1: FAULTY
EOF
check "一张坏卡应判出 1 故障 14 错误" \
      "1 14" "$(gpu_parse_burn_log "$TMP/burn-bad.log")"

: > "$TMP/burn-empty.log"
check "空日志不崩、全部归零" \
      "0 0" "$(gpu_parse_burn_log "$TMP/burn-empty.log")"

# ================================================================
echo
echo "=== 被 OOM killer 打死绝不能当成硬件故障 ==="
# 0.7.0 现场真事：内存压测目标容量取得太满，跑到第 9 分钟被 OOM killer 打死
#     Out of memory: Killed process 4168 (stressapptest) anon-rss:28397568kB
# 退出码 137，旧代码直接判 FAIL「测试进程异常退出」——
# 一台完全正常的机器就这么被拦在出货前。
# 这是本项目最忌讳的一类错误：**把好机器拦在出货前比漏判更糟**。

cat > "$TMP/dmesg-oom.txt" <<'EOF'
[  600.123456] stressapptest invoked oom-killer: gfp_mask=0x140cca(GFP_HIGHUSER_MOVABLE|__GFP_COMP), order=0
[  609.539575] Out of memory: Killed process 4168 (stressapptest) total-vm:29736252kB, anon-rss:28397568kB, file-rss:2048kB, shmem-rss:0kB, UID:0 pgtables:55780kB oom_score_adj:0
EOF
cat > "$TMP/dmesg-clean.txt" <<'EOF'
[    8.680607] EXT4-fs (sda1): mounted filesystem with ordered data mode
[  609.539575] nvidia-nvlink: Nvlink Core is being initialized
EOF

check "退出码 137 且 dmesg 里有 OOM 记录 -> 认定为 OOM" \
      "yes" "$(oom_killed 137 "$TMP/dmesg-oom.txt" && echo yes || echo no)"
# 读不到 dmesg 时也要按 OOM 处理：宁可少判一次，也绝不能把 SIGKILL 当成内存故障
check "退出码 137 但 dmesg 读不到 -> 仍按 OOM 处理（不许误判成故障）" \
      "yes" "$(oom_killed 137 "$TMP/no-such-file.txt" && echo yes || echo no)"
# 反向：正常退出和其它错误码不能被当成 OOM，否则真故障就被掩盖了
check "退出码 0 不是 OOM" \
      "no" "$(oom_killed 0 "$TMP/dmesg-oom.txt" && echo yes || echo no)"
check "退出码 1（工具自己报错）不是 OOM，该判故障还得判" \
      "no" "$(oom_killed 1 "$TMP/dmesg-oom.txt" && echo yes || echo no)"
check "退出码 134（SIGABRT）不是 OOM" \
      "no" "$(oom_killed 134 "$TMP/dmesg-clean.txt" && echo yes || echo no)"

# 判定分支的顺序：OOM 必须排在"异常退出"前面，否则又会被当成故障
mem_chain="$(declare -f stress_mem)"
check "stress_mem 里 OOM 判定必须排在「异常退出」判定之前" \
      "yes" \
      "$(if [[ "$(grep -n 'oom_killed' <<<"$mem_chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'rc != 0' <<<"$mem_chain" | tail -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
gpu_chain="$(declare -f gpu_stress)"
check "gpu_stress 里 OOM 判定必须排在「异常退出」判定之前" \
      "yes" \
      "$(if [[ "$(grep -n 'oom_killed' <<<"$gpu_chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'rc != 0' <<<"$gpu_chain" | tail -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "OOM 分支必须判 WARN，不许判 FAIL" \
      "yes" \
      "$(if grep -A3 'oom_killed' <<<"$mem_chain" | grep -q 'ST_WARN'; \
         then echo yes; else echo no; fi)"

# ================================================================
echo
echo "=== 显卡驱动与显卡不匹配：绝不能判成「卡坏了」==="
# 这是把好卡说成坏卡的最短路径：驱动版本旧了认不到新卡，nvidia-smi 一张都读不到，
# 而老代码只看"读不到 = FAIL（显卡/供电/插槽异常）"。NVRM 其实在内核日志里
# 明说了是驱动不支持 —— 判据就在这几行原话里。样本是 NVIDIA 驱动源码里的固定串。

cat > "$TMP/nvrm-unsupported.txt" <<'EOF'
[   12.001] nvidia: loading out-of-tree module taints kernel.
[   12.334] NVRM: The NVIDIA GPU 0000:c9:00.0 (PCI ID: 10de:2bb1)
[   12.334] NVRM: installed in this system is not supported by the NVIDIA
[   12.334] NVRM: 550.54.14 driver release.
[   12.335] NVRM: Please see 'Supported NVIDIA GPU Products' in this release's README
[   12.401] NVRM: The NVIDIA probe routine was not called for 1 device(s).
EOF

cat > "$TMP/nvrm-open-unsupported.txt" <<'EOF'
[   10.100] NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:1b06)
[   10.100] NVRM: installed in this system is not supported by open nvidia.ko.
EOF

cat > "$TMP/nvrm-none.txt" <<'EOF'
[   11.000] NVRM: No NVIDIA GPU found.
EOF

# 负样本：卡是真的挂了 —— 驱动加载正常，只是设备掉了/供电不上。
# 这份日志里一条"不支持"都没有，必须继续判 FAIL。
cat > "$TMP/nvrm-dead-card.txt" <<'EOF'
[   12.001] nvidia: loading out-of-tree module taints kernel.
[   13.552] NVRM: GPU 0000:c9:00.0: RmInitAdapter failed! (0x26:0xffff:1479)
[   13.552] NVRM: GPU 0000:c9:00.0: rm_init_adapter failed, device minor number 0
[   14.010] pcieport 0000:c8:00.0: AER: Uncorrected (Fatal) error received
EOF

check "驱动版本不支持这张卡 -> 认出是不匹配" "1" \
      "$(gpu_scan_driver_mismatch "$TMP/nvrm-unsupported.txt" | grep -c 'not supported by the NVIDIA')"
check "open 模块不支持这张卡 -> 也算不匹配" "1" \
      "$(gpu_scan_driver_mismatch "$TMP/nvrm-open-unsupported.txt" | grep -c 'not supported by open')"
check "NVRM 报 No NVIDIA GPU found -> 算不匹配" "1" \
      "$(gpu_scan_driver_mismatch "$TMP/nvrm-none.txt" | grep -c 'No NVIDIA GPU found')"
check "卡真挂了的日志里一条不匹配证据都不许有（否则会漏判故障卡）" "0" \
      "$(gpu_scan_driver_mismatch "$TMP/nvrm-dead-card.txt" | grep -c . || true)"
check "干净日志不误报" "0" \
      "$(gpu_scan_driver_mismatch "$TMP/sat-pass.log" | grep -c . || true)"
check "文件不存在时不崩、也不误报" "0" \
      "$(gpu_scan_driver_mismatch "$TMP/no-such-file.txt" | grep -c . || true)"

# 逐卡 PCI 地址要抠得出来：认不到的卡数能不能被"不支持"解释掉，全靠这个数
check "从 NVRM 原话里抠出不受支持的卡的 PCI 地址" "0000:c9:00.0" \
      "$(gpu_mismatch_devices "$TMP/nvrm-unsupported.txt")"
check "同一张卡刷屏多次也只算一张" "1" \
      "$(gpu_mismatch_devices "$TMP/nvrm-unsupported.txt" | grep -c .)"

# 判定分支本身：不匹配走 SKIP，没有证据才走 FAIL
gd_chain="$(declare -f gpu_detect)"
check "gpu_detect 必须在判 FAIL 之前先查一次不匹配" "yes" \
      "$(if [[ "$(grep -n 'gpu_scan_driver_mismatch' <<<"$gd_chain" | head -1 | cut -d: -f1)" \
               -lt "$(grep -n 'ST_FAIL' <<<"$gd_chain" | head -1 | cut -d: -f1)" ]]; \
         then echo yes; else echo no; fi)"
check "不匹配那条分支判的必须是 SKIP" "yes" \
      "$(if grep -A6 'GPU_MISMATCH=1' <<<"$gd_chain" | grep -q 'ST_SKIP'; \
         then echo yes; else echo no; fi)"

# ---------------------------------------------------------------- 端到端跑一遍 gpu_detect
#
# 上面几条验的是"零件对不对"（判读函数、分支顺序）。这一组把 gpu_detect 整个
# 跑一遍，直接断言**最终结论**——零件都对、装起来错了的事这个项目发生过
# （gpu_stress 那次判定函数还在、只是再没被调用过）。
#
# 1.7.0 特别要守这条：这一版明确决定**只带 open 内核模块**（GSP，Turing 及以后），
# 而 open 模块遇到 Maxwell/Pascal/Volta 这些没有 GSP 的老卡时，
# NVRM 打的就是 "not supported by open nvidia.ko"。那种情况必须判 SKIP ——
# 那是我们这张盘的驱动分支覆盖不到，跟客户的卡好不好毫无关系。
RAW_DIR="$TMP/gpudetect"; RUN_DIR="$TMP/gpudetect"; mkdir -p "$RAW_DIR"

# ⚠️ 整个替身环境必须关在**子 shell** 里。gpu_detect 会调 ok()/info()/warn()，
# 而本套件自己的断言助手也叫 ok() —— 在当前 shell 里把它们改成空函数，
# 后面所有 check 就都不再计数了（§11-13：屏幕全绿、总数悄悄少一截）。
# 第一版就是这么写的，结果整个套件从这里往下静默失效。
# 子 shell 里改函数不会漏回来，结论用文件带出来。
run_gpu_detect() {   # run_gpu_detect <dmesg样本> -> 结论写进 $TMP/gd.*
  local fixture="$1"
  (
    # 本套件只 source 了 stress.sh / gpu.sh（故意不 source core.sh —— 它里面的
    # ok()/info() 会把断言助手顶掉）。但 gpu_detect 要用四态常量，
    # 而本脚本是 set -u：不补上这四个，子 shell 会在第一次 result_add 之前
    # 就以 "unbound variable" 静默退出，表现成"结论是空的"。
    ST_PASS="PASS"; ST_FAIL="FAIL"; ST_SKIP="SKIP"; ST_WARN="WARN"
    INCLUDE_NVIDIA=1
    KLB_TOOLS="$TMP/tools"; mkdir -p "$KLB_TOOLS"
    GPU_PRESENT=0; GPU_USABLE=0; GPU_MISMATCH=0

    ok() { :; }; info() { :; }; warn() { :; }; dbg() { :; }
    metric_add() { :; }
    modprobe() { return 0; }
    sleep() { :; }
    have() { [[ "$1" == "nvidia-smi" ]]; }
    result_add() {
      printf '%s' "$3" > "$TMP/gd.status"
      printf '%s' "$4" > "$TMP/gd.detail"
    }
    # lspci 报 2 张卡；nvidia-smi 一张都认不到
    lspci() { printf '%s\n' \
      'c9:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP102 [10de:1b06]' \
      'ca:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP102 [10de:1b06]'; }
    nvidia-smi() { return 1; }
    # capture 的替身：把准备好的 dmesg 放到 gpu_detect 要读的那个文件里
    capture() {
      local out="$1"
      [[ "$out" == "-t" ]] && { shift 2; out="$1"; }
      if [[ "$out" == "gpu-modprobe-error.txt" ]]; then
        cp "$fixture" "$RAW_DIR/gpu-modprobe-error.txt"
      else
        : > "$RAW_DIR/$out"
      fi
      return 0
    }

    : > "$TMP/gd.status"; : > "$TMP/gd.detail"
    gpu_detect >/dev/null 2>&1
    printf '%s' "$GPU_MISMATCH" > "$TMP/gd.mismatch"
  )
}

run_gpu_detect "$TMP/nvrm-open-unsupported.txt"
check "两张老卡 + open 模块报不支持 -> SKIP（不是 FAIL）" "SKIP" "$(cat "$TMP/gd.status")"
check "文案必须写明不影响整机结论" "1" \
      "$(grep -c '不影响整机结论' "$TMP/gd.detail" || true)"
check "而且要留下不匹配的标志，供内部报告解释" "1" "$(cat "$TMP/gd.mismatch")"

# 反面：同样是一张卡都认不到，但内核日志里没有任何"不支持"的证据 ——
# 那就是卡真的坏了 / 供电插槽有问题，必须判 FAIL，不能被上面那条放过。
run_gpu_detect "$TMP/nvrm-dead-card.txt"
check "认不到卡且没有不匹配证据 -> FAIL（别让坏卡混过去）" "FAIL" "$(cat "$TMP/gd.status")"
check "不匹配的文案里不许把原因说成硬件异常" "0" \
      "$(grep -A8 'GPU_MISMATCH=1' <<<"$gd_chain" | grep -cE '故障|异常|损坏' || true)"

# ================================================================
echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
