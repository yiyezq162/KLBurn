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
# shellcheck source=/dev/null
source "$LIB/core.sh"
# shellcheck source=/dev/null
source "$LIB/conformance.sh"
# shellcheck source=/dev/null
source "$LIB/bench.sh"

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
echo "=== 显卡中途掉线：gpu_burn 说 OK 也不算数 ==="
#
# 1.7.8 现场那台 RTX 5090 开测第 20 秒掉下 PCIe 总线，跑满一小时依旧判 PASS、
# 零告警。事后翻数据，能区分好坏的证据有三条，**gpu_burn 自己的结论不在其中**：
# 好机器和坏机器最后都打 "GPU 0: OK"。下面钉的就是那三条。

# ---- 采样统计：有效行 = 真读到了一块卡 ----
cat > "$TMP/gm-good.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb
02:18:03,0,NVIDIA GeForce RTX 5090,36,64.45,1747,2,0
02:18:10,0,NVIDIA GeForce RTX 5090,71,412.15,2542,99,28935
02:18:18,0,NVIDIA GeForce RTX 5090,78,453.12,2542,100,28935
EOF
check "全是正常读数时，有效采样 = 总采样" "3 3" "$(gpu_sample_stats "$TMP/gm-good.csv")"

# 真实样本的原样：掉线后 nvidia-smi 每次只吐一句错误，连列都凑不齐
cat > "$TMP/gm-lost.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb
02:18:03,0,NVIDIA GeForce RTX 5090,36,64.45,1747,2,0
02:18:18,0,NVIDIA GeForce RTX 5090,36,67.12,2542,4,28935
02:18:23,No devices were found
02:18:28,No devices were found
02:18:33,No devices were found
EOF
check "掉线后的行不算有效采样" "5 2" "$(gpu_sample_stats "$TMP/gm-lost.csv")"

# 换一种错误文案也必须照样算作"没读到" —— 判据是正面的"这行是不是正常读数"，
# 不是去穷举 nvidia-smi 的错误措辞（措辞各版本不一样，穷举迟早漏）
cat > "$TMP/gm-lost2.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb
02:18:03,0,NVIDIA GeForce RTX 5090,36,64.45,1747,2,0
02:18:23,Unable to determine the device handle for GPU 0000:98:00.0: GPU is lost
02:18:28,NVIDIA-SMI has failed because it couldn't communicate with the driver
EOF
check "换一种掉线文案也算不到有效采样里" "3 1" "$(gpu_sample_stats "$TMP/gm-lost2.csv")"

: > "$TMP/gm-empty.csv"
check "空 csv 不崩" "0 0" "$(gpu_sample_stats "$TMP/gm-empty.csv")"
check "csv 根本不存在也不崩" "0 0" "$(gpu_sample_stats "$TMP/nope.csv")"

# ---- 进度停滞 ----
# gpu_burn 的进度是 \r 原地刷新的，整个日志常常只有"一行"。
printf 'Burning for 3600 seconds.\r' > "$TMP/burn-stall.log"
for _ in 1 2 3 4 5; do
  printf "50.0%%  proc'd: 109 (28477 Gflop/s)   errors: 0   temps: 55 C \r" >> "$TMP/burn-stall.log"
done
printf '\nTested 1 GPUs:\n\tGPU 0: OK\n' >> "$TMP/burn-stall.log"
check "卡掉线后进度纹丝不动 -> 只有 1 个取值" "1" "$(gpu_burn_progress_steps "$TMP/burn-stall.log")"
check "而它的结尾照样是 OK（所以结尾判不了掉卡）" "0 0" \
      "$(gpu_parse_burn_log "$TMP/burn-stall.log")"

printf 'Burning for 3600 seconds.\r' > "$TMP/burn-move.log"
for n in 81 940 5231 18877 29241; do
  printf "50.0%%  proc'd: %s (28477 Gflop/s)   errors: 0   temps: 71 C \r" "$n" >> "$TMP/burn-move.log"
done
printf '\nTested 1 GPUs:\n\tGPU 0: OK\n' >> "$TMP/burn-move.log"
check "正常跑的日志进度一直在涨 -> 多个取值" "5" "$(gpu_burn_progress_steps "$TMP/burn-move.log")"

# 读不出进度时必须返回 0（= 不判）。**这条是红线**：认不出日志格式是我们
# 这边的能力问题，不能倒过来说客户的卡坏了。
printf 'some other tool output\nwith no progress lines\n' > "$TMP/burn-alien.log"
check "认不出进度格式时返回 0（交给上层不判，绝不当成掉卡）" "0" \
      "$(gpu_burn_progress_steps "$TMP/burn-alien.log")"
check "日志不存在时也返回 0" "0" "$(gpu_burn_progress_steps "$TMP/nope.log")"

