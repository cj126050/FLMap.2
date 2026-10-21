# 关机与断连教程

> 面向现场操作。每一步都写清「敲什么」「看到什么算对」「不对怎么办」。
> 完整命令卡见 [11-runbook.md](11-runbook.md)，新手上手见 [12-handbook.md](12-handbook.md)。

---

## 0. 先记住：数据分别在谁身上

关机顺序之所以不能随便，是因为**三份东西存在三个不同的地方，消失的时机也不同**：

| 数据 | 存在哪 | 什么时候消失 |
|---|---|---|
| `scan/scan_0.db3` 录像 | **狗的硬盘**（正在实时写入） | 不会自己消失，但断电时可能写坏 |
| `map.pcd` 地图 | 狗的硬盘 | 只有 `stop` 时才生成 |
| ikd-Tree 建图结果 | **狗的内存** | `quit` 或断电即消失 |
| `/flmap/map` 累积点云 | **PC 的内存** | 关掉 `pc_view` / 关 PC 即消失 |

所以顺序的底层逻辑只有一条：

> **先让狗把硬盘上的东西收尾（`stop`），再关狗，最后关 PC。**

反过来做，丢的一定是内存里的那份，坏的可能是硬盘上的那份。

---

## 1. 先选场景

| 场景 | 想要什么 | 走哪一节 |
|---|---|---|
| A. 正常收工 | 要地图、要录像 | §2 标准流程 |
| B. 快速收工 | 不要这次数据，赶时间 | §2 跳过 `stop`，直接 `quit` |
| C. 突然要断电 | 来不及操作（要搬机器、有人催） | §4 断连后怎么救 |

---

## 2. 标准流程（6 步，约 40 秒）

三个窗口的位置见 [12-handbook.md](12-handbook.md) §4：**A = 对表 / B = 开狗 / C = 看图**。

### 第 1 步：窗口 B 敲 `stop` —— 存地图

```
flmap> stop
```

**看到什么算对**（约 3–10 秒，取决于点数）：

```
PCD 已导出: /home/unitree/bags/2026-10-19_14-46-30/map.pcd
total 38M
-rw-rw-r-- 1 unitree unitree  38M Oct 19 14:46 map.pcd
-rw-rw-r-- 1 unitree unitree 357 Oct 19 14:46 pcd_export.log
drwxrwxr-x 2 unitree unitree 4.0K Oct 19 14:46 scan
```

**不对怎么办**：
- 提示 `没有在录` → 你之前已经 `stop` 过，或者根本没 `start`，直接下一步。
- 提示 `PCD 导出失败，原因：…` → **别重扫**，bag 还在。看 `pcd_export.log` 最后几行，
  处置见 [06-troubleshooting.md §8.3](06-troubleshooting.md)。

> 这一步必须在**断网之前**做。`stop` 本身在狗本地完成，不依赖网络；但你需要通过
> ssh 敲它 —— 网断了你就敲不了了。

### 第 2 步：窗口 B 敲 `quit` —— 关节点

```
flmap> quit
```

会依次停掉 bridge → LIO → 雷达驱动，屏幕上滚过三行 `Killed`：

```
./scripts/edge_control.sh: line 74: 8045 Killed  ros2 launch livox_ros_driver2 ...
./scripts/edge_control.sh: line 74: 8075 Killed  ros2 launch go2_fastlio ...
./scripts/edge_control.sh: line 74: 8094 Killed  ros2 run flmap_bridge ...
已退出
unitree@ubuntu:~/flmap3_ws$
```

**`Killed` 不是错误**，是脚本在停进程，正常现象。看到提示符回到
`unitree@ubuntu:~/flmap3_ws$` 就对了。

> 如果这时 `stop` 还没做，`quit` 会**自动先 `stop`** 再关节点。所以赶时间的话，
> 直接 `quit` 也算保住了地图。

### 第 3 步：窗口 C 按 `Ctrl-C` —— 停看图

看到 `^C` 和提示符回来即可。这一步丢掉的是 PC 内存里累积的 `/flmap/map`，
**不影响狗上的 `map.pcd`**。

### 第 4 步：窗口 A 停授时服务

```bash
./scripts/clock_sync.sh stop
```

或者直接在该窗口按 `Ctrl-C`。看到 `已停止` 之类的提示即可。

