# 18 · 本地操作教程（开机 → 建图 → 出图 → 导出）

> 适用：Go2 + Mid360 + FAST-LIO2，**无线**链路（PC 开热点，狗连上来）。
> 全程手动：什么时候开始录、什么时候停、中间要不要空一段，都由你在 `flmap>` 控制台里决定。
> 本文所有命令可直接复制，路径按当前机器的实际布局写。

---

## 0. 先记住：录制由你控制

一条任务 = PC 上 3 个窗口 + 狗端 1 个控制台。**开扫和停录都是你在 `flmap>` 里敲的**，
没有定时器、没有自动结束。狗上的节点从进控制台起就一直跑，录不录、录多久完全听你的。

```
窗口 A（PC）  开热点 → 体检，跑完就可以关
窗口 B（PC 上的 ssh）   flmap> 控制台，整场都开着   ← 你在这里控制录制
窗口 C（PC）  RViz，整场都开着
```

---

## 1. `flmap>` 命令表

进控制台后敲这几条，别敲到别的窗口：

| 命令 | 作用 |
|---|---|
| `start` | 建任务目录 + 开始录包（首次会问要不要体检） |
| `pause` | 暂停录包（节点继续跑，地图继续长） |
| `resume` | 继续录 |
| `stop` | 停止录包 + 自动导出 PCD |
| `status` | 进程 / 话题频率 / 温度 / 内存 |
| `stats` | bridge 压缩比与输出频率 |
| `link` | 链路体检（无线信号/速率 + 到 PC/雷达 RTT） |
| `quit` | 退出（会自动先 `stop`） |

`help` 随时再打一遍这张表（还会列出一条 `env`：手动跑 21 项环境体检）。
除此之外的词一律回「未知命令」——**看到这句就是敲错窗口了**。

`start` 和 `stop` 是唯一一对必须成对出现的命令；`pause`/`resume` 只是中间的空档，可以反复用。

---

## 2. 开机（顺序不能反）

热点必须**先**起来，狗才连得上。狗端 `wlan0` 已设开机自动连（连接名 `flmap-wifi`），
只要热点在，狗上电后 20 秒内自己接上。

### 2.1 PC 先开热点

```bash
cd ~/FLMap.2
sudo ./scripts/pc_hotspot.sh
```

成功的样子：

```
✓ 热点已启动（a / ch44）
wlp132s0   10.42.0.1/24
SSID       FLMap3
密码       flmap2026
```

> 热点**不会**开机自启（NM 里 `autoconnect no` 是故意设的）。每次开机都要手动跑这一条，
> 否则狗会一直找不到 `FLMap3` 在那儿重试。

### 2.2 给狗上电

开狗、等它起完（约 40 秒）。狗端 `wlan0` 自动连热点。

### 2.3 确认链路

```bash
cd ~/FLMap.2
./scripts/link_probe.sh
```

四段全绿才能开扫：

```
✔ 走无线口 wlp132s0（预期）
✔ 丢包 0%      RTT 1 ms 上下，抖动 < 1 ms
✔ 免密 ssh 可用
✔ PC → 狗 / 狗 → PC  ← DDS 两个方向都收到数据
```

抖动超过 5 ms 说明有同频干扰，点云会一顿一顿，先挪一下狗或换信道再开扫。

> 第 5 项「`/flmap/cloud` 无数据」在开扫前**必然是红的**，正常 —— 桥还没起来。

---

## 3. 进入控制台（窗口 B）

```bash
ssh -t unitree@10.42.0.18 'bash ~/flmap3_ws/scripts/edge_control.sh'
```

`-t` 不能省：控制台要读键盘，没有 TTY 的 ssh 会让 `read` 立刻拿到 EOF，控制台刚起来就退出。

> 路径写的是狗上**当前唯一装好脚本**的工作空间 `~/flmap3_ws`。两包代码逐字节一致，
> 无线包直接复用它，不必再编译一份。若你另外用 `./scripts/deploy_edge.sh` 部署过
> （会装到 `~/flmap_ws`），把路径换掉即可。不确定先跑：
> `ssh unitree@10.42.0.18 'ls -d ~/*_ws/*/scripts/edge_control.sh'`

连上后它先清理上次残留的驱动/建图/桥进程，然后显示：

```
========================================
 狗端建图控制台（可视化在 PC 端）
 命令: start / stop / status / stats / link / quit
========================================
flmap>
```