# 计数为 0 时 grep -c 会「既打印 0 又返回 1」，写成 `|| printf 0` 就成了 "00"。
# core.sh 里 count_lines 那段注释记的就是这个坑，这里钉一条防止退回去。
check "返回值必须是干净的单个整数（不能是 '00'）" "1" \
      "$(printf '%s' "$(gpu_burn_progress_steps "$TMP/nope.log")" | grep -c '^0$')"

# ================================================================
echo
echo "=== 性能基准：显卡数据传输带宽（bandwidthTest）==="
#
# 单位随版本变：CUDA 11 的表头是 Bandwidth(MB/s)，CUDA 12 起是 Bandwidth(GB/s)。
# 照数字抄的话，同一台机器会时而"55 GB/s 达标"、时而"55000 GB/s"。

cat > "$TMP/bw-gb.log" <<'EOF'
[CUDA Bandwidth Test] - Starting...
Running on...

 Device 0: NVIDIA GeForce RTX 5090
 Quick Mode

 Host to Device Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   32000000			55.6

 Device to Host Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   32000000			57.1

 Device to Device Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   32000000			4380.2

Result = PASS
EOF
check "GB/s 表头：三个方向都取到" "55.60 57.10 4380.20" \
      "$(bw_parse_bandwidthtest "$TMP/bw-gb.log")"

# 同一份数据换成老版本的 MB/s 表头，解析结果必须完全一样
sed 's|Bandwidth(GB/s)|Bandwidth(MB/s)|; s|55\.6|55600|; s|57\.1|57100|; s|4380\.2|4380200|' \
  "$TMP/bw-gb.log" > "$TMP/bw-mb.log"
check "MB/s 表头要换算成 GB/s（否则同一台机器两个数量级）" "55.60 57.10 4380.20" \
      "$(bw_parse_bandwidthtest "$TMP/bw-mb.log")"

check "日志不存在时给 0，不能报错" "0.00 0.00 0.00" \
      "$(bw_parse_bandwidthtest "$TMP/nope-bw.log")"

echo
echo "=== 性能基准：显卡间互联带宽（P2P 矩阵）==="
cat > "$TMP/p2p.log" <<'EOF'
Device: 0, NVIDIA H100, pciBusID: 1b, pciDeviceID: 0, pciDomainID:0
Device: 1, NVIDIA H100, pciBusID: 3d, pciDeviceID: 0, pciDomainID:0

Unidirectional P2P=Enabled Bandwidth Matrix (GB/s)
   D\D     0      1
     0 1284.61  24.10
     1  24.11 1281.02

Bidirectional P2P=Enabled Bandwidth Matrix (GB/s)
   D\D     0      1
     0 1330.20  51.86
     1  51.42 1329.77

P2P=Enabled Latency Matrix (us)
   GPU     0      1
     0   2.10   1.90
EOF
# 对角线（1330 / 1329）是显存内部带宽，必须排掉；取的是 51.42 而不是 51.86
check "取双向矩阵里的最小值，且排掉对角线" "51.42" "$(p2p_parse_min_bw "$TMP/p2p.log")"

cat > "$TMP/p2p-1.log" <<'EOF'
Bidirectional P2P=Enabled Bandwidth Matrix (GB/s)
   D\D     0
     0 1330.20
EOF
check "只有一张卡时没有卡间带宽可言，输出空" "" "$(p2p_parse_min_bw "$TMP/p2p-1.log")"

echo
echo "=== 性能基准：CPU 浮点算力（LINPACK）==="
#
# ⚠️ 这份日志里有两张表头几乎一样的表，第一张的第 4 列是**秒**、第二张才是
#    GFlops。按固定列号取第 4 列的话，一台 3030 GFlops 的机器会被读成
#    "141.7 GFlops"，配上 3600 的门槛就是当场判 FAIL —— 好机器被拦在出货前。
# ⚠️ 这一份是 **xlinpack_xeon64（oneMKL 2025.3）真跑出来的原样输出**，
#    喂给它的输入文件就是 linpack_problem_size() 那套格式生成的。
#    它把这条判据要防的坑摆得明明白白：
#      计时表  第 4 列 = Time(s) = 0.529   <- 按列位置取就会拿到这个
#      汇总表  第 4 列 = Average = 79.1742 <- 这个才是算力
#    再配上一个 3600 的门槛，取错列就是一台好机器当场判 FAIL。
cat > "$TMP/linpack.log" <<'EOF'
Current date/time: Sun Aug  9 12:33:10 2026

CPU frequency:    5.389 GHz
Number of CPUs: 1
Number of cores: 24
Number of threads: 24

Parameters are set to:

Number of tests: 1
Number of equations to solve (problem size) : 4000
Leading dimension of array                  : 4000
Number of trials to run                     : 2
Data alignment value (in Kbytes)            : 4

