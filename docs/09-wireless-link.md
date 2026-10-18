# 09 · 无线链路：硬件前提与四条通路

> [02-network-and-dds.md](02-network-and-dds.md) 讲的是「有了无线之后怎么配」。这一篇讲
> **「无线从哪来」**——因为拓展坞出厂配置里根本没有无线射频，这一步绕不过去。

---

## 0. 一个必须先纠正的前提

**拓展坞（Orin Nano 载板）没有无线射频。** 实测证据（`unitree@192.168.123.18`）：

```bash
$ lspci | grep -i network
0008:01:00.0 Ethernet controller: Realtek RTL8111/8168/8411 Gigabit Ethernet   # 只有有线
$ lsusb
Bus 002 Device 001: ID 1d6b:0003 Linux Foundation 3.0 root hub                 # 没有设备
Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub
$ ls /sys/class/net/
docker0  dummy0  eth0  lo                                                       # 没有 wlan0
$ rfkill list                                                                   # 空
```

两个连带结论：

1. **[02](02-network-and-dds.md) 里的三种拓扑（同一路由器 / PC 开热点 / 狗做 AP）都隐含
   「狗端有 Wi-Fi」。** 在只有载板出厂配置的机器上这个前提不成立，必须先加射频。
2. **「两个 RJ45」是同一颗网卡下的两个交换口**，不是两张网卡——`ip link` 只有 `eth0`。
   所以「空闲网口接一个路由器」这条路，接上去和 `eth0` 在同一个二层里。

另外，拓展坞**没有任何外网出口**：默认路由指向 `192.168.123.1`，但该地址 ARP 是
`INCOMPLETE`、ping 不通。这解释了为什么校时必须靠 PC 的 HTTP 服务（见 [03](03-edge-deployment.md)）。

---

## 1. 四条通路

| | 方案 | 硬件 | 成本 | 狗端看到的网段 | 需要 root 改动 | 主要风险 |
|---|---|---|---|---|---|---|
| **A** | USB 无线网卡插拓展坞 | MT7612U 芯片网卡 | ¥50–120 | 与 PC **同网段** | 狗端 | USB 供电、天线遮挡 |
| **B** | 便携路由器插空闲 RJ45 | GL.iNet 类 | ¥150–350 | 与 PC **同网段** | 无（在路由器里配） | 多一个盒子要固定 |
| **C** | 借 Go2 自带 Wi-Fi | 无 | ¥0 | **跨网段**（12.x ↔ 123.x） | **狗端 + 运控** | 抢遥控带宽、可能影响 App |
| **D** | 5 GHz 点对点网桥 | UBNT / TP-Link CPE 一对 | ¥300–800 | 与 PC **同网段** | 无 | 体积重量，室内过重 |

**优先选同网段的方案。** ROS 2 的 DDS 发现对跨网段、跨 NAT 非常不友好，
同网段只需要处理「Wi-Fi 上多播常被丢」一个问题；跨网段要同时处理路由、NAT、
单播 Peer 三件事，而且出错时大多是**静默失败**。

---

## 2. 方案 A：USB 无线网卡（推荐）

### 选芯片，不是选品牌

狗端内核 `5.10.104-tegra` 自带的 USB 无线驱动（实测 `modinfo` 确认存在）：

| 驱动模块 | 覆盖芯片 | 频段 | 建议 |
|---|---|---|---|
| **`mt76x2u`** | **MT7612U** | **2.4 + 5 GHz** | **首选**，唯一自带驱动的 5 GHz 方案 |
| `rtl8xxxu` | RTL8188CU/EU、RTL8192CU/EU、RTL8723AU/BU | 2.4 GHz | 2.4 GHz 备选 |
| `mt7601u` | MT7601U | 2.4 GHz | 2.4 GHz 备选 |
| `r8188eu` | RTL8188EU | 2.4 GHz | 能用但不推荐 |

**要避开**：RTL8812AU、RTL8821CU、RTL88x2BU。这三个是市面上最常见的「双频高增益」
U 盘网卡，但内核里**没有**驱动，得 DKMS 编译。狗端虽然有 `dkms` 和
`linux-headers-5.10.104-tegra`，但 Jetson 上编外挂驱动很容易踩编译选项和符号版本
的坑——为了 1.3 Mbit/s 的负载去折腾驱动不值。

对应型号举例（认芯片不认牌子）：COMFAST CF-926AC v2、EDUP EP-AC1605。
下单前让商家确认是 **MT7612U**，不是 8812AU。

### 插上之后

```bash
# 狗端
ip link | grep wlan                     # 应该出现 wlan0
nmcli device wifi list                  # 能看到周边 AP
```

### ⚠️ 两块网卡的坑

插上网卡后，狗端会有 **两块网卡**：

```
eth0   192.168.123.18   ← 雷达(192.168.123.20) + 运控(192.168.123.161)
wlan0  192.168.50.x     ← PC
```

