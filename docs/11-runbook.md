# 11 · 本地操作手册（Runbook）

> 打印这一篇就够用。每一步都有**检查点**：输出不对就别往下走，直接跳 §6。
> 全流程约 3 分钟（不算首次部署）。
>
> 第一次上手、想先弄明白"这套东西在干嘛"，看 [12-handbook.md](12-handbook.md)
> —— 通俗版，不堆术语，每步只说"敲什么、看到什么算对"。

**本机固定参数**

| 角色 | 地址 | 说明 |
|---|---|---|
| PC 无线口（热点） | `10.42.0.1/24` | `wlp132s0`，SSID `FLMap3`，`pc_hotspot.sh` 创建 |
| Go2 无线口 | `10.42.0.18/24` | SSH 用户 `unitree`，建图跑在这上面 |
| Go2 有线口（内部） | `192.168.123.18` | 狗上 `eth0`，PC 不直连，只经狗转发 |
| 运控 | `192.168.123.161` | 狗内部网段，只用来确认狗活着 |
| Mid360 | `192.168.123.221` | 狗内部网段，由狗端供电，随狗上电 |
| ROS 域 | `ROS_DOMAIN_ID=42` | 避开宇树自用的 0 域，脚本已内置 |
| RMW | `rmw_cyclonedds_cpp` | 两端必须相同，脚本已内置 |

---

## 0. 最短路径（已经配好过、只想再建一次图）

```bash
# 终端 A（PC）    先开热点，再起授时（热点不会开机自启，每次都要跑）
cd ~/FLMap.2
sudo ./scripts/pc_hotspot.sh
./scripts/link_probe.sh                 # 四段全绿再往下
./scripts/clock_sync.sh start           # 常驻

# 终端 B（狗端）  进控制台，看到 10 Hz 后敲 start
ssh unitree@10.42.0.18          # 登录后问 ros:foxy(1) noetic(2) ? → 输入 1
cd ~/flmap3_ws && ./scripts/edge_control.sh
#   flmap> start

# 终端 C（PC）    出图
cd ~/FLMap.2 && ./scripts/pc_view.sh
```

收工：终端 B `stop` → `quit`，终端 C `Ctrl-C`。

## 0.1 三条路径，先选一条

| 我要做什么 | 走哪节 | 耗时 |
|---|---|---|
| 今天只是要建一次图 | 上面这段 / §3 | 3 分钟 |
| 换了新 PC / 重装了系统 / 第一次跑 | §2 一次性配置 → §3 | 20–30 分钟 |
| 已经有问题（连不上 / 画面空 / 形状怪） | §6 症状速查 | — |

一条命令判断"现在能不能直接开跑"：

```bash
cd ~/FLMap.2 && ./scripts/link_probe.sh
```

末尾出现「链路健康，直接 ./scripts/pc_view.sh」就跳 §3；有红项看 §6。

---

## 1. 上电前：连接方式与顺序

**无线链路，没有网线。**

```
   PC wlp132s0 (AP)  ═══ 5 GHz ch44 ═══  Go2 wlan0 (STA)
      10.42.0.1                            10.42.0.18
                                                │
                                     拓展坞 eth0 192.168.123.18
                                                ├── Mid360 192.168.123.221
                                                └── 运控 .161（内部链路）
```

PC 与狗之间只有一条 5 GHz 无线；狗内部仍是原来的 `192.168.123.0/24`，PC 不参与这一段，
要访问雷达/运控只能经狗转发。

上电顺序（有讲究，别反）：

1. **PC 先开热点**（`sudo ./scripts/pc_hotspot.sh`）。热点不开机自启，每次都要手动跑。
2. 狗上电（电池开机），等 20–40 秒。狗端 `wlan0` 会自动连 `FLMap3`。
3. PC 上 `ping` 一次狗：

```bash
ping -c3 10.42.0.18
```

**检查点**：3 个包全收，RTT 在 1 ms 级。

```
3 packets transmitted, 3 received, 0% packet loss
rtt min/avg/max/mdev = 0.42/0.55/0.71/0.08 ms
```

> 雷达/运控**不要从 PC 直接 ping**。它们在狗的 `eth0` 后面，能不能转发取决于狗端配置，
> 与建图无关。要确认它们活着，进 `flmap>` 敲 `link`，那是从狗端看的。
>
> 无线起不来（狗找不到热点 / 连上没地址）见 [17-wireless-link.md](17-wireless-link.md)。

