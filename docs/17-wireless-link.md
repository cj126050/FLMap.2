# 17 · 无线链路：PC 开热点，狗连上来

> [02](02-network-and-dds.md) 讲的是「有网之后怎么配 IP 和 DDS」。这一篇讲
> **「这条无线从哪来、为什么这么选」**，以及 2026-10-21 的实测结论。
>
> 一句话：**USB 无线网卡插在狗上（方案 A），但 AP 由 PC 来开。** 狗当 STA，
> PC 当 AP，两边落在 `10.42.0.0/24` 这一个二层里。

---

## 1. 现状（2026-10-21 实测）

| 项 | 实测值 |
|---|---|
| 主机无线网卡 | Realtek RTL8922AE（`wlp132s0`，驱动 `rtw89_8922ae_git`） |
| 支持模式 | managed / **AP** / AP-VLAN / monitor / P2P |
| 5 GHz 可用信道 | ch36–48、ch149–165（20 dBm） |
| 狗端无线 | USB 网卡已插上，**尚未配置** |
| 主机当前连的 AP | `13829973977`（Go2 自带），5745 MHz ch149，−37 dBm |
| 主机地址 | `192.168.12.122/24`，DHCP 由运控分配 |
| 到 `192.168.12.1` | 0 丢包，但 avg 23–63 ms / 抖动 42 ms（`power_save=on`） |
| 到 `192.168.123.161` | **通**，avg 1.89 ms / 抖动 0.11 ms |
| 到 `192.168.123.18` | **不通**，纯超时 |
| `192.168.123.254`（不存在） | 纯超时，**没有 ICMP 不可达** |

最后一行是判定 `ip_forward` 的关键：如果运控在转发，内核会真的去 `eth0` 上
ARP，失败后回 `Destination Host Unreachable`。一个包都不回，只有一种解释：
**目的不在本机的包被直接丢掉**。

所以「PC 连 Go2 自带 AP → 运控 → 拓展坞」（FLMap.2 的方案 C）**在软件层是死的**，
要打开必须拿到运控 SSH 密码去开 NAT。这条路本身也不适合跑点云——
AP 和手机 App 的图传共用一个射频模块，抖动 40 ms 起步。

---

## 2. 拓扑

```
        PC                                    Go2
┌───────────────────┐                  ┌──────────────────────────┐
│ wlp132s0  10.42.0.1│  ←── 5 GHz ──→  │ wlan0  10.42.0.18 (USB)  │
│  (AP 模式)         │                │        │                 │
│                    │                │        └─ eth0 192.168.123.18
│ enx…  192.168.42.x │── 手机 USB ──→ 公网 │             ├─ 运控 192.168.123.161
└───────────────────┘                  │             └─ Mid360 192.168.123.221
                                       └──────────────────────────┘
```

三个要点：

1. **公网走手机 USB 共享**（`enx0202355e3737`，RNDIS），无线网卡才能专心当 AP。
   否则开热点就没网，[19](19-wireless-selection.md) §7.1 已经踩过这个坑。
2. **热点网段是 `10.42.0.0/24`，不是 123 段。** 狗端 `eth0` 已经占了
   `192.168.123.18`，如果热点还发 123 段，狗端就有两个接口同网段：PC 的 ARP
   只有 `wlan0` 能听见，而 `.18` 绑在 `eth0` 上不会应答；就算用 `proxy_arp`
   糊过去，回包也会从 `eth0` 出去。**同网段双接口是这里最大的坑，直接避开。**
3. **PC 与狗之间的 ROS 通信只走 WiFi 这一跳。** 雷达数据由狗上的 FAST-LIO
   从 `eth0` 收 UDP，处理后以话题形式从 `wlan0` 发布。PC 不需要能 ping 通雷达。

---

## 3. 为什么 AP 开在 PC 而不是狗上