CycloneDDS 默认会在**所有**网卡上做发现。PC 只在 `wlan0` 那头，如果发现包从
`eth0` 出去，PC 就永远看不到话题——而 `ros2 topic list` 只是空的，不报错。

必须显式绑定：

```bash
# 狗端：只认 wlan0，Peer 指 PC
export CYCLONEDDS_URI=file://$HOME/dds_edge.xml
```

用 [config/cyclonedds_unicast.xml.example](../config/cyclonedds_unicast.xml.example) 做模板，
把 `NetworkInterface name` 改成 `wlan0`，`Peer address` 填 PC 的地址。

---

## 3. 方案 B：便携路由器

把 GL.iNet 之类的小路由器 LAN 口接到拓展坞空闲 RJ45，5 V 从拓展坞 USB 口取电。

**关键：必须用中继/Extender 模式（relayd 桥接），不能用路由模式。**
路由模式会让狗端落在路由器的 LAN 私网里，PC 要穿 NAT 才能到——DDS 会挂。

Bridge/Extender 模式下，路由器把下面的设备透传到上游 Wi-Fi，狗端拿到和 PC
同网段的地址，问题消失。

优点：不占 USB、不用驱动、可选 5 GHz、有网管界面、能长期固定。
缺点：多一个盒子和一根线，要绑在狗背上。

---

## 4. 方案 C：借 Go2 自带 Wi-Fi（零成本，但有硬前提）

Go2 机身自带 Wi-Fi 模块，服务手机 App 遥控，网段 `192.168.12.x`，运控在
`192.168.12.1`。运控同时有 `eth0 = 192.168.123.161`，和拓展坞在同一个二层。

意图是把运控当成一台路由器：

```
PC ──Wi-Fi──> 运控(12.1 / 123.161) ──eth0──> 拓展坞(123.18)
```

### 三个决定性前提

1. **Go2 的 Wi-Fi AP 要开着**——App 能连上就说明开着。
2. **运控要能把 12.x 和 123.x 打通**，这里分两种情况，结果完全不同：

   | 运控行为 | 狗端要不要改 | 结果 |
   |---|---|---|
   | **NAT（MASQUERADE）** | 不用 | 狗看到的源地址是 `192.168.123.161`，回复走本地二层，天然通 |
   | **纯转发（ip_forward=1 无 NAT）** | **必须加回程路由** | 否则「去程通、回程不通」，ping 有回应但回复包掉进 `123.1` 这个黑洞 |

3. **需要运控的 SSH 凭据**。`192.168.123.161:22` 是开放的，但需要密码；
   Unitree 文档里常见的默认口令 `123` 在部分批次上已不适用。

查一件事就能判定：登进运控执行

```bash
sysctl net.ipv4.ip_forward
iptables -t nat -S | grep -i masq
```

### 风险（不是危言耸听）

- **运控是安全相关的控制器。** 改它的路由/NAT 一旦配错，可能导致手机 App 连不上机器人
  ——等于失去遥控手段。动之前先确认能通过别的方式急停。
- **带宽共用。** Go2 的 AP 多为 2.4 GHz，和 App 的遥控图传抢同一条信道，抖动会明显
  大于方案 A/B。
- **PC 侧还有个坑**：拔掉网线后，如果 `192.168.123.10/24` 还留在 `enp131s0` 上，
  去往 `192.168.123.18` 的包会继续往那块没载波的网卡送，形成黑洞。要么删掉这个地址，
  要么加一条更具体的路由指到 Wi-Fi 那头。

---

## 5. 方案 D：5 GHz 点对点网桥

一对 CPE（如 UBNT LiteBeam、TP-Link CPE 系列）做透明桥接。适合室外、大场地、
金属货架多的厂房。室内用属于杀鸡用牛刀。

---

## 6. 无论哪条通路，Wi-Fi 上都要做三件事

1. **关省电**——空闲后 RTT 会从 3 ms 跳到 100 ms 以上
   ```bash
   sudo iw dev wlan0 set power_save off
   ```
2. **DDS 改单播**——很多 AP 会丢弃或限速多播
   ```bash
   export CYCLONEDDS_URI=file:///path/to/dds.xml
   ```
3. **固定 IP**——在路由器里做 DHCP 绑定，否则每次换地址都要改 `EDGE_HOST`

细节见 [02-network-and-dds.md](02-network-and-dds.md) 第 3–5 节。

---

## 7. 怎么验证

```bash
./scripts/wifi_path_check.sh
```

它按「路由 → 链路类型 → 去程 → **回程** → 抖动」五步走，最后给结论。
其中第 4 步专门测回程——这是 C 方案最容易失败、也最难自己想到的一环。

---

## 8. 相关

- [02-network-and-dds.md](02-network-and-dds.md) — 有无线之后的网络、IP、QoS 配置
- [03-edge-deployment.md](03-edge-deployment.md) — 校时与部署（狗端无外网，靠 PC 授时）
- [05-bandwidth-tuning.md](05-bandwidth-tuning.md) — 1.3 Mbit/s 是怎么来的
