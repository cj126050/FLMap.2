# 18 · 本地操作教程（开机 → 建图 → 出图 → 导出）

> 适用：Go2 + Mid360 + FAST-LIO2，**无线**链路（PC 开热点，狗连上来）。
> 一次完整任务 = 主机 3 个窗口 + 狗端 1 个控制台。
> 本文所有命令都是可直接复制执行的，路径按你机器上现有布局写死。

---

## 0. 两种用法，先选一个

**A. 一条命令跑完（先跑这个，10 分钟拿到 PCD）**

```bash
cd ~/FLMap.3
sudo ./scripts/pc_hotspot.sh        # ① 开热点（每次开机都要跑一次）
./scripts/link_probe.sh             # ② 四段全绿再往下
./scripts/edge_scan.sh --secs 120   # ③ 扫 120 秒 → 自动停录/导 PCD → 拉回主机
```

`edge_scan.sh` 会顺手把 RViz 拉起来（不想开就加 `--no-view`），结束时打印：

```
[ ok ] 2026-10-21_12-04-52/map.pcd  176M
[ ok ] PCD 点数 11520582（≈11.5 M）
[ ok ] PCD 大小与远端一致（184329506 B）
[ ok ] 全链路完成：/home/cj/Desktop/FLMap/2026-10-21_12-04-52/
```

它内部是：`ssh` 到狗端跑 `edge_control.sh --auto N` → 抓任务目录 → `rsync` 续传 → 校验点数与大小。
**断了直接重跑同一条命令**，rsync 会续上，不会从头再来。

**B. 手动三个窗口**（要边走边看、要 `pause`/`resume` 时用）—— 就是下面 §2 开始的内容。

---

## 1. 先认清：总共三个窗口，各管一件事

| 窗口 | 在哪台机器 | 干什么 | 生命周期 |
|---|---|---|---|
| **A 热点 / 体检** | PC | 开热点、跑链路体检，跑完就可以关 | 1 分钟 |
| **B 控制台** | PC 上的 ssh 会话（**实际在狗上执行**） | `start` / `stop` / `quit`，控制雷达与建图 | 整个任务期间保持开着 |
| **C RViz** | PC | 看实时点云与累加地图 | 整个任务期间保持开着 |

**最常见的一类操作失误**：把 `start` 敲在 RViz 那个窗口里，或者把 `./scripts/pc_view.sh` 敲进了狗端控制台。

判断自己在哪台机器上，看提示符：

```
cj@cj-System-Product-Name:~/FLMap.3$     ← 本机（PC）
unitree@ubuntu:~$                        ← 已经 ssh 进狗了
flmap>                                   ← 狗端建图控制台（只认 start/stop/status/stats/link/quit）
```

`flmap>` 下面除了那 8 个词，敲别的都只会回一句「未知命令」。

---

## 2. 开机（顺序不能反）

热点必须**先**起来，狗才连得上。狗端 `wlan0` 已经设了开机自动连（连接名 `flmap-wifi`），所以只要热点在，狗上电后 20 秒内自己就接上了。

### 2.1 PC 先开热点

```bash
cd ~/FLMap.3
sudo ./scripts/pc_hotspot.sh
```

成功的样子：

```
✓ 热点已启动（a / ch44）
wlp132s0   10.42.0.1/24
SSID       FLMap3
密码       flmap2026
```

> 热点不会开机自启（NM 里 `autoconnect no` 是故意设的）。**每次开机都要手动跑这一条**，
> 否则狗会一直找不到 `FLMap3` 而在那儿重试。

### 2.2 给狗上电

开狗、等它起完（约 40 秒）。狗端 `wlan0` 会自动连热点。

### 2.3 确认链路（窗口 A 的第二条命令）

```bash
cd ~/FLMap.3
./scripts/link_probe.sh
```

四段全绿才算可以开扫：

```
✔ 走无线口 wlp132s0（预期）
✔ 丢包正常          ← 应该 0%
✔ 免密 ssh 可用
✔ PC → 狗 / 狗 → PC  ← DDS 两个方向都要收到数据
```

重点看两处数字：**丢包必须是 0%**，**RTT 应该在 1 ms 上下、抖动 < 1 ms**。抖动超过 5 ms 说明有同频干扰，点云会一顿一顿。

> `link_probe` 里第 5 项「/flmap/cloud 无数据」在开扫前**必然是红的**，那是正常的 —— 桥还没起来。

---

## 3. 进入控制台（窗口 B）

```bash
ssh -t unitree@10.42.0.18 'bash ~/flmap_ws/scripts/edge_control.sh'
```

