#!/usr/bin/env bash
#
# 变异测试：把已经修好的 bug 逐个塞回代码里，确认对应的用例真的会跑红。
#
#     ./tests/mutate.sh              # 跑全部变异（默认按 nproc 并发）
#     ./tests/mutate.sh verdict-grep # 只跑一条
#     ./tests/mutate.sh -j 1         # 串行（排查某一条、或者机器吃紧时）
#     ./tests/mutate.sh --list       # 看有哪些
#
# ================================================================
# 为什么要有它
# ================================================================
# 「一个从没红过的测试等于没写」是这个项目反复说的一句话，而且是有依据的：
# 客户文案守卫曾经是个摆设（用 grep 扫 result_add，grep 逐行工作、只看得到
# 调用的第一行，而长文案全写在续行里），一句"本测试盘未包含"就那么进了客户报告。
#
# 问题在于，这种验证一直是**一次性人工**做的 —— 做完就没了，下次谁改了守卫，
# 没人会再手工验一遍。这个脚本把它固化成可重复执行的闸门。
#
# ================================================================
# 每条变异都对应一次真实翻车
# ================================================================
# 不要为了凑数加变异。加一条的标准是：**它曾经真的发生过，或者它一旦发生
# 后果严重到必须有人守**。每条都在下面写清楚它对应哪条不变量。
#
# ================================================================
# 安全性：**真工作区自始至终只读**（1.9.5 起）
# ================================================================
# 每条变异都在自己的**临时副本**里施加、在副本里跑套件，真源码一个字节都不动。
# 所以：
#   - 跑变异的时候照样能看 `git diff`、能提交（以前不行）
#   - 中途 Ctrl-C 不会留下改了一半的源码（以前会）
#   - 并行是天然安全的 —— 这也是它现在默认多路并发的前提
# 开跑前给整棵树留一份 sha256，跑完再比一次；对不上说明有人在变异函数里
# 写了绝对路径，当场大声报错。
#
# 它不碰 git，也不要求工作区干净。
#
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

RT="rootfs/opt/klburn"