| | PC 做 AP | 狗做 AP |
|---|---|---|
| 需要的软件 | NetworkManager（已有） | hostapd + dnsmasq |
| 能不能装上 | 能 | **不能**——狗端没有外网，`apt` 拉不到包 |
| 配置量 | 一条 `nmcli connection add` | 两份配置文件 + 起服务 |
| AP 位置 | 跟着操作者走 | 跟着狗走 |

狗端没有外网这一条就够定案了。真要狗做 AP，得先给它接个能上网的口装包，
绕一圈又回到「先插网线」。

顺带一提，USB 网卡的 `mt76x2u` 驱动虽然支持 AP 模式，但 Jetson 上 concurrent
（同时 STA+AP）基本不可用，狗端做 AP 就意味着它自己上不了网。

---

## 4. 一次性配置（约 5 分钟，只需插一次网线）

### 4.1 插网线，确认网卡认出来了

PC 的 `enp131s0` → 拓展坞**朝外**那个 RJ45（不是狗身内部的口）。

```bash
cd ~/FLMap.2
sudo ./scripts/dog_wlan_probe.sh
```

它做三件事：临时配 `192.168.123.10/24`、ssh 上去、把狗端无线相关的状态全查一遍
（`ip link` / `lsusb` / 驱动模块 / 支持的模式 / 固件加载失败）。

**这一步的结果决定后面能不能走**：

| 现象 | 含义 | 处理 |
|---|---|---|
| 出现 `wlan0` | 网卡正常 | 继续 4.2 |
| 没有 `wlan0`，`lsusb` 有未知设备 | 有设备没驱动 | 芯片不是 MT7612U，要 DKMS 编译 |
| `dmesg` 有 `Direct firmware load ... failed` | 缺固件 | 从 PC 拷 `mt7662u*.bin` 到狗端 `/lib/firmware/mediatek/` |
| `lsusb` 什么都没有 | 没插稳 / 供电不足 | 拔下来重插，换一个 USB 口 |

### 4.2 PC 开热点

先把网线拔了再开热点也行，但建议**先开热点再配狗**，否则狗端扫不到 SSID。

```bash
sudo ./scripts/pc_hotspot.sh
# SSID=FLMap3  PASS=flmap2026  ch44 10.42.0.1/24
```

信道默认 ch44：现场扫描里 ch149 被 `VGE_5` 占着、ch48 被 `VGE_0_5G` 占着，
ch36–44 是空的。2.4 GHz 上 22 个 AP 挤 3 条道，**不要用**。

> 开热点会踢掉当前 WiFi（主机现在连的是狗自带 AP）。公网在手机 USB 上，不受影响。
> 想关回去： `sudo ./scripts/pc_hotspot.sh --down`

### 4.3 狗连上来

```bash
sudo ./scripts/dog_wlan_join.sh
```

狗端 `wlan0` 连热点，静态配 `10.42.0.18/24`，网关 `10.42.0.1`，关省电，
设成开机自动连；同时写一份 `~/dds_wifi.xml`（只绑 `wlan0`，Peer 指 PC）。

**为什么静态不用 DHCP**：地址固定，`EDGE_HOST` 才不用每次查。`.18` 故意和
`eth0` 的 `123.18` 尾号一致，好记。

**为什么给狗配默认网关**：PC 的 `ipv4.method shared` 会自动做 NAT，狗端因此
恢复外网——`apt` 能用了，校时也不用再靠 PC 起 HTTP 服务。

### 4.4 拔网线，验收

```bash
ping -c 3 10.42.0.18
ssh unitree@10.42.0.18 'iw dev wlan0 link'
```

`iw dev wlan0 link` 应该显示 `bitrate` 在 100 Mbit/s 以上、`signal` 优于 −60 dBm。
低于 −65 就把网卡天线引到狗背开口处——狗身是金属壳，插在体内等于自带屏蔽罩。

---

## 5. 之后所有脚本怎么用

`link_probe.sh` / `edge_control.sh` / `deploy_edge.sh` 都会**自动探测** `EDGE_HOST`：
先探 `10.42.0.18`（无线），再回落 `192.168.123.18`（有线）。所以拔了网线什么都不用改：

