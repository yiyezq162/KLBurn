#!/usr/bin/env bash
#
# 端到端测试：把出好的 ISO 在 QEMU 里真的启动一次，跑完，再把报告从"U 盘"里
# 挖出来检查。
#
#     sudo ./tests/e2e-qemu.sh                    # 冒烟：约 3 分钟
#     sudo ./tests/e2e-qemu.sh --stage full       # 完整 QUICK 跑完：约 20 分钟
#     sudo ./tests/e2e-qemu.sh --iso out/xxx.iso  # 指定 ISO（默认取 out/ 里最新的）
#
# ================================================================
# 为什么需要它
# ================================================================
# tests/ 里其余 355 项断言全是**单元级**的：喂文件给纯函数、看它吐什么。
# 没有任何一条验证过「插上去、开机、真的跑完、报告真的落到盘上」——
# 而这中间任何一环断掉（服务没起、数据分区没认出来、报告生成器在真环境里崩），
# 单元测试一条都不会红，现场却是空手而归。
#
# v0.4.0 的 tag 里写着"已在 QEMU 里做过完整端到端验证"，但那是**人工做的**，
# 仓库里一行脚本都没留下，成果全在做的人脑子里。这个文件就是把它固化下来。
#
# ================================================================
# 它怎么模拟一根 KLBurn U 盘
# ================================================================
# Rufus 的 DD 模式就是把 ISO 原样写进 U 盘，然后在剩余空间建 exFAT 分区。
# 这里做的是同一件事，只不过对象是个文件：
#
#     cp ISO img  ->  truncate 撑大  ->  sgdisk -e 把 GPT 备份头挪到新的末尾
#                 ->  新建第 4 个分区  ->  mkfs.exfat -n KLBURN
#
# ISO 本身已经带了 3 个分区（ISO9660 / EFI / Gap1），所以数据分区是第 4 个。
#
# 另外再挂两块空白盘当"本机硬盘"，让 scan_disks / collect_disk 有东西可采
# —— collect_disk 是 21 个判定 id 里唯一一个单元测试覆盖不到的。
#
# ================================================================
# 怎么在没有串口的情况下操作它
# ================================================================
# klburn.service 是钉死在 tty1 上的（TTYPath=/dev/tty1），UI 不会走串口，
# 所以没法用 expect 那套。这里走 QEMU 的 monitor：`sendkey` 直接往虚拟键盘上
# 打字，和现场工程师按键盘是同一条路径 —— 不需要给产品加任何"无人值守模式"，
# 测的就是真正的交互流程。
#
# 断言则完全落在**磁盘产物**上：跑完把第 4 个分区挂起来看。这比抓屏幕文字
# 可靠得多，也正好是现场真正在乎的东西（报告到底有没有落到 U 盘里）。
#
# ⚠️ 按键是按时间窗口盲发的，发早了会打到 GRUB 菜单上。所以第一次按键要等到
#    GRUB（5 秒超时）早就过去之后，见 SELECT_START。
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# ---------------------------------------------------------------- 参数
STAGE="smoke"
ISO=""
DATA_MB=1024          # 模拟 U 盘的数据分区
SPARE_GB=2            # 每块"本机硬盘"多大
SPARE_N=2             # 挂几块
MEM_MB=4096
CPUS=4
KEEP=0
NET=0
WORKDIR=""
FIRMWARE="bios"
NO_DATA=0