# ================================================================
# 变异清单
# ================================================================
# 每条五个字段，用 $'\x1f' 分隔（正文里出现的概率为零）：
#   id ¦ 说明（对应哪条不变量）¦ 要跑哪个测试套件 ¦ 会被改的文件 ¦ 施加变异的函数名
#
# 文件单独列一列，而不是让变异函数顺便返回 —— 备份必须发生在施加之前，
# 让函数兼职报告文件名的话就得先跑一次再回滚，那才是真正危险的设计。
S=$'\x1f'
MUTATIONS=(
"ssh-source-exec-mode${S}SSH 归档丢掉 Git 执行位，发送端干净但接收端无法启动${S}test-customize${S}tools/customize/klburn-builder.py${S}mut_ssh_source_exec_mode"
"ssh-receiver-mode-check${S}接收端继承 filemode=false，执行位篡改无法触发脏源码守卫${S}test-customize${S}tools/customize/klburn-builder.py${S}mut_ssh_receiver_mode_check"
"package-notice-wrong-version${S}用另一版本版权文本填补缺失声明（基础包精确版本绑定失效）${S}test-package-notices${S}build/package-notices.py${S}mut_package_notice_wrong_version"
"package-notice-host-link${S}版权绝对链接借用宿主机文件而不是目标 ISO 根目录${S}test-package-notices${S}build/package-notices.py${S}mut_package_notice_host_link"
"package-notice-hook-missing${S}移除最终打包前版权检查调用（有函数却从不执行）${S}test-package-notices${S}build/build-iso.sh${S}mut_package_notice_hook_missing"
"mem-report-early-success${S}未等到内存报告就宣称完成（固定计时曾提前关机导致报告丢失）${S}test-e2e-log-wait${S}tests/lib/e2e-log-wait.sh${S}mut_mem_report_early_success"
"mem-report-stale-anchor${S}允许启动前已有的报告完成字节冒充本轮完成${S}test-e2e-log-wait${S}tests/lib/e2e-log-wait.sh${S}mut_mem_report_stale_anchor"
"verdict-grep${S}整机结论换回 grep 匹配 JSON 文本（§11-1 的 JSON 版：格式一变就每台机器都判 PASS）${S}test-hw-checks${S}$RT/factory-test.sh${S}mut_verdict_grep"
"verdict-empty${S}交付报告把「一条判定都没有」当成通过（什么都没测过的机器打绿色 PASS）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_verdict_empty"
"verdict-empty-int${S}内部报告把「一条判定都没有」当成通过（三处结论口径必须一致）${S}test-internal-report${S}$RT/report/generate_internal.py${S}mut_verdict_empty_int"
"verify-chain${S}把 verify_disk_temp 从 verify_all 里删掉（判定函数还在，只是再没被调用过）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_verify_chain"
"oom-fail${S}内存压测被 OOM 打死不再判 WARN（0.7.0 把好机器拦在出货前的那条）${S}test-log-parsing${S}$RT/lib/stress.sh${S}mut_oom_fail"
"lint-exempt${S}给 lint 偷偷多加一类豁免（豁免清单本身也要有人守）${S}lint${S}tests/lint.sh${S}mut_lint_exempt"
"net-servers${S}NET_TIME_SERVERS 改回裸赋值（现场在 klburn.conf 里换内网 NTP 会被静默顶掉）${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_net_servers"
"fd0-overreach${S}把软驱豁免扩大成所有设备（真盘的 I/O error 会被一起吃掉，坏盘查不出来）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_fd0_overreach"
"aer-init-noexempt${S}退回 1.7.3：不豁免 AER 启用日志（§2-2：固件把 AER 交给 OS 的平台，每台好机器都判 FAIL）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_aer_init_noexempt"
"pcie-all-onboard${S}把所有设备都当板载（插槽上的卡降速从此没人报，整条判定变成空跑）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_pcie_all_onboard"
"pcie-devof-fn${S}插槽比对带上功能号（DMI 只列 function 0，双口卡的第二个口会被误判成板载）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_pcie_devof_fn"
"disk-hide-fail${S}硬盘那两项连 FAIL 也一起藏（新增坏道的盘从客户报告里消失，坏盘直接出厂）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_disk_hide_fail"
"raid-hint-subshell${S}退回 1.7.6：raid_bmc_hint 用命令替换调（子 shell，标志位传不出来，整条线是死代码）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_raid_hint_subshell"
"deep-to-customer${S}「扩展信息留档」重新进客户报告（判的是我们的存档，不是机器）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_deep_to_customer"
"psu-not-present${S}退回裸 *Present* 匹配（Not Present 含 Present 子串，缺一路电源的机器被判正常）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_not_present"
"psu-ghost-count${S}空电源槽位（0W + 身份全占位符）重新计入在位数（报告写 4 个，实际 3 个）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_ghost_count"
"disk-none-fail${S}没装硬盘时判 FAIL 而不是 WARN（§2-2：能力缺失 ≠ 硬件故障，会把无盘机器拦在出货前）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_disk_none_fail"
"counter-postfix${S}断言计数改回 (( PASS++ ))（X=0 时返回 1，让 cond && ok || bad 两边都跑）${S}lint${S}tests/lint.sh${S}mut_counter_postfix"
"media-blind${S}scan_disks 不再反查启动 U 盘（Ventoy 下前两层同时落空，fio 会把测试盘写穿）${S}test-hw-checks${S}$RT/lib/storage.sh${S}mut_media_blind"
"ecc-ue-warn${S}内存不可纠正错误判 WARN 而不是 FAIL（数据已经错了，这种机器不能出厂）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_ecc_ue_warn"
"ecc-noedac-pass${S}读不到 EDAC 时判 PASS 而不是 SKIP（没查过和查过没问题被混为一谈）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_ecc_noedac_pass"
"counter-abs${S}计数器判定看绝对值而不是前后差值（带着历史计数的二手机器会被全判故障）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_counter_abs"
"screen-nonascii${S}面板不再过滤非 ASCII（一个中文字节就能把 BMC 上那屏顶成乱码）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_screen_nonascii"
"gpu-cap-fail${S}超过 8 张卡时不再收口（进度条被挤出屏幕，现场看不到测到哪了）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_gpu_cap"
"review-hang${S}配置核对面板的倒计时永不到点（现场插上去像死机，最怕的那种）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_review_hang"
"brand-nofit${S}大字标题不管装不装得下都画（超一行就滚屏，整屏重绘从此越刷越歪）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_brand_nofit"
"csv-unread${S}sys_metrics 多采一列却没人读（采了没人看等于没采）${S}test-internal-report${S}$RT/report/generate_internal.py${S}mut_csv_unread"
"rawindex-gap${S}加了新采集却忘了在 raw 索引里写说明（没人知道那份文件是什么）${S}test-internal-report${S}$RT/report/generate_internal.py${S}mut_rawindex_gap"
"emph-literal${S}判定文案里的 **重点** 原样印给客户（客户看到两串字面星号）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_emph_literal"
"gpu-loss-blind${S}退回 1.7.8：内核日志模式里没有掉卡关键字（掉下总线的显卡照样判 PASS 出厂）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_gpu_loss_blind"
"gpu-sample-blind${S}采样统计把读不到卡的行也算成有效（掉卡后的空行凑满有效率，掉卡判据整条失效）${S}test-log-parsing${S}$RT/lib/gpu.sh${S}mut_gpu_sample_blind"
"gpu-progress-zero${S}认不出进度格式时当成停滞（§2-2：读不懂日志反过来判客户的卡停转了）${S}test-concurrent-burn${S}$RT/lib/gpu.sh${S}mut_gpu_progress_zero"
"jbod-dup-disk${S}退回 1.7.8：直通盘不按序列号去重（同一块盘在客户报告里列两行，客户以为有两块）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_jbod_dup_disk"
"serial-merge-blank${S}序列号为空时也拿来撞（两块都读不到序列号的盘被并成一块，少报一块盘）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_serial_merge_blank"
"backplane-to-customer${S}背板盘位数进客户报告（拿不准的数字给客户看，会被当成缺件）${S}test-internal-report${S}$RT/report/generate_report.py${S}mut_backplane_to_customer"
"raid-dead-as-toolgap${S}退回 1.8.1：驱动没接管的坏卡说成「管理工具不支持」（把硬件故障粉饰成能力缺失，坏卡出厂）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_raid_dead_as_toolgap"
"raid-nodriver-as-fault${S}内核里没这张卡的驱动也判故障（§2-2 反向：我们缺能力却说客户的卡坏了）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_raid_nodriver_as_fault"
"gpu-stale-panel${S}退回 1.8.0：仪表盘继续显示掉卡前的缓存读数（现场看着卡还在满载跑）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_gpu_stale_panel"
"dmesg-raw-dump${S}内核错误摘要退回「条数 + 内核断言原文」（读起来像 3018 个毛病，且没人看得懂）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_dmesg_raw_dump"
"pdf-expand-logs${S}打印样式不再折叠原始日志（一份报告转出来 179 页，171 页是日志）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_pdf_expand_logs"
"pdf-pre-overflow${S}打印样式不再让长行换行（长行冲出页面，右边整片被切掉）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_pdf_pre_overflow"
"pdf-flex-row${S}判定行在 PDF 里退回 flex（徽章/名称/详情叠印成一团）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_pdf_flex_row"
"rapl-double${S}退回 1.8.2：同一个 RAPL package 域两条路径各算一遍（客户报告里的 CPU 功耗整整翻一倍）${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_rapl_double"
"psu-ac-overclaim${S}读不到任何交流输入传感器时照样写「交流输入…正常」（表里整列是破折号，文案却说核对过了）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_ac_overclaim"
"psu-cap-raw${S}额定功率原样照抄 DMI（0xFFFF 印成「65535 W」，客户每台都要问一遍）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_psu_cap_raw"
"badindex-content${S}dmidecode 的 <BAD INDEX> 当成厂商/型号内容（四格乱码印进客户报告）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_badindex_content"
"serial-na${S}整机序列号不认 N/A 这类占位符（报告抬头和报告目录都叫「NA」，而主板序列号是真的）${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_serial_na"
"serial-punctuation${S}全标点 BIOS/FRU 序列号又当成有效身份${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_serial_punctuation"
"mem-bmc-clock${S}内存盘无网络时又访问 BMC 校时${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_mem_bmc_clock"
"gpu-serial-zero${S}消费级显卡的 Serial Number: 0 当成序列号印出去（客户会拿这个 0 去对货）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_gpu_serial_zero"
"sample-state-persubshell${S}两次采样求差的「上一次读数」传不过子 shell（功耗/占用率/速率全变成「从压测开始到现在的平均值」）${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_sample_state_per_subshell"
"psu-sdr-outofrange${S}把离散量的 out-of-range 当成没进电（offset 5 明写 but present，会把好电源报成掉电）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_sdr_outofrange"
"psu-sdr-as-fail${S}离散量说有电就够格判 FAIL（FAIL 的证据标准被放低一档，§2-2 反向误杀）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_sdr_as_fail"
"raid-dup-fail-blind${S}坏阵列卡的两条 FAIL 不再互相指认（客户把同一件事读成两处独立故障）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_raid_dup_fail_blind"
"disk-temp-fake-burn${S}没跑硬盘压测也说「压测结束时温度」（客户以为我们烤过盘）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_disk_temp_fake_burn"
"nic-fw-path${S}网卡固件那一格原样印出 rtl_nic/xxx.fw（看着像漏了一条路径出去）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_nic_fw_path"
"metric-internal-leak${S}内部计数「失败压测项」重新进客户报告（判的是我们，不是机器）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_metric_internal_leak"
"metric-tool-name${S}压测工具的名字重新进客户报告（走数据那一路，查源码的守卫拦不住）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_metric_tool_name"
"result-tool-name${S}判定文案里重新写上 stress-ng（走源码那一路，由 FORBIDDEN 拦）${S}test-hw-checks${S}$RT/lib/stress.sh${S}mut_result_tool_name"
"metric-group-raw${S}「其他实测指标」的分组列退回内部键（一份中文报告里夹着 mem / pcie / gpu0）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_metric_group_raw"
"bogus-prefix-drop${S}Python 那份占位符名单丢掉「to be filled」前缀兜底（三份名单又不一致了）${S}test-hw-checks${S}$RT/report/generate_report.py${S}mut_bogus_prefix_drop"
"conform-bogus-uniq${S}一致性比对不再过滤占位符（BIOS 没填 PN 的机器被判成内存混插）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_conform_bogus_uniq"
"gpu-ecc-na-as-zero${S}显存 ECC 把 [N/A] 当成 0（没有 ECC 的卡被报成「ECC 全部正常」）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_gpu_ecc_na_as_zero"
"gpu-eccdetail-na-as-zero${S}ECC 分项把 [N/A] 当成 0（5090 这类没有 ECC 的卡被报成「两路分别核对均为 0」）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_gpu_eccdetail_na_as_zero"
"gpu-sram-agg-own-threshold${S}缓存历史错误改成我们自己定的次数门槛（凭空替客户定了一个标准）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_gpu_sram_agg_own_threshold"
"gpu-sram-thr-na-counted${S}厂家那个标志读到 N/A 也算一张卡（没有这机制的卡被报成「已核对、未超上限」）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_gpu_sram_thr_na_counted"
"gpu-csv-col-by-pos${S}采样列退回按位置拼（少采几列时 ECC 的数字写进风扇转速那一格）${S}test-hw-checks${S}$RT/lib/gpu.sh${S}mut_gpu_csv_col_by_pos"
"gpu-burn-tc-noprobe${S}不探就直接上 -tc（没有张量核的老卡非零退出 -> 好卡被判成坏卡）${S}test-hw-checks${S}$RT/lib/gpu.sh${S}mut_gpu_burn_tc_noprobe"
"fan-policy-fail${S}风扇策略不是全速就判 FAIL（那是订单要求，不是硬件好坏）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_fan_policy_fail"
"linpack-col-by-pos${S}算力按列位置取而不是按列名取（计时表第 4 列是秒，「跑了几次」也数不出来）${S}test-log-parsing${S}$RT/lib/bench.sh${S}mut_linpack_col_by_pos"
"gpu-clkmin-noskip${S}满载最低频率不再跳过前两个采样点（每台机器都凭空多出一条严重降频）${S}test-log-parsing${S}$RT/lib/gpu.sh${S}mut_gpu_clkmin_noskip"
"disk-tool-name${S}硬盘压测文案重新写上工具名（1.8.4 漏掉 fio 的那条，走源码那一路）${S}test-hw-checks${S}$RT/lib/stress.sh${S}mut_disk_tool_name"
"accept-group-drop${S}报告分节时把压测那一段的判定漏掉（分组只该决定印在哪一节，不该吞判定）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_accept_group_drop"
"accept-metric-dup${S}已经有专属小节的指标又进「其他实测指标」（同一个数字印两遍）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_accept_metric_dup"
"gpumem-history-leak${S}显存的累计/历史读数又漏进客户报告（和硬盘通电时间同一把尺子）${S}test-internal-report${S}$RT/report/generate_report.py${S}mut_gpumem_history_leak"
"bench-caliber-overwrite${S}逐盘带宽表的「测试口径」被写方向覆盖（读带宽那格顶着 _write_ 的口径）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_bench_caliber_overwrite"
"bench-title-static${S}逐盘带宽表的标题写死成「读写」（只测了读的机器上说得比测得多）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_bench_title_static"
"bench-empty-section${S}性能基准整节的判据把 bench 指标也算进去（画出一个只有标题的空章节）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_bench_empty_section"
"bench-status-warn${S}性能基准判出 WARN（性能数字不参与合格判定，只有 PASS/SKIP）${S}test-report-render${S}$RT/lib/bench.sh${S}mut_bench_status_warn"
"bench-pointer-static${S}判定文案里的指路写死成「读写」那一节（指向报告里不存在的小节）${S}test-hw-checks${S}$RT/lib/bench.sh${S}mut_bench_pointer_static"
"disk-uniform-usb${S}硬盘一致性不再按 scan_disks 的范围比（没插硬盘的机器拿我们自己那根 U 盘凑一组判 PASS）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_disk_uniform_usb"
"vtd-empty-fallthrough${S}VT-d 在 sysfs 空目录时又掉回去翻内核日志（一个已经确定的 disabled 被换成「读不到」）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_vtd_empty_fallthrough"
"vtd-fake-patterns${S}VT-d 的内核日志判据退回真机上一条都不命中的那两句${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_vtd_fake_patterns"
"gpu-load-metric-dup${S}逐卡满载读数又拆进「其他实测指标」（和那句结论重复，而且拆完就没了单位）${S}test-internal-report${S}$RT/report/generate_report.py${S}mut_gpu_load_metric_dup"
"freq-window-split${S}最低频率和平均频率拆回两个窗口（报告上印出「最低 2688 > 平均 2686」）${S}test-log-parsing${S}$RT/lib/stress.sh${S}mut_freq_window_split"
"bmc-zero-as-fail${S}传感器读数 0 直接判临界（空着的风扇位把好机器判 FAIL）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_bmc_zero_as_fail"
"bmc-judge-pre-snapshot${S}部件传感器判的是测前那份快照（压测把风扇跑停了永远查不出来）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_bmc_judge_pre_snapshot"
"bmc-discrete-mixed-in${S}离散量传感器也拿去比阈值（PWR_Button 这种被判成异常）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_bmc_discrete_mixed_in"
"selftest-fail-as-pass${S}硬盘自检「Completed: read failure」被当成通过（坏盘拿着干净报告出厂）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_selftest_fail_as_pass"
"selftest-never-read${S}发起了硬盘自检却没人读结果（盘在后台白跑一遍）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_selftest_never_read"
"nic-selftest-after-linkup${S}网卡自检排到拉链路之后（自检把链路踢掉，好机器被判成网口不通）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_nic_selftest_after_linkup"
"nic-selftest-link-as-fail${S}网卡自检只读总结论、不拆子项（没插网线的口被判成「网口硬件故障，需返修」）${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_nic_selftest_link_as_fail"
"gpu-temp-limit-ignored${S}显卡温度限值不问卡自己要（回到凭空钉死的那个数，好卡每轮刷黄）${S}test-hw-checks${S}$RT/lib/gpu.sh${S}mut_gpu_temp_limit_ignored"
"onboard-nic-placeholder-as-off${S}板载网口把主板没填的占位地址读成「BIOS 里禁用了」${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_onboard_nic_placeholder_as_off"
"fwts-to-customer${S}固件自检漏进客户报告（好机器上 ACPI 告警极常见，每台都刷一片黄）${S}test-internal-report${S}$RT/report/generate_report.py${S}mut_fwts_to_customer"
"memtest-first-entry${S}memtest 菜单项插到第一条（插上盘开机跑的是内存测试，不是我们的测试）${S}test-batch-tools${S}build/lib/patch-grub.py${S}mut_memtest_first_entry"
"summary-empty-as-pass${S}批次汇总把「一条判定都没有」算成 PASS（第四处口径自成一套）${S}test-batch-tools${S}tools/klburn-summary.py${S}mut_summary_empty_as_pass"
"sdc-nonzero-as-fail${S}专项验证把「非零退出」直接当成机器坏了（工具跑不起来 = 判客户的机器 FAIL）${S}test-log-parsing${S}$RT/lib/validate.sh${S}mut_sdc_nonzero_as_fail"
"sn-to-customer${S}序列号一致性漏进客户报告（组装机没处写序列号，每台都刷一条黄）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_sn_to_customer"
"selfskip-to-customer${S}「我们没带那个程序」的 SKIP 漏进客户报告（客户读成「这家供应商的工具箱是破的」）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_selfskip_to_customer"
"selfskip-overreach${S}藏 SKIP 的规则扩大化，把「本机只有一张卡」这种机器事实也藏了${S}test-report-render${S}$RT/report/generate_report.py${S}mut_selfskip_overreach"
"d2d-single-size${S}显存带宽退回只量一个小块（量到的是显卡缓存：4090 报出 3622 GB/s，标称 1008）${S}test-log-parsing${S}$RT/lib/bench.sh${S}mut_d2d_single_size"
"d2d-take-fastest${S}显存带宽曲线取最快那一行而不是最大块那一行（挑中的正是被缓存喂出来的小块）${S}test-log-parsing${S}$RT/lib/bench.sh${S}mut_d2d_take_fastest"
"psu-ghost-ignores-bmc${S}BMC 读到有电的电源仍被当成空槽位丢掉（四路数成三路，和现场那一屏对不上）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_ghost_ignores_bmc"
"psu-redundancy-unconditional${S}「不具备电源冗余」又变回无条件拼（四路掉一路的机器被说成没冗余）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_redundancy_unconditional"
"remap-index-field${S}行重映射查询加回 index 字段（每台机器都静默 SKIP，还对客户断言「该型号无此机制」）${S}test-hw-checks${S}$RT/lib/conformance.sh${S}mut_remap_index_field"
"disk-scope-skips-confirm${S}硬盘专测直接把破坏性写确认当成已同意（不问就擦盘）${S}test-hw-checks${S}$RT/factory-test.sh${S}mut_disk_scope_skips_confirm"
"info-scope-green-pass${S}仅导出硬件信息那一档打出绿色 PASS 大字（把「没测」包装成「通过」）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_info_scope_green_pass"
"info-scope-green-pass-screen${S}同上，现场那块屏幕的版本（收尾那一屏打 PASS 大字）${S}test-screen-render${S}$RT/lib/ui.sh${S}mut_info_scope_green_pass_screen"
"scope-stress-unguarded${S}范围之外的部件照样压（选了只测 CPU，内存还是被压了 30 分钟）${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_scope_stress_unguarded"
"scope-tag-dropped${S}报告目录名不带范围后缀（单项专测和全量的目录长得一模一样）${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_scope_tag_dropped"
"scope-summary-plain-pass${S}批次汇总把单项专测的 PASS 写成和全量一样的 PASS${S}test-batch-tools${S}tools/klburn-summary.py${S}mut_scope_summary_plain_pass"
"flops-only-best${S}算力只认末尾那行汇总（被超时打断时把已经量到的成绩白扔，平白判 SKIP）${S}test-log-parsing${S}$RT/lib/bench.sh${S}mut_flops_only_best"
"scope-missing-as-pass${S}选了显卡专测却没有显卡时不再判 FAIL（一项没测的机器拿到绿色 PASS）${S}test-hw-checks${S}$RT/factory-test.sh${S}mut_scope_missing_as_pass"
"scope-missing-blames-hw${S}缺部件那条 FAIL 套用「不建议出货」（把一台好机器说成硬件有毛病）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_scope_missing_blames_hw"
"scope-burn-skipped-green${S}选了硬盘专项、硬盘压测却被跳过，报告仍打绿色 PASS（把「没测」包装成「通过」）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_scope_burn_skipped_green_pass"
"scope-filter-hides-bad${S}范围裁剪把 WARN / FAIL 也一起藏掉（有毛病的机器拿到一份干净的专项报告）${S}test-report-render${S}$RT/report/generate_report.py${S}mut_scope_filter_hides_bad"
"pcie-idle-snapshot${S}PCIe 链路退回拿一次空闲快照判定（同一张卡六轮四轮误报）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_pcie_idle_snapshot_verdict"
"nic-selftest-nolink-fail${S}没插网线的口自检失败照样判 FAIL（1.9.2 和 1.9.7 各栽过一次）${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_nic_selftest_nolink_fails"
"bmc-virtual-nic-judged${S}BMC 的 USB 虚拟网口重新进判定（每台带 BMC 的机器都被刷一条 WARN）${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_bmc_virtual_nic_judged"
"gpu-d2d-int-overflow${S}显存 D2D 块大小退回 2GiB（正好溢出 32 位参数，每台大显存的卡都测不到）${S}test-log-parsing${S}$RT/lib/bench.sh${S}mut_gpu_d2d_int_overflow"
"psu-bench-wiring-warn${S}四路电源少插一根线又变回 WARN（七个版本 11 次，一次都不是真问题）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_psu_bench_wiring_warn"
"disk-confirm-single-key${S}破坏性写确认第二关退回单键（按下去就擦盘，没有反悔余地）${S}test-hw-checks${S}$RT/lib/storage.sh${S}mut_disk_confirm_single_key"
# ---- 内存专用盘（1.10.0）----
"mem-sn-dup-warn${S}序列号重复只判 WARN（那批假条子压测全过，就靠这一条拦，判 WARN 等于放行）${S}test-mem-edition${S}$RT/lib/memcheck.sh${S}mut_mem_sn_dup_warn"
"mem-dmesg-overreach${S}内存日志模式收回 uncorrectable（PCIe AER 也用这个词，坏阵列卡会被算成内存坏）${S}test-mem-edition${S}$RT/lib/memcheck.sh${S}mut_mem_dmesg_overreach"
"mem-spd-unread-fail${S}读不到 SPD 判 FAIL 而不是 SKIP（SMBus 归 BMC 管的平台上，每台好机器都被拦下）${S}test-mem-edition${S}$RT/lib/memcheck.sh${S}mut_mem_spd_unread_fail"
"mem-scope-silent${S}内存报告删掉「本报告仅针对内存」（一个孤零零的 PASS 会被当成整机验收通过）${S}test-mem-edition${S}$RT/report/generate_mem_report.py${S}mut_mem_scope_silent"
"mem-sn-empty-slots${S}空槽位也参与序列号比对（空槽占位符都是 NO DIMM，每台没插满的机器都判假货）${S}test-mem-edition${S}$RT/lib/memcheck.sh${S}mut_mem_sn_empty_slots"
# ---- 1.10.1：逐条审完 1.9.9 / 1.10.0 现场报告之后加的 ----
"full-scope-skips-confirm${S}全量档那道破坏性写确认也被当成已同意（不问就擦盘）${S}test-hw-checks${S}$RT/factory-test.sh${S}mut_full_scope_skips_confirm"
"disk-declined-keeps-running${S}硬盘专测没确认擦盘时悄悄跑完并打 PASS（那一项就是那一轮的全部意义）${S}test-hw-checks${S}$RT/factory-test.sh${S}mut_disk_declined_keeps_running"
"nic-loopback-nolink-hw${S}没插网线时回环子项又算成硬件故障（mlx5 每个空口都刷一条「自检未通过」）${S}test-hw-checks${S}$RT/lib/network.sh${S}mut_nic_loopback_nolink_hw"
"pcie-speed-without-load${S}没加载过的卡照样判速率（内存/硬盘专测里每张显卡都刷一条 2.5GT/s）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_pcie_speed_without_load"
"pcie-width-needs-load${S}宽度也要「加载过」才判（宽度训练一次就定死，豁免它 = 放过真的只跑到 x8 的卡）${S}test-hw-checks${S}$RT/lib/collect.sh${S}mut_pcie_width_needs_load"
"psu-noac-exempts-all${S}电源没进电的豁免扩大到所有 0 读数（一颗停转的机箱风扇会被顺手放过）${S}test-hw-checks${S}$RT/lib/verify.sh${S}mut_psu_noac_exempts_all"
"sensors-state-all-scopes${S}整机部件传感器又进单项专测的结论（内存专测报告顶上挂一条没插线的 PSU）${S}test-hw-checks${S}$RT/lib/core.sh${S}mut_sensors_state_all_scopes"
)