```bash
./scripts/link_probe.sh
./scripts/edge_control.sh status      # 非交互一次性执行，不会误关正在跑的建图
```

想固定下来就在 `~/.bashrc` 里写死：

```bash
export EDGE_HOST=10.42.0.18
```

**DDS 只需要一件事：把网卡绑死。** 保留默认多播（不写 Peer、不关多播 —— 那套配置在
热点上反而会变成"话题看得见、数据收不到"），但必须显式指定走哪张网卡，否则 CycloneDDS 会
`selected arbitrarily` 挑一张，挑错就整条链断路（详见 6.3）。

`edge_control.sh` / `pc_view.sh` 已经自动调用 `scripts/dds_bind.sh` 生成配置，正常流程不用管。
手动跑 CLI 时自己 eval 一句：

```bash
export ROS_DOMAIN_ID=42
eval $(bash scripts/dds_bind.sh pc --print)    # 主机侧
eval $(bash scripts/dds_bind.sh dog --print)   # 狗端
```

RMW 不必强求一致：实测 PC 用 CycloneDDS、狗用默认 FastRTPS，双向收发都正常。
`edge_control.sh` 里统一导出 `rmw_cyclonedds_cpp` 是为了和有线时期的行为保持一致，不是硬要求。

`pc_dds_peer.sh` 和狗端 `dds_wifi.xml`（单播 Peer + 关多播）留作备用手段：只有 AP 开了
客户端隔离、多播真的过不去时才需要。本项目的 AP 是自家 `nmcli` 起的，不做隔离，默认不用。

---

## 6. 实测验收（2026-10-21）

| 项 | 实测 |
|---|---|
| 主机地址 | `10.42.0.1/24`（AP，ch44 / 5220 MHz） |
| 狗端地址 | `10.42.0.18/24`（STA，`wlan0`，MT7612U） |
| 信号 | −47 dBm |
| 链路速率 | rx 115.6 / tx 117.0 Mbit/s（VHT-MCS5/6，NSS2） |
| 延迟 | 0.488 / 0.956 / 2.181 ms（min/avg/max），**抖动 0.313 ms** |
| 下行吞吐 | 12.9 MB/s（≈103 Mbit/s），100 MB / 8.16 s |
| DDS 狗 → PC | **通**（探针收到 30 条/8 s） |
| DDS PC → 狗 | **通**（探针收到 33 条/8 s） |

抖动 0.31 ms 这个数字比有线只差一点，跑 10 Hz 点云毫无压力。

### 6.1 DDS 的两个 QoS 坑

排查时踩了两个，都不是网络问题：

1. **`ros2 topic pub` 默认 durability 是 `TRANSIENT_LOCAL`**，而 Foxy 的 `echo` 默认
   `VOLATILE`。这两个不兼容，publisher 起了、`topic list` 也能看见，但永远收不到数据。
   发布时显式加 `--qos-durability volatile`。
2. **Foxy 的 `ros2 topic echo` 默认 reliability 是 `BEST_EFFORT`**，Humble 的 `pub`
   默认 `RELIABLE`。方向反过来时同样匹配不上。查法：
   ```bash
   ros2 topic info <topic> --verbose   # 看 Subscription count 和 Reliability
   ```

**这不是测试脚本的毛病，是真实链路的坑。** 以后狗端 FAST-LIO 发点云、PC 端 RViz
订阅，两边 QoS 必须对得上：FAST-LIO 用默认（reliable）发，RViz 用 reliable 订阅就没问题；
一旦一边降到 best_effort，另一边还是 reliable，就是"话题看得见、数据没影"。

### 6.2 "PC → 狗 不通" 是个假阴性（值得记一辈子）

> **2026-10-21 11:45 更正：这一节的结论只对了一半。** 缓冲确实会造成假阴性，
> 但换个不经过缓冲的判据（`ros2 topic list`）重测，PC → 狗 的发现**真的不通**。
> 真凶是主机的多播出口跟着默认路由跑到了手机网卡上，见 **§6.5**。