**看到 `flmap>` 就说明雷达驱动、FAST-LIO2、桥三个进程已经在跑了**（不用你敲命令）。
此时在 PC 上重跑 `link_probe.sh`，第 5 项会变绿。

---

## 4. `start`：开始录

```
start
```

先问一句体检：

```
扫描前是否做一次环境体检？(y/N)
[y/N]:
```

- **敲 `n`**（跳过，省 20 秒）。刚才 `link_probe.sh` 已经验过链路了。
- 换了硬件、改了配置、上次跑出过问题 → 敲 `y`，21 项检查逐条打出来。

然后：

```
录包中 → /home/unitree/bags/2026-10-21_11-21-02/scan/  (PID 16753)
```

**看到这一行才说明真在录了。** 若后面紧跟「录包进程已退出」，脚本会打 `record.log` 尾部，
照那个修，别硬往下走。

想换个场景重新录：直接再敲 `start` 会另建一个任务目录，旧的那份留在原地，
`stop` 时才导出，两个目录互不影响。

---

## 5. 录制过程中

### 5.1 想空一段（有人走过、要挪狗、等电梯）

```
pause      ← 暂停录包，节点继续跑
resume     ← 继续
```

`pause` 只是把录包进程挂起，**RViz 里的点云还是动的**，只是这一段不进 bag。
这比 `stop` 再 `start` 好在：不用重导 PCD、不会多出一个任务目录、位姿连续。

> 实测过：墙钟录 60 秒、中间 `pause` 8 秒，bag 的 `metadata.yaml` 里 `duration` 是
> 50.2 秒 —— 空档确实没进包，`resume` 之后时间戳也是连续的。

### 5.2 三条现场诊断命令

| 敲什么 | 什么时候用 | 正常值 |
|---|---|---|
| `status` | 怀疑某个进程死了 | 四个进程号都在，`/flmap/cloud` 有频率 |
| `stats` | 看桥的输出 | 约 `10.0 Hz`、`~10.9 Mbit/s` |
| `link` | 怀疑网络问题 | 信号 > −60 dBm、RTT < 2 ms |

`link` 是从**狗端视角**看的：无线口信号强度/协商速率，加一张到 PC 和到雷达的 RTT。
PC 端视角对应 `./scripts/link_probe.sh`，两边对一下就知道问题在哪一段。

### 5.3 边走边看画面

窗口 C 另开一个终端（**不是 `flmap>` 那个**）：

```bash
cd ~/FLMap.2
./scripts/pc_view.sh
```

它依次做：绑定网卡 → ping 一次狗 → 探测 `/flmap/cloud` → 启动累加器 + RViz。
启动前的两行自检很关键：

```
[ ok ] ping 通，平均 RTT 1.18 ms
[ ok ] 收到点云，当前帧 8501 点，约 10.1 Hz
```

第二行若是 `warn`，RViz 会一片空白，按它给的四条原因查（最常见：狗端还没 `start`）。

RViz 里看什么：

| 显示项 | 话题 | 含义 |
|---|---|---|
| `Cloud` | `/flmap/cloud` | **当前帧**，狗发什么就是什么，10 Hz，抽稀过的 |
| `Map` | `/flmap/map` | **累加图**，PC 端攒起来的完整点云，越走越大 |
| Fixed Frame | `camera_init` | 别改，改了报 "Fixed Frame does not exist" |

刚开扫时 `Map` 是空的，走两步就出来。判断建图好坏看两件事：**墙面是不是双层重影**（位姿飘了）、
**回环处有没有错位**（累积误差）。这是 FAST-LIO2 的固有特性，不是链路问题。

```bash
./scripts/pc_view.sh --raw        # 只看当前帧、不攒图（省 CPU）
./scripts/pc_view.sh --headless   # 不开窗口，只收数据
```

### 5.4 RViz 起不来：满屏 `Unable to create a suitable GLXContext`

看着像"链路断了"，其实 ROS 侧一切正常（`link_probe` 全绿、累加器在发点云）。判据是设备节点：

```bash
ls /dev/dri /dev/nvidia0      # 两个都不存在 → 硬件 GL 一定失败
```

`pc_view.sh` 会自动检测并切 mesa 软件渲染：

```
[warn] 没有 GPU 设备节点（/dev/dri、/dev/nvidia0）→ RViz 切软件渲染（能看，帧率低）
```