usage() {
  cat <<'EOF'
用法: sudo ./tests/e2e-qemu.sh [选项]

  --stage smoke|full   smoke=只验能不能起来并落盘（~3 分钟，默认）
                       full =完整跑一遍 QUICK 档（~20 分钟）
  --firmware bios|uefi bios=SeaBIOS（默认）；uefi=OVMF。真服务器基本都是 UEFI，
                       两条引导路径都得验
  --no-data-partition  把第 4 个分区格成 ext4 而不是 exFAT，模拟"U 盘上没有
                       可用数据分区"。验的是：报告不会被写到不该写的地方、
                       而且流程照常跑完不卡死（现场应看到黄色大框警告）
  --iso PATH           用指定 ISO（默认取 out/ 里 mtime 最新的）
  --net                给虚拟机接一块网卡（默认不接，网卡项会判 SKIP）
  --keep               跑完保留磁盘镜像和截图，方便手工看
  --workdir DIR        指定工作目录（默认 mktemp）。排查时务必用它 ——
                       /tmp 在 WSL 里跨会话不保留，--keep 也留不住
  --spare-disks N      挂几块空白盘当"本机硬盘"（默认 2）
EOF
}

while (( $# )); do
  case "$1" in
    --stage)       STAGE="$2"; shift 2 ;;
    --iso)         ISO="$2";   shift 2 ;;
    --net)         NET=1;      shift ;;
    --keep)        KEEP=1;     shift ;;
    --firmware)    FIRMWARE="$2"; shift 2 ;;
    --no-data-partition) NO_DATA=1; shift ;;
    --workdir)     WORKDIR="$2"; shift 2 ;;
    --spare-disks) SPARE_N="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) printf '未知参数: %s\n' "$1"; usage; exit 2 ;;
  esac
done

PASS=0; FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '  \033[36m--\033[0m   %s\n' "$1"; }
die()  { printf '\033[31m致命: %s\033[0m\n' "$1" >&2; exit 1; }

# 打错断言函数名不能静悄悄地过去（§11-13 那条，test-report-render.sh 里踩过）
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

# ---------------------------------------------------------------- 前置检查
(( EUID == 0 )) || die "要 root：要 losetup 造分区、要挂 exFAT、还要用 /dev/kvm"

for t in qemu-system-x86_64 sgdisk mkfs.exfat losetup truncate; do
  command -v "$t" >/dev/null 2>&1 || die "缺 $t（apt-get install qemu-system-x86 gdisk exfatprogs）"
done

if [[ -z "$ISO" ]]; then
  # shellcheck disable=SC2012
  ISO="$(ls -t out/KLBurn-*.iso 2>/dev/null | head -1)"
fi
[[ -n "$ISO" && -f "$ISO" ]] || die "找不到 ISO。先 build/build-iso.sh，或用 --iso 指定"

KVM_ARGS=()
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  KVM_ARGS=(-enable-kvm -cpu host)
else
  info "没有 /dev/kvm，走纯模拟 —— 会慢很多，full 档可能要几小时"
fi