---

## 2. 一次性配置（只在新机器 / 重装后做）

### 2.1 PC 热点（无线链路唯一要准备的东西）

一条命令就够（幂等，可反复跑）：

```bash
cd ~/FLMap.2 && sudo ./scripts/pc_hotspot.sh
```

它做五件事：查网卡的 AP 能力 → 设监管域 `CN`（不设的话 5 GHz 全被内核禁掉，
AP 起不来，原因见 [17-wireless-link.md](17-wireless-link.md)）→ 建/启用 `flmap-ap`
（`mode ap`、ch44、WPA2、`ipv4.method shared`）→ 起 AP → 补一条 `239.255.0.1/32`
的多播路由，让 DDS 发现包从无线口出去。

成功的样子：

```
✓ 热点已启动（a / ch44）
wlp132s0   10.42.0.1/24
SSID       FLMap3      密码 flmap2026
```

手工等价操作（**不推荐**，监管域那步最容易漏）：

```bash
nmcli device disconnect wlp132s0   # 必须先断开：否则 AP 的 country IE 会盖掉下面的 reg set
sudo iw reg set CN
sudo nmcli connection add type wifi ifname wlp132s0 con-name flmap-ap \
    autoconnect no 802-11-wireless.mode ap 802-11-wireless.band a \
    802-11-wireless.channel 44 \
    802-11-wireless.ssid FLMap3 \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk flmap2026 \
    ipv4.method shared
sudo nmcli connection up flmap-ap
ip -br addr show wlp132s0        # 期望 10.42.0.1/24
```

> **`ipv4.method shared` 会自动给 PC 自己配 `10.42.0.1` 并做 NAT**，所以手机网卡那条
> 默认路由照常出网 —— 这点和有线的静态地址不同，不用手工留空网关。
>
> 收工要关：`sudo ./scripts/pc_hotspot.sh --down`。热点**不会开机自启**
> （`autoconnect no` 是故意的），每次开机都得手动跑一次。
>
> `pc_net_fix.sh` 是用来配有线口的（`192.168.123.10`），**无线链路下不需要它**。

### 2.2 PC 端编译

```bash
cd ~/FLMap.2
./setup.sh                       # 首次约 4–5 分钟
```

**检查点**：末尾出现 `[ ok ] 编译完成`，并且 `install/setup.bash` 存在。

### 2.3 时间同步（**建图前必须做，且只需装一次**）

```bash
./scripts/clock_sync.sh start     # PC 起 HTTP 授时服务（后台常驻）
./scripts/clock_sync.sh install   # 推到狗端装 systemd 定时器（要狗端 sudo 密码）
```

装完之后，**狗端**每 30 秒自动校一次，以后开机不用管。但 **PC 端的授时服务不会开机自启**，
所以每次实验还是要在终端 A 跑一次 `clock_sync.sh start`（见 §3）。

验证：

```bash
./scripts/clock_sync.sh check
```

**检查点**：最后一行形如 `偏差=-0.0095s`，**|偏差| < 50 ms 即可**（实测在 5–10 ms 之间波动，
RTT 1.3–1.7 ms）。这个量级对 LIO 融合和 RViz 都完全没有影响 —— 出问题的是几百毫秒级的偏差。

> 不做这一步的后果：Orin Nano 没有 RTC 电池，断电后时间可能是 2023 年。RViz 会不停
> 刷 `Message Filter dropping message`，TF 全部过期，画面定住。原理见
> [09-time-sync.md](09-time-sync.md)。

### 2.4 部署到狗端

```bash
./scripts/deploy_edge.sh
```

脚本做三件事：`rsync` 整仓 → 远端打 Foxy 补丁 → 远端 `colcon build`。

**检查点**：`6 packages finished`，约 4–8 分钟（Orin Nano 实测 4 分 32 秒）。

```bash
# 可选：确认狗端装好了
ssh unitree@10.42.0.18 'ls ~/flmap3_ws/install/setup.bash'
```

> 只改了狗端代码时，可以只同步+编译，不重新打补丁：
> `./scripts/deploy_edge.sh --no-patch`

---

## 3. 每次实验 SOP（三个终端，顺序不能乱）

### 终端 A —— PC：时间基准

```bash
cd ~/FLMap.2
./scripts/clock_sync.sh start      # 已在跑会提示"已在运行"，无害
```

