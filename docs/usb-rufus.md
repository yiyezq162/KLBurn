# U 盘制作：Rufus 写盘 + 建 exFAT 数据分区

目标：一根 16G U 盘，做成
- **分区 1**：KLBurn 启动系统（Rufus 从 ISO 写入，插服务器能启动）
- **分区 2**：exFAT 数据分区，卷标 `KLBURN`，测试报告落在这里，插回 Windows 电脑直接能读

---

## ⚠️ 动手前先看这条

整个过程会**清空 U 盘**。开始前确认：
- U 盘里没有你要留的东西
- **看清楚磁盘编号**。下面用到 `diskpart`，选错盘会格掉你的硬盘。
  每一步的 `list disk` 输出都要核对容量（16G 的盘显示大约 `14 GB`），
  不确定就把 U 盘拔掉再 `list disk` 一次，对比少了哪个。

---

## 第一步：Rufus 写入启动分区

1. 下载 Rufus：https://rufus.ie/zh/  （绿色版，双击即用，需要管理员权限）

2. 插入 U 盘，打开 Rufus。

3. 按下面设置：

   | 项目 | 选择 |
   |---|---|
   | 设备 | 你的 U 盘（**核对容量**） |
   | 引导类型选择 | 点「选择」，选 `out\KLBurn-<版本号>-<构建日期>.iso`（挑最新的那个） |
   | 映像选项 | 标准安装 |
   | 分区类型 | GPT |
   | 目标系统类型 | UEFI (非 CSM) |
   | 卷标 | 随意，写盘后会被 ISO 里的卷标覆盖 |
   | 文件系统 / 簇大小 | 保持默认，DD 模式下不生效 |

4. 点「开始」。Rufus 会弹出一个对话框：

   > 检测到该映像是 ISOHybrid 映像 ...
   > - 以 ISO 映像模式写入（推荐）
   > - **以 DD 映像模式写入**

   **必须选「以 DD 映像模式写入」**，然后确定。

   > 为什么必须选 DD：我们的 ISO 的引导结构（BIOS 的 El Torito + UEFI 的 EFI 分区 +
   > 混合 MBR/GPT）是直接从官方 Ubuntu ISO 原样继承过来的。DD 模式是逐字节复制，
   > 引导行为和官方盘完全一致，老服务器的 Legacy BIOS 和新机器的 UEFI 都能认。
   > ISO 模式会让 Rufus 重建引导结构，在部分服务器 BIOS 上会认不到盘。

5. 再确认一次警告框，等进度走完（约 1~3 分钟）。

6. 写完后 Windows 可能弹「使用驱动器前需要将其格式化」——
   **点「取消」，不要格式化**。那是 Windows 认不出的 ISO9660 分区，属于正常现象。

---

## 第二步：建 exFAT 数据分区

Rufus 写完后，U 盘上只用掉了 ISO 那 1 GB 左右，剩下十几 G 是未分配空间。

### 方法 A：磁盘管理（图形界面）

1. 右键「开始」→「磁盘管理」
2. 找到你的 U 盘那一行（按容量认，会显示一段「未分配」）
3. 右键那段**未分配**空间 →「新建简单卷」
4. 一路下一步，到格式化那一步时：
   - 文件系统：**exFAT**
   - 分配单元大小：默认
   - 卷标：**`KLBURN`**（**全大写**）
   - 勾选「执行快速格式化」
5. 完成。资源管理器里会多出一个盘符。

### 方法 B：diskpart（图形界面里未分配空间点不动时用这个）

以**管理员身份**打开 PowerShell 或 CMD，然后：

```bat
diskpart
```

进入 diskpart 后逐条执行：

```
list disk
```

看清楚哪块是 U 盘（16G 盘一般显示 `14 GB`）。假设是 `磁盘 2`：

```
select disk 2
list partition
```

这时应该能看到 Rufus 写进去的 2~3 个分区。确认无误后：

```
create partition primary
format fs=exfat label="KLBURN" quick
assign
list volume
exit
```

`list volume` 里能看到一个 exFAT、卷标 KLBURN 的卷，并且分配了盘符，就成了。

---

## 第三步：验证

1. **在 Windows 上**：资源管理器能看到那个 exFAT 分区（盘符），能往里新建文件再删掉。
2. **卷标必须是 `KLBURN`**（大写）。可以右键盘符 →「属性」确认。
   > 卷标不叫 KLBURN 也能用（程序会退而求其次，去找 U 盘上的任意 exFAT 分区），
   > 但叫对名字最稳妥，尤其是当服务器上还插着别的 U 盘时。
3. **插到服务器上**：开机进 BIOS 启动菜单（常见按键 `F11` / `F7` / `Esc` / `F12`），
   选 U 盘启动。看到 KLBurn 的菜单就说明第一步成功了。
