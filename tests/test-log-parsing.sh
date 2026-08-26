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
# shellcheck source=/dev/null
source "$LIB/validate.sh"
ROOT="$(cd "$LIB/../../../.." && pwd)"

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
echo "=== 性能基准：逐卡汇总口径 ==="
# 三张卡故意给出不同结果：H2D 取最低，D2H / D2D 取最高。
# 这组直接跑 bench_gpu_bandwidth 的汇总循环，防止只改了文案、实际仍取最低。
GPU_USABLE=3
BENCH_LOG_DIR="$TMP/fake-bench"; mkdir -p "$BENCH_LOG_DIR"
GPU_BW_RESULTS=""
bench_tool() { printf '%s' "/tmp/fake-bandwidthTest"; }
gpu_vram_mib() { printf '%s' 24564; }
gpu_numa_node() { :; }
pcie_mark_gpus_loaded() { :; }
metric_add() { :; }
result_add() {
  GPU_BW_RESULTS="${GPU_BW_RESULTS}${1}|${4}"$'\n'
}
bench_run() {
  local log="$1"; shift 2
  case "$log" in
    *-d2d.log)
      case "$log" in
        *-0-d2d.log) printf 'Device to Device Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n536870912 900\n1073741824 1000\n' > "$log" ;;
        *-1-d2d.log) printf 'Device to Device Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n536870912 1100\n1073741824 1150\n' > "$log" ;;
        *)            printf 'Device to Device Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n536870912 1150\n1073741824 1200\n' > "$log" ;;
      esac
      ;;
    *gpu-bandwidth-0.log) printf 'Host to Device Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n268435456 50\nDevice to Host Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n268435456 22.6\n' > "$log" ;;
    *gpu-bandwidth-1.log) printf 'Host to Device Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n268435456 55\nDevice to Host Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n268435456 42.9\n' > "$log" ;;
    *)                     printf 'Host to Device Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n268435456 52\nDevice to Host Bandwidth, 1 Device(s)\nBandwidth(GB/s)\n268435456 38\n' > "$log" ;;
  esac
}
bench_gpu_bandwidth >/dev/null
check "H2D 汇总仍取逐卡最低值" "yes" \
      "$(grep -qF '实测 50.0 GB/s' <<<"$GPU_BW_RESULTS" && echo yes || echo no)"
check "D2H 汇总改为逐卡最高值" "yes" \
      "$(grep -qF '实测 42.9 GB/s' <<<"$GPU_BW_RESULTS" && echo yes || echo no)"
check "D2D 汇总改为逐卡最高值" "yes" \
      "$(grep -qF '实测 1200.0 GB/s' <<<"$GPU_BW_RESULTS" && echo yes || echo no)"
unset -f bench_tool gpu_vram_mib gpu_numa_node pcie_mark_gpus_loaded metric_add result_add bench_run
# ---------------------------------------------------------------- 显存带宽的块大小
#
# 1.9.3 真机翻车：一台 RTX 4090 的显存带宽报出 3622.7 GB/s，而标称值是 1008。
# 原因是 quick 档只搬 32MB，而 AD102 有 72MB L2 —— 整个拷贝都在缓存里。
#
# ⚠️ 这一组钉的不是"块要多大"，而是**"块不够大的时候必须能自己发现"**。
#    钉一个固定尺寸等于拿今天的卡去赌明天的卡：AMD 已经有 256MB 的
#    Infinity Cache 了，NVIDIA 堆到那个量级只是时间问题。
echo
echo "=== 性能基准：显存带宽的块大小与「曲线压平」判据 ==="

# H2D/D2H：受主机锁页内存限制，封顶 256MiB
check "显存够大、主机内存够多 -> 封顶 256MiB" "268435456" "$(gpu_bw_bytes 24564 33554432)"
check "主机可用内存只有 1GB -> 压到八分之一（128MiB）" "134217728" \
      "$(gpu_bw_bytes 24564 1048576)"
check "主机可用内存极少也不许低于 32MiB（低于就没意义了）" "33554432" \
      "$(gpu_bw_bytes 24564 65536)"
check "显存很小时按显存的四分之一让步" "134217728" "$(gpu_bw_bytes 512 33554432)"
check "读不到显存容量也要给得出一个能跑的块" "268435456" "$(gpu_bw_bytes "" 33554432)"