# ================================================================
# 有两条守卫**故意没有**变异 —— 不是漏了
# ================================================================
# 本脚本的契约是"3~5 分钟、不需要构建"。下面这两条都违反它，硬塞进来会让
# 每次跑变异都变成一小时，最后的结果是没人再跑它。
# （和 e2e 那条"把启动 U 盘写穿"的变异同一个道理，见 architecture.md。）
#
#   build-gpu-burn.sh 的逐代 cubin 自检
#       要重新裁剪 1GB 的 cuBLAS 静态库再链接一遍，十几分钟起步，
#       而且要机器上装着 CUDA。它自己已经红过一次（1.7.0 那版体积启发式
#       就是被它的前身抓出来的），不是没验过的守卫。
#
#   check-firmware.sh 的 pci.ids 日期断言
#       check-firmware 要一个**已经构建出来的 rootfs**，没构建过它判 0 项跳过。
#       在没有 rootfs 的机器上塞这条变异，会得到"逃掉了"的**假警报** ——
#       而假警报比漏报还难查，人会去改一条本来就没问题的守卫。

# ================================================================
# 施加变异的原语
# ================================================================
# 一律按**整行**替换/删除，锚点用固定字符串（grep -F），不写正则 ——
# 正则锚点一旦因为代码微调而失配，变异其实没施加上，测试当然是绿的，
# 于是这里会报告"这条变异逃掉了"。那是**假警报**，比漏报还难查。
# 所以锚点必须**恰好命中一行**，命中 0 次或多次都当场判错。

anchor_count() { grep -cF -- "$2" "$1" 2>/dev/null || echo 0; }

# ⚠️ 锚点和替换文本一律走 ENVIRON 传给 awk，**绝不能用 `awk -v`**。
#    `-v` 会对值做一遍反斜杠转义处理：锚点里的 `\033` 会在 awk 里变成一个真的
#    ESC 字节，而文件里是 `\`+`0`+`3`+`3` 四个字符，于是 index() 永远匹配不上。
#    表现极其难查 —— 上面 anchor_count 用的是 grep -F，它照样报"命中 1 次"，
#    于是变异**静默没施加**、对应套件照常全绿，最后被报成"这条守卫逃掉了"。
#    假警报比漏报还难查：人会去改一条本来就没问题的守卫。
#    （counter-postfix 就是这么栽的，它的锚点里正好有 \033。）
#
# 再加一道后置检查：施加完文件必须真的变了。锚点匹配得上、替换却没生效
# 这件事只要发生过一次，就说明"逃掉"这个结论本身不可信。
_apply_awk() {
  local f="$1" prog="$2"
  MUT_NEEDLE="${3:-}" MUT_NEW="${4:-}" awk "$prog" "$f" > "$f.mut" \
    || { rm -f "$f.mut"; printf 'awk 执行失败（%s）' "$f"; return 1; }
  if cmp -s "$f" "$f.mut"; then
    rm -f "$f.mut"
    printf '变异没有真的改到 %s —— 锚点匹配得上、替换却没生效' "$f"
    return 1
  fi
  mv "$f.mut" "$f"
}

replace_line() {
  local f="$1" needle="$2" new="$3" n
  n="$(anchor_count "$f" "$needle")"
  if [[ "$n" != "1" ]]; then
    printf '锚点在 %s 里命中 %s 次（要求恰好 1 次），变异无法可靠施加' "$f" "$n"
    return 1
  fi
  _apply_awk "$f" \
    'index($0, ENVIRON["MUT_NEEDLE"]) { print ENVIRON["MUT_NEW"]; next } { print }' \
    "$needle" "$new"
}

delete_line() {
  local f="$1" needle="$2" n
  n="$(anchor_count "$f" "$needle")"
  if [[ "$n" != "1" ]]; then
    printf '锚点在 %s 里命中 %s 次（要求恰好 1 次），变异无法可靠施加' "$f" "$n"
    return 1
  fi
  _apply_awk "$f" 'index($0, ENVIRON["MUT_NEEDLE"]) { next } { print }' "$needle"
}

# ================================================================
# 各条变异（函数名要和上面清单里的对上）
# 每个函数只负责改文件，成功回 0、失败把原因打到 stdout
# ================================================================
mut_ssh_source_exec_mode() {
  replace_line tools/customize/klburn-builder.py \
    '            member.mode = tracked_modes[member.name]' \
    '            member.mode = 0o644'
}

mut_ssh_receiver_mode_check() {
  replace_line tools/customize/klburn-builder.py \
    '    remote_command = ("git -C " + remote + "/source config --local core.filemode true && python3 "' \
    '    remote_command = ("python3 "'
}

mut_package_notice_wrong_version() {
  replace_line build/package-notices.py \
    'if name not in texts or texts[name][0]["binary_version"] != version:' \
    '            if name not in texts:'
}

mut_package_notice_host_link() {
  replace_line build/package-notices.py \
    '    pending = normalize(name.split("/"))' \
    '    return (root / name).resolve(strict=True)'
}

mut_package_notice_hook_missing() {
  delete_line build/build-iso.sh 'python3 "$SCRIPT_DIR/package-notices.py"'
}


mut_mem_report_early_success() {
  replace_line tests/lib/e2e-log-wait.sh "if wait_for_log 'Report PDF written'" '  if true; then'
}

mut_mem_report_stale_anchor() {
  replace_line tests/lib/e2e-log-wait.sh 'if image_has "$1"; then' '  if false; then'
}

mut_verdict_grep() {
  replace_line "$RT/factory-test.sh" \
    "if jq -e -s 'any(.[]; .status == \"FAIL\")'" \
    'if grep -q '"'"'"status":"FAIL"'"'"' "$RUN_DIR/results.jsonl" 2>/dev/null; then'
}

mut_verdict_empty() {
  replace_line "$RT/report/generate_report.py" \
    "no_results = not statuses" \
    "    no_results = False"
}

mut_verdict_empty_int() {
  replace_line "$RT/report/generate_internal.py" \
    'overall = "FAIL" if ("FAIL" in st or not st) else "PASS"' \
    '    overall = "FAIL" if "FAIL" in st else "PASS"'
}

mut_verify_chain() {
  delete_line "$RT/lib/verify.sh" "  verify_disk_temp"
}

mut_oom_fail() {
  replace_line "$RT/lib/stress.sh" \
    "(( rc == 137 )) || return 1" \
    "  (( rc == 1370 )) || return 1"
}

# tests/ 里到处是 `cond && ok "..." || bad "..."`（-S info 下 26 条 SC2015）。
# 它们安全**只依赖一件事**：ok()/bad() 返回 0。改成后缀 ++ 之后，PASS 为 0 的
# 那一次算术命令返回 1，"断言通过"接着又把 bad 跑一遍 —— 同一条既记通过又记失败。
mut_counter_postfix() {
  replace_line "tests/lint.sh" \
    "ok()  { printf '  \\033[32mOK\\033[0m   %s\\n' \"\$1\"; PASS=\$((PASS+1)); }" \
    "ok()  { printf '  \\033[32mOK\\033[0m   %s\\n' \"\$1\"; (( PASS++ )); }"
}

mut_lint_exempt() {
  replace_line "tests/lint.sh" \
    'EXCLUDE_RUNTIME="SC2034,SC2155,SC2120"' \
    'EXCLUDE_RUNTIME="SC2034,SC2155,SC2120,SC2086"'
}

# 豁免噪声最危险的失败方式不是"漏豁免"（那会误伤好机器，至少看得见），
# 而是"豁免扩大化"—— 顺手把真盘的 I/O error 一起吃掉，坏盘从此查不出来，
# 而且永远不会有人发现。
mut_fd0_overreach() {
  replace_line "$RT/lib/verify.sh" \
    "|dev fd[0-9]|AER: enabled with IRQ' \\" \
    "    | grep -viE 'thermal throttl.*not|nouveau|dev [a-z]|AER: enabled with IRQ' \\"
}

# 反过来那一半：**漏豁免**。1.7.3 就是这么把一台完好的海光 C86 判成
# 「上电初始化时就有硬件异常」的 —— 命中的四行全是内核在说"AER 已启用"。
# 谁踩不踩取决于固件交不交 AER，和 CPU 厂商无关，所以这条只能靠断言守，
# 不能指望"下次现场再发现一次"（§2-2：把好机器拦在出货前，比漏判更糟）。
mut_aer_init_noexempt() {
  replace_line "$RT/lib/verify.sh" \
    "|dev fd[0-9]|AER: enabled with IRQ' \\" \
    "    | grep -viE 'thermal throttl.*not|nouveau|dev fd[0-9]' \\"
}

# 「板载不判」这条豁免最危险的失败方式，和软驱那条是同一种：**扩大化**。
# 一旦所有设备都被当成板载，PCIe 链路那条判定就变成了空跑 —— 报告上还是绿的，
# 而"卡没插到底"从此再没人看得到。这条守的是 1.7.5 那条分界线本身。
mut_pcie_all_onboard() {
  replace_line "$RT/lib/collect.sh" \
    'local where="${slot_of[$bdf]:-unknown}"' \
    '    local where="onboard"'
}

# 更阴的一种：分界线还在，只是比对的粒度错了。DMI Type 9 只列 function 0，
# 带着功能号比，双口网卡的第二个口、四口卡的后三个口全会掉进"板载"，
# 于是插在槽上的卡降了速也只报一半。
mut_pcie_devof_fn() {
  replace_line "$RT/lib/collect.sh" \
    'function devof(b) { sub(/\.[0-9a-f]+$/, "", b); return b }' \
    '    function devof(b) { return b }'
}

# 1.7.6 把「硬盘压测没跑就别在客户报告里提」做成了过滤。这类过滤只有一种
# 失败方式是不可接受的：**连 FAIL 一起藏**。verify_smart 判 FAIL 的意思是
# 这一轮盘上新增了坏道，藏掉它 = 一块正在坏的盘拿着一份干净报告出厂。
# 「少写一行 SKIP」最多惹客户问一句，这个是把坏货放出去。
mut_disk_hide_fail() {
  replace_line "$RT/report/generate_report.py" \
    'and r.get("status") in ("PASS", "SKIP"))]' \
    '                         and True)]'
}

# 1.7.0~1.7.6 的真事：调用方写的是 `hint="$(raid_bmc_hint)"`，命令替换是**子 shell**，
# 里面设的 RAID_BMC_SILENT 出了子 shell 就没了 —— 那条判定从上线起就是死代码，
# 而两边的单元测试各自都绿（一边验文本、一边手工设标志位再验状态），
# **中间那根线一次都没测过**。这条变异把命令替换塞回去，钉住"接线本身"。
mut_raid_hint_subshell() {
  replace_line "$RT/lib/collect.sh" \
    '  raid_bmc_hint' \
    '  local _h; _h="$(raid_bmc_hint)"; : "$_h"'
}

# 「扩展信息留档」判的是我们的存档做没做，不是机器好不好 —— 它失败了客户
# 一个字都不会少拿。放回客户报告就是拿内部流程去占客户的版面（report-policy 二-4）。
mut_deep_to_customer() {
  replace_line "$RT/report/generate_report.py" \
    'INTERNAL_ONLY_ROWS = ("collect_deep", "collect_fwts", "check_sn_consistency")' \
    '    INTERNAL_ONLY_ROWS = ()'
}

# 一号红线（拿关键字当判定）在电源这条路上的同款：`Not Present` 里含有
# `Present` 子串，裸的 *"Present"* 会把明写"未在位"的槽位算成在位。
# 海光那台就是这么打出「共 2 个电源模块在位，交流输入与模块状态均正常」的 ——
# 而它 DMI 里两个槽位全是 Not Present / Plugged: No。
# 判错方向是最糟的那个：真缺一路电源的机器被说成正常。
mut_psu_not_present() {
  replace_line "$RT/lib/collect.sh" \
    '[[ "$st" == *"Present"* && "$st" != *"Not Present"* ]] || continue' \
    '    [[ "$st" == *"Present"* ]] || continue'
}

# 空的电源位 BIOS 照样报 Present, OK（6530 那台的 PSU4：0W + 身份全是占位符）。
# 计进去的话报告写「共 4 个电源模块在位」，客户一数电源就发现对不上。
mut_psu_ghost_count() {
  replace_line "$RT/lib/collect.sh" \
    '      real = (capseen && cap + 0 == 0 && idseen && !idreal) ? 0 : 1' \
    '      real = 1'
}

# 「本机未安装硬盘」和「硬盘坏了」是两回事。判成 FAIL 的话，出厂只测
# CPU/内存/网卡的无盘机器会被整机判不合格 —— 把好机器拦在出货前，
# 比漏判更糟（§2-2）。这条变异守的是 collect_disk 那三条分支里最要紧的一条。
mut_disk_none_fail() {
  replace_line "$RT/lib/collect.sh" \
    '"硬盘信息采集" "$ST_WARN"' \
    '      result_add "collect_disk" "硬盘信息采集" "$ST_FAIL" \'
}

# 整个项目最危险的一条路径：反查不出启动 U 盘 -> fio 把它当空盘写穿 ->
# 测试盘当场报废、历史报告全丢，不可逆。
# 排除有三层，但 Ventoy 场景下前两层（rm=1 / 有分区挂载）**同时**落空 ——
# 那时候只剩这一层。所以它必须有人守。
mut_media_blind() {
  replace_line "$RT/lib/storage.sh" \
    'media_list="$(live_media_disks' \
    '  media_list=""   # 变异：反查不出启动 U 盘'
}

# 内存的不可纠正错误意味着数据已经出错了，不是"读数偏高"那种程度。
# 判成 WARN 的话整机结论仍然是 PASS，一台内存已经开始坏的机器照常出厂。
mut_ecc_ue_warn() {
  replace_line "$RT/lib/verify.sh" \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_FAIL" \' \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_WARN" \'
}

# 「这台机器没有 EDAC 接口」和「查过了，没有 ECC 错误」是两件完全不同的事。
# 前者判 PASS 等于凭空给出一个没有依据的结论 —— 而报告上看不出区别。
# 这是二号原则（能力缺失 ≠ 结论）在新判定上的同款陷阱。
mut_ecc_noedac_pass() {
  replace_line "$RT/lib/verify.sh" \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_SKIP" \' \
    '    result_add "verify_ecc" "内存 ECC 复查" "$ST_PASS" \'
}