**检查点**：出现 `[ ok ]` 开头的一行即可，三种都算正常：

```
[ ok ] 授时服务已启动: http://10.42.0.1:8000/time     ← 本次拉起
[ ok ] 授时服务已在运行 (pid 12345)                        ← 之前拉起的
[ ok ] 端口 8000 上已有授时服务在响应 —— 直接复用           ← 脚本会探一下 /time 再认
```

出现 `[fail] 端口 8000 不可用` 说明 8000 被别的程序占了（脚本会打印占用者和换端口的方法）。

> 开着就别关。它只占一个 HTTP 端口，狗端定时来取。

### 终端 B —— 狗端：起建图

```bash
ssh unitree@10.42.0.18
#   登录后会先问一句：ros:foxy(1) noetic(2) ?   →  输入 1 回车
cd ~/flmap3_ws
./scripts/edge_control.sh
```

> **为什么有那个 1/2 的选择？** 狗端 `~/.bashrc` 里有一段 fishros 生成的 ROS 选择脚本
> （`~/.bashrc` 第 121–132 行），每次交互登录都会 `read` 一次。选 `1` 会 source Foxy，
> **同时** export `CYCLONEDDS_URI=~/cyclonedds_ws/cyclonedds.xml`。
>
> ⚠️ **那份 xml 在狗端是坏的**：它用的是 CycloneDDS 0.9+ 的 `<Interfaces>` 语法，
> 而狗端装的是 `ros-foxy-cyclonedds 0.7.0`，载入即报
> `Domain/General: Interfaces: unknown element`，然后 `rmw_create_node` 失败 ——
> 任何节点一启动就退出。`edge_control.sh` 已经在开头主动 `unset CYCLONEDDS_URI`
> 并打印一行 `[info] 忽略继承来的 ...`，所以你选了 1 也能正常跑。
>
> 想彻底摆脱：把 `~/.bashrc` 里 `# >>> fishros initialize >>>` 到
> `# <<< fishros initialize <<<` 之间整段注释掉，然后 `source ~/.bashrc`
> （或直接退出重登，什么都不按）。
>
> 直接回车（不选）也没事：`edge_control.sh` 自己会 source Foxy 并设好 DDS 变量。

脚本会自动依次拉起 **驱动 → FAST-LIO2 → bridge**，约 11 秒，然后进入 `flmap>` 提示符。

**检查点**（启动日志里必须看到这两条）：

```
[ ok ]  /cloud_registered: average rate: 10.0xx
```

（若这一行显示 `统计还没出（LIO 刚起，通常 10 秒内就正常）`，见下面一段。）

```
flmap_bridge: /cloud_registered -> /flmap/cloud | voxel 0.10 m | <= 10.0 Hz (tol 0.85)
              | <= 60000 pts | range 0.5-40.0 m | qos reliable->reliable
```

如果 `/cloud_registered` 那行显示 **“统计还没出（LIO 刚起）”**，属正常：话题刚建、`hz`
还没攒够样本。等 10 秒在 `flmap>` 里敲 `status` 再看，出现 `average rate: 10.x` 即可。

> **读数说明**：刚启动的十几秒里 `status` 常显示 **8.8–9.2**Hz，而不是 10.0。
> 这是 `hz` 把启动阶段的低速率也平均进去了，稳定后就是 10.0±0.1，**不是丢数据**。
> 判断标尺：`/flmap/cloud` 与 `/cloud_registered` 的帧率应该**接近**（差值 < 5%），
> 而不是死磕 10.00。

只有显示 **“驱动未连上雷达”** 时才需要处理，看 §6.2。

