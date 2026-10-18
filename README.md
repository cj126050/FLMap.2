# FLMap.2

**Split-architecture LiDAR-inertial mapping for the Unitree Go2 + Livox Mid360.**
Mapping runs on the robot's edge computer; RViz runs on your PC, over Wi-Fi.

`ROS 2 Foxy (edge)` · `ROS 2 Humble (PC)` · `Livox Mid360` · `FAST-LIO2` · `BSD-3-Clause`

> 中文文档见 [README_zh.md](README_zh.md)。本仓库的 `docs/` 用中文编写（目标使用者是中文社区），欢迎 PR 补英文翻译。

---

## Why a second version

The original [FLMap](https://github.com/cj126050/FLMap) architecture is the standard desktop setup:

```
Mid360 ──ethernet──▶ PC ──▶ livox driver ──▶ FAST-LIO2 ──▶ RViz
```

That works on a desk. It does not work on a quadruped:

* The robot's only spare Ethernet port is needed by the LiDAR itself, so the LiDAR can no longer
  share a cable with the PC.
* The operator has to stand next to the robot with a laptop — which defeats the point of a legged
  platform that is supposed to walk away from you.
* Streaming the raw registered cloud (`pcl::PointXYZINormal`, 48 B/point, ~20k points @10 Hz
  ≈ **77 Mbit/s**) does not survive a shared Wi-Fi channel.

FLMap.2 splits the pipeline at the right place: **compute stays next to the sensor, pixels stay
next to the human.**

```
   ┌──────────────────── Go2 (edge) ────────────────────┐        ┌──────── PC ────────┐
   │                                                    │        │                    │
   │  Mid360 ──▶ livox_ros_driver2 ──▶ FAST-LIO2        │        │  flmap_accumulator │
   │  100 Mbps        /livox/lidar       │              │  Wi-Fi │        │           │
   │                  /livox/imu         ▼              │        │        ▼           │
   │                             /cloud_registered      │        │   /flmap/map       │
   │                                     │              │        │        │           │
   │                                     ▼              │        │        ▼           │
   │                              flmap_bridge ─────────┼───────▶│      RViz2         │
   │                          (voxel+repack+throttle)   │  5 Hz  │                    │
   │                                     │              │ 33 kB  │                    │
   │                                     ▼              │        │                    │
   │                              /flmap/cloud ─────────┘        │                    │
   └────────────────────────────────────────────────────┘        └────────────────────┘
```

The trick that makes this cheap: the edge does **not** send a map. It sends one downsampled frame
at a time (33 kB), and the PC accumulates them into `/flmap/map` locally. Map growth costs zero
bandwidth.

| | Original FLMap | FLMap.2 |
|---|---|---|
| Where FAST-LIO2 runs | PC | Go2 dock (Orin Nano) |
| LiDAR cable goes to | PC | Go2 |
| Operator position | must be tethered | anywhere on the Wi-Fi |
| Link load | 77 Mbit/s (raw cloud) | **~1.3 Mbit/s** (measured, see below) |
| Map growth | free (local memory) | free (accumulated on PC) |

## Repository layout

```
FLMap.2/
├── src/
│   ├── FAST_LIO2_ROS2/      # upstream LIO core (+ gap-fix, unchanged)
│   ├── livox_ros_driver2/   # upstream Livox driver
│   ├── go2_fastlio/         # launch/config integration for the LIO
│   ├── flmap_bridge/        # ★ NEW  edge: voxel + repack + throttle  -> /flmap/cloud
│   ├── flmap_accumulator/   # ★ NEW  pc:   merge frames into a growing map -> /flmap/map
│   └── flmap_bringup/       # ★ NEW  launch files + RViz config for both sides
├── scripts/
│   ├── deploy_edge.sh       # rsync -> Go2, apply Foxy patches, build
│   ├── edge_control.sh      # interactive console on the robot (no RViz)
│   ├── pc_view.sh           # one-key remote RViz on the PC
│   ├── link_probe.sh        # 4-layer link diagnosis (phy -> net -> DDS -> app)
│   ├── patch_foxy.sh        # Humble -> Foxy source patches (idempotent)
│   ├── env_check.sh         # environment report
│   └── legacy/              # the old wired-to-PC scripts, kept for reference
├── config/
│   └── cyclonedds_unicast.xml.example   # optional: unicast-only DDS discovery
├── tools/
│   ├── fake_cloud.py        # synthetic /cloud_registered to test without a robot
│   └── bench_bridge.py      # measure real rate / bandwidth of any cloud topic
└── docs/
    ├── 01-architecture.md   # design decisions, data flow, bandwidth budget
    ├── 02-network-and-dds.md
    ├── 03-edge-deployment.md
    ├── 04-pc-visualization.md
    ├── 05-bandwidth-tuning.md
    ├── 06-troubleshooting.md
    ├── 07-gap-fix.md        # data-stream dropout resilience
    └── 08-hardware.md       # Mid360 mounting / wiring / IP config
```

## Quick start

**0. Prerequisites** — PC on Ubuntu 22.04 + ROS 2 Humble; Go2 dock reachable over Wi-Fi
(`ssh unitree@<edge-ip>`), with ROS 2 Foxy + Livox-SDK2 already installed on the robot.

**1. Build on the PC**

```bash
git clone https://github.com/cj126050/FLMap.2.git && cd FLMap.2
./setup.sh
```

**2. Push to the robot and build there** (applies the Foxy patches automatically)

```bash
./scripts/deploy_edge.sh                 # EDGE_HOST=... EDGE_USER=... EDGE_WS=...
```

**3. On the robot: start mapping** (no RViz, no display needed)

```bash
ssh unitree@<edge-ip>
cd ~/flmap_ws && ./scripts/edge_control.sh
flmap> start
```

**4. On the PC: watch it**

```bash
./scripts/pc_view.sh
```

If step 4 shows an empty RViz, run `./scripts/link_probe.sh` — it walks the stack bottom-up and
tells you which layer is broken.

## Measured performance

Same host, synthetic source that mimics FAST-LIO2's exact output geometry
(`tools/fake_cloud.py`), CycloneDDS, `ROS_DOMAIN_ID=42`:

| Topic | Points/frame | Bytes/point | Rate | Bandwidth |
|---|---|---|---|---|
| `/cloud_registered` (before bridge) | 20 000 | 48 | 10 Hz | **57–77 Mbit/s** |
| `/flmap/cloud` (after bridge) | 2 061 | 16 | 5 Hz | **1.3 Mbit/s** |
| `/flmap/map` (PC-local, 1 Hz) | grows | 16 | 1 Hz | not on the wire |

Downsampling ratio 10.3 % on that scene; real rooms land between 6 % and 20 %. Reproduce with:

```bash
ros2 run flmap_bridge flmap_bridge_node --ros-args -p stats_period:=10 &
python3 tools/fake_cloud.py --points 20000 --rate 10 &
python3 tools/bench_bridge.py --seconds 8
```

## Compatibility & honest limitations

* **Cross-distro DDS.** Edge is Foxy, PC is Humble. `sensor_msgs/PointCloud2`,
  `nav_msgs/Odometry`, `tf2_msgs/TFMessage` are wire-compatible, and both sides default to
  CycloneDDS here. That is the common case and works in practice — but if discovery fails while
  `ping` is fine, see the fallback in [docs/02-network-and-dds.md](docs/02-network-and-dds.md)
  (run a Foxy container on the PC, or record a bag and view it offline).
* **The edge has no display.** By design — there is no RViz on the robot.
* **Wi-Fi is a shared medium.** A congested 2.4 GHz channel will drop frames no matter what the
  bridge does. `docs/05-bandwidth-tuning.md` has a table of what to turn down, in what order.
* **The PC-side map is an accumulation, not the LIO's internal map.** It is built by merging
  streamed frames, so revisited areas are not de-duplicated until the memory cap triggers a global
  voxel dedupe. This is a visualization trade-off, not a mapping-accuracy one — the PCD exported
  on the robot is still the authoritative map.

## Credits

* [FAST_LIO2_ROS2](https://github.com/Vulcan-YJX/FAST_LIO2_ROS2) — LIO core
* [livox_ros_driver2](https://github.com/Livox-SDK/livox_ros_driver2) — Livox driver
* [Unitree Go2](https://www.unitree.com/go2) — the platform this was built for

Upstream packages keep their original BSD licenses. Everything added here is BSD-3-Clause.
