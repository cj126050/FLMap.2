#!/usr/bin/env python3
"""把相机彩色图从 30 fps 降到 1 Hz 再发到 /calib/image。

为什么需要它：1280x720x3 = 2.76 MB/帧，30 fps 就是 82 MB/s。标定只要静止场景里的
几帧就够，直接录 30 fps 的彩色流在无线链路上根本传不回来。

QoS 必须用 RELIABLE：`ros2 bag record` 侧如果按 best_effort 订阅，配合默认的
volatile durability，很容易一帧都收不到（表现为 bag 里 /calib/image 0 帧）。
"""
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy, DurabilityPolicy
from sensor_msgs.msg import Image

SRC = "/camera/color/image_raw"
DST = "/calib/image"
PERIOD = 1.0  # 秒


class Relay(Node):
    def __init__(self):
        super().__init__("calib_img_relay")
        qos_out = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
            depth=5,
            durability=DurabilityPolicy.VOLATILE,
        )
        self.pub = self.create_publisher(Image, DST, qos_out)
        self.latest = None
        self.create_subscription(Image, SRC, self.on_img, 10)
        self.create_timer(PERIOD, self.on_timer)
        self.n_in = 0
        self.n_out = 0
        self.get_logger().info("%s -> %s @ %.1f Hz" % (SRC, DST, 1.0 / PERIOD))

    def on_img(self, msg):
        self.latest = msg
        self.n_in += 1

    def on_timer(self):
        if self.latest is None:
            self.get_logger().warning("还没收到相机图，等一下…", throttle_duration_sec=5.0)
            return
        self.pub.publish(self.latest)
        self.n_out += 1
        self.get_logger().info(
            "转发 #%d (%dx%d %s)  收到 %d 帧" % (
                self.n_out, self.latest.width, self.latest.height,
                self.latest.encoding, self.n_in),
            throttle_duration_sec=5.0)


def main():
    rclpy.init()
    node = Relay()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