4. 测试跑完后，看屏幕上那行 `Storage     :`：
   - 绿色 `USB stick, folder  out\  - safe to power off` = 报告已经写进 exFAT 分区，可以直接关机
   - 红色 `/tmp ONLY - COPY IT OUT BEFORE POWER OFF` = 数据分区没被认出来，
     报告只在内存里，关机就没了，回头检查第二步

---

## 改了测试脚本后怎么重新出盘

⚠️ **重新用 Rufus DD 写盘会把整根 U 盘覆盖掉，包括第二分区里已有的报告。**

所以顺序是：

1. 先把 exFAT 分区里的 `out\` 文件夹整个拷到电脑上留档
2. 在 WSL 里重新构建：
   ```bash
   sudo ./build/build-iso.sh
   ```
3. Rufus 重新 DD 写入新 ISO（重复第一步）
4. 重新建 exFAT 数据分区（重复第二步）

---

## 替代方案：Ventoy（已完整验证，推荐）

如果你会**经常改脚本重新出盘**，Rufus 这条路每次都要重建数据分区，比较烦。
Ventoy 可以一劳永逸：

1. 下载 Ventoy：https://www.ventoy.net/cn/download.html
2. 运行 `Ventoy2Disk.exe`，选 U 盘，**在「选项」里把文件系统改成 exFAT**，点「安装」
   （只需做这一次）
3. 装完 U 盘上会有一个大的 exFAT 分区，**把 ISO 文件直接拷进去**即可
4. 插服务器启动，Ventoy 会列出盘里的 ISO，选 KLBurn 那个回车

好处：
- 换版本只要**替换 ISO 文件**，不用重新写盘、不用重建分区
- 那个 exFAT 分区**同时就是数据分区**，报告直接落在里面，和 ISO 放一起
- Windows 上就是个普通 U 盘，随时读写

### 报告落在哪

就落在**你放 ISO 的那个 exFAT 分区**（Ventoy 的主分区）的根目录下，
自动创建一个 `out\` 文件夹：

**每次测试单独一个文件夹，报告 `.html` 就在文件夹里面**（不是散在 `out\` 根目录）：

```
<Ventoy分区>\out\
    20260730_143052_2x-Intel-Xeon-Gold-6430_512GB\
        20260730_143052_2x-Intel-Xeon-Gold-6430_512GB.html   ← 双击看报告
        klburn.log  results.jsonl  meta.json  sys_metrics.csv  raw\...
```

插回 Windows 就能看到，和 ISO 文件在同一个盘符下，不用手工拷贝。
**卷标保持 Ventoy 默认的 `Ventoy` 就行，不需要改名**——程序会自动认。

### 已验证

Ventoy 1.1.17 + exFAT 主分区（默认 `Ventoy` 卷标）在 QEMU 里完整验证过：
引导正常、数据分区自动识别为 `/dev/dm-1`、报告正确落盘、
**U 盘自身被正确排除在硬盘压测目标之外**。

> 最后这条不是小事。Ventoy 用 device-mapper 把 ISO 和 exFAT 分区各包了一层，
> 而它的 dm 设备 udev 不处理、`lsblk` 完全看不见，`/dev/mapper/` 下连符号链接
> 都没有。开发过程中，最初版本在 Ventoy 下**认不出启动 U 盘、把它当成空盘列进了
> fio 的写入目标**——真敲下 YES 测试盘就报废了。现在改成用设备号
> （`/sys/dev/block/<maj>:<min>`）反查，并加了 `tests/test-disk-exclusion.sh`
> 专门锁住这个行为。

> Ventoy 唯一的注意点：个别老服务器的 BIOS 对 Ventoy 的引导链兼容性不如原生 DD 盘。
> 如果遇到认不到盘/启动卡住，回到 Rufus DD 方案。

---

## 常见问题

**Q：服务器 BIOS 里看不到 U 盘**
- 换个 USB 口试试，优先用主板后置 USB 2.0 口（有些老 BMC/BIOS 对前面板 USB 3.0 支持不好）
- BIOS 里确认 USB Boot / Legacy USB Support 是开启的
- 如果机器是纯 UEFI 模式，确认 Secure Boot 关闭（我们的 ISO 内核未签名）

**Q：启动到一半卡住 / 黑屏**
- 在 GRUB 菜单按 `e`，把 `quiet` 删掉再按 `F10`，能看到内核启动信息定位卡在哪
- 记下卡住位置反馈

**Q：Windows 看不到第二个分区**
- Windows 10 1703 以前的版本不支持可移动 U 盘的多分区。Win10 新版/Win11 没这问题
- 确认第二分区确实格式化成了 exFAT 而不是 NTFS（NTFS 也能读，但 Linux 侧写入支持较弱）

**Q：测试完报告在哪**
- exFAT 分区根目录下的 `out\` 文件夹（自动创建）
- 里面每次测试一个文件夹，名字是 `日期_时间_CPU型号_内存容量`
- 文件夹里那个**同名的 `.html`** 双击用浏览器打开就是完整报告，
  旁边的 `klburn.log` / `raw\` 是全部原始日志
