# 21 · 三设备上电到出图：完整操作 SOP

> 适用：**主机 PC + Go2（拓展坞）+ Mid360**，无线链路，FAST-LIO2 + FLMap。
> 本文是「照着一路敲下去」的清单式流程，每一步都带**可验证的成功标志**，不符合就别往下走。
> 详细背景见 `18-local-operation.md`（操作细节）、`08-hardware.md`（接线）、`17-wireless-link.md`（无线）。

---

## 0. 角色与地址（先记住这张表）

| 设备 | 角色 | 关键地址 | 说明 |
|---|---|---|---|
| **PC** | 热点 AP + RViz + 收数据 | `wlp132s0` **10.42.0.1/24** | `enp131s0` 是备用有线口，无线模式不用插 |
| **Go2 拓展坞** | 建图计算 + 录包 | `wlan0` **10.42.0.18/24**<br>`eth0` 192.168.123.18 | 工作空间 `~/flmap3_ws` |
| **Mid360** | 传感器 | **192.168.123.221** | 走狗的 `eth0`，与运控 `.161` 同一网段 |

- SSID `FLMap3` / 密码 `flmap2026` / ch44（5 GHz）/ 域名 `ROS_DOMAIN_ID=42`
- 三台设备的数据链路是：**雷达 →（网线，百兆）→ 狗 →（Wi-Fi）→ PC**

---

## 1. 一页速查（熟练之后只看这一节）

```bash
# ── ① PC：起热点（唯一必须手动的一步）
cd ~/FLMap.2 && sudo ./scripts/pc_hotspot.sh --chan=44

# ── ② 狗上电，等 40 秒，然后一条命令验链路
sudo ./scripts/postboot_check.sh --wait=120

# ── ③ 窗口 1：进狗端控制台
ssh -t unitree@10.42.0.18 'bash ~/flmap3_ws/scripts/edge_control.sh'
#    出现 flmap> 后敲：start

# ── ④ 窗口 2：开 RViz
cd ~/FLMap.2 && ./scripts/pc_view.sh

# ── ⑤ 录完：flmap> 里敲 stop（自动导出 PCD），再 quit

# ── ⑥ 取回主机
rsync -a --no-owner --no-group -e ssh unitree@10.42.0.18:~/bags/<时间戳> ~/Desktop/FLMap/
```

---

## 2. 阶段 A：上电前（30 秒，别省）

| 检查 | 合格标准 | 不做的后果 |
|---|---|---|
| 雷达 M8 航插插到底 | 卡的卡扣到位，雷达指示灯亮 | 供电峰值期欠压，雷达反复重启 |
| 雷达**出光面**与 Go2 自带 L1 雷达错开 | 不共面、有高度差 | **对射会烧雷达**（见 `08-hardware.md` §3） |
| 雷达放稳（桌面/支架） | 不晃 | 会引入真实运动，与 IMU 噪声难区分 |
| 狗电量 | > 30% | 建图中途掉电，整段 bag 报废 |
| PC 无线没有被别的 AP 占着 | 不用 `wlp132s0` 连别的 Wi-Fi | 一张卡不能同时当 AP 和 STA |

---

## 3. 阶段 B：PC 起热点

三台设备可以同时上电，**但 PC 的热点必须最先可用**。原因是狗要连它；
不过现在狗端已设 `autoconnect-retries=0`（无限重试），所以即使 PC 起得慢，
狗也会一直等，不会像以前那样重试 4 次就彻底放弃。

```bash
cd ~/FLMap.2
sudo ./scripts/pc_hotspot.sh --chan=44
```

**成功标志**（四个 ✓ 缺一不可）：

```
✓ 热点已启动（a / ch44）
✓ 省电已关（off）              ← 这行必须真的是 off
    wlp132s0   10.42.0.1/24
    SSID       FLMap3
```

- 若出现 `! country 00：5 GHz 全是 PASSIVE-SCAN` → 脚本会自动设 CN，不用管
- 若出现 `省电仍为 on` → 这张卡固件不让关，直接起 `ap_watchdog.sh` 兜底

> **热点不会开机自启**（NM 里是 `autoconnect no`，故意的）。每次重启 PC 都要跑这一条。

长期跑的话，第二个窗口挂上守护，AP 静默会自动重开：

```bash
sudo nohup ./scripts/ap_watchdog.sh --interval=10 > /tmp/ap_wd.log 2>&1 &
```

---

## 4. 阶段 C：狗上电 + 雷达起来