# D2D：**只受显存限制**，主机内存再紧张也不许把它压小 ——
# 压小就等于悄悄退回缓存里，正是 1.9.3 那个坑。
check "24GB 卡 -> 大块封顶 1GiB、小块 512MiB" "536870912 1073741824" \
      "$(gpu_d2d_bytes 24564)"
check "80GB 卡 -> 同样封顶 1GiB（再大也没意义）" "536870912 1073741824" \
      "$(gpu_d2d_bytes 81920)"
check "8GB 卡 -> 显存的八分之一（1GiB），小块 512MiB" "536870912 1073741824" \
      "$(gpu_d2d_bytes 8192)"
check "2GB 卡 -> 大块 256MiB、小块 128MiB" "134217728 268435456" "$(gpu_d2d_bytes 2048)"
check "显存太小（512MB）-> 给不出可信的块，输出空（那一项不出数）" "" \
      "$(gpu_d2d_bytes 512)"

# ⚠️⚠️ **每一个块大小都必须能装进 32 位有符号整数。**（1.9.9）
#
# CUDA Samples 的 bandwidthTest 用 getCmdLineArgumentInt() 读
# --start/--end/--increment，返回的是 **int**。1.9.4~1.9.8 这里封顶写的是
# 2048MiB = 2147483648 = 2^31，比 INT_MAX 大整整 1 —— 传进去溢出成负数，
# 程序打一行 `Illegal argument - end must be greater than zero / Result = FAIL`
# 就退出。后果是**每一张 16GiB 以上显存的卡（也就是所有正经的卡）
# 显存读写带宽这一项永远测不到**，报告里恒定写着"测试程序未返回有效结果"。
# 1.9.7 的现场数据里 RTX 4090（24G）和 RTX A6000（48G）两台全中。
#
# 这一条要逐个显存容量地钉：只钉某一个容量的话，改封顶时另一档照样能溜过去。
for _vm in 2048 8192 16384 24564 49140 81920 196608; do
  _sz="$(gpu_d2d_bytes "$_vm")"
  [[ -n "$_sz" ]] || continue
  check "${_vm}MiB 显存：两个块大小都必须 < 2^31（否则 bandwidthTest 参数溢出）" "yes" \
        "$(awk -v s="$_sz" 'BEGIN{
             split(s, a, " ")
             print (a[1] > 0 && a[2] > 0 && a[1] < 2147483648 && a[2] < 2147483648) \
                   ? "yes" : "no"
           }')"
done
unset _vm _sz

# 大块的工作集（大块 × 2）必须远大于目前最大的显卡末级缓存（MI300X 的 256MB）。
# 这一条钉的是"余量还在不在"，以后有人把封顶调小会当场红。
# 和上面那条是**一对**：一条防溢出（上界），一条防缓存（下界），
# 只留一条的话，另一个方向随时会被改坏。
check "常见卡的 D2D 工作集要有 1GiB 以上（缓存最大的卡也只有 256MB）" "yes" \
      "$(awk -v b="$(gpu_d2d_bytes 24564 | awk '{print $2}')" \
          'BEGIN{print (b * 2 >= 1073741824) ? "yes" : "no"}')"
check "读不到显存容量 -> 输出空，不许瞎猜一个" "" "$(gpu_d2d_bytes "")"
# 这一条是本组的重点：D2D 的块大小函数**根本不接受主机内存参数**，
# 所以主机内存再紧张也影响不到它。多传一个参数也不该改变结果。
check "D2D 的块大小和主机内存无关（多传参数也不许变）" "$(gpu_d2d_bytes 24564)" \
      "$(gpu_d2d_bytes 24564 65536)"

# 曲线压平判据：两个块大小各一行，**必须按块大小取**，不能取最大值 ——
# 取最大值挑中的正好是被缓存喂出来的那个小块，这道判据就白做了。
cat > "$TMP/d2d-flat.log" <<'EOF'
 Device to Device Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   536870912			872.4
   1073741824			881.9
EOF
check "落到显存上：两个块的读数贴在一起" "872.40 881.90" \
      "$(bw_parse_d2d_curve "$TMP/d2d-flat.log")"

