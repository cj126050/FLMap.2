// flmap_bridge_node.cpp
//
// Edge-side bridge: take FAST-LIO2's full-resolution registered cloud and turn it into
// a wireless-friendly stream.
//
// Why this node exists
// --------------------
// FAST-LIO2 publishes `/cloud_registered` as `pcl::PointXYZINormal`
// (x,y,z,pad,intensity,pad,normal[3],pad,curvature,pad = 48 B/point). With Mid360 at
// ~200k points/s (point_filter_num=1 -> ~20k points/frame @10 Hz) that is roughly
// 9.6 MB/s ≈ 77 Mbit/s of payload. A 5 GHz Wi-Fi link can survive that in a quiet lab,
// but it collapses the moment anyone else shares the channel, and every lost UDP
// fragment triggers a reliable-QoS retransmission storm.
//
// This node does three cheap things on the edge (where the data is already in cache):
//   1. voxel-grid downsample  (default 0.20 m)      -> typically 4-8x fewer points
//   2. repack to x,y,z,intensity (16 B/point)       -> 3x smaller per point
//   3. rate limit (default 5 Hz)                    -> 2x fewer messages
//
// Net effect for a typical indoor scan: ~77 Mbit/s -> ~3-6 Mbit/s. See
// docs/bandwidth-tuning.md for the numbers and the knobs.
//
// Deliberately dependency-free: only rclcpp + sensor_msgs, no PCL / Eigen / OpenMP.
// That keeps it buildable on the Go2 dock (Jetson Orin Nano, ROS 2 Foxy) and on a PC
// (ROS 2 Humble) without any version gymnastics.
//
// Author: FLMap.2 contributors
// License: BSD-3-Clause

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
#include <sensor_msgs/point_cloud2_iterator.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace flmap
{

// Accumulator for one voxel. We average instead of "first point wins" because the
// averaged centroid is visibly cleaner on thin structures (railings, chair legs)
// at the same bandwidth cost.
struct VoxelAcc
{
  float x = 0.0F;
  float y = 0.0F;
  float z = 0.0F;
  float i = 0.0F;
  std::uint32_t n = 0;
};

class BridgeNode : public rclcpp::Node
{
public:
  BridgeNode()
  : rclcpp::Node("flmap_bridge")
  {
    input_topic_ = declare_parameter<std::string>("input_topic", "/cloud_registered");
    output_topic_ = declare_parameter<std::string>("output_topic", "/flmap/cloud");
    voxel_leaf_ = declare_parameter<double>("voxel_leaf", 0.20);
    max_rate_hz_ = declare_parameter<double>("max_rate_hz", 5.0);
    // 允许比目标周期早 15% 发布。为什么要容差：真实链路（以及 Wi-Fi 抖动下的输入）
    // 帧间隔并不是均匀的。若严格用"间隔 >= 周期"判定，输入抖动时大量帧会被拒绝，
    // 实际输出频率会明显低于设定值（实测输入 7.5 Hz 抖动、目标 5 Hz 时只有 2.9 Hz）。
    // 加容差后等价于一个带信用额度的限流器，输出能贴着目标频率走。
    rate_tolerance_ = declare_parameter<double>("rate_tolerance", 0.85);
    max_points_ = declare_parameter<int>("max_points", 20000);
    range_min_ = declare_parameter<double>("range_min", 0.5);
    range_max_ = declare_parameter<double>("range_max", 40.0);
    keep_intensity_ = declare_parameter<bool>("keep_intensity", true);
    stats_period_ = declare_parameter<int>("stats_period", 60);  // frames between log lines

    // QoS 必须两端成对匹配。实测（CycloneDDS 0.10 / Humble）：
    //   发布 RELIABLE + 订阅 BEST_EFFORT  -> 收不到任何数据（不是"降级"，是压根不匹配）
    // FAST-LIO2 的 /cloud_registered 默认就是 RELIABLE，所以输入侧默认 reliable。
    // 输出侧也用 reliable：33 kB × 5 Hz 的重传代价远小于"RViz 默认按 Reliable 订阅却看不见"的坑。
    // 链路很差时可两边一起改成 best_effort（同时把 RViz 显示项的 Reliability Policy 也改掉）。
    input_reliability_ = declare_parameter<std::string>("input_reliability", "reliable");
    output_reliability_ = declare_parameter<std::string>("output_reliability", "reliable");

    if (voxel_leaf_ <= 0.0) {
      RCLCPP_WARN(get_logger(), "voxel_leaf <= 0 is invalid, falling back to 0.20 m");
      voxel_leaf_ = 0.20;
    }
    if (max_rate_hz_ <= 0.0) {
      max_rate_hz_ = 5.0;
    }
    min_period_ = 1.0 / max_rate_hz_;
    leaf_inv_ = 1.0 / voxel_leaf_;

    // Best-effort 适合丢包无所谓的实时可视化；reliable 则是为了和上下游严格匹配。
    // 见上面 input_reliability_ 的注释。
    auto sub_qos = makeQos(input_reliability_);
    auto pub_qos = makeQos(output_reliability_);

    sub_ = create_subscription<sensor_msgs::msg::PointCloud2>(
      input_topic_, sub_qos,
      std::bind(&BridgeNode::onCloud, this, std::placeholders::_1));
    pub_ = create_publisher<sensor_msgs::msg::PointCloud2>(output_topic_, pub_qos);

    grid_.reserve(1U << 15);

    RCLCPP_INFO(
      get_logger(),
      "flmap_bridge: %s -> %s | voxel %.2f m | <= %.1f Hz (tol %.2f) | <= %d pts | range %.1f-%.1f m | qos %s->%s",
      input_topic_.c_str(), output_topic_.c_str(), voxel_leaf_, max_rate_hz_, rate_tolerance_,
      max_points_, range_min_, range_max_, input_reliability_.c_str(), output_reliability_.c_str());
  }

private:
  void onCloud(const sensor_msgs::msg::PointCloud2::ConstSharedPtr msg)
  {
    // ---- 1. rate limit first: cheapest possible rejection -------------------
    const rclcpp::Time now = this->now();
    if (have_published_ && (now - last_pub_).seconds() < min_period_ * rate_tolerance_) {
      ++skipped_by_rate_;
      return;
    }

    if (msg->width * msg->height == 0U) {
      return;
    }

    const bool has_intensity = hasFloat32Field(*msg, "intensity") && keep_intensity_;

    // ---- 2. voxel accumulate ------------------------------------------------
    grid_.clear();
    std::uint32_t kept = 0;
    std::uint32_t capped = 0;

    sensor_msgs::PointCloud2ConstIterator<float> ix(*msg, "x");
    sensor_msgs::PointCloud2ConstIterator<float> iy(*msg, "y");
    sensor_msgs::PointCloud2ConstIterator<float> iz(*msg, "z");
    std::unique_ptr<sensor_msgs::PointCloud2ConstIterator<float>> ii;
    if (has_intensity) {
      ii = std::make_unique<sensor_msgs::PointCloud2ConstIterator<float>>(*msg, "intensity");
    }

    const std::size_t total = static_cast<std::size_t>(msg->width) * msg->height;
    const float r2_min = static_cast<float>(range_min_ * range_min_);
    const float r2_max = static_cast<float>(range_max_ * range_max_);

    for (std::size_t idx = 0; idx < total; ++idx) {
      const float x = ix[idx];
      const float y = iy[idx];
      const float z = iz[idx];
      if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
        continue;
      }
      const float r2 = x * x + y * y + z * z;
      if (r2 < r2_min || r2 > r2_max) {
        continue;
      }

      const std::int64_t kx = static_cast<std::int64_t>(std::floor(x * leaf_inv_));
      const std::int64_t ky = static_cast<std::int64_t>(std::floor(y * leaf_inv_));
      const std::int64_t kz = static_cast<std::int64_t>(std::floor(z * leaf_inv_));
      const std::int64_t key = packKey(kx, ky, kz);

      auto it = grid_.find(key);
      if (it == grid_.end()) {
        if (static_cast<int>(grid_.size()) >= max_points_) {
          ++capped;
          continue;
        }
        VoxelAcc acc;
        acc.x = x;
        acc.y = y;
        acc.z = z;
        acc.i = has_intensity ? (*ii)[idx] : 0.0F;
        acc.n = 1;
        grid_.emplace(key, acc);
      } else {
        VoxelAcc & acc = it->second;
        acc.x += x;
        acc.y += y;
        acc.z += z;
        if (has_intensity) {
          acc.i += (*ii)[idx];
        }
        ++acc.n;
      }
      ++kept;
    }

    if (grid_.empty()) {
      return;
    }

    // ---- 3. repack ----------------------------------------------------------
    auto out = std::make_unique<sensor_msgs::msg::PointCloud2>();
    out->header = msg->header;          // keep frame_id (usually "camera_init")
    out->header.stamp = now;            // publish time, not sensor time
    out->height = 1;
    out->width = static_cast<std::uint32_t>(grid_.size());
    out->is_bigendian = false;
    out->is_dense = true;

    sensor_msgs::PointCloud2Modifier modifier(*out);
    modifier.setPointCloud2Fields(
      4,
      "x", 1, sensor_msgs::msg::PointField::FLOAT32,
      "y", 1, sensor_msgs::msg::PointField::FLOAT32,
      "z", 1, sensor_msgs::msg::PointField::FLOAT32,
      "intensity", 1, sensor_msgs::msg::PointField::FLOAT32);
    modifier.resize(grid_.size());

    sensor_msgs::PointCloud2Iterator<float> ox(*out, "x");
    sensor_msgs::PointCloud2Iterator<float> oy(*out, "y");
    sensor_msgs::PointCloud2Iterator<float> oz(*out, "z");
    sensor_msgs::PointCloud2Iterator<float> oi(*out, "intensity");

    for (const auto & kv : grid_) {
      const VoxelAcc & acc = kv.second;
      const float inv_n = 1.0F / static_cast<float>(acc.n);
      *ox = acc.x * inv_n;
      *oy = acc.y * inv_n;
      *oz = acc.z * inv_n;
      *oi = has_intensity ? acc.i * inv_n : 0.0F;
      ++ox;
      ++oy;
      ++oz;
      ++oi;
    }

    pub_->publish(std::move(out));

    last_pub_ = now;
    have_published_ = true;
    ++frame_count_;

    // ---- 4. periodic reporter (for docs/bandwidth-tuning.md) ----------------
    if (stats_period_ > 0 && frame_count_ % static_cast<std::uint64_t>(stats_period_) == 0) {
      const double bytes = static_cast<double>(grid_.size()) * 16.0;
      const double kbps = bytes * max_rate_hz_ * 8.0 / 1000.0;
      RCLCPP_INFO(
        get_logger(),
        "in %zu pts -> out %zu pts (%.1f%%), ~%.0f kB/msg, ~%.1f Mbit/s @%.1f Hz%s",
        total, grid_.size(), 100.0 * static_cast<double>(grid_.size()) / static_cast<double>(total),
        bytes / 1000.0, kbps / 1000.0, max_rate_hz_,
        capped > 0 ? " [hit max_points cap]" : "");
    }
  }

  // 21 bits per axis, offset by 2^20 -> covers +-1.05e6 voxels (~+-200 km @0.2 m).
  static std::int64_t packKey(std::int64_t x, std::int64_t y, std::int64_t z)
  {
    constexpr std::int64_t kOffset = 1LL << 20;
    return ((x + kOffset) << 42) | ((y + kOffset) << 21) | (z + kOffset);
  }

  static bool hasFloat32Field(
    const sensor_msgs::msg::PointCloud2 & msg, const std::string & name)
  {
    for (const auto & f : msg.fields) {
      if (f.name == name) {
        return f.datatype == sensor_msgs::msg::PointField::FLOAT32;
      }
    }
    return false;
  }

  static rclcpp::QoS makeQos(const std::string & reliability)
  {
    rclcpp::QoS qos(rclcpp::KeepLast(1));
    if (reliability == "best_effort" || reliability == "besteffort") {
      qos.best_effort();
    } else {
      qos.reliable();
    }
    return qos.durability_volatile();
  }

  // parameters
  std::string input_topic_;
  std::string output_topic_;
  double voxel_leaf_ = 0.20;
  double max_rate_hz_ = 5.0;
  double rate_tolerance_ = 0.85;
  int max_points_ = 20000;
  double range_min_ = 0.5;
  double range_max_ = 40.0;
  bool keep_intensity_ = true;
  int stats_period_ = 60;
  std::string input_reliability_ = "reliable";
  std::string output_reliability_ = "reliable";

  // derived
  double min_period_ = 0.2;
  double leaf_inv_ = 5.0;

  // state
  std::unordered_map<std::int64_t, VoxelAcc> grid_;
  rclcpp::Time last_pub_;
  bool have_published_ = false;
  std::uint64_t frame_count_ = 0;
  std::uint64_t skipped_by_rate_ = 0;

  rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr sub_;
  rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr pub_;
};

}  // namespace flmap

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<flmap::BridgeNode>());
  rclcpp::shutdown();
  return 0;
}