1. 电池上电 → 狗站立/趴下（约 10 秒）
2. 拓展坞开机，**等 40 秒**（Jetson 起完）
3. 雷达随拓展坞的 M8 口一起供电；若雷达是**独立 12 V 供电**，此时再给它上电，
   等 **8 秒**让自检过（这 8 秒是功耗峰值，别再挂别的外设）

**这个阶段不要敲任何命令**，让狗自己把 `wlan0` 连上来。

---

## 5. 阶段 D：一条命令验完链路

```bash
cd ~/FLMap.2
sudo ./scripts/postboot_check.sh --wait=120
```

**成功标志**：

```
✓ AP 已起  SSID=FLMap3  ch44
✓ 省电 off
✓ 狗端已自动关联并 ping 通 10.42.0.18
   90:de:80:4e:32:ec  信号 -31 dBm
```

信号若低于 **-70 dBm**，脚本会警告 —— 建图中途可能掉线，先把狗挪近或抬高天线。

## 6. 阶段 E：确认雷达活着

这是**最容易被跳过、又最值得查**的一步。雷达没数据时，症状是"控制台起来了但地图不长"，
很难第一眼看出原因。

```bash
ssh unitree@10.42.0.18 'ping -c3 192.168.123.221'
```

**成功标志**：`0% packet loss`，RTT 约 **1.5 ms**。
顺便确认运控也在：`ping -c1 192.168.123.161` → 约 0.3 ms。

雷达不通就别往下走，按 `08-hardware.md` §5 查：网段 / 网线只通电不通数据 / 没上电。

---

## 7. 阶段 F：进控制台

```bash
ssh -t unitree@10.42.0.18 'bash ~/flmap3_ws/scripts/edge_control.sh'
```

`-t` **不能省**：控制台要读键盘，没有 TTY 的 ssh 会让 `read` 立刻拿到 EOF，起来就退。

**成功标志**：

```
=== 启动 Livox 驱动
=== 启动 FAST-LIO2（use_sim_time=false）
=== 启动瘦身桥（发给 PC）
========================================
 狗端建图控制台（可视化在 PC 端）
 命令: start / stop / status / stats / link / quit
========================================
flmap>
```

看到 `flmap>` 就说明**雷达驱动、FAST-LIO2、桥三个进程已经在跑**了（不用你敲命令）。
此时另开一个终端重跑 `./scripts/link_probe.sh`，第 4、5 项应该都变绿
（开扫前它报红是正常的：桥还没起）。

---

## 8. 阶段 G：开录

在 `flmap>` 里敲：

```
start
```

会问一句 `扫描前是否做一次环境体检？(y/N)`：

- **敲 `n`**（省 20 秒）—— 阶段 D/E 已经验过链路和雷达
- 换了硬件、改过配置、上次出过问题 → 敲 `y`，21 项逐条打出来

**成功标志**：

```
录包中 → /home/unitree/bags/2026-10-21_15-36-56/scan/  (PID 4889)
```

**看到这一行才说明真在录。** 若紧跟「录包进程已退出」，脚本会打 `record.log` 尾部，照那个修。

---

## 9. 阶段 H：PC 端开 RViz（另一个窗口）

```bash
cd ~/FLMap.2
./scripts/pc_view.sh
```

它自动做四件事：绑定 DDS 到 `wlp132s0` → ping 狗 → 探测 `/flmap/cloud` → 起累加器 + RViz2。
软件渲染已内置（`LIBGL_ALWAYS_SOFTWARE` + mesa + llvmpipe），不用手动 export。

**成功标志**：

```
[ ok ] ping 通，平均 RTT 1.18 ms
[ ok ] 收到点云，当前帧 8501 点，约 10.1 Hz
```

RViz 里 Fixed Frame 设 `map`，看 `/flmap/cloud`（累加后的整图）和 `/cloud_registered`（当前帧）。

---

## 10. 阶段 I：录制中可用的三条现场命令

| 敲什么 | 什么时候用 | 正常值 |
|---|---|---|
| `status` | 怀疑某个进程死了 | 四个进程号都在，`/flmap/cloud` 有频率 |
| `stats` | 看桥的输出 | 约 `10.0 Hz`、`~10.9 Mbit/s` |
| `link` | 怀疑网络问题 | 信号 > −60 dBm、RTT < 2 ms |

**要空一段**（有人走过、要挪设备）：`pause` → 处理 → `resume`。
比 `stop`+`start` 好在：不用重导 PCD、不多出任务目录、位姿连续。

---