当天最贵的教训：差不多一个小时的排查，全部建立在一个假象上。

现象：`ros2 topic list` 能看见对方话题，`ros2 topic echo` 一个字不打印；狗端抓包也只有
RTPS 内建流量。看起来像 writer 没匹配上，于是把 QoS、RMW（FastRTPS / CycloneDDS 各试一遍）、
接口绑定（`interfaceWhiteList` / `NetworkInterfaceAddress`）、`ros2 daemon` 缓存全查了一遍。

真实原因：**`ros2` CLI 是 Python，stdout 接管道时是块缓冲**。写法是

```bash
timeout 8 ros2 topic echo /topic | head -4
```

`timeout` 到点直接 SIGTERM，缓冲区里那几行（不到 4 KB）根本没 flush，于是"什么都没收到"。
数据其实一直在流。加一个环境变量立刻现原形：

```bash
PYTHONUNBUFFERED=1 timeout 8 ros2 topic echo /topic | head -4
```

判据很简单：**如果同一个命令在本机自发自收也是空的，那跟网络一点关系都没有。**
本机回环都不通，就该先怀疑 CLI/缓冲/环境，而不是链路。

现在 `link_probe.sh` 的第 4 节已经换成了主动探针：自己发一个 `String` 话题，两个方向各收
一次，全程 `PYTHONUNBUFFERED=1` + 显式 QoS 对齐，不再依赖"有人正在建图"。

顺带把 `192.168.123.0/24` 的路由补上也有好处：狗端 DDS 监听 `0.0.0.0`，会把 `eth0` 的
`192.168.123.18` 也当成接收地址通告出去，PC 有这条路由才能把数据送到那个地址。它不是
必需项（10.42 的地址同时也在通告），但留着可以让双栈 locator 都能用：

```bash
sudo ip route add 192.168.123.0/24 via 10.42.0.18 dev wlp132s0
```

### 6.3 CycloneDDS 会自己挑网卡，而它经常挑错

建图跑起来之后，狗端本机 `/flmap/cloud` 是 8.6 Hz，主机 `ros2 topic hz /flmap/cloud`
却报 `does not appear to be published yet`。狗端 CLI 的输出里有唯一一条线索：

```
ros2: using network interface eth0 (udp/192.168.123.18)
      selected arbitrarily from: eth0, docker0, wlan0
```

`arbitrarily` 是字面意思：CycloneDDS 在多网卡机器上**只绑一张卡**，挑哪张看运气。
挑中 `eth0`（雷达那一段，主机上根本没有这张网卡）或主机侧的手机 RNDIS
（`192.168.42.106`）时，多播发现只发在那个网段，对面永远收不到。现象和"节点没启动"
完全一样，但狗端一切正常 —— 这就是它难查的地方。

概率很高，不是偶发：狗端有 `eth0/docker0/wlan0` 三张，主机有 `enp131s0`（DOWN）/
`wlp132s0` / `enx…`（手机）三张，两边都可能挑错。

**处置**：显式绑一张卡。`scripts/dds_bind.sh` 按角色生成配置并写进 `CYCLONEDDS_URI`：

```bash
bash scripts/dds_bind.sh pc        # 主机：按到 EDGE_HOST 的路由选网卡
bash scripts/dds_bind.sh dog       # 狗端：优先 10.42.x 的无线网卡，其次 192.168.123.x
eval $(bash scripts/dds_bind.sh pc --print)   # 只想拿到 export 语句
```

`edge_control.sh` 和 `pc_view.sh` 在启动节点前**自动**调用它，所以正常流程不用管。
手动排查时记得自己 eval 一句，否则你看的图和节点看的图可能不是同一张。

配置用的是 CycloneDDS 0.7 就认的 `<NetworkInterfaceAddress>`，0.10 也接受，两侧共用同一份
模板（这一点实测过：0.10 载入不报 `unknown element`，图也正常解析）。