`-t` 不能省：控制台要读键盘输入，没有 TTY 的 ssh 会让 `read` 立刻拿到 EOF，控制台起不来就退出。

连上后它会自动做一遍清理（把上次残留的驱动/建图/桥进程杀掉），然后显示：

```
========================================
 狗端建图控制台（可视化在 PC 端）
 命令: start / stop / status / stats / link / quit
========================================
flmap>
```

**看到 `flmap>` 就说明雷达驱动、FAST-LIO2、桥三个进程已经在跑了**（这一步不用你敲命令）。此时在 PC 上跑 `link_probe.sh`，第 5 项就会变成绿的。

---

## 4. 开始扫描

在 `flmap>` 后面敲：

```
start
```

它会先问一句体检：

```
扫描前是否做一次环境体检？(y/N)
[y/N]:
```

- **先敲 `n`**（跳过，省 20 秒）。刚才 `link_probe.sh` 已经验过链路了。
- 换了硬件、改了配置、或者上次跑出问题 → 敲 `y`，21 项检查会逐条打出来。

然后：

```
录包中 → /home/unitree/bags/2026-10-21_11-21-02/scan/  (PID 16753)
```

**看到这一行才说明真在录了。** 如果这句后面跟着「录包进程已退出」，脚本会把 `record.log` 的尾部打出来，照那个修，别硬着头皮往下走。

### 录制过程中的三条辅助命令

| 敲什么 | 什么时候用 |
|---|---|
| `status` | 怀疑某个进程死了，看四个进程号 + 话题 |
| `stats` | 看桥的输出频率与压缩比（正常约 `10.0 Hz`、`~10.9 Mbit/s`） |
| `link` | 狗端视角测到 PC / 雷达的 RTT，判断是不是网络问题 |

想让点云中间停一段（比如有人走过、或者你想挪一下狗），用：

```
pause      ← 暂停录包，节点继续跑
resume     ← 继续
```

`pause` 只是把录包进程挂起，**点云在 RViz 里还是动的**，只是这一段不会进 bag。

### 4.1 无人值守：`--auto N`

不想敲 `start`/`stop`、或者要写脚本定时跑，用这条（**不读键盘**，所以可以直接被 ssh 调用）：

```bash
ssh unitree@10.42.0.18 'bash ~/flmap_ws/scripts/edge_control.sh --auto 300'
```

它依次做：起驱动/LIO/桥 → 录 300 秒 → `stop`（停录 + 导 PCD）→ 关节 → 退出，
最后一行打印 `TASK_DIR=/home/unitree/bags/2026-10-21_11-54-52`，PC 端拿它去 `scp`/`rsync`。

> **不要用「ssh + 管道喂 start/stop」**。交互控制台靠 stdin 读命令，管道送完就 EOF，
> `read` 拿到 EOF 立刻 `do_quit`，把正在跑的建图关掉；靠 `sleep` 卡时序又会跟节点启动
> 速度赛跑（抢跑被当成"未知命令"，晚到被体检问答 `read` 吃掉）。`--auto` 就是为这个加的。

---

## 5. RViz 可视化（窗口 C，另开一个终端）

**在 PC 上另开一个终端**（不是 `flmap>` 那个），执行：

```bash
cd ~/FLMap.3
./scripts/pc_view.sh
```

它会依次做：绑定网卡（多网卡机器上必须做，否则 CycloneDDS 可能挑中手机那块网卡）→ ping 一次狗 → 探测 `/flmap/cloud` → 启动累加器 + RViz。

启动前的自检会打出这两行，**都很关键**：

```
[ ok ] ping 通，平均 RTT 1.18 ms
[ ok ] 收到点云，当前帧 8501 点，约 10.1 Hz
```

如果第二行是 `warn`，RViz 会是一片空白，按它给出的四条原因查（最常见的是狗端还没 `start`）。

### RViz 里看什么

| 显示项 | 话题 | 含义 |
|---|---|---|
| `Cloud` | `/flmap/cloud` | **当前帧**。狗发什么就是什么，10 Hz，抽稀过的 |
| `Map` | `/flmap/map` | **累加图**。PC 端攒起来的完整点云，越走越大 |
| Fixed Frame | `camera_init` | 别改。改了会报 "Fixed Frame does not exist" |

刚开扫时 `Map` 是空的，走两步就出来了。判断建图好坏看两件事：**墙面是不是双层重影**（位姿飘了）、**回环处有没有错位**（累积误差）。这两点是 FAST-LIO2 的固有特性，不是链路问题。