## 11. 阶段 J：收尾

```
stop        ← 停止录包 + 自动导出 PCD
quit        ← 关掉所有节点
```

**成功标志**：

```
PCD 已导出: /home/unitree/bags/2026-10-21_15-36-56/map.pcd
-rw-rw-r-- 1 unitree unitree 121M ... map.pcd
```

`quit` 时若看到 `... Killed`，那是 `pkill` 关节点的正常输出，不是错误。

---

## 12. 阶段 K：取回主机

```bash
rsync -a --no-owner --no-group -e ssh \
  unitree@10.42.0.18:~/bags/<时间戳> ~/Desktop/FLMap/
```

- `--no-owner --no-group` **必须带**：目标盘不支持 chown，不带会误报 `code 23`
- 实测 685 MB / 63 秒 / 约 11 MB/s
- 校验：两端 `md5sum map.pcd` 应完全一致

拿到之后立刻看结果：

```bash
/usr/bin/python3 scripts/pcd_preview.py ~/Desktop/FLMap/<时间戳>/map.pcd    # 出 PNG
cloudcompare ~/Desktop/FLMap/<时间戳>/map.pcd &                            # 交互看
/usr/bin/python3 scripts/diag_bag_timing.py ~/Desktop/FLMap/<时间戳>/scan    # 查有没有倾斜
```

> 想省掉"控制台 + 取数据"这一整套，用 PC 端一条命令跑完：
> `./scripts/edge_scan.sh --secs 120`（自动 start→录 N 秒→stop→导出→拉回→校验）。
> 但那样中途不能 `pause`，现场用控制台更灵活。

---

## 13. 关机顺序

```
1. flmap> quit（若还在控制台里）
2. PC 端关 RViz（Ctrl+C）
3. 停看门狗：sudo ./scripts/ap_watchdog.sh --stop
4. 关热点：  sudo ./scripts/pc_hotspot.sh --down
5. 雷达断电 → 拓展坞关机 → 狗电池断电
```

反着关的后果：先断雷达再 `quit`，驱动会刷一串 UDP 超时；先关热点，狗端会一直重连刷日志。

---

## 14. 故障分支（按阶段定位）

| 卡在 | 现象 | 在哪查 | 处置 |
|---|---|---|---|
| B | `热点启动失败` | `journalctl -u NetworkManager -n 40` | `sudo ./scripts/pc_hotspot.sh --reload`（重载 rtw89） |
| D | `120s 内没有连上` | `sudo ./scripts/postboot_check.sh` | 手机搜 `FLMap3`：手机也搜不到→热点静默，走 `--reload`；搜得到→插网线跑 `./scripts/dog_wifi_diag.sh --fix` |
| D | 信号 < −70 dBm | 同上 | 挪近狗、抬高天线 |
| E | `ping 192.168.123.221` 不通 | 雷达指示灯 | 查供电 / 换线 / 网段（`MID360_config.json`） |
| F | 控制台秒退 | 是否漏了 `ssh -t` | 补 `-t` |
| F | `No point!!!` | `/tmp/flmap_edge/mapping.log` | 雷达没数据，回阶段 E |
| G | 录包进程已退出 | `/tmp/flmap_edge/record.log` | 磁盘满 / 话题名不对 |
| H | RViz 一片空白 | `pc_view.sh` 的 `[warn]` 行 | 多半是狗端还没 `start` |
| H | 满屏 `GLXContext` 错误 | — | 已被 `pc_view.sh` 内置软件渲染解决；手动跑时需 `LIBGL_ALWAYS_SOFTWARE=1` + `__GLX_VENDOR_LIBRARY_NAME=mesa` + `GALLIUM_DRIVER=llvmpipe` |

---

## 15. 每次都要留意的三件事

1. **PC 热点不自动起** —— 每次 PC 重启后必须跑一次 `pc_hotspot.sh`。这是整套流程里唯一
   无法自动化的一步（需要 sudo + 网络管理权限）。
2. **狗端二进制可能不是最新的** —— 跑之前确认一下：
   `ssh unitree@10.42.0.18 'ls -l ~/flmap3_ws/install/fast_lio2/lib/fast_lio2/fastlio2_mapping'`。
   改过 `src` 之后必须 `./scripts/deploy_edge.sh` 重新部署，否则狗上跑的还是旧代码。
3. **狗上有一个废弃的 `~/flmap_ws`** —— 那是 10-18 的旧工作空间，没有 `scripts/`。
   所有命令都用 `~/flmap3_ws`。