实测能正常出图（`OpenGl version: 4.5 (GLSL 4.5)`），只是帧率低。

> 只设 `LIBGL_ALWAYS_SOFTWARE=1` **不够**，必须同时设 `__GLX_VENDOR_LIBRARY_NAME=mesa`，
> 否则 GLVND 还是去调 nvidia 的 GLX，继续报同样的错。强制关掉自动切换：`FLMAP_SOFT_GL=0`。

画面长什么样：`docs/images/rviz-live-cloud.png`。

---

## 6. `stop`：停录并导出 PCD

走完了就停：

```
stop
```

它做三件事：停录包 → 给 bag 补尾部元数据 → **跑 PCD 导出**。

导出 800 帧大约 1–3 分钟，期间终端不动是正常的。成功时：

```
PCD 已导出: /home/unitree/bags/2026-10-21_11-21-02/map.pcd
```

`stop` 之后节点还在跑（雷达还转），所以此时 **`link`/`status` 照样能用，也还能再 `start` 一次**。

### 6.1 导出失败怎么办

它会打出真实原因（不再是含糊的「可能没数据」）。**bag 本体是好的，修好后直接重导，不用重扫**：

```bash
ssh unitree@10.42.0.18
source /opt/ros/foxy/setup.bash
/usr/bin/python3 ~/flmap3_ws/scripts/bag_to_pcd.py \
    ~/bags/2026-10-21_11-21-02 ~/bags/2026-10-21_11-21-02/map.pcd
```

（`source` 不能省，否则缺 `rclpy`。）

---

## 7. `quit`：退干净

```
quit
```

`quit` 会先自动补一次 `stop`（如果还没停），然后关掉驱动、建图、桥三个进程，退回 `unitree@ubuntu:~$`。

> **`stop` ≠ 退出。** `stop` 只停录包，节点还在跑。
> 只敲 `stop` 就关终端，节点会变成孤儿进程留在狗上，下次 `start` 会有两个雷达驱动同时发
> `/livox/lidar`，频率翻倍、点云交替跳变。

ssh 断了、控制台找不回来时兜底：

```bash
ssh unitree@10.42.0.18 'pkill -f fastlio2_mapping; pkill -f flmap_bridge_node; pkill -f livox_ros_driver2_node'
```

---

## 8. 把 bag 和 PCD 导到主机

任务目录名 `stop` 时打印过，也可以查最新的：

```bash
ssh unitree@10.42.0.18 'ls -t ~/bags | head -3'
TS=2026-10-21_11-21-02      # ← 换成你自己的
```

```bash
# 整体拷回（推荐）：scan/ + map.pcd + info.txt + 两个日志
mkdir -p ~/Desktop/FLMap
scp -r unitree@10.42.0.18:~/bags/$TS ~/Desktop/FLMap/

# 只要 PCD
scp unitree@10.42.0.18:~/bags/$TS/map.pcd ~/Desktop/

# 只要 bag（自己回家用 FAST-LIO2 重跑）
scp -r unitree@10.42.0.18:~/bags/$TS/scan ~/Desktop/
```

| 内容 | 大小 | 无线耗时（约 100 Mbit/s） |
|---|---|---|
| `map.pcd` | 190 MB | 约 20 秒 |
| `scan/` | 900 MB | 约 90 秒 |
| 整个任务目录 | 1.1 GB | 约 2 分钟 |

传输时**别在 RViz 里开新任务**，带宽被抢两边都慢。

### 8.1 不开 RViz 也先看一眼

```bash
python3 scripts/pcd_preview.py ~/Desktop/FLMap/2026-10-21_11-21-02/map.pcd
# → 同目录生成 map_xy.png / map_xz.png
```

俯视图上能看出墙和走廊就说明数据是通的（示例 `docs/images/pcd-preview-xy.png`）。
`--info` 只打统计不画图：点数、XYZ 范围、强度区间。

---

## 9. 关机顺序

**先停采集，再断链路，最后断电**。反了会留下半截 bag（`metadata.yaml` 没写完，得手工抢救）。

```bash
# 1) 在 flmap> 里停干净
stop          # 等 "PCD 已导出"
quit

# 2) 关热点（PC）
sudo ./scripts/pc_hotspot.sh --down

# 3) 关狗：按狗身电源键正常关机，等指示灯全灭
# 4) 关 PC
```

