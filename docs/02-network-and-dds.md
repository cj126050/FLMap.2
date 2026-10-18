# 02 · 无线链路与 DDS 配置

> **连不上的时候，第一个看这份文档。** 它按「拓扑 → IP → Wi-Fi → DDS → 症状表」的顺序写。

---

## 1. 先选拓扑

PC 和狗必须**在同一个二层网络**里（同一网段）。三种可行方式：

### 方式 A：都连同一个路由器（推荐）

```
        ┌──────────┐
        │  路由器   │  5 GHz
        └──┬────┬──┘
     Wi-Fi │    │ Wi-Fi
        ┌──▼─┐ ┌▼──────┐
        │ PC │ │ Go2   │
        └────┘ └───────┘
```

- 优点：稳定、两边都能上网、IP 由 DHCP 分配好管理
- 要求：路由器**关闭 AP 隔离**（很多路由器的「访客网络」默认开着，客户端之间互相不可见）
- 建议给狗固定 IP（路由器里做 DHCP 绑定），否则每次换地址就要改 `EDGE_HOST`

### 方式 B：PC 开热点，狗连 PC

```bash
# 在 PC 上（NetworkManager）
nmcli connection add type wifi ifname wlp132s0 con-name go2-hotspot \
  autoconnect no ssid FLMAP-5G \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk 'flmap12345' \
  802-11-wireless.band a ipv4.method shared ipv4.addresses 10.42.0.1/24
nmcli connection up go2-hotspot
```

- `ipv4.method shared` 让 PC 自己当 DHCP 服务器，狗的地址通常是 `10.42.0.x`
- 优点：现场没有路由器也能用；缺点：PC 的 Wi-Fi 网卡要同时承担热点，带宽略降

### 方式 C：狗做 AP

部分 Go2 出厂镜像带 `hostapd`。**本仓库不推荐**，因为 Go2 自带的 Wi-Fi 模块通常
服务的是机器人 App（`192.168.12.x` 网段），与拓展坞的计算网卡不是一回事，容易搞混。

> **注意网段别撞车：** Mid360 出厂 IP 常是 `192.168.1.1xx`，而很多家用路由器也用
> `192.168.1.0/24`。如果雷达和 PC 在同一网段，会出现"PC 以为雷达在路由器后面"的诡异路由。
> 本仓库统一把雷达改到 `192.168.123.x`（见 [08-hardware.md](08-hardware.md)）。

---

## 2. IP 规划

本仓库默认的地址约定（都可以通过环境变量改）：

| 设备 | 地址 | 说明 |
|---|---|---|
| PC | 由路由器 DHCP 分配，如 `192.168.1.100` | 脚本里用 `EDGE_HOST` 指向狗，PC 自己的地址一般不用配 |
| Go2 拓展坞 | `192.168.123.18`（宇树内网约定） | 若走 Wi-Fi，可能是 `192.168.1.x`，以实际为准 |
| Mid360 | `192.168.123.20` | 与拓展坞同一网段，接在狗的雷达网口上 |

> **两台机器的 IP 不需要"配成一对"**，只要在同一网段且能互相 ping 通即可。
> 唯一需要显式填写的地方是：
> - `scripts/*.sh` 里的 `EDGE_HOST`（PC 找狗）
> - 狗端 `scripts/edge_control.sh` 里的 `FLMAP_PC_IP`（狗找 PC，只用于 `link` 命令测 RTT）

查地址：

```bash
ip -br addr                    # 本机所有网卡与地址
ip route get 192.168.123.18    # 去某个地址走哪个网卡
```

---

## 3. Wi-Fi 要求清单

点云流对链路的要求和网页浏览完全不同：**持续、单向、对延迟抖动敏感、丢包不重传**。

| 项目 | 要求 | 不满足会怎样 |
|---|---|---|
| 频段 | **5 GHz** | 2.4 GHz 在办公室几乎必然拥堵，画面频繁卡顿 |
| AP 隔离 | **必须关闭** | 两台机器 ping 不通，`ros2 topic list` 永远空 |
| 省电模式 | 关（`iw dev wlan0 set power_save off`） | 空闲后进省电，RTT 从 3 ms 跳到 100+ ms |
| 信道宽度 | 40 或 80 MHz | 20 MHz 单流吞吐约 40 Mbps，够但没余量 |
| Mesh / 中继 | 尽量避免 | 多跳后抖动大增，5 Hz 的点云会一顿一顿 |
| VPN / 代理 | 不要在同一网卡上开 | DDS 走 UDP，很多 VPN 只代理 TCP，会静默丢包 |

关省电（狗端执行，重启失效，可写进 `/etc/rc.local`）：