```bash
# 只想看当前帧、不攒图（省 CPU）
./scripts/pc_view.sh --raw

# 不开 RViz 窗口，只收数据（换别的工具看，或只做本地留存）
./scripts/pc_view.sh --headless
```

### RViz 起不来：满屏 `Unable to create a suitable GLXContext`

看着像"链路断了"，其实 ROS 侧一切正常（`link_probe` 全绿、累加器在发点云）。判据是设备节点：

```bash
ls /dev/dri /dev/nvidia0      # 两个都不存在 → 硬件 GL 一定失败
```

`pc_view.sh` 会自动检测并切 mesa 软件渲染，日志里会出现：

```
[warn] 没有 GPU 设备节点（/dev/dri、/dev/nvidia0）→ RViz 切软件渲染（能看，帧率低）
```

实测软件渲染能正常出图（`OpenGl version: 4.5 (GLSL 4.5)`），只是帧率低。

> 只设 `LIBGL_ALWAYS_SOFTWARE=1` **不够**，必须同时设 `__GLX_VENDOR_LIBRARY_NAME=mesa`，
> 否则 GLVND 还是去调 nvidia 的 GLX，继续报同样的错。想强制关掉自动切换：`FLMAP_SOFT_GL=0`。

画面长什么样：`docs/images/rviz-live-cloud.png`（这次实跑截的）。

---

## 6. 结束扫描

**顺序很重要，别急着关窗口。**

### 6.1 先 `stop`（在 `flmap>` 里）

```
stop
```

它做三件事：停录包 → 给 bag 补尾部元数据 → **跑 PCD 导出**。

导出 800 帧大约要 1–3 分钟，期间终端不动是正常的。成功时你会看到：

```
PCD 已导出: /home/unitree/bags/2026-10-21_11-21-02/map.pcd
```

### 6.2 如果导出失败

它会打出真实原因（不会再是含糊的「可能没数据」）。**bag 本体是好的，修好后直接重导，不用重扫**：

```bash
# 在狗上执行（先 source ROS，否则缺 rclpy）
ssh unitree@10.42.0.18
source /opt/ros/foxy/setup.bash
/usr/bin/python3 ~/flmap_ws/scripts/bag_to_pcd.py \
    ~/bags/2026-10-21_11-21-02 ~/bags/2026-10-21_11-21-02/map.pcd
```

### 6.3 再 `quit`

```
quit
```

`quit` 会先自动补一次 `stop`（如果还没停），然后关掉驱动、建图、桥三个进程，退回 `unitree@ubuntu:~$`。

> **`stop` ≠ 退出。** `stop` 只停录包，节点还在跑（雷达还在转）。
> 只敲 `stop` 就关终端，节点会变成孤儿进程留在狗上，下次 `start` 会出现两个雷达驱动同时发 `/livox/lidar`，频率翻倍、点云交替跳变。

如果 ssh 断了、控制台找不回来，用这条兜底：

```bash
ssh unitree@10.42.0.18 'pkill -f fastlio2_mapping; pkill -f flmap_bridge_node; pkill -f livox_ros_driver2_node'
```

---

## 7. 把 bag 和 PCD 导到主机

拿到刚才的任务目录名（`stop` 时打印过，也可以查最新的）：

```bash
ssh unitree@10.42.0.18 'ls -t ~/bags | head -3'
```

设成变量，后面就不用反复敲：

```bash
TS=2026-10-21_11-21-02      # ← 换成你自己的
```

### 7.1 整体拷回来（推荐）

```bash
mkdir -p ~/Desktop/FLMap
scp -r unitree@10.42.0.18:~/bags/$TS ~/Desktop/FLMap/
```

一个目录带走全部：`scan/`（bag 本体）、`map.pcd`、`info.txt`、`record.log`、`pcd_export.log`。

### 7.2 只想要 PCD

```bash
scp unitree@10.42.0.18:~/bags/$TS/map.pcd ~/Desktop/
```

### 7.3 只要 bag（自己回家用 FAST-LIO2 重跑）

```bash
scp -r unitree@10.42.0.18:~/bags/$TS/scan ~/Desktop/
```

### 传输时间参考

| 内容 | 大小 | 无线耗时（约 100 Mbit/s） |
|---|---|---|
| `map.pcd` | 190 MB | 约 20 秒 |
| `scan/` | 900 MB | 约 90 秒 |
| 整个任务目录 | 1.1 GB | 约 2 分钟 |

传输时**别在 RViz 里开新任务**，否则带宽被抢，两边都慢。看进度就用 `scp` 自带的那条进度条，或者加 `-v`。