> 忘了停也没关系，PC 关机时它自然结束。它只是个 HTTP 服务，没有写盘。

### 第 5 步：狗端刷盘 + 关机

还在 ssh 里（第 2 步之后那个 `unitree@ubuntu` 提示符）：

```bash
sync                # 把缓存刷进硬盘，约 1 秒，不给 sudo 也能跑
sudo poweroff       # 密码 123（宇树默认）
```

**看到什么算对**：ssh 会自己断开，显示 `Connection to 192.168.123.18 closed by remote host.`，
狗身上风扇停转、指示灯全灭，约 **15–20 秒**。

> **`sync` 不能省。** `poweroff` 虽然也会刷盘，但录像刚写完的那几百 MB 还在页缓存里，
> 给内核一个明确的落盘点，代价 1 秒，能避免"上次的 bag 打不开"。

### 第 6 步：关电池开关，最后才是拔线

1. 等狗完全断电（风扇停）后，**关电池上的电源开关**；
2. 然后才拔网线、关交换机、关 PC。

**顺序的意义**：先关电池开关，狗下次上电时是干净的冷启动；如果长期只拔网线不断电池，
狗会一直待机耗电，也可能因为电量耗尽而异常掉电。

---

## 3. 为什么不能乱序（四个反例）

| 错误做法 | 会发生什么 | 代价 |
|---|---|---|
| 先拔网线 / 关交换机 | 狗还在跑，bag 继续写，但你失去所有监控；PC 累积图断流 | 数据不丢，但你在"盲开"，且会以为已经停了 |
| 先关 PC | DDS 断开，狗端 bridge 持续报错；`/flmap/map` 直接没了 | 累积点云丢失，需要重扫才能再看 |
| 不 `quit` 直接 `sudo poweroff` | rosbag2 被强杀，`metadata.yaml` 可能没写出来 | bag 变"半截"，多数能抢救（§5.3），少数真损坏 |
| 不 `poweroff` 直接关电池开关 | 文件系统处于脏状态，最坏损坏系统分区 | 需要重刷系统镜像 |

一句话：**`stop` 保地图，`quit` 保文件系统，`sync` 保录像。**

---

## 4. 关机途中断连了，会怎样

有两种"断连"，处理方式完全不同。

### 4.1 网络断了，但狗还在跑

典型：拔了网线、交换机掉电、PC 先关了。

- 狗端 FAST-LIO2 **继续建图**，bag **继续写**，`map.pcd` 还没生成；
- PC 端 `/flmap/map` 停止累积；
- 你无法再通过 ssh 操作。

**恢复**（网络回来后）：

```bash
ssh unitree@192.168.123.18     # 输 1
cd ~/flmap3_ws && ./scripts/edge_control.sh
# 出现 flmap> 后，脚本会自动检测并清理上次残留的节点
flmap> status
flmap> stop        # 把断连期间录的内容也存下来
flmap> quit
```

> `start` 时会打印「发现残留节点，已清理」之类的提示，这是脚本的兜底逻辑，不是故障。

### 4.2 直接断电（关电池开关 / 电量耗尽）

风险按顺序：

1. **正在写的 `scan_0.db3`** 可能缺尾部数据（sqlite 有 WAL，多数情况可读）；
2. **`map.pcd` 正在生成** → 文件不完整，删掉重导即可；
3. **文件系统**脏 → 下次开机可能触发 fsck，通常自动修复；
4. 极小概率：系统分区损坏，需要重刷。

**上电后按这个顺序检查**（不要急着重新扫）：

```bash
ssh unitree@192.168.123.18        # 输 1
ls -lh ~/bags/ | tail              # 看最新目录还在不在
ls -lh ~/bags/<最新>/scan/         # scan_0.db3 是不是 0 字节
```

- 有 `scan_0.db3` 且不是 0 字节 → **数据基本没事**，照 §5.3 重导；
- 是 0 字节 → 这个包废了，重扫，别纠结；
- 开机时出现 `emergency mode` / 只读文件系统 → 别硬扛，`fsck -y` 或重刷镜像。

---

## 5. 断连后的补救动作

### 5.1 半截 bag 能不能救？先看完整性