```bash
sudo iw dev wlan0 set power_save off
iw dev wlan0 link          # 看 signal 与 bitrate
```

---

## 4. DDS 配置

### 4.1 三个必须一致的东西

两端**必须完全相同**，否则表现为"都在跑但互相看不见"：

| 变量 | 本仓库默认 | 为什么 |
|---|---|---|
| `ROS_DOMAIN_ID` | **42** | 宇树自己的节点在 domain 0，用 42 隔离，避免串台 |
| `RMW_IMPLEMENTATION` | **rmw_cyclonedds_cpp** | FastDDS 与 CycloneDDS 的发现机制不同，混用必然不通 |
| 消息定义版本 | 同 ROS 版本即可 | 见 §5 跨发行版 |

这些变量在所有脚本里都已经设好（`edge_control.sh` / `pc_view.sh` / `link_probe.sh`），
**手工开终端时记得自己 export**：

```bash
export ROS_DOMAIN_ID=42
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_LOCALHOST_ONLY=0     # 千万别设成 1，那会只走本机
```

### 4.2 QoS 对照表（重要）

| 话题 | 可靠性 | 深度 | 说明 |
|---|---|---|---|
| `/cloud_registered` | RELIABLE | 100 | FAST-LIO2 默认值，桥接必须匹配 |
| `/flmap/cloud` | RELIABLE（可调） | 1 | 33 kB/帧，重传代价极小；改 best_effort 需同步改 RViz |
| `/flmap/map` | RELIABLE | 1 | PC 本地，不占网络 |
| `/aft_mapped_to_init` | RELIABLE | 10 | 数据极小 |

**QoS 是"成对匹配"语义，不是"自动降级"语义。** 实测（CycloneDDS 0.10 / Humble）：

```
发布端 RELIABLE  +  订阅端 BEST_EFFORT  ->  订阅端收到 0 帧
发布端 BEST_EFFORT + 订阅端 RELIABLE    ->  收不到
```

两种不匹配的表现都是**静默的**：`ros2 topic list` 能看到话题，`ros2 topic info`
能看到 publisher，但 `ros2 topic hz` 一条都没有。这是本仓库开发过程中真实踩过的坑：

- 桥接最初用 BEST_EFFORT 订阅 `/cloud_registered`，而 FAST-LIO2 发布的是 RELIABLE
  → 真机上会一帧都收不到（本地测试用的是 BEST_EFFORT 的合成源，恰好掩盖了问题）
- RViz2 的 PointCloud2 显示项默认按 RELIABLE 订阅 → 若桥接发 BEST_EFFORT，画面永远是空的

所以本仓库默认**全链路 RELIABLE**。要改成 best_effort 必须**成对改**：

```yaml
# 狗端 bridge_default.yaml
output_reliability: "best_effort"
```
```yaml
# PC 端 pc_view.yaml
input_reliability: "best_effort"
```
```
# RViz：Displays → Edge Frame (live) → Topic → Reliability Policy → Best effort
```

### 4.3 多播 vs 单播

CycloneDDS 默认用多播做节点发现。在有线局域网里没问题，但在 Wi-Fi 上：

- 很多 AP 对多播限速（最低 1–6 Mbps）或直接丢弃
- 开了 AP 隔离的网络，多播完全不通

症状：两边都起了节点，但要等几十秒才互相发现，或者一直发现不了。

**先不要急着改配置。** 默认设置在家用路由器上通常能用。只有在
`link_probe.sh` 第 4 层明确报"一个节点都没发现"、而 ping 通的时候，才启用单播模式：

```bash
# 1. 复制模板，把 Peer 填成对端 IP（不是本机 IP）
cp config/cyclonedds_unicast.xml.example config/dds_edge.xml   # 狗上：Peer = PC 的 IP
cp config/cyclonedds_unicast.xml.example config/dds_pc.xml     # PC 上：Peer = 狗的 IP

# 2. 改 NetworkInterface 的 name 为实际网卡名（ip -br addr 查）

# 3. 启动前设置
export CYCLONEDDS_URI=file:///绝对路径/dds_edge.xml     # 狗
export CYCLONEDDS_URI=file:///绝对路径/dds_pc.xml       # PC
```

⚠️ Peer 写错会**静默失败**，症状和"完全没连上"一模一样。改之前先用默认配置确认能通。

---

## 5. 跨发行版互操作（Foxy ↔ Humble）

狗端 Ubuntu 20.04 + Foxy，PC 端 22.04 + Humble。这是**两个不同版本的 ROS 2**，
DDS 层理论上互通，实践上要注意：

