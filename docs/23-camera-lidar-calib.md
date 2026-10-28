# 23 · 相机–雷达外参标定（direct_visual_lidar_calibration）

> 这份文档解决"相机和 MID360 之间的 6DoF 外参怎么标出来"。
> 工具链已在本机编译通过、整条链路跑通；但 2026-10-28 采的 `calib_01` 这一包
> **标不出可用结果**，本文把实测证据、根因和复采要求写在前面，命令写在后面。
> 不要跳过第 2 节直接照命令跑一遍又得到一堆散点。

---

## 1. 结论先行

| 项 | 状态 |
|---|---|
| DVLCalib 及依赖（Ceres / GTSAM+unstable / Iridescence / Sophus / nanoflann / json） | **已编译可用**，装到 `~/dvlc_deps`，标定器在 `~/dvlc_ws/install/` |
| 采集 → preprocess → calibrate → 投影验证 全链路 | **已跑通**（全程 ssh 遥控，人不用蹲在狗旁边） |
| `calib_01` 这一包能否标出外参 | **不能**。目标函数在全部朝向上是平的 |
| 需要做什么 | 按第 3 节重采一包，然后照第 4 节跑，20 分钟出结果 |

一句话根因：**相机和雷达的共享视野太小，而且共享面上的"图像亮度"和"雷达反射率"不相关**，
DVLCalib 依赖的 NID（归一化信息距离）没有被优化的方向。

---

## 2. 为什么 `calib_01` 标不出来（实测证据）

先排除数据本身的问题——这些都查过了，**数据是干净的**：

| 检查项 | 实测 | 判定 |
|---|---|---|
| 采集期间是否移动 | 前半程 vs 后半程点云，最佳对齐就是 yaw=0 / t=0，最近邻中位残差 24 mm | 静止，无抹动 |
| 点云方位覆盖 | 5° 分箱 72/72 全非空 | 完整 360° |
| 点云仰角 | −7.0° … +53.2° | 与 Mid360 规格一致 |
| 雷达反射率 | 0–181，166 级，std 38.9（非全零） | 有信息 |
| 图像质量 | 1280×720，均值 128.3，Laplacian 方差 705 | 清晰、纹理充足 |
| 图像/点云是否同一场景 | 全景图里的白柜子、深色窗帘、办公椅在相机画面里都能找到 | 同一房间 |

问题出在**目标函数**上：

| 量 | 实测 | 说明 |
|---|---|---|
| 全网格 NID（yaw 360°×5°，pitch ±40°×5°，roll ±30°×5°，12694 个合格姿态） | 最优 **0.889**，中位约 0.98 | NID∈[0,1]，0 才是对齐；0.89 约等于无关 |
| Ceres 残差 `f`（= NID²）从任何初值出发（BFGS） | 0.9768 … 0.988 | 几乎不动 |
| 联合直方图熵 `H_joint` | 5.31 nats（16×16 上限 5.545） | 联合分布近乎均匀 = 几乎独立 |
| 互信息 `MI` | 最优偏差校正后约 **0.33 nats** | 远低于可用标定所需的量级 |
| 落在画面内的点数占比 | 2 % … 22 %（取决于朝向） | 共享视野小 |
| 点云距离分布 | 中位 4.21 m，p90 6.50 m，最大 20.7 m | 落进画面的多是远墙和地面 |

最关键的证据：把 Nelder-Mead 步长从默认 `1e-3` 放大到 `0.4`（相当于 ±23°/±0.4 m）让它自由搜，
它确实把 cost 一路压到 **0**——但那是**退化解**：把绝大部分点投到画面外，直方图空了，NID 的分母趋零。
也就是说这个目标函数唯一的"改进方向"是**让重叠变少**，而不是让对齐变好。

补充：另外两个独立的几何目标（深度不连续落在图像边缘、深度边 vs 图像边的平均梯度）也都试了，
top-1 分别落在 yaw=−130° 和 yaw=+110°，前三名分差只有 4 分——同样不可信。
**结论：换成更弱的评分函数绕不过去，必须改数据。**

---

## 3. 复采要求（这一节最重要）

DVLCalib 是无靶标的强度互信息方法，它对场景的要求比"能看清"苛刻得多：

1. **把相机怼到有纹理的东西前面，1.5–3 m。** 海报、纸箱、椅子、桌子、贴胶带的墙都行。
   相机视线中心要落在这堆杂物上，不要对着空房间、大白墙、空旷地面。
2. **要有强反照率对比。** 同一片视野里既有很暗（黑箱、深色家具）又有很亮（白纸、浅色墙）的表面。
   这台机器出问题的正是"暗房间里靠灯光而不是靠反照率成像"，相机亮度跟雷达反射率对不上。
3. **让雷达在 1–3 m 内有东西。** Mid360 点云密度集中在仰角 0–20°，1 m 以内还会被
   preprocess 的 `--min_distance 1.0` 直接丢掉，所以近处要有实体表面。
4. **采 2–3 个不同视角。** 每个视角一包，`calib.json` 的 `meta.bag_names` 列全部包名，
   一次优化一起用，比单包稳得多。
5. **静止 10–15 s。** 相机固定曝光（关自动曝光），别让人在旁边走动。采完先跑静止检查再进 preprocess。
6. 相机、雷达话题与 `xfer_format:=0` 别改：`xfer_format:=1` 发的是 `CustomMsg`，preprocess 读不了。

