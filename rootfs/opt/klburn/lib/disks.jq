# 从 lsblk -J -b -O 的输出里挑出"整盘"设备，输出 TSV 供 shell 消费。
# 字段: name  path  size_bytes  model  serial  rota  tran  removable  pttype  mounted_count
#
# mounted_count > 0 表示这块盘上有任何分区当前被挂载 —— 一律不碰。

def norm($v): if $v == null or $v == "" then "-" else ($v | tostring) end;

# 递归收集自身及所有子设备的挂载点
def all_mounts:
  [ (.mountpoint // empty) ]
  + [ (.mountpoints // [])[] | select(. != null) ]
  + [ (.children // [])[] | all_mounts ]
  | flatten;

.blockdevices[]
| select(.type == "disk")
| [ .name,
    norm(.path // ("/dev/" + .name)),
    norm(.size),
    (norm(.model) | gsub("\\s+"; " ") | gsub("^ | $"; "")),
    norm(.serial),
    (if (.rota == true or .rota == "1" or .rota == 1) then "HDD" else "SSD" end),
    norm(.tran),
    (if (.rm == true or .rm == "1" or .rm == 1 or .hotplug == true) then "1" else "0" end),
    norm(.pttype),
    (all_mounts | length | tostring)
  ]
| @tsv
