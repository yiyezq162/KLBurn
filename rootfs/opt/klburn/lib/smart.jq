# 把 smartctl -j 的输出归一化成一组固定字段。
# SATA/SAS 走 ata_smart_attributes，NVMe 走 nvme_smart_health_information_log，
# 这里统一成同样的键名，verify.sh 和报告生成器都用这一份。

def attr($id):
  (.ata_smart_attributes.table // [])
  | map(select(.id == $id))
  | (.[0].raw.value // null);

{
  model:            (.model_name // .scsi_model_name // "-"),
  serial:           (.serial_number // "-"),
  firmware:         (.firmware_version // "-"),
  capacity_bytes:   (.user_capacity.bytes // .nvme_total_capacity // 0),
  rotation_rate:    (.rotation_rate // null),

  # 通电时间：证明是新盘的关键证据
  power_on_hours:   (.power_on_time.hours
                     // .nvme_smart_health_information_log.power_on_hours // null),
  power_cycles:     (.power_cycle_count
                     // .nvme_smart_health_information_log.power_cycles // null),
  temperature_c:    (.temperature.current
                     // .nvme_smart_health_information_log.temperature // null),
  smart_passed:     (.smart_status.passed // null),

  # SATA 关键坏道属性
  realloc_sectors:  attr(5),
  pending_sectors:  attr(197),
  uncorrectable:    attr(198),
  crc_errors:       attr(199),

  # NVMe 关键健康字段
  media_errors:     (.nvme_smart_health_information_log.media_errors // null),
  critical_warning: (.nvme_smart_health_information_log.critical_warning // null),
  percentage_used:  (.nvme_smart_health_information_log.percentage_used // null),
  unsafe_shutdowns: (.nvme_smart_health_information_log.unsafe_shutdowns // null)
}