```bash
# 在狗上，把 <ts> 换成时间戳
/usr/bin/python3 -c "
import sqlite3
c = sqlite3.connect('file:/home/unitree/bags/<ts>/scan/scan_0.db3?mode=ro', uri=True)
print('完整性:', c.execute('pragma integrity_check').fetchone()[0])
print('消息数:', c.execute('select count(*) from messages').fetchone()[0])
"
```

`ok` + 有消息数 → 能救。`*** in database main ***` → 这个包废了。

### 5.2 没有 `metadata.yaml` 也能导

正常 `stop` 会生成，硬断电时可能没有。导出脚本会自己往下找 `*.db3`：

```bash
cd ~/flmap3_ws
/usr/bin/python3 scripts/bag_to_pcd.py ~/bags/<ts> ~/bags/<ts>/map.pcd
```

成功时打印每个话题的条数，一眼能看出到底录到了什么：

```
[info] bag=/home/unitree/bags/<ts>  storage=sqlite3
[info] backend=sqlite3 直读 / scan_0.db3
[info] /cloud_registered           176 条
[info] /livox/imu                 4911 条
[OK] 176 帧, 2470463 点 -> .../map.pcd  (37.7 MB)
```

### 5.3 唯一需要重扫的情况

- `scan_0.db3` 是 0 字节；
- `integrity_check` 报错；
- `/cloud_registered` 条数是 0（说明当时 LIO 就没出图，见 [06 §8.2](06-troubleshooting.md)）。

---

## 6. 重新上电的顺序（反向操作）

**如果 PC 也重启过，必须先把授时服务拉起来，再给狗上电** —— 狗端开机时会去拉时间，
PC 不在就是空拉一次，之后每 30 秒重试，也不致命，但日志会很吵。

```bash
# ① PC
cd ~/FLMap.2 && ./scripts/clock_sync.sh start

# ② 狗上电池开关 → 等 30 秒（Orin 启动 + 驱动加载）

# ③ PC，另开窗口
ping -c3 192.168.123.18            # 通了再往下
ssh unitree@192.168.123.18         # 输 1
cd ~/flmap3_ws && ./scripts/edge_control.sh

# ④ flmap> 里
flmap> start
flmap> status                      # 三个话题频率都该是 7–10 Hz

# ⑤ PC，第三个窗口
cd ~/FLMap.2 && ./scripts/pc_view.sh
```

`start` 之后如果 `status` 显示频率是 1–2 Hz，先别扫，看
[11-runbook.md](11-runbook.md) 的频率表。

---

## 7. 一页清单（建议打印）

```
□ 窗口 B:  stop          → 看到 "PCD 已导出: .../map.pcd"
□ 窗口 B:  quit          → 看到提示符回到 unitree@ubuntu:~/flmap3_ws$
□ 窗口 C:  Ctrl-C
□ 窗口 A:  ./scripts/clock_sync.sh stop
□ 狗 ssh:  sync
□ 狗 ssh:  sudo poweroff → 等风扇停、灯灭（15–20 s）
□ 关电池开关
□ 拔网线 / 关交换机
□ 关 PC
```

**绝对不要做的事**：拔网线当关机 / 不 `quit` 直接断电 / 直接关电池开关。

---

## 8. 常见现象对照

| 你看到的 | 八成是 | 怎么办 |
|---|---|---|
| `stop` 后滚出三行 `Killed` | 正常停进程 | 不用管 |
| `quit` 后 ssh 没断，还能敲命令 | 只退出了控制台，没关机 | 继续敲 `sudo poweroff` |
| `poweroff` 后 ssh 卡住不动 | 正常，狗正在关机 | 等 20 秒，别重复敲 |
| ssh 完全没反应（网络断了） | 网线/交换机/狗已断电 | 见 §4 |
| 下次开机 bag 打不开 | 上次是硬断电 | 见 §5.1 |
| 下次开机 `/cloud_registered` 是 0 条 | 录制时 LIO 就没出图 | 见 [06 §8.2](06-troubleshooting.md) |
| 重启后频率只有 1–2 Hz | Orin 还在启动/负载高 | 等 1 分钟再 `status` |

> ssh 卡死想强退：依次按 `回车` → `~` → `.`（三个键，不是同时按），
> 或者直接关掉这个终端窗口。别用 `Ctrl-Z`，那只是把它挂到后台。