cat > "$TMP/d2d-cache.log" <<'EOF'
 Device to Device Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   536870912			3622.7
   1073741824			1204.3
EOF
check "还在缓存里：小块明显更快，两个数都要如实取回来" "3622.70 1204.30" \
      "$(bw_parse_d2d_curve "$TMP/d2d-cache.log")"

# **绝不能取最大值**：取最大值的话上面那份缓存样本会给出 3622.70，
# 而那正是 1.9.3 印给客户的那个数。
check "取的是最大块那一行，不是最快那一行" "1204.30" \
      "$(bw_parse_d2d_curve "$TMP/d2d-cache.log" | awk '{print $2}')"

# H2D/D2H 那两段的数字不许混进来（同一份日志里三段并存）
cat > "$TMP/d2d-mixed.log" <<'EOF'
 Host to Device Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   268435456			25.2

 Device to Device Bandwidth, 1 Device(s)
 PINNED Memory Transfers
   Transfer Size (Bytes)	Bandwidth(GB/s)
   1073741824			881.9
EOF
check "只认 Device to Device 那一段" "881.90 881.90" \
      "$(bw_parse_d2d_curve "$TMP/d2d-mixed.log")"

sed 's|Bandwidth(GB/s)|Bandwidth(MB/s)|; s|872\.4|872400|; s|881\.9|881900|' \
  "$TMP/d2d-flat.log" > "$TMP/d2d-mb.log"
check "老版本的 MB/s 表头同样要换算" "872.40 881.90" \
      "$(bw_parse_d2d_curve "$TMP/d2d-mb.log")"
check "日志不存在时输出空（-> 那一项不出数，不是出个 0）" "" \
      "$(bw_parse_d2d_curve "$TMP/nope-d2d.log")"

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
# 对角线（1330 / 1329）是显存内部带宽，必须排掉；取的是 51.86 而不是 51.42
check "取双向矩阵里的最高值，且排掉对角线" "51.86" "$(p2p_parse_max_bw "$TMP/p2p.log")"

cat > "$TMP/p2p-1.log" <<'EOF'
Bidirectional P2P=Enabled Bandwidth Matrix (GB/s)
   D\D     0
     0 1330.20
EOF
check "只有一张卡时没有卡间带宽可言，输出空" "" "$(p2p_parse_max_bw "$TMP/p2p-1.log")"

echo
echo "=== 性能基准：CPU 浮点算力（LINPACK）==="
#
# ⚠️ 这份日志里有两张表头几乎一样的表，第一张的第 4 列是**秒**、第二张才是
#    GFlops。按固定列号取第 4 列的话，一台 3030 GFlops 的机器会在报告上
#    印成 "141.7 GFlops" —— 差了二十几倍，而这是要发给客户的数。
#    （这里**不会**因此判 FAIL：性能项只有 PASS/SKIP，没有合格线。
#    正因为没有合格线，这个数错了也不会有任何判定去兜 —— 谁也拦不住它，
#    它会原样印进交付报告。解析对不对，就是这一项唯一的防线。）
# ⚠️ 这一份是 **xlinpack_xeon64（oneMKL 2025.3）真跑出来的原样输出**，
#    喂给它的输入文件就是 linpack_problem_size() 那套格式生成的。
#    它把这条判据要防的坑摆得明明白白：
#      计时表  第 4 列 = Time(s) = 0.529   <- 按列位置取就会拿到这个
#      汇总表  第 4 列 = Average = 79.1742 <- 这个才是算力
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
echo "=== 性能基准：CPU 浮点算力（自研程序，1.9.5）==="
# ⚠️ 这一份是 **vendor/bench/cpuflops/klburn_flops 真跑出来的原样输出**
#    （本机 24 线程、N=3000、跑三次），不是照着源码编的。
#
# 换掉 xlinpack_xeon64 的理由见 CHANGELOG 1.9.5 第三节：那个是 Intel 发布的
# 二进制，在海光 / AMD 上第一行就罢工，非 Intel 机器这一项永远测不出来。
cat > "$TMP/flops.log" <<'EOF'
KLBurn CPU floating-point throughput
Method        : LU factorization (LAPACK dgesv), double precision
Problem size  : 3000
Threads       : 24
Matrix memory : 0.07 GiB
Runs          : 3