**能通的部分**：`sensor_msgs/PointCloud2`、`nav_msgs/Odometry`、`nav_msgs/Path`、
`tf2_msgs/TFMessage`、`std_msgs/*` 这些从 Foxy 到 Humble 消息定义没变，CDR 序列化一致。

**可能不通的部分**：

- 自定义消息类型（本仓库不跨机器传自定义消息，`CustomMsg` 只在狗端本地用）
- Iron/Jazzy 之后引入的 type hash 机制（Humble 还没启用，所以没这个问题）
- 两端 RMW 版本差异过大时（Foxy 的 CycloneDDS 0.7 vs Humble 的 0.10）

**判定方法**：

```bash
# PC 上
ros2 topic list                 # 能看到 /flmap/cloud 吗？
ros2 topic info /flmap/cloud -v # 能看到 publisher 的 GID 吗？
ros2 topic hz /flmap/cloud      # 有频率吗？
```

能看到 topic 但没有数据 = QoS 或类型不匹配；看不到 topic = 发现层没通。

**回退方案（按推荐顺序）**：

1. **PC 上跑 Foxy 容器**（最稳）：

   ```bash
   docker run -it --rm --net=host --ipc=host \
     -e DISPLAY=$DISPLAY -e ROS_DOMAIN_ID=42 \
     -e RMW_IMPLEMENTATION=rmw_cyclonedds_cpp \
     -v /tmp/.X11-unix:/tmp/.X11-unix \
     ros:foxy \
     bash -c "apt update && apt install -y ros-foxy-rviz2 ros-foxy-rmw-cyclonedds-cpp && rviz2"
   ```

   注意：容器里没有本仓库的 `flmap_accumulator`，此时用 `pc_view.sh --raw` 只看当前帧，
   或者把仓库挂载进容器编译一份。

2. **录包离线看**：狗端 `start` → 走完 → `stop`，把 bag 拷回 PC 用本仓库回放
   （见 [04-pc-visualization.md](04-pc-visualization.md) 的离线回放一节）。

---

## 6. 症状 → 处置表

| 症状 | 最可能的原因 | 处置 |
|---|---|---|
| `ping` 不通 | 不同网段 / AP 隔离 / 没连同一个 Wi-Fi | `ip -br addr` 对比前三段；关路由器 AP 隔离 |
| `ping` 通，`ros2 node list` 空 | DOMAIN_ID 或 RMW 不一致 | 两端 `echo $ROS_DOMAIN_ID $RMW_IMPLEMENTATION` 必须一样 |
| 能看到节点，看不到话题 | 节点还没发布 / 话题名不同 | `ros2 topic list` 对比；看狗端 `status` |
| 话题在，`ros2 topic hz` 无输出 | **QoS 不匹配**（最高频原因） | 用 `tools/bench_bridge.py --best-effort` 反向验证；见 §4.2 |
| 有数据但只有 1–2 Hz | 链路丢包 / 省电模式 | 关 power_save；降到 5 GHz；看 `link_probe` 抖动 |
| 画面卡 3–10 秒后突然追上 | 重传队列堆积（链路质量差） | 先看 `link_probe` 抖动；必要时两侧一起降 QoS + 降 `max_rate_hz` |
| RTT 从 3 ms 跳到 100 ms | Wi-Fi 省电 / 漫游 | `iw dev wlan0 set power_save off`；固定 AP |
| 狗端能 ping 通 PC，PC 不能 ping 狗 | PC 防火墙 | `sudo ufw allow from 192.168.123.0/24` |

---

## 7. 用 link_probe.sh 定位

```bash
./scripts/link_probe.sh          # 常规体检
./scripts/link_probe.sh --bw     # 附带 iperf3 原始带宽（两端都要装 iperf3）
```

它按四层依次检查，**哪一层先红，问题就在哪一层，不要跳着看**：

```
1. 本机网络      走的是无线还是有线？有没有到对端的路由？
2. 连通性与时延  丢包 / 平均 RTT / 抖动 / 最大 RTT
3. SSH           部署通道是否可用
4. DDS 发现      能不能看到对端节点
5. 点云流        应用层，最能说明问题：/flmap/cloud 的实际频率与带宽
```

判据（脚本里使用的阈值）：

| 指标 | 健康 | 需要处理 |
|---|---|---|
| 丢包 | < 2 % | > 2 % 说明物理层就有问题 |
| 平均 RTT | < 30 ms | > 30 ms 链路拥塞或速率协商过低 |
| 抖动（mdev） | < 20 ms | > 20 ms 画面必然一顿一顿 |
| `/flmap/cloud` 频率 | 4–5 Hz | < 3.5 Hz 需要降参（见 05 文档） |