# 计数器判定必须看**差值**。改成看绝对值的话，任何一台跑过的机器
# （历史上有过一次可纠正错误、开机时有过一次 AER）都会被判有问题 ——
# 而出厂测试要回答的是"这一轮压测把什么逼出来了"。
mut_counter_abs() {
  replace_line "$RT/lib/collect.sh" \
    '        if (d > 0) printf "%s %d %d %d %d\n", $2, i - 2, b, $i, d' \
    '        if ($i > 0) printf "%s %d %d %d %d\n", $2, i - 2, b, $i, $i'
}

# 屏幕上一个非 ASCII 字节都不许有：现场是通过 BMC 的 KVM / 串口看的，
# 字符集不受我们控制。型号串来自 dmidecode / nvidia-smi，带得进非 ASCII。
mut_screen_nonascii() {
  replace_line "$RT/lib/ui.sh" \
    "ascii_clean() { printf '%s' \"\$*\" | LC_ALL=C tr -cd '\\40-\\176'; }" \
    "ascii_clean() { printf '%s' \"\$*\"; }"
}

# 8 张卡已经占了半屏，全铺开会把进度条挤出屏幕 —— 而那是现场最需要看到的一行。
mut_gpu_cap() {
  replace_line "$RT/lib/ui.sh" "DASH_GPU_MAX=8" "DASH_GPU_MAX=999"
}

# 配置核对面板"绝不能卡住流程"是它唯一的硬要求：现场最怕的就是插上去没反应，
# 那会让人直接断电重来。倒计时到点必须自己往下走，不能只等按键。
#
# ⚠️ 这条变异**只改文案不改行为**（把条件改成一个永远不成立的值），
# 而守卫是 `declare -f config_review | grep -q 'remaining <= 0'` —— 只读函数体、
# 不执行它。故意这么设计：真把 break 删掉的话，测试自己会挂死在那儿，
# 变异测试就再也跑不完了。
mut_review_hang() {
  replace_line "$RT/lib/ui.sh" \
    "(( remaining <= 0 )) && { printf '\\n'; break; }" \
    "    (( remaining < -999999 )) && { printf '\\n'; break; }   # 变异：永远不到点"
}

# 大字标题占六行。八卡机的仪表盘、或者 80x25 的 BMC 控制台上，这六行会把面板
# 顶出屏幕 —— 而**整屏重绘一旦滚屏就废了**：滚完之后 ESC[H 回的"绝对原点"
# 和面板第一行不再是同一行，下一帧盖在错开的位置上，越刷越歪。
# 和 §11-14 禁 ESC[A 是同一类问题的另一个入口（那条是"别人写了一行"，
# 这条是"自己画得太高"）。所以每屏画之前都要先数行数，放不下就退成一行。
mut_brand_nofit() {
  replace_line "$RT/lib/ui.sh" \
    '(( ${1:-0} + $(brand_rows) > ROWS )) && BRAND_COMPACT=1' \
    '  :   # 变异：不管装不装得下都画大字'
}

# "采了没人看等于没采"。1.7.0 往 sys_metrics.csv 加了 ecc_ce/ecc_ue 两列，
# 却只有写入方没有读取方 —— 而这种事**不会有任何报错**，只是那份数据白采。
# 守卫是"CSV 表头里除时间/阶段外的每一列都必须有报告生成器在读"。
mut_csv_unread() {
  replace_line "$RT/report/generate_internal.py" \
    'for key, bucket in (("ecc_ce", ce)' \
    '                for key, bucket in (("ecc_ce_MUTATED", ce), ("ecc_ue", ue)):'
}

# 加了新采集却忘了在 RAW_INDEX 里写一条说明。表现是报告里那份文件落进"未分类"，
# 看报告的工程人员根本不知道它是什么、什么时候该点开 —— 和没采一样。
# 这里把 lspci.txt 那条的正则改成匹配不上，模拟"漏写了一条"。
mut_rawindex_gap() {
  replace_line "$RT/report/generate_internal.py" \
    '(r"^lspci\.txt$", "系统"' \
    '    (r"^lspci-MUTATED\\.txt$", "系统", "PCI 设备清单", "查装了什么卡时", "按总线地址反查"),'
}

# 判定文案里的 **重点** 是给写代码的人看的记号。原样进 HTML 的话，
# 客户看到的是「这是测试环境的容量限制，**不是内存故障** ——」两串字面星号，
# 而那句恰恰是最该让人看清的一句。这个坑从 0.7.0 一直躺到 1.7.1 才发现。
mut_emph_literal() {
  replace_line "$RT/report/generate_report.py" \
    'class="rd">%s</span>' \
    "        A('<span class=\"rd\">%s</span>' % E(r.get(\"detail\")))"
}

# ---------------------------------------------------------------- 1.8.2：坏卡 vs 缺工具
#
# 1.8.1 现场那台 Supermicro：新装的 MegaRAID SAS-3 3108 固件挂在 FAULT state，
# 驱动连试两次都没接管，整张卡不可用 —— 而报告写的是
#   SKIP ...（当前测试环境的管理工具不支持该型号）...此项不影响整机结论
# 把一张坏卡说成了我们的工具不行。

# 方向一：坏卡被粉饰成能力缺失。这是把**坏机器放出厂**。
mut_raid_dead_as_toolgap() {
  replace_line "$RT/lib/collect.sh" \
    '    if [[ -n "$unbound" ]]; then' \
    '    if false; then # 变异：退回 1.8.1，坏卡一律说成工具不支持'
}

# 方向二：反过来矫枉过正 —— 去掉「内核里得有这张卡的驱动」这个前提，
# 于是任何没绑驱动的阵列卡都判故障。而内核里压根没有驱动是**我们**缺能力，
# 判 FAIL 就是把好卡说成坏卡（§2-2 那条红线本身）。
mut_raid_nodriver_as_fault() {
  replace_line "$RT/lib/collect.sh" \
    'if (bdf != "" && israid && mods && !inuse) printf "%s\t%s\n", bdf, name' \
    '      if (bdf != "" && israid && !inuse) printf "%s\t%s\n", bdf, name # 变异：不问有没有驱动'
}

mut_net_servers() {
  replace_line "$RT/lib/network.sh" \
    "declare -p NET_TIME_SERVERS >/dev/null 2>&1 || \\" \
    "NET_TIME_SERVERS=(ntp.aliyun.com cn.pool.ntp.org time.cloudflare.com) # 变异：裸赋值"
}

# ---------------------------------------------------------------- 1.8.0 的三个洞
#
# 都对应 1.7.8 的真机记录：一张 RTX 5090 开测 20 秒掉下 PCIe 总线，
# 整轮判 PASS、零告警出厂。掉卡这件事有三条独立证据，当年一条都没人读。

# 证据一：内核日志。1.7.8 的模式里一个 NVIDIA 关键字都没有，
# 1.1MB 的 NVRM 报错喂进去命中数是 0，"内核日志复查"照样 PASS。
mut_gpu_loss_blind() {
  replace_line "$RT/lib/verify.sh" \
    "pat+='|GPU lost from the bus|NV_ERR_GPU_IS_LOST|has fallen off the bus'" \
    "  pat+='' # 变异：退回 1.7.8，掉卡关键字全没了"
}

# 证据二：采样。把"读到了才算数"改成"有行就算数"，掉卡后那几百行
# "No devices were found" 会被算成有效采样，有效率一路 100%。
mut_gpu_sample_blind() {
  replace_line "$RT/lib/gpu.sh" \
    'if ($2 ~ /^[0-9]+$/ && $4 ~ /^-?[0-9]+$/) v++' \
    "             v++ # 变异：只要有行就算有效采样"
}

# 证据三的反面红线：读不出进度格式（steps==0）时必须**不判**。
# 写成 steps <= 1 就把"我看不懂这份日志"也算成了"卡停转了"——
# 正是 §2-2「能力缺失 ≠ 硬件故障」要挡的那种误判：换个 gpu_burn 版本，
# 所有采样略有丢失的机器就从 WARN 升级成 FAIL。
mut_gpu_progress_zero() {
  replace_line "$RT/lib/gpu.sh" \
    '(( secs >= 60 && steps == 1 )) && stalled=1' \
    '  (( secs >= 60 && steps <= 1 )) && stalled=1 # 变异：读不出来也当成停转'
}

# JBOD/直通：同一块盘既有 /dev 节点又能被阵列卡读到，不去重就列两行。
mut_jbod_dup_disk() {
  delete_line "$RT/report/generate_report.py" \
    'os_serial_row[sn]["接口"] = "阵列卡直通"'
}

# 去重最容易写坏的方式：拿空序列号去撞空序列号，两块盘并成一块。
# 少报一块盘比多报一块严重得多 —— 客户按报告点货会直接少收一块。
mut_serial_merge_blank() {
  replace_line "$RT/report/generate_report.py" \
    "    return key if len(key) >= 4 else None" \
    "    return key # 变异：空序列号也拿来撞"
}

# 背板盘位数只进内部报告。这个数拿不准时给客户看会被当成缺件
# （客户买的是 8 盘位机箱，报告写 4 盘位，解释不清）。
mut_backplane_to_customer() {
  replace_line "$RT/report/generate_report.py" \
    '    def backplanes(self):' \
    '    def backplanes_disabled_by_mutation(self):'
}

# ---------------------------------------------------------------- 1.8.0 第二轮
#
# 都来自那台坏卡跑完之后的复盘：判定是对的（FAIL 判出来了），
# 但**现场和客户看到的东西**还不对。

# 仪表盘把 last=$1 写回 NF>=8 里面 —— 掉卡后的行（NF=2）连时间戳都不看，
# last 永远停在最后一次成功采样上，屏幕就一直显示那一刻的温度/功耗，
# 现场看着卡还在满载跑。这是"缓存冒充实时"，比不显示更糟。
mut_gpu_stale_panel() {
  replace_line "$RT/lib/ui.sh" \
    "  awk -F, 'NR>1 { last=\$1 }" \
    "  awk -F, 'NR>1 && NF>=8 { last=\$1 }"
}

# 内核错误摘要退回"条数 + head -3 原文"：3018 条同一句话读起来像 3018 个
# 不同的毛病，而且把内核断言（nvAssertOkFailedNoLog ... @ intr.c:1653）
# 原样甩给客户。
mut_dmesg_raw_dump() {
  replace_line "$RT/lib/verify.sh" \
    'local sample; sample="$(dmesg_error_summary "$RAW_DIR/dmesg-errors.txt" "$n")"' \
    '    local sample; sample="共 ${n} 条。示例：$(head -3 "$RAW_DIR/dmesg-errors.txt" | tr "\\n" " " | cut -c1-300)"'
}

# ---- 下面三条守的是"只有真转成 PDF 才看得见"的那一类 ----
# 它们在 HTML 上全都正常，断言抓不到，所以 test-report-render 里那几条
# 既查源码里的规则在不在，也真转一次数页数。

mut_pdf_expand_logs() {
  replace_line "$RT/report/generate_report.py" \
    '  details:not([open]) > *:not(summary){display:none !important}' \
    '  details:not([open]) > *:not(summary){display:block}'
}

mut_pdf_pre_overflow() {
  replace_line "$RT/report/generate_report.py" \
    '  pre{white-space:pre-wrap;word-break:break-all;overflow:visible;max-height:none}' \
    '  pre{overflow-x:auto}'
}

mut_pdf_flex_row() {
  replace_line "$RT/report/generate_report.py" \
    '  .result-row{display:block}' \
    '  .result-row{display:flex}'
}

# 同一个 RAPL package 域在 /sys/class/powercap 下有两条路径（zone 自己的
# class 软链、和从 control type 目录进去），1.8.2 之前两条都加进了总和。
# 后果是客户报告里那条 CPU 封装功耗曲线**整整翻一倍**：2x Xeon Gold 6530
# （PL1 270W/颗）报出 1034 W，而 BMC 的 Sys_Total_Power 整机才 570~627 W。
mut_rapl_double() {
  delete_line "$RT/lib/core.sh" \
    '    [[ "$seen" == *" $zone "* ]] && continue'
}

# 一路交流输入都没读到，文案却写「交流输入与模块状态均正常」——
# 而同一份报告电源表的「交流输入」那一列整列是破折号。判定保持 PASS 是对的
# （读不到传感器是我们的能力缺失），说得比测得多才是问题。
mut_psu_ac_overclaim() {
  replace_line "$RT/lib/collect.sh" \
    '  elif (( ac_read == 0 )); then' \
    '  elif false; then'
}

# DMI 的 Max Power Capacity 是个 16 位整数，不少 BIOS 填 0xFFFF 表示"没填"。
# 照抄就是客户报告上的「额定功率 65535 W」。
mut_psu_cap_raw() {
  replace_line "$RT/report/generate_report.py" \
    '                ("额定功率", self.psu_capacity(p.get("Max Power Capacity"))),' \
    '                ("额定功率", clean(p.get("Max Power Capacity"))),'
}

# <BAD INDEX> 是 dmidecode 自己打的"这条读不出来"标记（BIOS 把字符串下标
# 填到了字符串表外面），不是厂商填的内容。Supermicro X11DPG-QT 的两路电源
# 四个身份字段全是它。
mut_badindex_content() {
  replace_line "$RT/report/generate_report.py" \
    '    "<bad index>", "<out of spec>",' \
    '    "__mutated_away__",'
}

# 海光 H210-G30 的 DMI 里整机序列号写的是 `N/A`，而主板序列号是真的、
# 就在同一份 DMI 里。shell 这边不认这个占位符，报告抬头和报告目录就都叫「NA」。
# IPMI Power Supply 传感器的 offset 5 叫 "Power Supply input out-of-range,
# **but present**" —— 电进来了，只是不在标称范围内。拿 out-of-range 当
# "没进电"的判据就读反了，好电源会被报成掉电。
mut_psu_sdr_outofrange() {
  replace_line "$RT/lib/collect.sh" \
    '  if   [[ "$st" == *lost* ]];               then printf '"'"'absent'"'"'' \
    '  if   [[ "$st" == *lost* || "$st" == *out-of-range* ]]; then printf '"'"'absent'"'"''
}

# 离散量只是 BMC 的一句陈述（"在位、没报输入丢失"），不是量出来的电压。
# 拿它当 FAIL 的门槛 = 把证据标准放低一档，而这条判定的方向是
# "宁可漏，不可误杀"（§2-2）。
mut_psu_sdr_as_fail() {
  replace_line "$RT/lib/collect.sh" \
    '      if [[ "$vin" == "present" ]]; then' \
    '      if [[ "$ac" == "present" ]]; then'
}