### 7.4 不开 RViz 也看一眼（没 GPU、或者手边没图形界面时最省事）

```bash
python3 scripts/pcd_preview.py ~/Desktop/FLMap/2026-10-21_12-04-52/map.pcd
# → 同目录生成 map_xy.png / map_xz.png
```

俯视图上能看出墙和走廊就说明数据是通的（示例 `docs/images/pcd-preview-xy.png`）。
`--info` 只打统计不画图：点数、XYZ 范围、强度区间 —— 拿到 PCD 第一件事建议先跑这个，
比开 RViz 快，也不用等显卡。

---

## 8. 关机顺序

**先停采集，再断链路，最后断电**。反了会留下半截 bag（`metadata.yaml` 没写完，得手工抢救）。

```bash
# 1) 在 flmap> 里停干净
stop
# 等 "PCD 已导出"
quit

# 2) 关热点（PC，窗口 A）
sudo ./scripts/pc_hotspot.sh --down

# 3) 关狗：按狗身电源键正常关机，等指示灯全灭

# 4) 关 PC
```

顺序的理由：狗还在写 `scan.db3` 的时候断 WiFi，rosbag2 的收尾会失败；热点先关掉，狗会反复重连、白耗电。完整反例见 `docs/13-shutdown.md`。

---

## 9. 一页速查

```bash
# ——— 最快路径：一条命令 ———
cd ~/FLMap.3
sudo ./scripts/pc_hotspot.sh          # ① 开热点
./scripts/link_probe.sh               # ② 四段全绿
./scripts/edge_scan.sh --secs 120     # ③ 扫 120s → 导 PCD → 拉回 ~/Desktop/FLMap

# ——— 开机 ———
cd ~/FLMap.3
sudo ./scripts/pc_hotspot.sh          # ① 先开热点（每次开机必跑）
# ② 给狗上电，等 40 秒
./scripts/link_probe.sh               # ③ 四段全绿再往下

# ——— 进控制台（窗口 B）———
ssh -t unitree@10.42.0.18 'bash ~/flmap_ws/scripts/edge_control.sh'

#   flmap> start       开始扫描（体检问 y/N，一般 n）
#   flmap> status      看进程
#   flmap> stats       看桥频率/带宽
#   flmap> pause       暂停录包
#   flmap> resume      继续
#   flmap> stop        停止录包 + 导出 PCD（等它打印"PCD 已导出"）
#   flmap> quit        退干净（会先自动 stop）

# ——— 看画面（窗口 C，另开终端）———
cd ~/FLMap.3 && ./scripts/pc_view.sh

# ——— 导出 ———
TS=$(ssh unitree@10.42.0.18 'ls -t ~/bags | head -1')
mkdir -p ~/Desktop/FLMap
scp -r unitree@10.42.0.18:~/bags/$TS ~/Desktop/FLMap/

# ——— 关机 ———
sudo ./scripts/pc_hotspot.sh --down
```

---

## 10. 出问题先看这张表

| 现象 | 最可能的原因 | 一句话处置 |
|---|---|---|
| `flmap>` 一直不出来 | ssh 少了 `-t`，或狗端仓库没编译 | 加 `-t`；狗上跑 `ls ~/flmap_ws/install/setup.bash` |
| 控制台报未知命令 | 敲错窗口了 | 看提示符是不是 `flmap>`；`help` 看合法命令 |
| RViz 一片空白 | 狗端没 `start`，或 DDS 绑错网卡 | `status` 看进程；`link_probe` 第 4 项 |
| RViz 报 `GLXContext` / 窗口不出来 | 没有 GPU 设备节点 | `ls /dev/dri /dev/nvidia0`；`pc_view.sh` 会自动切软件渲染，也可 `FLMAP_SOFT_GL=1` |
| `scp` 传到一半断了 | 无线抖动 / 休眠 | 改用 `./scripts/edge_scan.sh` 重跑（rsync 续传），别删目标目录 |
| 点云一顿一顿 | 无线抖动大 / 功率省电开了 | `link_probe` 看抖动；`iw dev wlan0 get power_save` 应为 off |
| `stop` 后没生成 PCD | 导出脚本报错（bag 通常没问题） | 按 §6.2 单独重导，别重扫 |
| 关终端后狗还在转 | 只 `stop` 没 `quit` | 用 §6.3 末尾的 `pkill` 兜底 |

更多分层排查：`docs/06-troubleshooting.md`；无线专项：`docs/17-wireless-link.md`；通俗版原理：`docs/12-handbook.md`。