Run    Time(s)       GFlops     MaxResidual
  1     0.3595       50.114       4.219e-15
  2     0.3576       50.385       4.219e-15
  3     0.3461       52.063       4.219e-15

Best GFlops   : 52.063
Average GFlops: 50.854
Max residual  : 4.219e-15
EOF
check "取最好成绩，并数出真的跑成了几次" "52.0630 3" "$(flops_parse "$TMP/flops.log")"
# 别取成平均值（50.854）或最后一次（52.063 恰好也是最好的，所以单独钉平均值）
check "取到的不是平均值（50.854）" "0" \
      "$(flops_parse "$TMP/flops.log" | grep -c '^50\.854' || true)"
# 也别把"问题规模 3000"或"线程数 24"当成算力
check "取到的不是问题规模或线程数" "0" \
      "$(flops_parse "$TMP/flops.log" | grep -cE '^(3000|24)\.' || true)"

# ⚠️ **被超时打断的那份必须仍然出数。**bench_run 的超时是硬的（无人值守的工具
#    里任何外部程序都得短得住），被 kill 时末尾那三行汇总根本没打出来 ——
#    只认 `Best GFlops` 的话，已经量到的三次成绩就白扔了，还平白判一个 SKIP。
grep -v '^Best GFlops\|^Average GFlops\|^Max residual' "$TMP/flops.log" > "$TMP/flops-cut.log"
check "被超时打断（没有 Best GFlops 那一行）仍要从逐次表里捞出成绩" "52.0630 3" \
      "$(flops_parse "$TMP/flops-cut.log")"

# 求解失败的那几次不算进"跑成了几次"
cat > "$TMP/flops-partial.log" <<'EOF'
KLBurn CPU floating-point throughput
Problem size  : 3000

Run    Time(s)       GFlops     MaxResidual
  1     0.3595       50.114       4.219e-15
  2          -            -               -   (dgesv info=3)
EOF
check "求解失败的那一次不计入次数" "50.1140 1" "$(flops_parse "$TMP/flops-partial.log")"

# 一次都没跑成（内存要不起 / 残差过大 / 参数不合法）-> 0，调用方会干净地 SKIP
cat > "$TMP/flops-none.log" <<'EOF'
KLBurn CPU floating-point throughput
Problem size  : 40000
内存不足：需要约 298.0 GiB
EOF
check "一次都没跑成时给 0 0（-> SKIP，不是 FAIL）" "0.0000 0" \
      "$(flops_parse "$TMP/flops-none.log")"
check "日志不存在时给 0 0" "0 0" "$(flops_parse "$TMP/nope-flops.log")"

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

# ---- 1.10.1：AMD 平台上没有大页时 MLC 直接退出，一个数都不给 ----
#
# ⚠️ 下面这份是 1.10.0 现场那台 EPYC 7542 的**日志全文**（真的就这么长，
#    打完这几行程序就结束了）。后果是**每一台 AMD 机器**的
#    「内存读取带宽」都恒定 SKIP，报告里写着「测试程序未返回有效结果」——
#    听起来像机器读不出来，实际是我们没按它的要求分配大页。
#    和 1.9.9 那次显存带宽（参数溢出）是同一类：能力缺失被写成机器的毛病。
cat > "$TMP/mlc-nohuge.log" <<'EOF'
Intel(R) Memory Latency Checker - v3.12
Command line parameters: --peak_injection_bandwidth -b250387

Using buffer size of 244.519MiB/thread for reads and an additional 244.519MiB/thread for writes

*************   Hugepages need to be allocated using /proc/sys/vm/nr_hugepages ******
*************   Without large pages, the latencies are not accurate
*************   We need at least 1000 2M pages per numa node
*************   Adjust 4000 below to account for # of NUMA nodes
*************   and execute the following and re-run
*************   echo 4000 > /proc/sys/vm/nr_hugepages
EOF
check "没有大页时那份日志里确实一个 ALL Reads 都没有" "" \
      "$(mlc_parse_all_reads "$TMP/mlc-nohuge.log")"