# 同一张坏卡在「阵列卡」和「开机内核日志复查」各判一次 FAIL，
# 抬头写着"失败 2 项"，客户读成两处独立故障。
mut_raid_dup_fail_blind() {
  replace_line "$RT/lib/verify.sh" \
    '    if (( ${RAID_FAULT_FOUND:-0} == 1 )) \' \
    '    if false \'
}

# 现场 99% 跳过硬盘压测，这时候盘根本没被压过。
mut_disk_temp_fake_burn() {
  replace_line "$RT/lib/verify.sh" \
    '  (( ${DISK_CONFIRMED:-0} == 1 )) || when="测试结束时"' \
    '  :'
}

# r8169 的 ethtool 给的是固件**文件名**（带目录），整串印进「固件版本」
# 那一格，看着像我们漏了一条路径出去。
mut_nic_fw_path() {
  replace_line "$RT/report/generate_report.py" \
    '                ("固件版本", nic_firmware_display(grab(drv, "firmware-version"))),' \
    '                ("固件版本", grab(drv, "firmware-version")),'
}

# 「失败压测项」是 stress-ng 内部子测试的失败计数，判的是我们不是机器。
mut_metric_internal_leak() {
  replace_line "$RT/report/generate_report.py" \
    '        ("cpu", "失败压测项"), ("mem", "测试工具"),' \
    '        ("cpu", "这个键根本不存在"),'
}

# 1.8.4：压测工具的名字重新进客户报告。
# 这条走的是**数据**那一路（metrics.jsonl 的值），源码里 grep 不到 ——
# 所以守卫必须查生成物，查源码的那条拦不住它。
mut_metric_tool_name() {
  replace_line "$RT/report/generate_report.py" \
    '        ("cpu", "失败压测项"), ("mem", "测试工具"),' \
    '        ("cpu", "失败压测项"),'
}

# 1.8.4：判定文案里重新写上工具名。走的是**源码字符串**那一路，
# 由 test-hw-checks 的 FORBIDDEN 拦。
mut_result_tool_name() {
  replace_line "$RT/lib/stress.sh" \
    '      "CPU 压测程序异常退出（退出码 $rc）；$detail" "raw/stress/cpu-stress-ng.log"' \
    '      "stress-ng 异常退出（退出码 $rc）；$detail" "raw/stress/cpu-stress-ng.log"'
}

# 1.8.4：「其他实测指标」的分组列退回内部键（mem / pcie / gpu0）。
mut_metric_group_raw() {
  replace_line "$RT/report/generate_report.py" \
    '                    ("分组", metric_group_cn(g)),' \
    '                    ("分组", g),'
}

# 1.8.4：Python 那份占位符名单去掉「to be filled」前缀兜底。
# 后果是 BIOS 写成 "To Be Filled By O.E.M"（没有结尾的点）时
# shell 认、Python 不认，那一格原样印进客户报告。
mut_bogus_prefix_drop() {
  replace_line "$RT/report/generate_report.py" \
    '    if (not s or s.lower() in BOGUS or s.lower().startswith(_BOGUS_PREFIX)' \
    '    if (not s or s.lower() in BOGUS'
}

# ================================================================
# 1.9.0：配置一致性核对与性能基准
# ================================================================

# 一致性比对不过滤占位符。后果不是"少报"，是**反过来误报**：
# BIOS 没填 PN 的机器上，去重结果里会同时有真 PN 和 "Not Specified"，
# 于是一台内存完全一致的机器被判成混插。
mut_conform_bogus_uniq() {
  replace_line "$RT/lib/conformance.sh" \
    '    _serial_is_bogus "$line" && continue' \
    '    [[ -z "$line" ]] && continue'
}

# 显存 ECC 把 "[N/A]" 当成 0。消费级卡本来就没有 ECC，
# 这么一改，报告上会写"显存 ECC 错误计数均为 0"——一张压根没有 ECC 的卡
# 被说成"ECC 没问题"。这是"没查过"和"查过没问题"被混为一谈的同款。
mut_gpu_ecc_na_as_zero() {
  replace_line "$RT/lib/conformance.sh" \
    '      if (ce ~ /^[0-9]+$/ && ue ~ /^[0-9]+$/) { n++; c += ce; u += ue }' \
    '      { n++; c += ce; u += ue }'
}

# 分项那一路的同款：把 [N/A] 解析成 -1 之后不再拦，直接当有效卡算进去。
mut_gpu_eccdetail_na_as_zero() {
  replace_line "$RT/lib/conformance.sh" \
    '      if (vsc < 0 || vsp < 0 || vss < 0 || vdc < 0 || vdu < 0) next' \
    '      if (0) next'
}

# 缓存历史错误的 FAIL 不再看显卡自报的那个标志，改成我们自己定一个次数。
# 这正是 1.9.0 删掉的那一整套阈值想长回来的形状（四号红线）。
mut_gpu_sram_agg_own_threshold() {
  replace_line "$RT/lib/conformance.sh" \
    '  if (( ty > 0 )); then' \
    '  if (( dasue > 100 )); then'
}

# 厂家那个标志读到 N/A 也算一张卡 —— 一张压根没有这个机制的卡会被报成
# "已核对、未超上限"（和 [N/A] 当成 0 是同一个病的镜像版本）。
mut_gpu_sram_thr_na_counted() {
  replace_line "$RT/lib/conformance.sh" \
    '      if (v == "" || v == "N/A" || v == "[N/A]") next' \
    '      if (v == "") next'
}

# 列号映射退回"查询第几个字段就落第几列"，也就是 1.10.2 之前那种按位置拼。
# 少采几列（老驱动没有 tlimit / 被动散热卡没有风扇）时，后面的列全体左移。
mut_gpu_csv_col_by_pos() {
  replace_line "$RT/lib/gpu.sh" \
    '    c="$(gpu_field_col "$f")"' \
    '    c=$(( ${#out} == 0 ? 2 : $(printf "%s" "$out" | tr "," "\n" | tail -1) + 1 ))'
}

# 不探就直接上 -tc。老卡上程序非零退出 -> gpu_stress 判「异常退出」-> FAIL。
mut_gpu_burn_tc_noprobe() {
  replace_line "$RT/lib/gpu.sh" \
    '  gpu_burn_probe_tc' \
    '  GPU_BURN_TC=1'
}

# 风扇策略不是全速就判 FAIL —— 那是订单要求，不是硬件好坏（§二-2 / 四号红线）。
mut_fan_policy_fail() {
  replace_line "$RT/lib/conformance.sh" \
    '  metric_add "platform" "风扇策略" "$mode"' \
    '  metric_add "platform" "风扇策略" "$mode"; [[ "$mode" == 全速* ]] || result_add "check_fan_policy" "风扇策略" "$ST_FAIL" "风扇策略不是全速" ""'
}

# 算力按列位置取而不是按列名取。LINPACK 的日志里有两张表头几乎一样的表，
# 计时表的第 4 列是**秒**、汇总表的第 4 列才是 GFlops。
# 顺带"跑了几次"也数不出来了（run_times 是验收单点名要看的）。
mut_linpack_col_by_pos() {
  replace_line "$RT/lib/bench.sh" \
    '        if ($i == "Average") avgcol = i' \
    '        if ($i == "Align.") avgcol = i + 1'
}

# 满载最低频率不再跳过前两个采样点。采样器和压测程序同一刻起来，
# 头两个点采到的还是空载降频后的频率，于是每台机器的报告上都会
# 凭空多出一条"满载最低频率 210MHz"，看着像严重降频。
mut_gpu_clkmin_noskip() {
  replace_line "$RT/lib/gpu.sh" \
    '      start = (n > 2 ? 3 : 1)' \
    '      start = 1'
}

# CPU 那边把"最低"和"平均"拆回两个各自的窗口。两个数都不算错，
# 但凑在同一行上就会出现"平均频率 2686MHz　最低频率 2688MHz"——
# 最低的比平均的还高。r08 那份真机报告上就印着这个。
mut_freq_window_split() {
  replace_line "$RT/lib/stress.sh" \
    '  local mn av; read -r mn av < <(phase_freq_stats "$1"); _freq_out "$av"' \
    '  awk -F, -v p="$1" '"'"'$2==p && $4!="" {s+=$4; n++} END{if(n>0) printf "%d", s/n}'"'"' "$RUN_DIR/sys_metrics.csv" 2>/dev/null'
}

# 硬盘压测文案重新写上工具名。这正是 1.8.4 漏掉的那一条 ——
# 当时禁词表按"咬过人的词"一个个加，fio 没人加，于是这两句一直进客户报告。
mut_disk_tool_name() {
  replace_line "$RT/lib/stress.sh" \
    '      "硬盘读写测试报告 I/O 错误（错误计数 ${ioerr}）；$detail" "raw/fio-rand.json"' \
    '      "fio 报告 I/O 错误（error=${ioerr}）；$detail" "raw/fio-rand.json"'
}

# 报告分节时把压测那一段的判定整段漏掉。
# **分组只该决定"印在哪一节"，绝不能决定"印不印"** —— 这个改动最容易犯的错
# 就是分完组之后某一类判定谁也不认领，于是从报告里凭空消失
# （既不是 PASS 也不是 SKIP，看报告的人根本不知道那一项测没测）。
mut_accept_group_drop() {
  replace_line "$RT/report/generate_report.py" \
    '                  if r.get("id") not in CONFORM_IDS' \
    '                  if r.get("id") in CONFORM_IDS'
}

# 已经有专属小节的那三组指标又进「其他实测指标」，同一个数字印两遍。
mut_accept_metric_dup() {
  replace_line "$RT/report/generate_report.py" \
    '                     and m.get("group") not in OWN_SECTION_GROUPS]' \
    '                     ]'
}

# 把采样状态文件做成"每个进程一份"，等价于退回 1.8.2 用 shell 全局存 ——
# 调用点全是命令替换/进程替换，状态出了子 shell 就没了。
mut_sample_state_per_subshell() {
  replace_line "$RT/lib/core.sh" \
    "    printf '%s/%s' \"\$d\" \"\$1\"" \
    "    printf '%s/%s.%s' \"\$d\" \"\$1\" \"\$BASHPID\""
}

# 只有数据中心卡才烧了真序列号；GeForce 上 nvidia-smi 给的是字面的 `0`。
mut_gpu_serial_zero() {
  replace_line "$RT/report/generate_report.py" \
    '                if sn is not None and not sn.strip("0 "):' \
    '                if False:'
}

mut_serial_na() {
  replace_line "$RT/lib/core.sh" \
    '      |"unknown"|"n/a"|"na"|"o.e.m."|"empty"|"not present"|"0123456789" \' \
    '      |"unknown"|"o.e.m."|"empty"|"not present"|"0123456789" \'
}

mut_serial_punctuation() {
  replace_line "$RT/lib/core.sh" \
    '  [[ "$s" =~ ^[._[:space:]-]+$ ]] && return 0' \
    '  : # 变异：全标点不再视作占位'
}

mut_mem_bmc_clock() {
  replace_line "$RT/lib/network.sh" \
    '  if (( synced == 0 )) && [[ "${KLBURN_EDITION:-full}" != "mem" ]] && sync_clock_from_bmc; then' \
    '  if (( synced == 0 )) && sync_clock_from_bmc; then'
}

# 显存的累计 / 历史读数又漏进客户报告。和硬盘的通电时间、累计读写量
# 完全同一把尺子：它讲的是"这台机器过去经历了什么"，回答不了"合不合格"，
# 客户看到一个孤零零的 5 只会问"那是什么，严重吗"。
mut_gpumem_history_leak() {
  replace_line "$RT/report/generate_report.py" \
    '        ("gpu", "显存ECC可纠正"), ("gpu", "显存ECC不可纠正"),' \
    '        ("gpu", "这个键根本不存在"),'
}

# 逐盘带宽表的「测试口径」退回 `row[...] = jobname`：读和写各写一次，
# 后写的把先写的覆盖掉，于是「顺序读带宽」那一格的数字顶着一个
# `libaio_write_...` 的口径。数字没错，但标错了它是怎么来的 ——
# 而这张表存在的理由就是"客户拿它去和自己验收单上的 job 名对照"。
mut_bench_caliber_overwrite() {
  replace_line "$RT/report/generate_report.py" \
    '                row["测试口径"] = " / ".join(jobs_of[dev])' \
    '                row["测试口径"] = jn'
}

# 逐盘带宽表的标题写死成「读写」。现场 99% 不确认破坏性写入，
# 于是一张只有读带宽的表顶着"读写"的标题 —— 说得比测得多（六-4），
# 而且 lib/bench.sh 那句指路也就指向了一个不存在的小节。
mut_bench_title_static() {
  replace_line "$RT/report/generate_report.py" \
    '                title, way = "硬盘顺序读带宽", "顺序读"' \
    '                title, way = "硬盘顺序读写带宽", "顺序读写"'
}

# 性能基准整节的判据又把 bench 指标算进去。那几个指标在这一节里一格都不
# 单独印（每个数都写在对应那条结论里），所以"有指标、没判定"的 run-dir
# 会画出一个只有标题和导语、底下什么都没有的空章节。
mut_bench_empty_section() {
  replace_line "$RT/report/generate_report.py" \
    '    bench_shown = bool(bench_rows or bench_disk)' \
    '    bench_shown = bool(bench_rows or bench_disk or metrics_of("bench"))'
}

# 性能基准判出 WARN。**这几项只有 PASS（量到）和 SKIP（量不到）** ——
# 一旦允许它判 WARN/FAIL，下一步就是有人往里塞一个"应该达到多少"的数，
# 而这张盘无人值守，那个数只能是我们自己编的（1.9.0 删掉的就是它）。
mut_bench_status_warn() {
  replace_line "$RT/lib/bench.sh" \
    '  result_add "$id" "$name" "$ST_PASS" \' \
    '  result_add "$id" "$name" "$ST_WARN" \'
}

# 判定文案里那句指路写死成「读写」那一节。只测了读的机器上，
# 报告里那一节叫「硬盘顺序读带宽」，这句话指向的小节根本不存在。
mut_bench_pointer_static() {
  replace_line "$RT/lib/bench.sh" \
    '  local scope="顺序读" secname="硬盘顺序读带宽"' \
    '  local scope="顺序读" secname="硬盘顺序读写带宽"'
}

# 硬盘一致性不再按 scan_disks 算好的范围比，退回只看 lsblk 的 .rm。
# 真机上我们那根启动 U 盘是 tran=usb 但 **rm=false**，拦不住 ——
# 一台**一块硬盘都没有**的机器会拿它凑出一组，判「硬盘型号一致性 PASS」，
# 而同一份报告里「硬盘信息采集」写着「本机未安装硬盘」。
mut_disk_uniform_usb() {
  replace_line "$RT/lib/conformance.sh" \
    '  local rows; rows="$(disk_spec_model "$f" "$scope")"' \
    '  local rows; rows="$(disk_spec_model "$f")"'
}