---

## 4. 完整流程

### 4.1 狗端采集

```bash
# 在狗上，把 tools/cam_lidar_calib/ 拷到 ~/cam_lidar_calib/
cd ~/cam_lidar_calib
./dog_collect.sh calib_02 15        # 参数：包名，秒数
# 产出 /tmp/calib_bags/calib_02/（默认 ~110 MB / 15 s）
```

`dog_collect.sh` 内部起三样东西：`livox_ros_driver2_node`（`xfer_format:=0`）、
`realsense2_camera`（1280×720×30）、`img_relay.py`（把 30 fps 的彩色图降频到
`/calib/image` 1 Hz，否则 82 MB/s 传不回无线）。

### 4.2 拉回主机并预处理

```bash
scp -r unitree@192.168.123.18:/tmp/calib_bags/calib_02 ~/tmp/dvlc/bags/
cd ~/tmp/dvlc
./preprocess.sh          # 见 tools/cam_lidar_calib/preprocess.sh
```

预处理会打印 `lidar_points[0]:` 和 `LiDAR FoV:`；**只要 `calib_02/calib_02.ply` 和 `calib_02.png` 生成了就算过**。
（`LiDAR FoV` 那个数是凸包估出来的，Mid360 会报 173° 左右，是假象，不影响。）

### 4.3 初值

官方两条路：`initial_guess_auto`（要 SuperGlue + torch，未装）和 `initial_guess_manual`（GUI 拖拽）。
本机 GUI 窗口创建成 10×10 且被全屏窗口压住，**暂时用程序化初值**：

```bash
./nid_diag.py            # 带点数约束的 NID 全网格，挑出候选
./render_grid.py         # 把候选渲染成联系表，肉眼挑一个像的
```

把选中的姿态写进 `calib_data/calib.json` 的 `results.init_T_lidar_camera`
（**注意方向，见第 5 节第 1 条**）。可信的做法是等有显示器时用 `initial_guess_manual` 手拖。

### 4.4 优化

```bash
./calibrate.sh
# 等价于：
#   calibrate ~/tmp/dvlc/calib_data --background --auto_quit \
#             --registration_type nid_bfgs --nid_bins 16
```

结果写回 `calib_data/calib.json` 的 `results.T_lidar_camera`。**先看 Ceres 最后几行的 `f`**：
`f < 0.5` 才值得往下走；`f ≈ 0.98` 说明没收敛，别拿它当结果。

### 4.5 验证（必做）

```bash
./proj_check.py bags/calib_02 final_check.png <x y z qx qy qz qw>
```

外参差 1–2 cm 整幅画面就双重影，**不能只看标定报告的数字**。
把点云投回原图，看桌腿、墙角、柜子边是否重合；不重合就是没标好。

---

## 5. 五个坑

1. **`T_lidar_camera` 是 camera→lidar，不是 lidar→camera。**
   定义是 `p_lidar = T_lidar_camera · p_camera`；`calibrate.cpp` 里
   `init_T_camera_lidar = init_T_lidar_camera.inverse()`，代价函数用的是 `T_camera_lidar * point`。
   自己按 `p_cam = R·p_lidar` 算出来的旋转，写进 `init_T_lidar_camera` 必须**取转置**
   （四元数取共轭 `(-qx,-qy,-qz,qw)`）。这次就栽在这里，白跑了两轮 0.98。

2. **运行时两条 `LD_LIBRARY_PATH` 都要给**，少一条就 `cannot open shared object file`：

   ```bash
   export LD_LIBRARY_PATH=$HOME/dvlc_deps/lib:$HOME/dvlc_ws/install/direct_visual_lidar_calibration/lib:$LD_LIBRARY_PATH
   ```

3. **Ceres 打印的 `f` 是 NID²**，不是 NID。`f=0.977` 对应 NID 0.988。
   判断收敛看 NID：`NID = sqrt(f)`。

4. **Nelder-Mead 的默认步长 `1e-3` 对全局搜索没有意义**，在小范围内等于原地不动；
   但把它放大到 0.4 又会掉进"点全投出画面"的退化解。
   所以 `--registration_type nid_nelder_mead` 不能单独当判据，必须配 `proj_check.py` 肉眼确认。

5. **`preprocess` 默认 `--min_distance 1.0`**，1 m 以内的点全部丢弃。
   如果复采时贴得太近，会发现自己把有用的近景点全删了；必要时显式调小。

另外：`--data_path` 要传**包含 bag 目录的父目录**（如 `~/tmp/dvlc/bags`），不是 bag 目录本身；
`--camera_intrinsics` 是单数不加 s 的写法不对，正确是 `--camera_intrinsics`（复数），别写成 `--camera_intrinsic`。

---

## 6. 产物位置

| 东西 | 路径 |
|---|---|
| 依赖（Ceres/GTSAM/Iridescence…） | `~/dvlc_deps/{lib,include,bin}` |
| 标定器 6 个可执行文件 | `~/dvlc_ws/install/direct_visual_lidar_calibration/lib/direct_visual_lidar_calibration/` |
| 源码 | `~/dvlc_ws/src/direct_visual_lidar_calibration/` |
| 本次数据与全部诊断产物 | `~/tmp/dvlc/`（`calib_data/` 是预处理结果，`bags/` 是原始包） |
| 标定套件 | `tools/cam_lidar_calib/`（两个包内容一致） |
