# FLMap.2 —— Go2 边缘建图 + PC 远程可视化

**机器狗上建图，电脑上看图。** Mid360 接 Go2，FAST-LIO2 在狗载 Orin 上跑，点云经 Wi-Fi
实时送到 PC，在 RViz 里看着地图一点点长出来。

`ROS 2 Foxy（狗端）` · `ROS 2 Humble（PC 端）` · `Livox Mid360` · `FAST-LIO2` · `BSD-3-Clause`

---

## 一、为什么要有第二版

原版 [FLMap](https://github.com/cj126050/FLMap) 是标准的桌面架构：

```
Mid360 ──网线──▶ PC ──▶ livox 驱动 ──▶ FAST-LIO2 ──▶ RViz
```

摆在桌上能用，放到四条腿上就不行了，原因有三个：

1. **网口不够。** 雷达自己要占一个网口，就没法再拉一根网线给电脑。
2. **人得跟着走。** 笔记本连着线，狗走两步就得跟着挪两步 —— 那机器狗的意义就没了。
3. **带宽扛不住。** 原始配准点云是 `pcl::PointXYZINormal`，48 字节/点，每秒 20 万点
   ≈ **77 Mbit/s**。在共享的 Wi-Fi 上这是必挂的量。

所以在正确的层次上切一刀：**算力留在传感器旁边，画面留在人旁边。**

```
   ┌──────────────────── Go2（边缘）────────────────────┐        ┌──────── PC ────────┐
   │                                                    │        │                    │
   │  Mid360 ──▶ livox_ros_driver2 ──▶ FAST-LIO2        │        │  flmap_accumulator │
   │  百兆网口        /livox/lidar       │              │  Wi-Fi │        │           │
   │                  /livox/imu         ▼              │        │        ▼           │
   │                             /cloud_registered      │        │   /flmap/map       │
   │                                     │              │        │        │           │
   │                                     ▼              │        │        ▼           │
   │                              flmap_bridge ─────────┼───────▶│      RViz2         │
   │                          （降采样+重打包+限流）     │  5 Hz  │                    │
   │                                     │              │ 33 kB  │                    │
   │                                     ▼              │        │                    │
   │                              /flmap/cloud ─────────┘        │                    │
   └────────────────────────────────────────────────────┘        └────────────────────┘
```

**关键设计：狗端不传地图，只传「当前这一帧」。**
PC 把一帧帧拼起来得到 `/flmap/map`。地图越长，带宽一点都不涨 —— 这是这套方案能成立的根本原因。

| | 原版 FLMap | FLMap.2 |
|---|---|---|
| FAST-LIO2 跑在哪 | PC | Go2 拓展坞（Orin Nano） |
| 雷达网线接到哪 | PC | Go2 |
| 操作位置 | 被线拴住 | Wi-Fi 覆盖范围内任意位置 |
| 链路负载 | 77 Mbit/s（原始点云） | **约 1.3 Mbit/s**（实测） |
| 地图增长开销 | 本地内存，免费 | PC 累加，同样免费 |

## 二、目录结构

```
FLMap.2/
├── src/
│   ├── FAST_LIO2_ROS2/      # LIO 核心（含断流修复，未改动）
│   ├── livox_ros_driver2/   # Livox 驱动
│   ├── go2_fastlio/         # LIO 的 launch / 参数集成
│   ├── flmap_bridge/        # ★ 新增  狗端：降采样 + 重打包 + 限流 → /flmap/cloud
│   ├── flmap_accumulator/   # ★ 新增  PC 端：多帧累积成地图 → /flmap/map
│   └── flmap_bringup/       # ★ 新增  双端 launch 文件 + RViz 配置
├── scripts/
│   ├── deploy_edge.sh       # 同步到狗 + 打 Foxy 补丁 + 远程编译
│   ├── edge_control.sh      # 狗端交互控制台（不起 RViz）
│   ├── pc_view.sh           # PC 端一键远程可视化
│   ├── link_probe.sh        # 四层链路体检（物理→网络→DDS→应用）
│   ├── patch_foxy.sh        # Humble → Foxy 源码补丁（幂等）
│   ├── env_check.sh         # 环境体检报告
│   └── legacy/              # 旧的有线直连脚本，仅留档
├── config/
│   └── cyclonedds_unicast.xml.example   # 可选：关多播走单播发现
├── tools/
│   ├── fake_cloud.py        # 没有雷达也能压测的合成点云源
│   └── bench_bridge.py      # 量任意话题的真实帧率/带宽
└── docs/                    # 八篇文档，建议按编号读
```

## 三、快速开始

### 0. 前置条件

- **PC**：Ubuntu 22.04 + ROS 2 Humble（桌面版，带 RViz2）
- **狗端**：Go2 拓展坞（Orin Nano），已装 ROS 2 Foxy + Livox-SDK2
- **网络**：PC 与狗在同一个 Wi-Fi / 同网段，`ping <狗IP>` 通，`ssh unitree@<狗IP>` 免密

> 狗端没有 Wi-Fi 网卡的话，先加一个 USB 无线网卡（或让它连 PC 开的热点）。
> 具体选型与配置见 [docs/02-network-and-dds.md](docs/02-network-and-dds.md)。

### 1. PC 上编译

```bash
git clone https://github.com/cj126050/FLMap.2.git && cd FLMap.2
./setup.sh
```

### 2. 推到狗上并编译

```bash
./scripts/deploy_edge.sh
# 可用环境变量：EDGE_HOST=192.168.1.50 EDGE_USER=unitree EDGE_WS=~/flmap_ws
```

脚本会做三件事：rsync 源码 → 远端执行 `patch_foxy.sh` → 远端 `colcon build`。
**注意：不要在两端共用同一份被补丁改过的 src** —— 补丁只该作用在狗端副本上。

### 3. 狗端：开始建图

```bash
ssh unitree@<狗IP>
cd ~/flmap_ws && ./scripts/edge_control.sh
```

控制台命令：

| 命令 | 作用 |
|---|---|
| `start` | 开始一次扫描（建任务目录 + 录包） |
| `pause` / `resume` | 暂停 / 继续录包 |
| `stop` | 停止并导出 PCD 到任务目录 |
| `status` | 进程、话题频率、温度、内存 |
| `stats` | 看 bridge 的压缩比与实际输出频率 |
| `link` | 无线链路体检（RTT / 丢包 / 信号） |
| `quit` | 退出（自动 stop + 关节點） |

### 4. PC 端：远程看图

```bash
./scripts/pc_view.sh
```

RViz 里有四个显示项：

| 显示项 | 话题 | 含义 |
|---|---|---|
| Accumulated Map | `/flmap/map` | 累积地图（PC 本地拼的，越走越大） |
| Edge Frame (live) | `/flmap/cloud` | 狗端刚发来的当前帧 |
| Odometry | `/aft_mapped_to_init` | 当前位姿 |
| Trajectory | `/path` | 走过的轨迹 |

**RViz 一片空白？** 跑 `./scripts/link_probe.sh`，它按物理层→网络层→DDS 层→应用层
逐层检查，直接告诉你断在哪一层。

## 四、实测性能

同一台机器、合成点云源（`tools/fake_cloud.py`，几何与点数对齐 FAST-LIO2 的真实输出）、
CycloneDDS、`ROS_DOMAIN_ID=42`：

| 话题 | 点数/帧 | 字节/点 | 频率 | 带宽 |
|---|---|---|---|---|
| `/cloud_registered`（桥接前） | 20 000 | 48 | 10 Hz | **57–77 Mbit/s** |
| `/flmap/cloud`（桥接后） | 2 061 | 16 | 5 Hz | **1.3 Mbit/s** |
| `/flmap/map`（PC 本地） | 持续增长 | 16 | 1 Hz | 不上网 |

该场景降采样比 10.3%；真实室内场景在 6%–20% 之间。自己复现：

```bash
ros2 run flmap_bridge flmap_bridge_node --ros-args -p stats_period:=10 &
python3 tools/fake_cloud.py --points 20000 --rate 10 &
python3 tools/bench_bridge.py --seconds 8
```

### 实机验证（Go2 拓展坞 Orin Nano，ROS 2 Foxy + 内置 L1 雷达）

上表是合成数据下的上限。以下是**真实硬件、真实点云、跨机器**跑通的结果：

| 环节 | 结果 |
|---|---|
| 狗端 `colcon build`（6 个包，aarch64 / Foxy） | **通过，4 分 32 秒** |
| `/cloud_registered`（FAST-LIO2 输出） | 10 Hz，LIO 残差 0.016 |
| `/flmap/cloud`（狗端桥接 → 过网 → PC） | **5.4 Hz**，跨机收到，降采样比 34–39% |
| `/flmap/map`（PC 累加） | 1.3 Hz，8 秒内 2 416 → 5 148 点，**持续增长** |

跨机这一段是 **Foxy(Foxy 狗端) ↔ Humble(PC)** 互操作，`rmw_cyclonedds_cpp` + 同域号即可通，
不需要额外桥接。这次测试用的是内置 L1（点少，约 130 点/帧），换成 Mid360 后点数会上来，
带宽由 `docs/05` 的公式决定。

> 未验证项：Mid360 实物（测试时雷达未接）、无线链路下的长时间稳定性。
> 文档里凡涉及这两点的结论都标了"预期"而不是"实测"。

## 五、文档索引

| 文档 | 内容 | 什么时候读 |
|---|---|---|
| [01-architecture.md](docs/01-architecture.md) | 为什么这样拆分、数据流、带宽账、备选方案对比 | 想改设计 / 想理解取舍 |
| [02-network-and-dds.md](docs/02-network-and-dds.md) | 网段规划、Wi-Fi 要求、DDS 参数、跨发行版互操作、症状→处置表 | **连不上时第一个看** |
| [03-edge-deployment.md](docs/03-edge-deployment.md) | 狗端依赖、Foxy 补丁、开机自启、功耗模式、看门狗 | 首次部署 / 换机器 |
| [04-pc-visualization.md](docs/04-pc-visualization.md) | PC 端环境、RViz 面板、累加器调参、录屏、离线回放 | 想让画面更好看 |
| [05-bandwidth-tuning.md](docs/05-bandwidth-tuning.md) | 带宽公式、调参优先级、极端场景预设 | 画面卡顿 / 掉帧 |
| [06-troubleshooting.md](docs/06-troubleshooting.md) | 按症状索引的排查手册 | 出问题时 |
| [07-gap-fix.md](docs/07-gap-fix.md) | 数据断流导致的点云发散修复 | 点云突然飞走 |
| [08-hardware.md](docs/08-hardware.md) | Mid360 接线、IP 配置、安装姿态、与内置 L1 共存 | 装雷达时 |
| [09-wireless-link.md](docs/09-wireless-link.md) | 拓展坞没有无线射频的事实、四条通路的成本与风险、USB 网卡选芯片 | **想让狗脱离网线时** |

## 六、兼容性与已知限制

- **跨发行版 DDS。** 狗端 Foxy、PC 端 Humble。`PointCloud2` / `Odometry` / `TFMessage`
  这些消息在 RTPS 层是兼容的，两端都默认 CycloneDDS，实践中可用。但如果 `ping` 通而
  `ros2 node list` 看不到对方，按 [02 文档](docs/02-network-and-dds.md) 的回退方案处理
  （PC 上跑 Foxy 容器，或录包离线看）。
- **狗端没有显示器。** 这是设计，不是缺陷 —— 狗上不装 RViz。
- **Wi-Fi 是共享介质。** 2.4 GHz 拥挤信道下谁都救不了，`05 文档` 有"按顺序关哪些东西"的表。
- **PC 端地图是累积结果，不是 LIO 的内部地图。** 它是把流过来的帧拼起来的，走回头路时
  重复点只有在触到内存上限时才会全局去重。这是可视化的取舍，不影响建图精度 ——
  权威地图始终是狗端导出的 PCD。

## 七、致谢

- [FAST_LIO2_ROS2](https://github.com/Vulcan-YJX/FAST_LIO2_ROS2) —— LIO 核心
- [livox_ros_driver2](https://github.com/Livox-SDK/livox_ros_driver2) —— Livox 驱动
- [Unitree Go2](https://www.unitree.com/go2) —— 承载平台

上游包保留其原始 BSD 许可，本仓库新增部分均为 BSD-3-Clause。