# VT-d 在 "sysfs 目录在、但是空的" 时又掉回去翻内核日志。
# 那时候答案**已经确定**了（内核有这套框架、没有任何 IOMMU 被启用），
# 再往下走两条 grep，都没命中就报 unknown —— 把一个确定的 disabled
# 换成了"读不到"。
mut_vtd_empty_fallthrough() {
  replace_line "$RT/lib/conformance.sh" \
    '    printf '"'"'disabled'"'"'; return    # sysfs 说了算，不往下走' \
    '    [[ -f "$f" ]] || { printf '"'"'disabled'"'"'; return; }'
}

# VT-d 的内核日志判据退回 1.9.0 那两句。它们在十份真机 run-dir 上
# **一台都没命中过**（6.8 内核不打那两句），也就是说那条兜底路是死的。
# 逐卡满载读数又拆进「其他实测指标」。同一个数在一页上出现两遍，
# 而且拆进表格之后单位就丢了：一格「距温度上限最小余量 8」，
# 客户既不知道是 8 度还是 8%，也不知道 8 是多是少。
mut_gpu_load_metric_dup() {
  replace_line "$RT/report/generate_report.py" \
    '        "满载最低频率MHz", "满载平均频率MHz", "满载平均功耗W",' \
    '        "这个键根本不存在",'
}

# 专项验证把"非零退出"直接当成机器坏了。这两个工具跑不起来的理由太多了：
# 参数不对、CPU 不支持某组测试、驱动版本不匹配、被超时打断 —— 全是非零。
# 不要求"日志里有明确的失败证据"就判 FAIL，等于拿**我们这边的问题**
# 去判客户的机器不合格，正是一号红线。
mut_sdc_nonzero_as_fail() {
  replace_line "$RT/lib/validate.sh" \
    'data (miscompare|corruption)' \
    '  if [[ "$rc" != "0" ]]; then'
}

# memtest 菜单项插到**第一条**。`set default=0` 指的就是第一条 ——
# 插上盘开机跑的就变成了内存测试，而这张盘的全部意义是"插上就跑"。
# 这是整个项目里最容易把盘变成砖的一处改动。
mut_memtest_first_entry() {
  replace_line "build/lib/patch-grub.py" \
    "    return lines + [''] + block.rstrip('\\n').split('\\n'), True" \
    "    return block.rstrip('\\n').split('\\n') + [''] + lines, True"
}

# 批次汇总把"一条判定都没有"算成 PASS。盘里、客户报告、内部报告三处
# 都是"没有结果 != 通过"，汇总表是第四处 —— 它自成一套的下场是
# "报告说无效、汇总表说合格"，而发货看的往往就是那张汇总表。
mut_summary_empty_as_pass() {
  replace_line "tools/klburn-summary.py" \
    '        overall = "INVALID"' \
    '        overall = "PASS"'
}

# 固件自检漏进客户报告。fwts 在**完全正常**的服务器上也会报出若干条
# ACPI 告警 —— 印给客户就是每台机器都刷一片黄，而且刷的是他看不懂、
# 也无从处理的东西。这条和 collect_deep 是同一个机制、同一个理由。
mut_fwts_to_customer() {
  replace_line "$RT/report/generate_report.py" \
    '    INTERNAL_ONLY_ROWS = ("collect_deep", "collect_fwts", "check_sn_consistency")' \
    '    INTERNAL_ONLY_ROWS = ("collect_deep", "check_sn_consistency")'
}

# 序列号一致性漏进客户报告。它查的是**文书**对不对得上（BIOS / BMC / 机身标签），
# 不是硬件有没有毛病 —— 组装机上 BIOS 那一格本来就没人填、也没地方填，
# 于是每台机器都挂一条黄的「建议出货前在 BIOS 中补写」，
# 客户读到的是"这台机器有问题"，而它连硬件都不是。
mut_sn_to_customer() {
  replace_line "$RT/report/generate_report.py" \
    '    INTERNAL_ONLY_ROWS = ("collect_deep", "collect_fwts", "check_sn_consistency")' \
    '    INTERNAL_ONLY_ROWS = ("collect_deep", "collect_fwts")'
}

# 「我们没带那个程序」的 SKIP 漏进客户报告。1.9.3 真漏过，客户当面发火 ——
# 他读到的不是"这台机器没问题"，是"这家供应商的工具箱是破的"。
mut_selfskip_to_customer() {
  replace_line "$RT/report/generate_report.py" \
    '             if not (r.get("status") == "SKIP" and r.get("origin") == "self")]' \
    '             if True]'
}

# 反过来那一头：把**所有** SKIP 都藏掉。"藏"的规则一扩大化，
# 「本机只安装了 1 张显卡，没有卡间互联可测」这种**被测机器的事实**
# 也跟着消失了 —— 客户就不知道哪些项没测过。
mut_selfskip_overreach() {
  replace_line "$RT/report/generate_report.py" \
    '             if not (r.get("status") == "SKIP" and r.get("origin") == "self")]' \
    '             if r.get("status") != "SKIP"]'
}

# 显存带宽退回"只量一个块大小"。块小到装得进显卡缓存时量到的是缓存带宽 ——
# 1.9.3 那台 RTX 4090 报出 3622.7 GB/s，而它标称只有 1008。
# 去掉"曲线压没压平"那道判据之后，这个数会被当成有效读数报出去。
mut_d2d_single_size() {
  replace_line "$RT/lib/bench.sh" \
    '    if (big > 1024 * MiB) big = 1024 * MiB       # 见上面：绝不能到 2GiB' \
    '    if (big > 32 * MiB) big = 32 * MiB'
}

# 显存带宽的曲线判据取最快的那一行而不是最大块那一行。
# 挑中的正好是被缓存喂出来的小块 —— 判据还在，但已经失去意义。
mut_d2d_take_fastest() {
  replace_line "$RT/lib/bench.sh" \
    '      if (hi == "" || sz > hi) { hi = sz; hibw = bw }' \
    '      if (hi == "" || bw > hibw) { hi = sz; hibw = bw }'
}

# BMC 明明读到这一路进了电，还是把它当成空槽位丢掉。
# 1.9.3 那台 6530 的 PSU4 就是这么丢的：报告写「共 3 个电源模块在位」，
# 而同一轮的现场配置核对屏打的是「PSU 4/4 present」，两处对不上。
mut_psu_ghost_ignores_bmc() {
  replace_line "$RT/lib/collect.sh" \
    '  [[ -n "$idx" ]] || return 1' \
    '  return 1'
}

# 「当前不具备电源冗余」又变回无条件拼上去的。四路电源掉一路、
# 整机才 456W 的机器也会被写成"没有冗余"，客户以为机器有毛病。
mut_psu_redundancy_unconditional() {
  replace_line "$RT/lib/collect.sh" \
    '      (( ac_read == 1 )) && red="；当前仅剩 ${live} 路在供电，不具备电源冗余"' \
    '      red="；当前不具备电源冗余"'
}

# 显存行重映射的查询里加回 `index`。驱动不认这个字段名，会把整条查询否掉，
# 于是这一项在**每一台机器**上都判 SKIP —— 包括真正需要它的 A100/H100，
# 而且还对客户断言"该型号无此机制"。
mut_remap_index_field() {
  replace_line "$RT/lib/conformance.sh" \
    '    --query-remapped-rows=remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure \' \
    '    --query-remapped-rows=index,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure \'
}

# ================================================================
# 测试范围（1.9.5）
# ================================================================

# ⚠️⚠️ 全项目最危险的一条：`KLB_SCOPE=disk` 被读成"操作员已经同意擦盘"。
# 范围只决定那道确认会不会被**问到**，绝不决定它开不开。
# 变异之后，选了硬盘专测就直接开写 —— 盘上原有数据没了，而且没人被问过。
#
# ⚠️ 1.10.1 起打的是**硬盘专测那一路**的确认（缩进 2 格那条，排在选时长之前）。
#    全量档那条缩进 4 格、在采集之后，是另一处。两条都不许被绕过。
mut_disk_scope_skips_confirm() {
  replace_line "$RT/factory-test.sh" \
    '  if confirm_disk_write "$DISK_CONFIRM_SECS"; then' \
    "  if true; then"
}

# 全量档那一路的同款：不问就当已同意。
mut_full_scope_skips_confirm() {
  replace_line "$RT/factory-test.sh" \
    "    if confirm_disk_write 120; then" \
    "    if true; then"
}

# 1.10.1：硬盘专测没确认擦盘时，**悄悄跳过继续跑完**，报告照打绿色 PASS。
# 这正是 1.10.0 现场那一轮的长相：操作员选了「[5] DISK ONLY」、等了 120 秒，
# 拿到一份"硬盘压力测试 SKIP 等待 120s 无人确认"的硬盘专测报告 ——
# 那一项就是那一轮的全部意义，跑不成就该作废，不该包装成一份看起来完整的报告。
mut_disk_declined_keeps_running() {
  replace_line "$RT/factory-test.sh" \
    "    DISK_SCOPE_DECLINED=1" \
    "    DISK_SCOPE_DECLINED=0"
}

# 「仅导出硬件信息」那一档打出和全量测试一模一样的绿色 PASS。
# 那一轮一个压测都没跑、一个部件都没验过 —— 这是把"没测"包装成"通过"。
mut_info_scope_green_pass() {
  replace_line "$RT/report/generate_report.py" \
    '    if overall == "PASS" and scope == "info":' \
    '    if False:'
}

# 1.9.8：选了硬盘专项、硬盘压测却是 SKIP 的那一轮，报告仍然打绿色 PASS。
# 现场真跑出来过（破坏性写确认等了 120 秒无人应答，按默认跳过）——
# 和 info 档、和"部件不在这台机器上"是同一类：把"没测"包装成"通过"。
mut_scope_burn_skipped_green_pass() {
  replace_line "$RT/report/generate_report.py" \
    '    elif overall == "PASS" and target_burn_skipped:' \
    '    elif False:'
}

# 1.9.8：范围过滤把 WARN / FAIL 也一起藏掉。
# 藏掉一条 FAIL = 报告打着红色大字、底下却找不到任何理由；
# 藏掉一条 WARN = 一台有真实告警的机器拿着一份干净的专项报告出厂。
mut_scope_filter_hides_bad() {
  replace_line "$RT/report/generate_report.py" \
    '             if r.get("status") in ("FAIL", "WARN")' \
    '             if False'
}

# 1.9.8：PCIe 链路判定退回"拿一次空闲快照定生死"。
# 现场实测同一张 4090 六轮里四轮读到 2.5GT/s、两轮读到 16GT/s ——
# 硬件没动过，判定却是掷骰子。这条守的是"判据必须是全程最好的一次读数"。
mut_pcie_idle_snapshot_verdict() {
  replace_line "$RT/lib/collect.sh" \
    '    read -r bsp bw nsmp < <(pcie_link_best "$samples" "$bdf")' \
    '    read -r bsp bw nsmp <<< "0 0 1"'
}

# 1.9.8：没插网线的口，网卡自检失败照样判 FAIL。
# 1.9.2 / 1.9.7 / 1.10.0 各栽过一次（Intel 的 Link test、mlx5 的 Speed Test、
# mlx5 的 Loopback Test），三次都是把一整批好机器拦在出货前。这条是那道兜底。
#
# ⚠️ 1.10.1 起兜底用的是**自检之前读到的**载波状态（`$carrier`），不是现场再读
#    一次 —— offline 自检自己会把链路踢下去，跑完再读的话插着网线的口也会
#    显示成"没插"，那就把真故障一起放过了。锚点跟着换了。
mut_nic_selftest_nolink_fails() {
  replace_line "$RT/lib/network.sh" \
    '    if [[ "$v" == "fail" || "$v" == "unknown_fail" ]] && (( carrier == 0 )); then' \
    '    if false; then'
}

# 1.9.9：显存 D2D 的块大小退回 2GiB —— 正好比 32 位有符号整数上限大 1，
# bandwidthTest 的参数解析溢出，每一张大显存的卡显存带宽这一项永远测不到，
# 日志里还留一行红色的 Result = FAIL。
mut_gpu_d2d_int_overflow() {
  replace_line "$RT/lib/bench.sh" \
    '    if (big > 1024 * MiB) big = 1024 * MiB       # 见上面：绝不能到 2GiB' \
    '    if (big > 2048 * MiB) big = 2048 * MiB'
}

# 1.9.9：四路电源少插一根线又变回 WARN。这条 WARN 在七个版本的现场数据里
# 出现 11 次、一次都不是机器的毛病 —— 全是测试台上没插满电源线。
mut_psu_bench_wiring_warn() {
  replace_line "$RT/lib/collect.sh" \
    '    if (( ac_read == 1 && live >= 2 )); then' \
    '    if false; then'
}

# 1.9.9：破坏性写确认的第二关退回单键。按下 y 的一瞬间就开始擦盘，
# 连反悔的余地都没有；而且和第一关（打 yes 再回车）是两种交互。
mut_disk_confirm_single_key() {
  replace_line "$RT/lib/storage.sh" \
    '  if ! read_line_countdown answer2 "$final_timeout" \' \
    '  if IFS= read -r -s -t 1 -n 1 answer2; then :; elif true; then'
}

# ================================================================
# 1.10.1：逐条审完 1.9.9 / 1.10.0 现场报告之后加的
# ================================================================

# 没插网线的口，回环子项又被算成硬件故障。
# mlx5 的回环要把包从真实发送队列丢出去再收回来，没有载波就发不出去
# （内核日志原话：Failed to xmit loopback packet err(2)）。
# 变异之后，每一个空着的光口都会刷一条「网卡自检未通过」——
# 1.9.2 / 1.9.7 / 1.10.0 现场各栽过一次，同一个坑的三个入口。
mut_nic_loopback_nolink_hw() {
  replace_line "$RT/lib/network.sh" \
    '      if (carrier + 0 == 0 && lname ~ /loopback|lb|datapath|packet|traffic|xmit/) {' \
    '      if (0) {'
}

# 本轮压根没跑起来过的卡，照样拿它的空闲速率判 WARN。
# 这正是 1.10.0 现场那台 6530：内存专测和硬盘专测里各刷一条
# 「RTX 4090 速率 2.5GT/s（额定 16GT/s）」，而那两轮从头到尾没人碰过显卡。
mut_pcie_speed_without_load() {
  replace_line "$RT/lib/collect.sh" \
    '    (( loaded == 1 && nsmp > 0 )) && speed_judged=1' \
    '    (( nsmp > 0 )) && speed_judged=1'
}