# 跑之前分配、跑完还原 —— 两边都必须在，缺后一半的话 8GB 大页会一直占着，
# 后面的内存压测就少覆盖那么多（而且不会有任何报错）。
_BENCH_SH="$LIB/bench.sh"
check "跑 MLC 之前要按它的提示分配大页" "1" \
      "$(grep -c '^  mlc_hugepages_setup$' "$_BENCH_SH" || true)"
check "跑完必须还原（否则大页一直占着，内存压测少覆盖 8GB）" "1" \
      "$(grep -c '^  mlc_hugepages_restore$' "$_BENCH_SH" || true)"
check "还原要紧跟在这一次 MLC 之后，不能拖到函数末尾（中途 return 会漏）" "yes" \
      "$( [[ "$(grep -n '^  bench_run "\$log" "\$exe" --peak_injection_bandwidth' "$_BENCH_SH" | head -1 | cut -d: -f1)" \
             -lt "$(grep -n '^  mlc_hugepages_restore$' "$_BENCH_SH" | head -1 | cut -d: -f1)" ]] \
          && echo yes || echo no )"
# ⚠️ 分配必须排在 mlc_buffer_kib **之后**：那个函数按当前可用内存算缓冲区，
#    先占掉 8GB 的话它会算小一档，量出来的数就不是同一个口径了。
check "分配要排在算缓冲区大小之后（否则缓冲区被算小一档）" "yes" \
      "$( [[ "$(grep -n 'bufkib="\$(mlc_buffer_kib)"' "$_BENCH_SH" | head -1 | cut -d: -f1)" \
             -lt "$(grep -n '^  mlc_hugepages_setup$' "$_BENCH_SH" | head -1 | cut -d: -f1)" ]] \
          && echo yes || echo no )"

# ---- 1.10.1：内存带宽要排在基准的第一项 ----
#
# ⚠️ 同一台 6133、同一个工具、同样 2666 MT/s，两个范围量出来差 65%：
#      全量档  78650.8 MB/s     内存档 129522.0 MB/s
#    （1.9.9 那版同样是 78833.5 / 129299.3，两版都复现。）
#    区别只有一个：全量档里它排在 CPU 算力（40000 阶、约 12.8 GB 矩阵）后面，
#    空闲页被打散之后，MLC 每线程 391 MiB 的缓冲区落到了别的 NUMA 节点上，
#    双路机器整条测量都在跨 UPI，正好腰斩。
#    **出货主报告（全量档）印的一直是低的那个数。**
_p_mem="$(grep -n 'scope_runs bench_mem  && bench_mem_bandwidth' "$_BENCH_SH" | head -1 | cut -d: -f1)"
_p_cpu="$(grep -n 'scope_runs bench_cpu  && bench_cpu_flops'     "$_BENCH_SH" | head -1 | cut -d: -f1)"
_p_gpu="$(grep -n '    bench_gpu_bandwidth$'                     "$_BENCH_SH" | head -1 | cut -d: -f1)"
check "内存带宽排在 CPU 算力之前（否则量的是被打散之后的内存）" "yes" \
      "$( [[ -n "$_p_mem" && -n "$_p_cpu" && "$_p_mem" -lt "$_p_cpu" ]] && echo yes || echo no )"
check "内存带宽也排在显卡基准之前（显卡那几项同样会分走大块内存）" "yes" \
      "$( [[ -n "$_p_mem" && -n "$_p_gpu" && "$_p_mem" -lt "$_p_gpu" ]] && echo yes || echo no )"
check "跑之前要放掉页缓存" "1" \
      "$(grep -c 'drop_caches' "$_BENCH_SH" || true)"
check "跑之前要整理一遍空闲页（这条才是治跨 NUMA 落点的）" "1" \
      "$(grep -c 'compact_memory' "$_BENCH_SH" || true)"