# 这个版本号后面要拿去和盘里 meta.json 对
EXPECT_VER="$(grep -oE 'KLBURN_VERSION="[^"]+"' build/config.sh | cut -d'"' -f2)"

printf '\n\033[1;36m===== KLBurn 端到端（QEMU）=====\033[0m\n'
info "ISO      : $ISO ($(du -h "$ISO" | cut -f1))"
info "期望版本 : $EXPECT_VER"
info "阶段     : $STAGE"

# ---------------------------------------------------------------- 工作区
if [[ -n "$WORKDIR" ]]; then
  rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
  WORK="$WORKDIR"; KEEP=1
else
  WORK="$(mktemp -d)"
fi
LOOP=""
MNT="$WORK/mnt"
MON_PORT=$(( 20000 + RANDOM % 20000 ))
QEMU_PID=""

cleanup() {
  [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null
  mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  if (( KEEP )); then
    printf '\n  镜像和截图保留在: %s\n' "$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

mkdir -p "$MNT"

# ---------------------------------------------------------------- 1. 造 U 盘镜像
printf '\n\033[1m[1/4] 造模拟 U 盘镜像\033[0m\n'

IMG="$WORK/usb.img"
cp --sparse=always "$ISO" "$IMG"
ISO_BYTES="$(stat -c %s "$IMG")"
truncate -s "$(( ISO_BYTES + DATA_MB * 1024 * 1024 ))" "$IMG"

# ISO 被撑大之后，GPT 的备份头还留在原来的位置（老的"末尾"），
# 不挪的话新分区建不出来。-e 就是干这个的。
sgdisk -e "$IMG" >/dev/null 2>&1

# ISO 自带 3 个分区，数据分区是第 4 个。0700 = Microsoft basic data。
sgdisk -n 4:0:0 -t 4:0700 -c 4:KLBURNDATA "$IMG" >/dev/null 2>&1

LOOP="$(losetup -P --find --show "$IMG")"
[[ -n "$LOOP" ]] || die "losetup 失败"
sleep 1

if [[ -b "${LOOP}p4" ]]; then
  ok "第 4 个分区建出来了（${LOOP}p4）"
else
  bad "第 4 个分区没建出来 —— 后面全白搭"
  sgdisk -p "$IMG" 2>&1 | tail -8 | sed 's/^/       /'
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
fi

if (( NO_DATA )); then
  # 故意格成 ext4：四层回退找的全是 exFAT，所以一层都不会命中，
  # KLBurn 应该退到 /tmp 并打黄色大框警告，**而不是**往这个分区上乱写。
  mkfs.ext4 -q -F -L NOTKLBURN "${LOOP}p4" >/dev/null 2>&1
  ok "数据分区故意格成 ext4（模拟 U 盘上没有可用的 exFAT 数据分区）"
else
  # 卷标必须是大写 KLBURN —— 四层回退的第 1 层就是按它找的
  mkfs.exfat -n KLBURN "${LOOP}p4" >/dev/null 2>&1
  lbl="$(blkid -s LABEL -o value "${LOOP}p4" 2>/dev/null)"
  [[ "$lbl" == "KLBURN" ]] && ok "数据分区格式化为 exFAT，卷标 KLBURN" \
                           || bad "卷标不对：拿到 [$lbl]，要的是 KLBURN"
fi

losetup -d "$LOOP"; LOOP=""

# "本机硬盘"：稀疏文件，不占真实空间
SPARE_ARGS=()
for (( i = 0; i < SPARE_N; i++ )); do
  d="$WORK/spare$i.img"
  truncate -s "${SPARE_GB}G" "$d"
  SPARE_ARGS+=(-drive "file=$d,format=raw,if=virtio,cache=unsafe")
done
info "另挂 $SPARE_N 块 ${SPARE_GB}G 空白盘当本机硬盘"

# ---------------------------------------------------------------- 2. 起虚拟机
printf '\n\033[1m[2/4] 启动虚拟机\033[0m\n'

NET_ARGS=(-nic none)
# shellcheck disable=SC2054  # 这里的逗号是 qemu 参数自己的语法，不是数组分隔符
(( NET )) && NET_ARGS=(-nic "user,model=virtio-net-pci")

# UEFI：真服务器基本都是 UEFI 启动，而 ISO 是 BIOS/UEFI 双引导的 —— 两条路
# 走的是完全不同的引导链（SeaBIOS + isohybrid MBR  vs  OVMF + ESP 里的 grub），
# 只验一条等于只验了一半。
FW_ARGS=()
if [[ "$FIRMWARE" == "uefi" ]]; then
  OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
  OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
  [[ -f "$OVMF_CODE" ]] || die "缺 OVMF（apt-get install ovmf）：$OVMF_CODE"
  # VARS 必须是可写副本，直接用系统那份会失败（而且不该污染它）
  cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
  FW_ARGS=(
    -machine q35
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$WORK/OVMF_VARS.fd"
  )
  info "固件：UEFI（OVMF，q35）"
else
  info "固件：BIOS（SeaBIOS，i440fx）"
fi

# U 盘走 USB 总线，和现场一致 —— storage.sh 里那套 removable/hotplug 判断
# 和 live 介质反查都指望这个身份。用 virtio 挂的话就测不到那条路了。
#
# ⚠️ U 盘这块**绝对不能加 cache=unsafe**。那个选项让 QEMU 直接忽略 flush 请求，
#    虚拟机一停，还在缓存里的写入就没了 —— 表现是"跑完挂上去，分区里空空如也"，
#    而虚拟机里其实一切正常。第一版就是这么栽的，查了半天以为是产品没落盘。
#    空白盘无所谓（本来就是丢弃的），所以只有它们留着 cache=unsafe。
#
# ⚠️ bootindex=0 也不是可有可无。挂了空白盘之后，SeaBIOS 会先去试那几块
#    virtio 盘（它们是"硬盘"），试完不会正确回落到 USB，直接
#    "No bootable device" 停在那儿 —— 而脚本这边看到的现象是
#    "跑完 U 盘里什么都没有"，和产品没落盘长得一模一样。
#    现场是工程师在 BIOS 菜单里手动选 U 盘，bootindex 就是在模拟这一下。
qemu-system-x86_64 \
  "${KVM_ARGS[@]}" \
  "${FW_ARGS[@]}" \
  -m "$MEM_MB" -smp "$CPUS" \
  -device qemu-xhci,id=xhci \
  -drive "file=$IMG,format=raw,if=none,id=usbstick" \
  -device usb-storage,bus=xhci.0,drive=usbstick,removable=on,bootindex=0 \
  "${SPARE_ARGS[@]}" \
  "${NET_ARGS[@]}" \
  -display none \
  -monitor "tcp:127.0.0.1:$MON_PORT,server,nowait" \
  >"$WORK/qemu.log" 2>&1 &
QEMU_PID=$!

sleep 3
kill -0 "$QEMU_PID" 2>/dev/null || {
  bad "QEMU 没起来"
  sed 's/^/       /' "$WORK/qemu.log"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
}
ok "QEMU 已启动（pid $QEMU_PID, monitor 127.0.0.1:$MON_PORT）"

# monitor 用一条常驻连接，省得每次重连
exec 3<>"/dev/tcp/127.0.0.1/$MON_PORT" || die "连不上 QEMU monitor"

# ⚠️ 虚拟机可能在任何时候自己退出（关机键生效了、内核 panic 了），
#    此后再往 monitor 写就是**往已关闭的 socket 写 -> SIGPIPE -> 整个脚本被杀**。
#    第一版就是这么死的：完整档的关机循环把 'p' 发进去、虚拟机正常退出，
#    紧接着那句 screendump 直接把脚本干掉了 —— 后面所有断言一条都没跑，
#    而磁盘上其实躺着一份完整的报告。
#    所以每次写之前先确认它还活着，写失败也不算错。
mon() {
  kill -0 "$QEMU_PID" 2>/dev/null || return 0
  printf '%s\n' "$*" >&3 2>/dev/null || return 0
  sleep 0.2
}

shot() { mon "screendump $WORK/shot-$1.ppm"; }

# ---------------------------------------------------------------- 3. 驱动它
printf '\n\033[1m[3/4] 操作虚拟机\033[0m\n'

SELECT_START=40      # GRUB 超时只有 5 秒，40 秒之后按键一定打不到 GRUB 上
SELECT_UNTIL=240

if [[ "$STAGE" == "smoke" ]]; then
  # 冒烟只想知道"起没起来、认没认出数据分区"。
  # KLBurn 一开机就 mount_data_partition + log_attach，klburn.log 会立刻落盘 ——
  # 所以根本不用等它跑完，看盘上有没有东西就够了。
  info "冒烟档：等 150 秒让它开机并建立报告目录"
  # 15 秒这一张是专门为 --no-data-partition 留的：找不到数据分区时那个黄色大框
  # 警告出现在 STEP 1、只停 8 秒，等到 30 秒就已经被后面的采集日志顶走了。
  # 那条"有没有打警告"没法程序化断言，只能靠人看截图，所以至少得截到。
  sleep 15; shot "15"
  for t in 30 60 90 120 150; do
    sleep $(( t == 30 ? 15 : 30 ))
    kill -0 "$QEMU_PID" 2>/dev/null || { bad "虚拟机在第 ${t}s 意外退出了"; break; }
    shot "$t"
    printf '       ... %ss\n' "$t"
  done
else
  info "完整档：等开机 -> 选 QUICK -> 跑完 -> 关机"
  sleep "$SELECT_START"
  # 时长菜单是 30 秒倒计时。这里在窗口里反复按 "1"+回车：
  #   - 打在时长菜单上 -> 选中 QUICK（要的就是这个）
  #   - 打在硬盘破坏性写入确认上 -> "1" 不是 "yes" -> 跳过（安全方向）
  #   - 打在最终警告面板上 -> "1" 不是 "y" -> 跳过
  # 全都落在安全的一侧，多按几次不会把事情搞坏。
  t="$SELECT_START"
  while (( t < SELECT_UNTIL )); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    mon "sendkey 1"; mon "sendkey ret"
    sleep 4; t=$(( t + 4 ))
    (( t % 60 == 0 )) && { shot "$t"; printf '       ... 选档窗口 %ss\n' "$t"; }
  done
  # 这里只能说"键发出去了"，说明不了"选中了"—— 所以是 info 不是 ok。
  # 一条永远为真的断言就是摆设，会把通过数刷虚。
  # 真正验证选档生效的是后面那条 meta.json 里 profile == QUICK。
  info "选档按键已发完（目标：QUICK = 10 分钟）"

  # QUICK 10 分钟 + 采集/复查/出报告的余量
  info "等压测跑完（QUICK 600s + 余量）"
  for (( t = 0; t < 900; t += 60 )); do
    sleep 60
    kill -0 "$QEMU_PID" 2>/dev/null || { info "虚拟机已自行退出"; break; }
    printf '       ... 压测中 %ss\n' "$t"
  done
  shot "burn-done"

  # 收尾菜单：p = 关机。反复按到它真的退出为止。
  info "发关机键"
  for (( t = 0; t < 300; t += 10 )); do
    kill -0 "$QEMU_PID" 2>/dev/null || { ok "收尾菜单按 p 之后虚拟机正常关机"; break; }
    mon "sendkey p"
    sleep 10
  done
fi

shot "final"

# 走 ACPI 关机，不要直接 kill。
#
# 硬杀会把**虚拟机内核的 page cache** 一起扔掉 —— 那些 capture() 刚写下去、
# 还没被 writeback 刷到 exFAT 上的采集文件就没了。表现和"产品没落盘"一模一样，
# 极难区分。ACPI 关机会让 systemd 正常收尾、卸载文件系统，
# 顺带也把关机这条路径本身测了。
if kill -0 "$QEMU_PID" 2>/dev/null; then
  info "发 ACPI 关机信号，等虚拟机自己收尾"
  mon "system_powerdown"
  for (( t = 0; t < 120; t += 5 )); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 5
  done
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    info "ACPI 关机 120 秒没关掉，只能硬杀（下面的断言可能因此少东西）"
    kill -9 "$QEMU_PID" 2>/dev/null
  else
    ok "虚拟机响应 ACPI 关机并正常退出"
  fi
else
  info "虚拟机已经自己退出了"
fi
exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
wait "$QEMU_PID" 2>/dev/null
QEMU_PID=""

# ---------------------------------------------------------------- 4. 检查产物
printf '\n\033[1m[4/4] 把"U 盘"挂起来看\033[0m\n'

LOOP="$(losetup -P --find --show "$IMG")"
sleep 1
if mount -o ro "${LOOP}p4" "$MNT" 2>/dev/null; then
  ok "第 4 个分区能挂上"
else
  bad "第 4 个分区挂不上"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
fi

if (( NO_DATA )); then
  # 没有可用数据分区时该发生什么：
  #   - 报告退到 /tmp（关机就没了，这是已知且会在屏幕上打黄色大框警告的）
  #   - **绝不能**往这个不认识的分区上乱写
  #   - 流程照常跑完，不能卡死 —— 现场最怕的是"插上去没反应"
  #
  # 前两条这里能验；"打了黄框"只能靠截图人工看（shot-*.ppm 都留着）。
  # ⚠️ 这里绝不能写 `grep -c . || echo 0`。§11-7：grep -c 在计数为 0 时
  #    **既打印 "0" 又返回 1**，于是 `|| echo 0` 补出第二个 0，结果是两行的
  #    "0\n0" —— 拿去比较就成了"期望 0、实际 0，却判不相等"。
  #    而且它**只在健康路径上发作**（真没写东西的时候才会为 0），
  #    第一次跑这个场景就撞上了。运行时脚本有 count_lines() 专治这个，
  #    这里不 source core.sh，所以自己写一份同样形状的。
  count_lines_() {
    local n; n="$(grep -c . 2>/dev/null)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
  }
  n_files="$(find "$MNT" -mindepth 1 2>/dev/null | count_lines_)"
  # ext4 会有个 lost+found，那是 mkfs 建的，不算 KLBurn 写的
  n_written="$(find "$MNT" -mindepth 1 -not -name 'lost+found' 2>/dev/null | count_lines_)"
  check_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1（期望 $2，实际 $3）"; }
  check_eq "认不出的分区上一个字节都没写（不是 exFAT 就不该碰它）" "0" "$n_written"
  [[ -d "$MNT/out" ]] && bad "居然在非 exFAT 分区上建了 out/ 目录" \
                      || ok "没有在非 exFAT 分区上建 out/"
  info "分区里共 $n_files 个条目（lost+found 是 mkfs 建的）"
  info "「屏幕上有没有黄色大框警告」只能人工看截图：$WORK/shot-*.ppm"

  umount "$MNT" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null; LOOP=""
  printf '\n'
  printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
  exit $(( FAIL > 0 ? 1 : 0 ))
fi

# --- 报告目录 ---
RUNDIR="$(find "$MNT/out" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)"
if [[ -n "$RUNDIR" ]]; then
  ok "U 盘里出现了报告目录：out/$(basename "$RUNDIR")"
else
  bad "U 盘的 out/ 下没有任何报告目录 —— 报告没落盘（现场就是白跑一趟）"
  info "U 盘根目录内容：$(ls -A "$MNT" 2>/dev/null | tr '\n' ' ')"
  printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"; exit 1
fi

TAG="$(basename "$RUNDIR")"

# --- 一定会有的：日志 ---
[[ -s "$RUNDIR/klburn.log" ]] && ok "klburn.log 有内容" \
                              || bad "klburn.log 不存在或是空的"

# 目录名格式：日期_时间_CPU型号_内存容量
[[ "$TAG" =~ ^[0-9]{8}_[0-9]{6}_.+ ]] && ok "报告目录名格式对（日期_时间_CPU_内存）" \
                                      || bad "报告目录名不像话：$TAG"

if [[ "$STAGE" == "smoke" ]]; then
  # 冒烟到此为止：能开机、能认出数据分区、能建目录写日志，就算过。
  if grep -q "KLBurn v${EXPECT_VER}" "$RUNDIR/klburn.log" 2>/dev/null; then
    ok "日志里的版本号是 $EXPECT_VER（盘里跑的确实是这次构建的代码）"
  else
    got_v="$(grep -oE 'KLBurn v[0-9.]+' "$RUNDIR/klburn.log" 2>/dev/null | head -1)"
    bad "版本对不上：盘里是「${got_v:-?}」，源码是 $EXPECT_VER"
    info "  = 你测的不是你以为的那份代码。改完代码要先重新构建："
    info "    sudo KLBURN_WORK=/home/li/klburn-build ./build/build-iso.sh"
    info "  （这条断言就是为了拦住"改完代码直接拿旧 ISO 跑 e2e"）"
  fi
else
  # --- 完整档：报告本体 ---
  [[ -s "$RUNDIR/$TAG.html" ]] && ok "交付报告 $TAG.html 生成了" \
                               || bad "交付报告没生成"
  [[ -s "$RUNDIR/raw/INTERNAL_$TAG.html" ]] \
    && ok "内部工程报告落在 raw/ 里（防手滑那一层）" \
    || bad "内部工程报告没生成"

  [[ -s "$RUNDIR/results.jsonl" ]] && ok "results.jsonl 非空" \
                                   || bad "results.jsonl 空的 —— 这一轮什么都没判"

  # --- meta.json ---
  if [[ -s "$RUNDIR/meta.json" ]]; then
    got_ver="$(grep -oE '"klburn_version":[^,]*' "$RUNDIR/meta.json" | cut -d'"' -f4)"
    [[ "$got_ver" == "$EXPECT_VER" ]] \
      && ok "meta.json 的版本是 $EXPECT_VER" \
      || bad "meta.json 版本对不上：盘里是 [$got_ver]，源码是 [$EXPECT_VER]"
    grep -q '"profile": *"QUICK"' "$RUNDIR/meta.json" \
      && ok "档位确实选中了 QUICK（sendkey 生效了）" \
      || bad "档位不是 QUICK —— 选档按键没打中，实际跑的是默认 STANDARD"
  else
    bad "meta.json 不存在"
  fi

  # --- 判定分布：这台"机器"是虚拟的，很多项必然 SKIP，但不该有 FAIL ---
  if [[ -s "$RUNDIR/results.jsonl" ]] && command -v jq >/dev/null 2>&1; then
    n_fail="$(jq -s '[.[] | select(.status == "FAIL")] | length' "$RUNDIR/results.jsonl" 2>/dev/null || echo -1)"
    n_all="$(jq -s 'length' "$RUNDIR/results.jsonl" 2>/dev/null || echo 0)"
    info "判定共 $n_all 项，其中 FAIL $n_fail 项"
    if [[ "$n_fail" != "0" ]]; then
      # QEMU 里没有 BMC、没有阵列卡、没有显卡，这些都该 SKIP 不该 FAIL。
      # 真出现 FAIL 说明有判定逻辑把"没有这个硬件"当成了"硬件坏了"——
      # 这正是二号原则（能力缺失 ≠ 硬件故障）要防的事。
      bad "虚拟机上出现了 $n_fail 条 FAIL（虚拟环境不该有硬件故障）"
      jq -r 'select(.status=="FAIL") | "       " + .id + ": " + .detail' \
         "$RUNDIR/results.jsonl" 2>/dev/null | head -10
    else
      ok "一条 FAIL 都没有（没把「虚拟机里没这个硬件」误判成故障）"
    fi

    # collect_disk 是 21 个判定 id 里唯一单元测试覆盖不到的，这里正好带上
    jq -e -s 'any(.[]; .id == "collect_disk")' "$RUNDIR/results.jsonl" >/dev/null 2>&1 \
      && ok "collect_disk 有结论（单元测试覆盖不到的那一项）" \
      || bad "collect_disk 这一项没出现在结论里"
  fi

  # --- 交付边界：报告里不许有内部用语 ---
  if [[ -s "$RUNDIR/$TAG.html" ]]; then
    leaked=""
    for w in "重新出盘" "构建目录" "盘内缺少" "vendor/" "storcli" "git commit"; do
      grep -qF -- "$w" "$RUNDIR/$TAG.html" 2>/dev/null && leaked="$leaked $w"
    done
    [[ -z "$leaked" ]] && ok "交付报告里没有内部用语（真跑出来的那一份，不是造的 fixture）" \
                       || bad "交付报告泄漏了内部用语：$leaked"
  fi
fi

# ---------------------------------------------------------------- 收尾
umount "$MNT" 2>/dev/null
losetup -d "$LOOP" 2>/dev/null; LOOP=""

printf '\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