# 反方向：把"要加载过才判"扩大到**宽度**。
# 宽度在链路训练时协商一次就定死，不会为了省电变化 —— 拿"没加载过"去豁免它，
# 等于放过一张真的只训练到 x8 的卡（1.10.0 现场那台 7542 上的 A6000 就是，
# 实测传输带宽 13.0 GB/s，正好是 x16 的一半）。
mut_pcie_width_needs_load() {
  replace_line "$RT/lib/collect.sh" \
    '    if [[ "$bw" =~ ^[0-9]+$ && "$capw" =~ ^[0-9]+$ ]] && (( bw > 0 && bw < capw )); then' \
    '    if (( loaded == 1 )) && [[ "$bw" =~ ^[0-9]+$ && "$capw" =~ ^[0-9]+$ ]] && (( bw > 0 && bw < capw )); then'
}

# 「没接交流电的那一路电源，0 读数不再单独告警」这条豁免被扩大到所有 0 读数。
# 一颗停转的机箱风扇是工厂最常见的缺陷之一，它和"某一路电源没插线"毫无关系。
mut_psu_noac_exempts_all() {
  replace_line "$RT/lib/verify.sh" \
    '      if (lvl == "zero" && on_noac_psu(name)) lvl = "noac"' \
    '      if (lvl == "zero") lvl = "noac"'
}

# 整机部件传感器（风扇 / 电压 / 电源）又回到每个范围都判。
# 1.10.0 现场那份内存专项报告顶上就挂着一条没插线的 PSU3 —— 和内存毫无关系，
# 而客户读到的是"这台机器有问题"。
mut_sensors_state_all_scopes() {
  replace_line "$RT/lib/core.sh" \
    '    sensors_state)                   allow="full" ;;' \
    '    sensors_state)                   allow="full cpu mem gpu disk" ;;'
}

# ================================================================
# 内存专用盘（1.10.0）
# ================================================================

# 序列号重复只判 WARN。
#
# 现场 2026-08-12 买到的那批假内存**压测是全过的** —— 能读能写、ECC 不涨、
# 内核日志干净，唯一露馅的地方就是好几条的序列号一模一样。
# 这条判定是拦住它们的**唯一**一道门，判成 WARN 就等于放行：
# 整机结论只看有没有 FAIL，一批假条子会顶着绿色 PASS 出厂。
mut_mem_sn_dup_warn() {
  # ⚠️ 不能用 replace_line：这一行在 check_dimm_serial 里出现**两次**
  #    （序列号重复那一支、读不到那一支），replace_line 要求锚点恰好命中一次，
  #    会直接报"变异无法可靠施加"。
  #    这里只改**第一次**出现的那个 —— 也就是重复那一支，拦假条子的那道门。
  _apply_awk "$RT/lib/memcheck.sh" \
    'index($0, ENVIRON["MUT_NEEDLE"]) && !done { print ENVIRON["MUT_NEW"]; done = 1; next } { print }' \
    '    result_add "check_dimm_serial" "内存序列号核对" "$ST_FAIL" \' \
    '    result_add "check_dimm_serial" "内存序列号核对" "$ST_WARN" \'
}

# 内存日志模式收回 uncorrectable。
#
# 这个词看着像内存错误，实际上 **PCIe AER 的严重级别就叫这个**
# （"PCIe Bus Error: severity=Uncorrected"）。收回来的后果正是这张盘
# 定死要避免的那件事：一张坏阵列卡、一块坏网卡，会让报告写"内存 FAIL"。
# 用户 2026-08-12 当面定的口径是"只有内存坏才 FAIL"。
mut_mem_dmesg_overreach() {
  replace_line "$RT/lib/memcheck.sh" \
    "  pat+='|Corrupted low memory'" \
    "  pat+='|Corrupted low memory|uncorrectable|Uncorrected|Hardware Error'"
}

# 读不到 SPD 判 FAIL 而不是 SKIP。
#
# 一号红线的同款陷阱：很多服务器平台的 SMBus 归 BMC 管、或者被 BIOS 锁了，
# 主机侧本来就读不到；DDR5 的驱动在 6.8 内核上还不存在。
# 那是**平台的事**，跟这条内存好不好毫无关系 —— 判 FAIL 就是把一整批
# 好机器拦在出货前，而这比漏判更糟。
mut_mem_spd_unread_fail() {
  replace_line "$RT/lib/memcheck.sh" \
    '    result_add "check_spd_clone" "内存芯片信息比对" "$ST_SKIP" \' \
    '    result_add "check_spd_clone" "内存芯片信息比对" "$ST_FAIL" \'
}

# 内存报告删掉「本报告仅针对内存」那句话。
#
# 和 1.9.5 给单项专测立的那条红线是同一把尺子：一份只测了内存的报告顶着
# 一个孤零零的绿色 PASS，读报告的人会当成整机验收通过 ——
# 而处理器、硬盘、网卡这些本轮一项都没测。
# **把"没测"包装成"通过"，比不做这个功能还糟。**
mut_mem_scope_silent() {
  delete_line "$RT/report/generate_mem_report.py" \
    "    A('<div class=\"notice notice-info\"><b>本报告仅针对内存。</b>'"
}

# 空槽位也参与序列号比对。
#
# 空槽的序列号占位符全都是 `NO DIMM`（或者 `Not Specified`），照单比对的话
# 一台 16 槽只插了 8 条的机器会得到 8 个"重复"—— **每一台没插满的机器
# 都被判成假货**。这是"占位符不是内容"那条老规矩在新判定上的复发。
mut_mem_sn_empty_slots() {
  replace_line "$RT/lib/memcheck.sh" \
    '    _serial_is_bogus "$sn" && continue' \
    '    [[ -z "$sn" ]] && continue'
}

# 1.9.8：BMC 的 USB 虚拟网口重新进判定。
# 它那头没有 DHCP 服务器、永远拿不到网关 —— 放回来就是每台带 BMC 的机器
# 都被我们自己刷一条「网卡连通性 WARN」。
mut_bmc_virtual_nic_judged() {
  replace_line "$RT/lib/network.sh" \
    '  [[ "$bus" == "usb" ]] && return 0' \
    '  [[ "$bus" == "ZZ_NEVER" ]] && return 0'
}

# 同一件事在现场那块屏幕上的版本。两处各有各的守卫，缺一处就漏一半。
mut_info_scope_green_pass_screen() {
  delete_line "$RT/lib/ui.sh" \
    '  [[ "$scope" == "info" && "$verdict" == "PASS" ]] && verdict="INFO"'
}

# 范围映射表被改成"什么都跑"：选了只测 CPU，内存/硬盘/显卡照样被压满时长。
# 这条守的是那张表本身 —— 它就是这个功能的全部语义。
mut_scope_stress_unguarded() {
  replace_line "$RT/lib/core.sh" \
    '    stress_mem)                      allow="full mem" ;;' \
    '    stress_mem)                      allow="full cpu mem gpu disk info" ;;'
}

# 报告目录名不带范围后缀。半年后没人分得清哪份报告能当验收依据 ——
# 而这正是这个功能最容易被"顺手简化掉"的一处。
mut_scope_tag_dropped() {
  replace_line "$RT/lib/core.sh" \
    "  printf '%s_%s_%s_%s' \"\$stamp\" \"\$(get_cpu_tag)\" \"\$(get_mem_gb)\" \"\$(scope_tag \"\$scope\")\"" \
    "  printf '%s_%s_%s' \"\$stamp\" \"\$(get_cpu_tag)\" \"\$(get_mem_gb)\""
}

# 批次汇总把单项专测的 PASS 写成和全量一样的 PASS。
# 一列全是 PASS 的表格里混进一台"只测了 CPU"的机器，没有任何人会发现。
mut_scope_summary_plain_pass() {
  replace_line "tools/klburn-summary.py" \
    '    if overall == "PASS" and scope != "full":' \
    '    if False:'
}

# 算力判读只认末尾那行 `Best GFlops`。它是程序跑完才打的，而 bench_run 的超时
# 是硬的 —— 被 kill 时前几次的成绩已经打出来了。只认末行 = 把量到的数扔掉，
# 平白判一个 SKIP，而且没有任何人看得出为什么。
mut_flops_only_best() {
  replace_line "$RT/lib/bench.sh" \
    '    $1 ~ /^[0-9]+$/ && NF >= 4 && $3 ~ /^[0-9]+\.?[0-9]*$/ {' \
    '    $1 ~ /^ZZ_NEVER_MATCHES_ZZ$/ && NF >= 4 && $3 ~ /^[0-9]+\.?[0-9]*$/ {'
}

# 选了显卡专项、机器却没有独立显卡 —— 退回 1.9.6 之前那样一路跑到底。
# 结果是一台**一项测试都没跑成**的机器拿到绿色 PASS，
# 下面还写着"本轮只对显卡做了压力测试与专项诊断"。
mut_scope_missing_as_pass() {
  replace_line "$RT/factory-test.sh" \
    'if [[ "$KLB_SCOPE" == "gpu" ]] && (( GPU_USABLE == 0 )); then' \
    'if false; then'
}

# 缺部件那条 FAIL 套用「本机存在未通过项，不建议出货」。
# 那句话说的是**这台机器有毛病** —— 而它只是没装显卡，本身一点问题都没有。
# 一号红线的反向踩法：不是漏判，是把好机器拦在出货前。
mut_scope_missing_blames_hw() {
  replace_line "$RT/report/generate_report.py" \
    '    elif scope_missing:' \
    '    elif False:'
}

# 硬盘自检结果里「Completed: read failure」被当成通过。这句话里也有
# "Completed" —— 判据顺序反了就会把**盘自己说的"我没通过"**读成通过，
# 一块正在坏的盘拿着干净报告出厂。
mut_selftest_fail_as_pass() {
  replace_line "$RT/lib/verify.sh" \
    "  if grep -aqiE 'Completed:[[:space:]]*(read|electrical|servo|handling|unknown)|Fatal or unknown error' \"\$f\" 2>/dev/null; then" \
    "  if grep -aqiE 'ZZ_NEVER_MATCHES_ZZ' \"\$f\" 2>/dev/null; then"
}

# 发起了自检却没人读结果。盘在后台老老实实跑了一遍短自检，结论没人看 ——
# 加了工具却不看它说什么，等于没加。
mut_selftest_never_read() {
  delete_line "$RT/lib/verify.sh" '  verify_disk_selftest'
}

# 网卡自检排到拉链路之后。offline 自检会把链路踢下去，后面 DHCP 拿到的
# 是一个刚被自己踢掉的链路 —— 一台网口完全正常的机器被判成"网口不通"。
mut_nic_selftest_after_linkup() {
  delete_line "$RT/lib/collect.sh" '  check_nic_selftest  # 定义在 lib/network.sh'
}

# 网卡自检只读总结论、不拆子项 —— 1.9.3 之前就是这样。
# `ethtool -t` 的总结论是所有子项的与，而「链路」那一项依赖网线：
# 没插线的口总结论必然 FAIL，于是每一个没接网线的口都被判成
# "该网口存在硬件故障，需更换或返修后复测"。6530 那台就是这么被拦下的。
mut_nic_selftest_link_as_fail() {
  replace_line "$RT/lib/network.sh" \
    '    (( link_bad > 0 )) && { printf '"'"'link_only'"'"'; return; }' \
    '    (( link_bad > 0 )) && { printf '"'"'fail'"'"'; return; }'
}

# 显卡温度限值不问卡自己要。回到"我们凭空钉一个数"那条老路上：
# RTX 4090 自报的最高工作温度就是 84°C，钉 83 的话每一张好卡都刷一条黄。
mut_gpu_temp_limit_ignored() {
  replace_line "$RT/lib/gpu.sh" \
    '      if (slow == "" || shut == "") exit' \
    '      exit'
}

# 板载网口把"主板没填地址"读成"BIOS 里禁用了"。海光那台 type 41 的两条 LAN
# 全填 0000:00:00.0（主桥地址），照着它匹配必然一个都对不上 ——
# 报告于是写着"共 2 个，其中 0 个在系统中可用"，而那两个口当轮全都采到了。
mut_onboard_nic_placeholder_as_off() {
  replace_line "$RT/lib/conformance.sh" \
    '      if [[ "$short" == "00:00.0" || "$lower" =~ ^0+:0+:0+\.0+$ ]]; then' \
    '      if [[ "$short" == "ZZ_NEVER_MATCHES_ZZ" ]]; then'
}

# 传感器读数恰好为 0 时不再降级。0 既可能是"这个位置没装部件"，也可能是
# "装了但停转"，从读数上分不开 —— 不降级的话，一台空着两个风扇位的好机器
# 会被判 FAIL。这是二号红线（分不清的东西不该去染客户的结论）。
mut_bmc_zero_as_fail() {
  replace_line "$RT/lib/verify.sh" \
    '      if (lvl == "crit" && v == 0) lvl = "zero"' \
    '      if (0) lvl = "zero"'
}

# 部件传感器判的是**测前**那份快照。那样"压测把风扇跑停了""VRM 烤到 100℃"
# 这一整类事永远查不出来 —— 而那正是这条判定存在的理由。
mut_bmc_judge_pre_snapshot() {
  replace_line "$RT/lib/verify.sh" \
    '  [[ "${IPMI_OK:-0}" == "1" ]] && capture -t 60 "ipmi-sensors-post.txt" ipmitool sensor list' \
    '  [[ "${IPMI_OK:-0}" == "1" ]] && capture -t 60 "ipmi-sensors-pre-only.txt" ipmitool sensor list'
}

# 离散量传感器也拿去比阈值。它的"读数"是 0x80 这种事件位，
# 混进来就会把 PWR_Button / CPU0_Status 判成异常 —— 和 1.8.3 电源那次同一课。
mut_bmc_discrete_mixed_in() {
  replace_line "$RT/lib/verify.sh" \
    '      if (!isnum(val)) next' \
    '      if (!isnum(val)) { val = 0; lcr = 1; lnc = 1 }'
}

mut_vtd_fake_patterns() {
  replace_line "$RT/lib/conformance.sh" \
    'Virtualization Technology for Directed I/O|' \
    '  if grep -aqiE '"'"'DMAR: (IOMMU|Intel-IOMMU).*(enabled|hardware identity mapping)|AMD-Vi: (Interrupt remapping enabled|Found IOMMU)'"'"' "$f" 2>/dev/null; then'
}