狗还在写 `scan.db3` 时断 WiFi，rosbag2 的收尾会失败；热点先关，狗会反复重连白耗电。
反例见 `docs/13-shutdown.md`。

---

## 10. 一页速查

```bash
# ——— 开机（每次）———
cd ~/FLMap.2
sudo ./scripts/pc_hotspot.sh          # ① 先开热点
# ② 给狗上电，等 40 秒
./scripts/link_probe.sh               # ③ 四段全绿再往下

# ——— 进控制台（窗口 B）———
ssh -t unitree@10.42.0.18 'bash ~/flmap3_ws/scripts/edge_control.sh'

# ——— 看画面（窗口 C，另开终端）———
cd ~/FLMap.2 && ./scripts/pc_view.sh

# ——— 在 flmap> 里按你的节奏操作 ———
#   start          开始录（体检问 y/N，一般 n）
#   status/stats   看进程、看桥频率
#   link           无线信号 + RTT
#   pause/resume   空一段再继续
#   stop           停录 + 导出 PCD（等 "PCD 已导出"）
#   quit           退干净（会先自动 stop）

# ——— 导出 ———
TS=$(ssh unitree@10.42.0.18 'ls -t ~/bags | head -1')
mkdir -p ~/Desktop/FLMap
scp -r unitree@10.42.0.18:~/bags/$TS ~/Desktop/FLMap/

# ——— 关机 ———
sudo ./scripts/pc_hotspot.sh --down
```

---

## 11. 出问题先看这张表

| 现象 | 最可能的原因 | 一句话处置 |
|---|---|---|
| `flmap>` 一直不出来 | ssh 少了 `-t`，或狗端工作空间路径不对 | 加 `-t`；`ssh unitree@10.42.0.18 'ls -d ~/*_ws/*/scripts/edge_control.sh'` |
| 控制台报未知命令 | 敲错窗口了 | 看提示符是不是 `flmap>`；`help` 看合法命令 |
| `start` 后没出现「录包中」 | 录包进程起不来，磁盘满 | 看它打的 `record.log` 尾部；`ssh … 'df -h /home'` |
| RViz 一片空白 | 狗端没 `start`，或 DDS 绑错网卡 | `status` 看进程；`link_probe` 第 4 项 |
| RViz 报 `GLXContext` | 没有 GPU 设备节点 | `ls /dev/dri /dev/nvidia0`；`pc_view.sh` 会自动切软渲染 |
| 点云一顿一顿 | 无线抖动大 / 网卡省电开着 | `link_probe` 看抖动；狗上 `iw dev wlan0 get power_save` 应为 off |
| `scp` 传到一半断了 | 无线抖动 / 休眠 | 用 §12 的 `edge_scan.sh` 重跑（rsync 续传），别删目标目录 |
| `stop` 后没生成 PCD | 导出脚本报错（bag 通常没问题） | 按 §6.1 单独重导，别重扫 |
| 关终端后狗还在转 | 只 `stop` 没 `quit` | 用 §7 末尾的 `pkill` 兜底 |

更多分层排查：`docs/06-troubleshooting.md`；无线专项：`docs/17-wireless-link.md`；原理通俗版：`docs/12-handbook.md`。

---

## 12. 附录：想让它自己跑（可选，不影响手动流程）

日常用不上。两种情况才看这节：写自动化验收，或者人在外面遥控跑一趟。

**`--auto N`** —— 不读键盘，起节点 → 录 N 秒 → `stop`/导 PCD → 退出，末尾打印 `TASK_DIR=`：

```bash
ssh unitree@10.42.0.18 'bash ~/flmap3_ws/scripts/edge_control.sh --auto 300'
```

**`edge_scan.sh`** —— PC 端一条命令串起来（扫描 → 导出 → rsync 续传 → 校验点数和大小）：

```bash
./scripts/edge_scan.sh --secs 120            # 顺便拉起 RViz
./scripts/edge_scan.sh --secs 120 --no-view  # 只看结果
```

> **别用「ssh + 管道喂 start/stop」代替这两条**。交互控制台靠 stdin 读命令，管道送完就 EOF，
> `read` 拿到 EOF 立刻 `do_quit`，把正在跑的建图关掉；靠 `sleep` 卡时序又会跟节点启动速度赛跑
> （抢跑被当成"未知命令"，晚到被体检问答 `read` 吃掉）。`--auto` 就是为这个加的。