unset _BENCH_SH _p_mem _p_cpu _p_gpu

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
# 0 的含义是「这台机器认不出通道数」，调用方据此**在报告里不写通道数**
# ——**绝不猜一个**。（这句原来写的是"放弃自动算门槛"，那是 1.9.0 中途
# 那套阈值留下的说法，阈值早就整个删了，这个返回值现在只影响一句文案。）
check "两种写法都认不出来时给 0（调用方据此在报告里不写通道数，不猜）" "0" \
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
# ⚠️ 平均值也跳同样两个点（1.9.2 改的）。原来最低跳、平均不跳，两个数出自
#    两个窗口，凑在同一句话里就会出现"平均 2686MHz（最低 2688MHz）"——
#    最低的比平均的还高。客户不会去想那是两个口径，他想的是"这报告算错了"。
check "平均频率跳同样两个点（2687，不是把空载那两点也算进来的 2014）" "2687" "$g_cavg"
check "风扇取峰值"                                 "92"   "$g_fan"
check "距温度上限取最小余量"                       "8"    "$g_tl"
check "平均功耗也跳同样两个点（572，不是 419）"     "572"  "$g_pow"
# **这一条才是真正要守的东西**：不管窗口怎么改，只要两个数出自同一组样本，
# 最低 <= 平均就是结构上成立的。它红了说明有人又把窗口拆成了两个。
check "最低频率不许高于平均频率（同一组样本，结构上就该成立）" "yes" \
      "$(awk -v a="$g_cmin" -v b="$g_cavg" 'BEGIN{print (a+0<=b+0)?"yes":"no"}')"

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
      "1395 1398 - - 400" "$(gpu_load_stats "$TMP/gpumetrics-old.csv" 0)"
check "五个字段一个都不能少（少一个会让后面的值整体左移）" "5" \
      "$(gpu_load_stats "$TMP/gpumetrics-old.csv" 0 | wc -w)"

echo
echo "=== 部件专项验证：结论由那个工具给（1.9.2）==="
#
# ⚠️ 这两条的判据都是"**非零退出不等于机器有问题**"。
#    工具跑不起来、参数不对、驱动版本不匹配、被超时打断，全都会非零 ——
#    要在日志里找到**明确的失败证据**才敢判 FAIL。分不清的东西不该去染
#    客户的结论（一号红线）。
printf 'ok 1 - test kernel\nok 2 - test cpuid\n' > "$TMP/sdc-ok.log"
check "退出 0 且没有失败行 -> pass" "pass" "$(sdc_verdict 0 "$TMP/sdc-ok.log")"
printf 'ok 1 - test kernel\nnot ok 2 - test avx512\n  - failed: thread 12 data miscompare\n' \
  > "$TMP/sdc-bad.log"
check "日志里有明确的失败证据 -> fail" "fail" "$(sdc_verdict 1 "$TMP/sdc-bad.log")"
# ⚠️ 顺序不能反：既有失败行、又碰巧退出 0 的日志必须读成 fail
check "有失败行时即使退出 0 也判 fail" "fail" "$(sdc_verdict 0 "$TMP/sdc-bad.log")"
printf 'error: unknown CPU feature, cannot run\n' > "$TMP/sdc-env.log"
check "非零退出但找不到失败证据 -> inconclusive（不是 fail）" "inconclusive" \
      "$(sdc_verdict 2 "$TMP/sdc-env.log")"
check "日志文件不存在 + 非零退出 -> inconclusive" "inconclusive" \
      "$(sdc_verdict 1 "$TMP/nope-sdc.log")"

printf 'Deployment| Blacklist                | Pass\nIntegration| PCIe                    | Pass\n' \
  > "$TMP/dcgm-ok.log"
check "显卡诊断全 Pass -> pass" "pass" "$(dcgm_verdict 0 "$TMP/dcgm-ok.log")"
printf 'Hardware  | Memory                   | Fail\n' > "$TMP/dcgm-bad.log"
check "有 Fail 行 -> fail" "fail" "$(dcgm_verdict 1 "$TMP/dcgm-bad.log")"
printf 'Error: Unable to connect to nv-hostengine\n' > "$TMP/dcgm-env.log"
check "连不上诊断服务 -> inconclusive（不是显卡坏了）" "inconclusive" \
      "$(dcgm_verdict 255 "$TMP/dcgm-env.log")"

# 两个可选件都必须挂在汇总入口上，而且 validate_all 要被 factory-test.sh 调用 ——
# 少一句的后果是工具白放进 vendor/、判定从报告里消失
for fn in validate_init validate_cpu_sdc validate_gpu_diag; do
  check "validate_all 必须调用 $fn" "yes" \
        "$(declare -f validate_all | grep -q "\b${fn}\b" && echo yes || echo no)"
