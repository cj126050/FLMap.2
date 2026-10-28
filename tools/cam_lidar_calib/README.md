# tools/cam_lidar_calib — 相机–雷达外参标定套件

配套文档：`docs/23-camera-lidar-calib.md`（先读它，里面有为什么这么做的实测依据）。

基于 [direct_visual_lidar_calibration](https://github.com/koide3/direct_visual_lidar_calibration)
（koide3，无靶标强度互信息方法）。

## 文件

| 文件 | 在哪跑 | 作用 |
|---|---|---|
| `dog_collect.sh` | 狗 | 起 MID360(`xfer_format:=0`)+D435i，降频图像并录包 |
| `img_relay.py` | 狗 | `/camera/color/image_raw` 30fps → `/calib/image` 1Hz |
| `qos.yaml` | 狗 | bag record 的 QoS 覆盖（缺它 `/calib/image` 会 0 帧） |
| `check_static.py` | 主机 | 判静止：前后各累积数秒比体素重叠 |
| `preprocess.sh` | 主机 | bag → `calib_data/`（ply + png + calib.json） |
| `nid_diag.py` | 主机 | 带点数约束的 NID 全网格，诊断目标函数是否有信号 |
| `render_grid.py` | 主机 | 把若干候选外参渲染成联系表，肉眼挑初值 |
| `calibrate.sh` | 主机 | 跑 NID 优化，打印 `f` 和 `T_lidar_camera` |
| `proj_check.py` | 主机 | **验证**：把点云按外参投回原图，肉眼看是否重合 |

## 顺序

```
狗:   ./dog_collect.sh calib_02 15
主机: scp -r unitree@<狗IP>:/tmp/calib_bags/calib_02 ~/tmp/dvlc/bags/
      ./check_static.py ~/tmp/dvlc/bags/calib_02      # 必须判静止
      ./preprocess.sh                                 # 出 calib_data/
      ./nid_diag.py                                   # 目标函数有没有信号？
      ./render_grid.py                                # 挑初值，写进 calib.json
      ./calibrate.sh                                  # f < 0.5 才算收敛
      ./proj_check.py <bag> out.png <t q>             # 肉眼验证，必做
```

## 两条硬规矩

1. `T_lidar_camera` 是 **camera→lidar**：`p_lidar = T_lidar_camera · p_camera`。
   自己按 `p_cam = R · p_lidar` 算的旋转，写进 `init_T_lidar_camera` 要**取转置**。
2. 运行时 `LD_LIBRARY_PATH` 两条都要给：`~/dvlc_deps/lib` **和**
   `~/dvlc_ws/install/direct_visual_lidar_calibration/lib`。