### 6.4 无线跑实时点云的实测数据

| 指标 | 值 |
|---|---|
| `/flmap/cloud` 帧率 | **10.06 Hz**（min 0.087 / max 0.116 s，std 0.009） |
| 单帧点数 | 入 15592 → 出 8501（54.5%） |
| 单帧大小 | ~136 kB |
| 带宽 | 1.46 MB/s ≈ 11.7 Mbit/s，占 173 Mbit/s 协商速率的 **7%** |
| 桥自报 | `~10.9 Mbit/s @10.0 Hz` |
| 端到端 | 狗端 8.4 Hz → 主机 10.06 Hz（桥限流 10 Hz，不受链路影响） |

**7% 的占用意味着还有 10 倍余量**，无线跑点云完全不是瓶颈。真正要盯的是信号强度
（−65 dBm 以上）和抖动（5 ms 以内），这两项一坏，帧率才会掉。

### 6.5 主机的 DDS 多播会跟着默认路由跑（单向不通的真凶）

这一节纠正 6.2 的结论。6.2 把"PC → 狗不通"归因于 Python 块缓冲，那只是**当时那次测试**
的假阴性；换用 `ros2 topic list` 这个不经过缓冲的判据重测，**PC → 狗 的发现确实不通**，
而且一直不通。

真正的原因和 DDS 配置、QoS、RMW 全都无关，是**内核的多播出口**：

```bash
$ ip route get 239.255.0.1
multicast 239.255.0.1 dev enx0202355e3737 src 192.168.42.106
                                        ↑ 手机 USB 共享，不是 wlp132s0
```

主机的默认路由在上网那块网卡上（手机 USB），内核就把所有 239.x 多播从那儿发出去。
狗在 `wlan0` 上，永远收不到。而狗端的默认路由是指向 PC 的 `wlan0`，所以狗发的多播
PC 收得到 —— **一个方向通、一个方向不通，而 ping / ssh / scp 全部正常**。

对照实验（同一台机器、同一个组地址，只改出接口）：

| 发送方式 | 狗能否收到 |
|---|---|
| `IP_MULTICAST_IF = 10.42.0.1`（显式指定无线口） | **收到** 3/3 包 |
| 不指定，交给默认路由 | **0 包**，超时 |

修法是给发现用的那个组单独加一条路由，不动默认路由、不影响上网：

```bash
sudo ip route add 239.255.0.1/32 dev wlp132s0
```

`scripts/pc_hotspot.sh` 已经把这条加进流程（开热点时自动加，`--down` 时自动删）；
`link_probe.sh` 第 4 节会把这个出口打出来，指错就提示修法。

**试过但不行的方案**（省得再走一遍）：

| 方案 | 结果 |
|---|---|
| PC 端 `<Interfaces><NetworkInterface name="wlp132s0"/></Interfaces>` | 仍不通，多播没跟着走 |
| 两端 `<Peers>` 单播发现 + `AllowMulticast=false` | 不通（0.7 与 0.10 的端口推算对不上） |
| 两端 `ParticipantIndex=0` + 单播 Peer | 仍不通 |
| 两端都不配 `CYCLONEDDS_URI`（默认随机挑网卡） | 不通，狗端挑中 `eth0` |

**影响面**：只影响 PC → 狗 的交互话题（RViz 的 `/initialpose`、远程参数下发）。
点云是狗 → PC，控制指令走 ssh，**建图完全不受影响**。实测 `/flmap/cloud` 稳定 10.0 Hz。

---

## 7. 故障对照表