> 自己手工敲 `ros2 topic hz` 时如果接管道（`| grep`）看不到输出，加
> `PYTHONUNBUFFERED=1`，原因见 [06 §8.2](06-troubleshooting.md#82-ros2-topic-hz-通过管道没有输出)。

> **驱动和建图一进控制台就在跑**，`start` 只是"开始录包 + 建任务目录"。

### 终端 C —— PC：看图

```bash
cd ~/FLMap.2
./scripts/pc_view.sh
```

它会先做连通性检查，再起累加器 + RViz2（自带配置，不用手动加 Display）。

**检查点**：

```
[ ok ] 收到点云，当前帧 8812 点，约 9.9 Hz
```

点数在 8500–9200 之间浮动是正常的（视野内容变了），**别当成丢数据**。

RViz 里应该出现四个显示项：

| 显示项 | 话题 | 长什么样 |
|---|---|---|
| Accumulated Map | `/flmap/map` | 越攒越大的地图，1 Hz 刷新 |
| Edge Frame (live) | `/flmap/cloud` | 当前这一帧，10 Hz 闪动 |
| Odometry | `/aft_mapped_to_init` | 位姿箭头 |
| Trajectory | `/path` | 走过的轨迹 |

### 开始 / 暂停 / 结束（在终端 B 的 `flmap>` 里）

```
flmap> start        # 建任务目录 + 开始录包
flmap> pause        # 暂停录包（节点继续跑，地图继续长）
flmap> resume       # 继续录
flmap> stop         # 停止录包 + 自动导出 PCD
flmap> status       # 进程 / 话题频率 / 温度 / 内存
flmap> stats        # bridge 压缩比与输出频率
flmap> link         # 链路体检（无线信号/速率 + 到 PC/雷达 RTT）
flmap> quit         # 退出（会自动先 stop）
```

**检查点**（`stats` 输出，实测基线）：

```
in 15921 pts -> out 8982 pts (56.4%), ~144 kB/msg, ~11.5 Mbit/s @10.0 Hz
```

| 数值 | 正常范围 | 偏低说明 |
|---|---|---|
| 保留比例 | 50–60% | 体素调大了，或场景太空旷 |
| 输出频率 | 9.5–10.0 Hz | 输入帧率不足 / 限流参数被改 |
| 带宽 | 10–13 Mbit/s | 点太少，检查雷达 |

---

## 4. 收工

顺序：**先停狗端，再关 PC 端，最后断电**。

```
flmap> stop      # 导出 PCD（不 stop 直接 quit 也会自动 stop）
flmap> quit      # 关掉驱动 / LIO / bridge
```

PC 端：终端 C `Ctrl-C` 结束 `pc_view.sh`。

数据在哪：

```
狗端  ~/bags/<日期>_<时间>/scan/      # rosbag（/livox/lidar /livox/imu /cloud_registered /aft_mapped_to_init）
狗端  ~/bags/<日期>_<时间>/map.pcd    # stop 时导出的全分辨率地图（导出成功才有）
狗端  ~/bags/<日期>_<时间>/info.txt   # 开始时间、主机、话题清单
狗端  ~/bags/<日期>_<时间>/record.log # 录制进程自己的输出
狗端  ~/bags/<日期>_<时间>/pcd_export.log  # 导出 PCD 的完整输出（失败先看这个）
狗端  /tmp/flmap_edge/{driver,mapping,bridge}.log
```

**如果 `stop` 报"PCD 导出失败"，先别重扫。** bag 通常还在 `scan/` 里，
重导一次就行（详见 [06 §8.3](06-troubleshooting.md#83-stop--quit-之后-pcd-导出失败)）：

```bash
cd ~/flmap3_ws
/usr/bin/python3 scripts/bag_to_pcd.py ~/bags/<目录>/scan ~/bags/<目录>/map.pcd
```

它还会打印每个话题的条数——顺便确认录制期间到底出了多少帧。

拷回 PC（千兆，几十 MB 一两秒）：

```bash
scp -r unitree@10.42.0.18:~/bags/2026-10-19_14-30-00 ~/bags/   # 换成实际目录名
```

### 4.1 整机断电重启（换场景 / 收工带回家）

**顺序：先停节点 → 再 `poweroff` → 最后断电。** 不要直接拨电池开关。

```bash
# ① 狗端：正常停节点（在控制台里）
flmap> stop        # 导出 PCD；不 stop 直接 quit 也会自动 stop
flmap> quit

# ② 狗端：走系统关机，别按电源键硬断
sudo poweroff      # 需要密码；等风扇停、指示灯灭（约 20 s）

# ③ 再关电池开关 / 拔电源
```

> 完整的关机/断连教程（每一步"看到什么算对"、乱序的后果、硬断电后怎么救半截 bag）
> 见 [13-shutdown.md](13-shutdown.md)。

> **为什么不直接断电**：`stop` 时要写 `map.pcd`，LIO 的日志也在持续写盘。
> 硬断最容易留下半截文件；ext4 能扛住，但 PCD 会是坏的，而且不会报错——
> 你只会在下次打开时发现少了一半。
>
> 关机命令需要密码（宇树机器狗默认 `123`，如果你改过就用改过的）。

**重启后要确认的三件事**（前两项 30 秒内自动完成）：

```bash
# 狗端（ssh 上去，登录时 ros:foxy(1) noetic(2) ? 输入 1）
date                                    # ① 时间对不对
/usr/local/bin/go2-clock status | tail -3   # ② 校时是否已生效

# PC 端
cd ~/FLMap.2 && ./scripts/link_probe.sh     # ③ 四层链路是否恢复
```

**时钟注意**：Orin 断电后没有电池保时，重启会回到镜像构建的日期。只要 PC 的
授时服务在跑，狗端 `go2-clock-pull.timer` 每 30 秒拉一次，**30 秒内自己就对了**。

但如果 **PC 也一起重启了**，顺序要反一下：

1. 先起 PC，跑 `./scripts/clock_sync.sh start`（它开机不自启）
2. 再给狗上电

否则狗会一直拉不到时间，`go2-clock status` 会显示"不可达"，而建图本身不会报错
——它用的是相对时间，只是 RViz 里的 TF 会和系统时间对不上。

**换新场景要清的只有两样，都不在磁盘上**：

| 东西 | 在哪 | 怎么清 |
|---|---|---|
| 累加后的地图 `/flmap/map` | PC 内存，不落盘 | 重启 `pc_view.sh` |
| LIO 的 ikd-Tree | 狗端内存 | 重启节点（`quit` 再进控制台） |

所以"从头扫一遍"= 两端重起，**不需要删任何文件**。旧的 bag / PCD 留在
`~/bags/` 里当历史，随时 `scp` 回来。

---

## 5. 实时体检：什么数值算正常

任何时候怀疑"跑歪了"，按这个顺序看，一级一级往下排。

先加载环境 —— **只有手动敲下面这些命令才需要**，`scripts/` 里的脚本内部已经配好了：

```bash
source /opt/ros/humble/setup.bash
export PATH="/usr/bin:$PATH"        # 有 conda/pyenv 时，保证 python3 带 rclpy/numpy
export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_LOCALHOST_ONLY=0
```

```bash
# ① 链路：脚本一次跑完 6 节（网络/时延/SSH/DDS/点云/带宽）
cd ~/FLMap.2 && ./scripts/link_probe.sh

# ② 狗端：驱动在不在、点云有没有、bridge 什么参数
ssh unitree@10.42.0.18 'pgrep -af "livox_ros|fastlio2|flmap_bridge"'

# ③ 话题：狗端本机 vs PC 端，两边频率是否一致
ros2 topic hz /flmap/cloud

# ④ 数据本身：数值分布对不对（不是"有没有数据"）
cd ~/FLMap.2 && python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1
```

④ 的正常长相（实测）：

```
[帧 0] 8812 点  step=16  row_step=140992  len=140992 OK
  x : min  -5.333  max  23.678 | =0  0.0%  =1.0  0.0%
  y : min -26.073  max   6.821 | =0  0.0%  =1.0  0.0%
  z : min  -0.742  max   6.883 | =0  0.0%  =1.0  0.0%
  i : min   0.000  max 190.000 | =0  9.5%  =1.0  7.5%   ← 强度有 0/1.0 属正常
  错位指纹 (y[i+1]==x[i] 且 z[i+1]==y[i]): 0.0%  (正常)
```

**三轴范围必须各不相同**。如果 `x/y/z` 三列的最小值一模一样，或出现大量 `=1.000`
的值，就是点云串位 —— 见 §6.4。

---

## 6. 症状速查

> 完整版在 [06-troubleshooting.md](06-troubleshooting.md)，这里只放现场最常撞的七种。

### 6.1 `ping` 不通 `10.42.0.18`

按「热点在不在 → 狗连上没有 → 地址对不对」三层查，每层一条命令：

```bash
# ① 热点起没起
ip -br addr show wlp132s0                    # 有没有 10.42.0.1/24？
iw dev wlp132s0 info | grep -E "type|channel"   # type 必须是 AP，channel 44

# ② 狗连上没有（AP 视角，看客户端数）
iw dev wlp132s0 station dump | grep -c "^Station"   # 0 = 狗没连上
```

- ① 没地址 / type 不是 AP → 热点没起来，重跑 `sudo ./scripts/pc_hotspot.sh`。
  如果它报 `supplicant-timeout`，是监管域没设成 `CN`（`iw reg get` 看 country），
  5 GHz 在 `country 00` 下全是 PASSIVE-SCAN，内核拒发 beacon。见
  [17-wireless-link.md](17-wireless-link.md)。
- ② 是 0 → 狗没连上。狗刚上电要等 20–40 秒；还不行就在狗上确认
  （要临时插一次网线，或看狗端串口）：

  ```bash
  iw dev wlan0 link            # not connected = 没连上
  nmcli -f NAME,STATE connection show | grep flmap-wifi
  ```

  断了就重连：`sudo nmcli connection up flmap-wifi`（狗端免密 sudo 已配好）。
- ① ② 都正常但 ping 不通 → 看是不是 DDS/路由层的假象，先跑
  `./scripts/link_probe.sh`，它会指出是丢包、还是回程没配。
- 热点重启过、狗还没重连上 → 别急着改配置，等 10 秒再 ping。这就是
  `lib_link.sh` 里 `flmap` 目标解析要「等狗重连」的原因。

### 6.2 狗端 `/cloud_registered` 没数据

```bash
tail -30 /tmp/flmap_edge/driver.log      # 找 "successfully set lidar attitude"
tail -30 /tmp/flmap_edge/mapping.log     # 找 "Raw feature num"
```

| 日志 | 含义 | 处置 |
|---|---|---|
| `successfully set lidar attitude, ip: 192.168.123.221` | 驱动正常 | 继续看 mapping.log |
| `failed to connect` / 一直重试 | 雷达没上电或 IP 不对 | **在狗上** `ping 192.168.123.221`（从 PC 不直连），见 [08](08-hardware.md) |
| 驱动正常但 mapping 没 `Raw feature num` | LIO 没收到点云 | `ros2 topic hz /livox/lidar`，检查 QoS 是否成对 |

### 6.3 有数据，但 RViz 一片空白

```bash
./scripts/link_probe.sh          # 先看第 4 节（DDS 发现）和第 5 节（点云流）
```

- 第 4 节（DDS 发现）就红 → 两边 `ROS_DOMAIN_ID` / `RMW_IMPLEMENTATION` 不一致。
  **别手动 export**，用脚本启动（脚本内部已固化 `42` + `cyclonedds`）。
- 第 5 节（点云流）红但第 4 节正常 → CycloneDDS 可能绑错网卡（多网卡机器常见）：

```bash
# 先按 §5 加载环境
ros2 daemon stop; ROS_LOCALHOST_ONLY=0 ros2 topic list | grep flmap
```

- 都正常 → RViz 的 Fixed Frame 是否为 `camera_init`？显示项的 Reliability 是否为
  `Reliable`（与发布端成对，BEST_EFFORT 订阅 RELIABLE 在 CycloneDDS 下**收不到**）。

### 6.4 点云"有数据但形状不对"

典型表现：点挤在原点一小片、像狗身轮廓；或 Z 轴范围到 ±20 m；或三轴最小值相同。

```bash
python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1
```

判定：

- `x/y/z` 任一项的 `=1.0` 占比 > 5% → **点云串位**，跑回归测试确认
  （强度列的 `=1.0` 是真实反射值，不算）。

```bash
./tools/diag/run_bridge_selftest.sh -n 5000     # 期望 5000/5000
```

回归不过 = `flmap_bridge` 被改回了迭代器写法。原因（`operator[]` 按
`sizeof(T)` 而不是 `point_step` 前进）见 [10-pitfalls.md](10-pitfalls.md)。

### 6.5 画面卡顿

```bash
# 狗端本机频率 vs PC 端频率，两个数一比就知道丢在哪
ssh unitree@10.42.0.18 'export ROS_DOMAIN_ID=42 RMW_IMPLEMENTATION=rmw_cyclonedds_cpp; \
  source ~/flmap3_ws/install/setup.bash; ros2 topic hz /flmap/cloud'
ros2 topic hz /flmap/cloud
```

| 狗端 | PC 端 | 结论 |
|---|---|---|
| 10 Hz | 10 Hz | 卡在 RViz 渲染 / PC 性能，不是链路 |
| 10 Hz | 6–8 Hz | 链路丢帧 → `link_probe.sh` 看丢包与协商速率 |
| 6 Hz | 6 Hz | 输入帧率就不够 → 看雷达 / CPU 温度（`status`） |

### 6.6 RViz 报 `Unable to create a suitable GLXContext`

跟仓库无关，是本机显卡驱动 / 远程桌面没有 GLX。绕开窗口：

```bash
./scripts/pc_view.sh --headless          # 只收数据
python3 tools/render_cloud.py -t /flmap/map -o /tmp/map.png --view both   # 先按 §5 加载环境
```

### 6.7 `stop` 后提示「PCD 导出失败」

```bash
ros2 bag info ~/bags/<时间>/scan       # 先看 /cloud_registered 的 Message count
```

| Message count | 含义 | 处置 |
|---|---|---|
| 几百上千 | bag 是好的，导出这一步坏了 | 看 `~/bags/<时间>/pcd_export.log` |
| 0，或没有这个 topic | 录制时 LIO 就没出图 | 回 §6.2 查雷达 / LIO |

bag 没坏就不用重扫，直接重导：

```bash
/usr/bin/python3 scripts/bag_to_pcd.py ~/bags/<时间> ~/bags/<时间>/map.pcd
```

> 老版本把这条一律写成「可能没数据」，其实最常见的原因是狗端 Foxy 没有
> `sensor_msgs_py`、脚本在 import 阶段就崩了，跟点云一点关系都没有。
> 详见 [06 §8.3](06-troubleshooting.md#83-stop--quit-之后-pcd-导出失败)。

---

## 7. 调参速查

改 `src/flmap_bridge/config/bridge_default.yaml`。狗端是 `--symlink-install` 编译的，
**只改 yaml 不用重编译**：

```bash
scp src/flmap_bridge/config/bridge_default.yaml \
    unitree@10.42.0.18:~/flmap3_ws/src/flmap_bridge/config/
```

然后在狗端控制台 `quit` 再重进。改了 C++ 代码才需要
`./scripts/deploy_edge.sh --no-patch`。

| 我想要 | 改什么 | 代价 |
|---|---|---|
| 更细的墙面 / 家具边缘 | `voxel_leaf: 0.10 → 0.05` | 带宽 ×3（约 35 Mbit/s），Orin CPU +15% |
| 更省 CPU / 更稳 | `voxel_leaf: 0.15` | 细节变糊，带宽降到 ~6 Mbit/s |
| 画面更连续 | `max_rate_hz: 10.0`（已是默认上限） | 再高没意义，输入只有 10 Hz |
| 只保留近处 | `range_max: 40 → 15` | 远处墙没了，带宽降一半 |
| 不要强度、只要几何 | `keep_intensity: false` | RViz 不能按反射率着色，省 25% |

PC 端累加密度：`./scripts/pc_view.sh voxel_leaf:=0.10`（默认 0.15，越小越细、越吃内存）。

> 千兆链路下**基本不需要为了带宽调参**（11.6 Mbit/s 只占 1.2%）。调参是为了
> 观感或 CPU，不是为了"塞得下"。

---

## 8. 完整命令卡（可整段复制）

```bash
# ---------- 首次 ----------
cd ~/FLMap.2
./setup.sh
./scripts/clock_sync.sh start
./scripts/clock_sync.sh install
./scripts/deploy_edge.sh

# ---------- 每次实验 ----------
# 终端 A
cd ~/FLMap.2 && ./scripts/clock_sync.sh start

# 终端 B
ssh unitree@10.42.0.18
cd ~/flmap3_ws && ./scripts/edge_control.sh
#   进去后：start

# 终端 C
cd ~/FLMap.2 && ./scripts/pc_view.sh

# ---------- 收工 ----------
# 终端 B：stop  →  quit
# 终端 C：Ctrl-C

# ---------- 出问题 ----------
# 先按 §5 的前三行加载 ROS 环境
cd ~/FLMap.2 && ./scripts/link_probe.sh
python3 tools/diag/cloud_stat.py -t /flmap/cloud -n 1
./tools/diag/run_bridge_selftest.sh -n 5000
```

---

## 附：本机路径

| 内容 | 路径 |
|---|---|
| 仓库（PC） | `/home/cj/FLMap.2` |
| 仓库（狗端副本） | `unitree@10.42.0.18:~/flmap3_ws` |
| 狗端运行日志 | `/tmp/flmap_edge/{driver,mapping,bridge}.log` |
| 狗端录包 | `~/bags/<时间戳>/scan/` |
| 授时服务日志 | `/tmp/go2_timeserver.log` |
| 累积地图渲染图 | `docs/images/cloud_pc_map.png` |