Maximum memory requested that can be used=128084096, at the size=4000

=================== Timing linear equation system solver ===================

Size   LDA    Align. Time(s)    GFlops   Residual     Residual(norm) Check
4000   4000   4      0.529      80.7297  1.917971e-11 3.892786e-02   pass
4000   4000   4      0.550      77.6187  1.704567e-11 3.459653e-02   pass

Performance Summary (GFlops)

Size   LDA    Align.  Average  Maximal
4000   4000   4       79.1742  80.7297

Residual checks PASSED

End of tests
EOF
check "取的必须是 Average 列（不是计时表的 Time(s)，也不是 Maximal）" "79.1742 2" \
      "$(linpack_parse "$TMP/linpack.log")"
# 单独钉一下"没拿成那两个错值"，免得哪天改成取 Maximal 还以为是对的
check "取到的不是 Maximal（80.7297）" "0" \
      "$(linpack_parse "$TMP/linpack.log" | grep -c '^80\.7297' || true)"
check "取到的不是计时表的秒数（0.529）" "0" \
      "$(linpack_parse "$TMP/linpack.log" | grep -c '^0\.529' || true)"
check "日志不存在时给 0 0" "0 0" "$(linpack_parse "$TMP/nope-lp.log")"

echo
echo "=== 性能基准：内存读带宽（MLC）==="
# ⚠️ 这一份是 **v3.12 真跑出来的原样输出**（制表符、行尾多余的制表符、
#    那两行 `***` 提示，全都照抄），不是照着记忆编的。
#    两个容易被编错、而真输出里确实存在的地方：
#      1. 标签和数值之间是**制表符**，不是空格
#      2. `1:1 Reads-Writes` 这类标签**自己带冒号** —— 解析用的是 `-F:`，
#         这些行会被切成三段，只有"行首是 ALL Reads"这条判据才躲得开
cat > "$TMP/mlc.log" <<'EOF'
Intel(R) Memory Latency Checker - v3.12
Command line parameters: --peak_injection_bandwidth

Using buffer size of 122.070MiB/thread for reads and an additional 122.070MiB/thread for writes
*** Unable to modify prefetchers (try executing 'modprobe msr')
*** So, enabling random access for latency measurements

Measuring Peak Injection Memory Bandwidths for the system
Bandwidths are in MB/sec (1 MB/sec = 1,000,000 Bytes/sec)
Using all the threads from each core if Hyper-threading is enabled
Using traffic with the following read-write ratios
ALL Reads        :	 32848.9
3:1 Reads-Writes :	 31786.3
2:1 Reads-Writes :	 34752.3
1:1 Reads-Writes :	 34231.7
Stream-triad like:	 35711.5
All NT writes    :	 33775.0
1:1 Read-NT write:	 34325.9
EOF
check "只取 ALL Reads 那一行（样本是 v3.12 真输出）" "32848.9" \
      "$(mlc_parse_all_reads "$TMP/mlc.log")"
check "标签自带冒号的那几行不能被误取" "1" \
      "$(printf '%s\n' "$(mlc_parse_all_reads "$TMP/mlc.log")" | grep -c '^32848\.9$')"

echo
echo "=== 内存带宽：缓冲区大小必须自己定，不能让 MLC 自己挑 ==="
#
# 1.9.0 实测翻车：一台 4GB 内存、4 线程的机器上，MLC 自己挑了
#     Using buffer size of 732.422MiB/thread ... and an additional 732.422MiB/thread
# 也就是 732 × 4 × 2 ≈ 5.8GB，而整机只有 4GB —— 打完第一行 ALL Reads 就开始抖，
# 整轮测试卡在那儿再也出不来报告。它挑多大是按缓存/平台推的，
# **和这台机器还剩多少内存没关系**，所以只能我们来定。
#
# 参数是 (可用内存 KB, 线程数)，只为脱机测用。
check "4GB / 4 线程：压在可用内存的 1/4 以内" "100000" \
      "$(mlc_buffer_kib 3200000 4)"
check "512GB / 128 线程：按 1/4 算出来是 507812" "507812" \
      "$(mlc_buffer_kib 520000000 128)"
check "2TB / 256 线程：顶到上限 512MiB（再大对结果没帮助，只是白占内存）" "524288" \
      "$(mlc_buffer_kib 2000000000 256)"
check "内存极小时顶到下限 64MiB（低于最后一级缓存就量不出内存带宽了）" "65536" \
      "$(mlc_buffer_kib 700000 2)"
check "读不到内存信息时也要给出一个安全值，不能给空" "65536" \
      "$(mlc_buffer_kib abc xyz | grep -oE '^[0-9]+$' >/dev/null && mlc_buffer_kib 700000 2)"