| 现象 | 最可能的原因 | 查法 |
|---|---|---|
| 狗端扫不到 SSID | 信道不匹配（2.4G-only 网卡）/ 热点没起 | `iw dev wlp132s0 info \| grep ssid` |
| 连上了但 ping 不通 | 狗端地址配错 / PC 防火墙 | 狗上 `ip -4 addr show wlan0` |
| **狗端本机有数据，主机 `topic hz` 说"未发布"** | **CycloneDDS 挑了错网卡** | 看 CLI 的 `selected arbitrarily` 那行；`bash scripts/dds_bind.sh pc` |
| ping 通、`ros2 topic list` 空 | DDS 多播被丢 / 绑错网卡 | 两边是否都设了 `CYCLONEDDS_URI`（应当都不设） |
| **话题看得见、`echo` 空** | **`ros2` CLI 输出被缓冲**（非网络问题） | 加 `PYTHONUNBUFFERED=1` 再试；本机自发自收也空就与链路无关 |
| `echo` 空，且本机自发自收也空 | QoS 不兼容（durability / reliability） | `ros2 topic info <t> --verbose` 看两侧 Reliability |
| 延迟周期性飙到 100 ms | 省电没关 | `iw dev wlan0 get power_save` |
| 吞吐只有几 Mbit/s | 信号弱 / 同信道干扰 | `iw dev wlan0 link` 看 signal 和 bitrate |
| 接上雷达后掉线 | USB 供电不足（网卡+雷达抢同一个控制器） | 狗端 `lsusb -t` 看拓扑 |
| `link_probe` 报"未关联任何 AP" | 主机在 AP 模式，`iw link` 恒为 Not connected | 看 `iw dev <if> info` 的 type，应为 AP；本节脚本已按类型分支 |
| **热点启动失败，NM 只报 `reason 'none'`** | **监管域掉回 `country 00`（5 GHz 全 PASSIVE-SCAN，内核不许发 beacon）** | `iw reg get`；再 `iw list \| grep -F "5220 MHz [44]"` 看该行是否还在 |

### 7.1 监管域为什么老是掉回 00

`iw reg set CN` **只是运行时设置，不持久**，而且被覆盖有两条独立路径：

1. **phy 级覆盖**：`iw list` 报的是每个 phy 自己的 regd。网卡关联到某个 AP 后，
   该 AP 的 country IE 会盖掉全局设置 —— 现场 `VGE_1`（ch52 / 80 MHz）就把 5 GHz
   功率从 23 dBm 压到 20 dBm，严重时 ch44 整行从 `iw list` 里消失。
   此时脚本会**误判成"监管域限制"**，但真正该做的是先断开 STA。
2. **重载模块**：`--reload` 卸载 rtw89 后 phy 重建，运行时设置一并清空。

所以 `pc_hotspot.sh` 现在的顺序是 **先断开 STA → 再 `iw reg set CN` → 再判定信道 → 起 AP**，
每次运行都重设一遍。想一劳永逸则在内核参数加一行（重启生效）：

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX="/&cfg80211.ieee80211_regdom=CN /' /etc/default/grub
sudo update-grub
```

注意：`cfg80211.ieee80211_regdom=CN` 只保证开机时是 CN，**仍会被 AP 的 country IE 覆盖**，
所以"先断 STA"这一步不能省。

---

## 8. 带宽够不够

点云本身只有约 1.3 Mbit/s（见 [05](05-bandwidth-tuning.md)）。5 GHz 40 MHz、
VHT-NSS2 在 1 m 内实测物理速率 400 Mbit/s，扣掉空口开销也够跑十几个点云流。

**真正的瓶颈不是带宽，是抖动。** 实时点云每帧要连续到达，40 ms 的抖动就会让
RViz 一顿一顿。所以：

- 必须关省电（脚本会做，但**重连后恢复 `on`**）
- 尽量 5 GHz，别用 2.4 GHz
- 信道避开现场已有的 AP

要把关省电做成持久的，在 PC 上：

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager
```

狗端同理。这一步等链路稳定后再做，免得先改了反而干扰排查。

---

## 9. 相关

- [02-network-and-dds.md](02-network-and-dds.md) — IP、DDS、QoS 的完整配置
- [05-bandwidth-tuning.md](05-bandwidth-tuning.md) — 1.3 Mbit/s 是怎么算出来的
- [06-troubleshooting.md](06-troubleshooting.md) — 有线链路的故障排查（逻辑通用）