done
FT_MAIN="$ROOT/rootfs/opt/klburn/factory-test.sh"
check "factory-test.sh 必须调用 validate_all" "yes" \
      "$(grep -qE '^[[:space:]]*validate_all( |$)' "$FT_MAIN" && echo yes || echo no)"
# 和基准同一个阶段：都要机器空闲。排到压测里去的话，量到的和判到的都是别的东西。
#
# ⚠️ 锚点不能写成 `^validate_all`：1.9.7 起这一段被包进了
#    `if (( SCOPE_ABORT == 0 )); then`（范围里的部件不在这台机器上就整段跳过），
#    调用点缩进了两格，行首锚点会说"它排到压测后面去了"—— 一个不存在的问题。
vl_pos="$(grep -nE '^[[:space:]]*validate_all([[:space:]]|$)' "$FT_MAIN" | head -1 | cut -d: -f1)"
st_pos="$(grep -n 'stress_cpu "\$CPU_SECS"' "$FT_MAIN" | head -1 | cut -d: -f1)"
check "validate_all 必须排在并发压测之前（空闲时测）" "yes" \
      "$( [[ -n "$vl_pos" && -n "$st_pos" && "$vl_pos" -lt "$st_pos" ]] && echo yes || echo no )"
# ⚠️ 它**不能**放进 bench.sh：那个文件的出口只有 PASS/SKIP，
#    而这两条是会判 FAIL 的（工具说部件坏了）。混在一起就会让
#    "性能数字不判合格"那条守卫和事实打架。
check "validate.sh 不许被写进 bench.sh（两者的出口性质不同）" "0" \
      "$(grep -c 'validate_' "$ROOT/rootfs/opt/klburn/lib/bench.sh" || true)"

echo
echo "=== CPU 满载频率：最低和平均必须同一个窗口（phase_freq_stats）==="
#
# 和上面显卡那一组是同一条规矩、同一个理由。r08 那份真机报告上印过
#     平均频率 2686MHz　　最低频率 2688MHz
# 最低的比平均的还高 —— 两个函数各跳各的窗口跳出来的。
RUN_DIR="$TMP"
cat > "$TMP/sys_metrics.csv" <<'EOF'
time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w
10:00:00,cpu,45,1200,0.5,1000,65536,120
10:00:05,cpu,55,1800,20.0,1200,65536,200
10:00:10,cpu,68,2700,64.0,1400,65536,320
10:00:15,cpu,70,2650,64.5,1400,65536,325
10:00:20,cpu,71,2710,64.8,1400,65536,330
EOF
read -r p_min p_avg < <(phase_freq_stats cpu)
check "最低频率跳过头两个采样点" "2650" "$p_min"
check "平均频率跳同样两个点（2687，不是 2212）" "2687" "$p_avg"
check "两个薄包装取的是同一组样本（min）" "2650" "$(phase_min_freq cpu)"
check "两个薄包装取的是同一组样本（avg）" "2687" "$(phase_avg_freq cpu)"
check "最低不许高于平均（结构上就该成立）" "yes" \
      "$(awk -v a="$p_min" -v b="$p_avg" 'BEGIN{print (a+0<=b+0)?"yes":"no"}')"
# 采样点不足 3 个的超短阶段：全都算，宁可粗糙也不要空值
cat > "$TMP/sys_metrics.csv" <<'EOF'
time,phase,cpu_temp_c,cpu_freq_mhz,load1,mem_used_mb,mem_total_mb,cpu_power_w
10:00:00,cpu,45,1200,0.5,1000,65536,120
10:00:05,cpu,55,1800,20.0,1200,65536,200
EOF
check "只有两个采样点时不跳（否则一个数都出不来）" "1200 1500" "$(phase_freq_stats cpu)"
: > "$TMP/sys_metrics.csv"
check "一行数据都没有时给 '- -'（调用方据此写「未知」）" "- -" "$(phase_freq_stats cpu)"
check "没数据时薄包装给空串（不是 '-'）" "" "$(phase_min_freq cpu)"
unset RUN_DIR

# ================================================================
echo
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