# 最要紧的一条：**算出来的总占用绝不能超过可用内存**
check "总占用（线程 x 2 x 每线程）不许超过可用内存" "yes" \
      "$(awk -v b="$(mlc_buffer_kib 3200000 4)" -v t=4 -v a=3200000 \
           'BEGIN{ print (b*t*2 <= a) ? "yes" : "no" }')"

echo
# ⚠️ **这里故意没有"理论带宽应该是多少"那种断言。**
# 一度写过一个 `mem_expected_read_mbs`（频率 × 通道数 × 8 × 系数）拿来当合格线，
# 1.9.0 整个删掉了：那个数是我们自己算出来的，客户从没定过它，
# 拿它去判一台机器合不合格没有任何依据。报告里只出现实测值。
# 频率和通道数仍然采集，但只作为**事实**写进报告（读者要知道这两个前提）。

echo
echo "=== 性能基准：内存通道数（两种 DMI 写法）==="
cat > "$TMP/mem-ch-bank.txt" <<'EOF'
Handle 0x0001, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMM_A1
	Bank Locator: P0_Node0_Channel0_Dimm0

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: CPU0_DIMM_B1
	Bank Locator: P0_Node0_Channel1_Dimm0

Handle 0x0003, DMI type 17, 92 bytes
Memory Device
	Size: No Module Installed
	Locator: CPU0_DIMM_C1
	Bank Locator: P0_Node0_Channel2_Dimm0
EOF
check "Bank Locator 带 Channel 时直接数通道（空槽不算）" "2" \
      "$(dmi_channel_count "$TMP/mem-ch-bank.txt")"

cat > "$TMP/mem-ch-loc.txt" <<'EOF'
Handle 0x0001, DMI type 17, 92 bytes
Memory Device
	Size: 16 GB
	Locator: CPU0_DIMMA0
	Bank Locator: NODE 0

Handle 0x0002, DMI type 17, 92 bytes
Memory Device
	Size: 16 GB
	Locator: CPU0_DIMMB0
	Bank Locator: NODE 0
EOF
check "没有 Channel 时退回按 Locator 的字母数（单路）" "2" \
      "$(dmi_channel_count "$TMP/mem-ch-loc.txt")"
check "两种写法都认不出来时给 0（调用方据此放弃自动算门槛）" "0" \
      "$(dmi_channel_count "$TMP/nope-mem.txt")"

echo
echo "=== 显卡满载读数（gpu_load_stats）==="
#
# 最低频率要跳过前两个采样点：采样器和 gpu_burn 同一刻起来，
# 头两个点采到的还是空载降频后的频率。不跳的话报告上会凭空多出
# "满载最低频率 210MHz"，看着像严重降频。
cat > "$TMP/gpumetrics.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb,fan_pct,temp_tlimit_c
02:18:01,0,NVIDIA RTX 5090,42,80.0,210,3,512,30,45
02:18:06,0,NVIDIA RTX 5090,55,300.0,1800,60,20000,50,30
02:18:11,0,NVIDIA RTX 5090,71,560.0,2700,99,28935,88,12
02:18:16,0,NVIDIA RTX 5090,73,575.0,2650,99,28935,92,9
02:18:21,0,NVIDIA RTX 5090,74,580.0,2710,99,28935,90,8
EOF
read -r g_cmin g_cavg g_fan g_tl g_pow < <(gpu_load_stats "$TMP/gpumetrics.csv" 0)
check "最低频率跳过头两个采样点（2650，不是 210）" "2650" "$g_cmin"
check "平均频率按全部采样算"                       "2014" "$g_cavg"
check "风扇取峰值"                                 "92"   "$g_fan"
check "距降频阈值取最小余量"                       "8"    "$g_tl"
check "功耗取平均"                                 "419"  "$g_pow"

# 老驱动没有 fan/tlimit 两列：必须输出 "-"，不能当成 0，
# 更不能少输出两个字段（少了会让后面的值整体左移一位）
cat > "$TMP/gpumetrics-old.csv" <<'EOF'
time,index,name,temp_c,power_w,clock_sm_mhz,util_pct,mem_used_mb,fan_pct,temp_tlimit_c
02:18:01,0,NVIDIA A100,42,80.0,210,3,512,,
02:18:06,0,NVIDIA A100,55,300.0,1300,60,20000,,
02:18:11,0,NVIDIA A100,71,400.0,1400,99,28935,,
02:18:16,0,NVIDIA A100,73,400.0,1395,99,28935,,
EOF
check "读不到的列给 '-'，不是 0（'风扇 0%' 和 '没有风扇' 是两件事）" \
      "1395 1076 - - 295" "$(gpu_load_stats "$TMP/gpumetrics-old.csv" 0)"
check "五个字段一个都不能少（少一个会让后面的值整体左移）" "5" \
      "$(gpu_load_stats "$TMP/gpumetrics-old.csv" 0 | wc -w)"

# ================================================================
echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