# ================================================================
# 跑
# ================================================================
usage() {
  cat <<'EOF'
用法: ./tests/mutate.sh [选项] [变异名]

  --list       看有哪些变异
  -j N         同时跑几条（默认按 nproc 算，上限 8）
  -j 1         串行。排查某一条、或者机器很吃紧的时候用
EOF
}

JOBS=0
ONLY=""
LIST=0
while (( $# )); do
  case "$1" in
    --list)    LIST=1;      shift ;;
    -j|--jobs) JOBS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*)        printf '未知参数: %s\n' "$1" >&2; usage; exit 2 ;;
    *)         ONLY="$1";   shift ;;
  esac
done

if (( LIST )); then
  printf '%-20s %-18s %s\n' "变异" "由谁守" "说明"
  for m in "${MUTATIONS[@]}"; do
    IFS="$S" read -r id desc suite _fn <<< "$m"
    printf '%-20s %-18s %s\n' "$id" "$suite" "$desc"
  done
  exit 0
fi

if [[ ! "$JOBS" =~ ^[0-9]+$ ]] || (( JOBS == 0 )); then
  JOBS="$(nproc 2>/dev/null || echo 4)"
  # 再多就是在跟自己抢 I/O，而且 test-report-render 那一路会起 weasyprint，
  # 挺吃内存 —— 并发太高反而更慢。
  (( JOBS > 8 )) && JOBS=8
fi
(( JOBS < 1 )) && JOBS=1

# ================================================================
# 并行怎么做到安全：**每条变异跑在自己的副本里，真工作区一个字节都不动**
# ================================================================
#
# 1.9.5 之前是"就地改真源码、跑完再还原"。那样根本没法并行（两条变异会互相
# 踩），而且有个一直存在的副作用：**跑变异期间 `git diff` 不可信、不能提交**，
# 中途 Ctrl-C 还可能留下改了一半的源码。104 条串行下来要二十多分钟，
# 而"跑一次要二十多分钟"的闸门，最后的结果是没人再跑它。
#
# 现在改成：把源码树拷进临时目录，在**副本**里施加变异、在副本里跑套件。于是
#   - 并行是天然安全的（各人一份，互不相干）
#   - 真工作区自始至终只读 —— 跑变异的时候照样能看 diff、能提交
#   - 中途被打断也不会留下半截源码
#
# 代价是每条变异要拷一次源码树。**拷的是 rootfs/tests/tools/build/docs，
# 不含 vendor/ 和 out/**（那两个加起来好几个 G，而且没有一条测试读它们），
# 一份 3MB 上下、几十毫秒，相比套件本身的耗时可以忽略。
#
# ⚠️ 副本必须落在 **WSL 原生文件系统**上（mktemp 默认的 /tmp），
#    不能落在 /mnt/c 下 —— 在 9p 上拷几千个小文件比跑测试本身还慢。
COPY_DIRS=(rootfs tests tools build docs)

# 只读的真机样本。**先在池子里拷一份，之后每个副本用硬链接挂过去。**
#
# `test_out/` 是从 U 盘拷回来的真机记录（78MB / 2192 个文件），
# `test-hw-checks.sh` 里那组 BMC 传感器断言直接吃它 ——
# "十份真机共 25~91 条带阈值的传感器，越线 0 条"那一条就是拿它跑的。
# 副本里没有它，那组断言会判"一份样本都没吃到"而跑红，于是
# **每一条走 test-hw-checks 的变异都显示"被抓住"** —— 一片假绿。
# （这正是下面那段基线自检抓出来的真问题，两次。）
#
# ⚠️ **软链不行。**`find <软链> -name x` 在不加 -H/-L 时**不会往下走**
#    （POSIX 就这么定的），那条断言照样一份样本都找不到。踩过一次，别改回去。
#
# 所以：整份拷进池子一次（从 9p 上拷，几秒），之后每个副本 `cp -al` 挂硬链接。
# 池子在 /tmp（同一个文件系统），硬链接只建 inode，不搬数据。
# 没有任何变异会写它；真有人写了，下面「真工作区校验」把它一起算进指纹。
FIXTURE_DIRS=(test_out)

REPO_ROOT="$PWD"

POOL="$(mktemp -d)"
cleanup() { rm -rf "$POOL"; }
trap cleanup EXIT

# 真机样本只从 /mnt/c 上拷这一次
FIXTURES="$POOL/.fixtures"
mkdir -p "$FIXTURES"
for d in "${FIXTURE_DIRS[@]}"; do
  [[ -d "$d" ]] && cp -a "$d" "$FIXTURES/" 2>/dev/null
done

# make_copy <目标目录> —— 造一份能跑测试的源码副本
make_copy() {
  local w="$1" d
  mkdir -p "$w"
  for d in "${COPY_DIRS[@]}"; do
    [[ -d "$d" ]] && cp -a "$d" "$w/" 2>/dev/null
  done
  for d in "${FIXTURE_DIRS[@]}"; do
    [[ -d "$FIXTURES/$d" ]] && cp -al "$FIXTURES/$d" "$w/$d" 2>/dev/null
  done
  return 0
}

# 开跑前给真工作区留一份指纹，跑完再比一次。
# 这条断言现在的含义变了：不是"还原干净了"，而是**"我们压根没碰过它"**。
#
# 只按 COPY_DIRS 算，**不含 test_out**：那 78MB / 2192 个文件在 /mnt/c 上，
# 前后各 sha256 一遍就是白读 156MB 的 9p，而它压根不是任何一条变异的目标
# （变异只改 rootfs/tests/tools/build 下的源码）。
SNAP="$POOL/.snapshot"
( for d in "${COPY_DIRS[@]}"; do
    [[ -d "$d" ]] && find "$d" -type f -print0
  done | sort -z | xargs -0 sha256sum ) > "$SNAP" 2>/dev/null

# run_one <id> <desc> <suite> <target> <fn>  -> 往 stdout 打一行
#   CAUGHT|<id>|<suite>|
#   ESCAPED|<id>|<suite>|
#   BROKEN|<id>|<suite>|<原因>
run_one() {
  local id="$1" _desc="$2" suite="$3" target="$4" fn="$5"
  local w="$POOL/$id"

  if [[ ! -f "$target" ]]; then
    printf 'BROKEN|%s|%s|目标文件不存在：%s\n' "$id" "$suite" "$target"
    return
  fi

  make_copy "$w"

  # 变异函数里写的都是**相对路径**（$RT/…、tests/…、tools/…、build/…），
  # 所以进副本目录再调它，改的就是副本。下面「真工作区校验」那一条同时兜住
  # "哪天有人在变异函数里写了绝对路径"这种事。
  local err rc=0
  err="$( cd "$w" && "$fn" 2>&1 | tail -1 )" || rc=$?
  if (( rc != 0 )); then
    printf 'BROKEN|%s|%s|施加失败：%s\n' "$id" "$suite" "$err"
    rm -rf "$w"; return
  fi

  # 跑对应的套件，**必须**非零退出
  if ( cd "$w" && ./tests/"$suite".sh >/dev/null 2>&1 ); then
    printf 'ESCAPED|%s|%s|\n' "$id" "$suite"
  else
    printf 'CAUGHT|%s|%s|\n' "$id" "$suite"
  fi
  rm -rf "$w"
}

CAUGHT=0; ESCAPED=0; BROKEN=0
ESCAPED_LIST=()

printf '\n\033[1;36m===== 变异测试 =====\033[0m\n'
printf '每条变异都必须让对应的测试套件跑红；没红 = 那条守卫是摆设\n'
printf '并发 %d 条，各跑在自己的源码副本里（真工作区只读）\n\n' "$JOBS"

TODO=()
for m in "${MUTATIONS[@]}"; do
  IFS="$S" read -r id _desc _suite _target _fn <<< "$m"
  [[ -n "$ONLY" && "$ONLY" != "$id" ]] && continue
  TODO+=("$m")
done

# ---------------------------------------------------------------- 基线自检
#
# ⚠️⚠️ **这一段是副本模式的命门，别删。**
#
# 判定"被抓住"的依据是"套件跑红了"。可套件跑红的原因**不止变异一种** ——
# 副本要是少拷了一个目录、或者拷坏了，套件会因为完全无关的原因红，
# 于是**每一条变异都显示"被抓住"**，屏幕上一片绿，而它一条都没真验过。
# 那正是这个项目最恨的那种失效：一个什么都没检查的闸门，长得和检查过一模一样。
#
# 所以先在一份**没有施加任何变异**的干净副本里，把这一轮要用到的套件各跑一遍，
# 必须全绿。有一个不绿就整轮作废 —— 那时候"抓住"这个结论本身没有意义。
printf '\033[1m基线自检\033[0m（干净副本里各套件必须全绿，否则"抓住"没有意义）\n'
BASE="$POOL/.baseline"
make_copy "$BASE"

SUITES_USED=()
while IFS= read -r s; do [[ -n "$s" ]] && SUITES_USED+=("$s"); done < <(
  for m in "${TODO[@]:-}"; do IFS="$S" read -r _i _d s _t _f <<< "$m"; printf '%s\n' "$s"; done \
    | sort -u
)

BASE_BAD=()
for s in "${SUITES_USED[@]:-}"; do
  if ( cd "$BASE" && ./tests/"$s".sh >/dev/null 2>&1 ); then
    printf '  \033[32mOK\033[0m   %s\n' "$s"
  else
    printf '  \033[31mFAIL\033[0m %s —— 干净副本里它就是红的\n' "$s"
    BASE_BAD+=("$s")
  fi
done
rm -rf "$BASE"

if (( ${#BASE_BAD[@]} )); then
  printf '\n\033[1;31m基线就不绿，整轮作废：%s\033[0m\n' "${BASE_BAD[*]}"
  printf '这时候每条变异都会显示"被抓住"，而那个绿是假的。\n'
  printf '先在真工作区把这些套件跑通（./tests/run-all.sh），或者检查 COPY_DIRS 是不是少拷了目录。\n'
  exit 1
fi
printf '\n'

RESULTS="$POOL/.results"; : > "$RESULTS"

# 作业池：跑满 JOBS 条就 `wait -n` 等一条收工再补一条。
if (( ${#TODO[@]} )); then
  running=0
  for m in "${TODO[@]}"; do
    IFS="$S" read -r id desc suite target fn <<< "$m"
    run_one "$id" "$desc" "$suite" "$target" "$fn" >> "$RESULTS" &
    running=$(( running + 1 ))
    if (( running >= JOBS )); then
      wait -n 2>/dev/null || true
      running=$(( running - 1 ))
    fi
  done
  wait
fi

# ⚠️ 结果按**清单顺序**打，不按完成顺序。
#    并行的完成顺序每次都不一样，照完成顺序打的话两次跑出来的报告没法直接
#    diff —— 而"这次和上次比多了/少了哪条"正是看这份输出最常干的事。
RESTORED=1
if (( ${#TODO[@]} )); then
  for m in "${TODO[@]}"; do
    IFS="$S" read -r id desc suite _target _fn <<< "$m"
    printf '\033[1m%s\033[0m  (%s)\n' "$id" "$suite"
    printf '    %s\n' "$desc"
    line="$(grep -F -- "|${id}|" "$RESULTS" | head -1)"
    IFS='|' read -r verdict _id _suite why <<< "$line"
    case "$verdict" in
      CAUGHT)
        printf '    \033[32m✓ 被 %s 抓住\033[0m\n\n' "$suite"
        CAUGHT=$(( CAUGHT + 1 )) ;;
      ESCAPED)
        printf '    \033[31m✗ 逃掉了 —— %s 仍然全绿，这条守卫是摆设\033[0m\n\n' "$suite"
        ESCAPED=$(( ESCAPED + 1 )); ESCAPED_LIST+=("$id -> $suite") ;;
      BROKEN)
        printf '    \033[31m✗ %s\033[0m\n\n' "$why"
        BROKEN=$(( BROKEN + 1 )) ;;
      *)
        # 子进程被 OOM / 被杀掉时会走到这儿。**不能当成"抓住了"** ——
        # 没有结果就是没有结果，宁可报成施加失败让人去看。
        printf '    \033[31m✗ 这一条没跑出结果（子进程被杀了？内存不够就 -j 1 再跑）\033[0m\n\n'
        BROKEN=$(( BROKEN + 1 )) ;;
    esac
  done
fi

# ---------------------------------------------------------------- 真工作区没被碰过
#
# 以前这里叫"还原校验"（就地改完再还原）。变异跑进副本之后，这条断言问的是
# 更强的一句：**这一轮从头到尾，真工作区一个字节都没变过。**
# 它同时兜住"哪天有人把变异函数改成写绝对路径"这种事 —— 那种改动在副本模式下
# 会静悄悄地去改真源码，而且测试照样全绿。
printf '\033[1m真工作区校验\033[0m\n'
if sha256sum -c --quiet "$SNAP" >/dev/null 2>&1; then
  printf '  \033[32m真工作区一个字节都没被动过\033[0m\n'
else
  RESTORED=0
  printf '  \033[1;31m真工作区被改动了！下面这些对不上：\033[0m\n'
  sha256sum -c "$SNAP" 2>/dev/null | grep -v ': OK$' | head -10 | sed 's/^/    /'
  printf '  \033[1;31m变异函数里是不是写了绝对路径？先看 git status\033[0m\n'
fi

printf '\n========================================\n'
printf '抓住 %d 条，逃掉 %d 条，施加失败 %d 条\n' "$CAUGHT" "$ESCAPED" "$BROKEN"

# ⚠️ **一条都没跑成也会走到这儿，而下面那个判据全是 0 —— 它会打绿字。**
# 实际踩到过：`./tests/mutate.sh 某个打错的名字` 屏幕上是「全部被抓住」。
# 一条"什么都没做也说全过了"的闸门，和没有这个闸门是一回事。
if (( CAUGHT + ESCAPED + BROKEN == 0 )); then
  printf '\033[1;31m一条变异都没跑成\033[0m\n'
  [[ -n "$ONLY" ]] \
    && printf '  「%s」不在变异清单里。看一眼：./tests/mutate.sh --list\n' "$ONLY" \
    || printf '  变异清单是空的？检查 MUTATIONS 数组\n'
  exit 1
fi
if (( ESCAPED )); then
  printf '\033[1;31m逃掉的：\033[0m\n'
  printf '  %s\n' "${ESCAPED_LIST[@]}"
  printf '逃掉 = 那条守卫抓不住它对应的 bug，要么补断言，要么把变异改准\n'
fi
(( ESCAPED == 0 && BROKEN == 0 && RESTORED == 1 )) \
  && { printf '\033[1;32m全部被抓住\033[0m\n'; exit 0; } \
  || exit 1
