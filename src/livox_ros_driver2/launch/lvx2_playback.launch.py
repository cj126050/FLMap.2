import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    # 1. 指定你的 .lvx2 文件路径
    lvx_file_path = '/home/cj/data/b6_middle_mid360_scan/2026-10-14_17-50-20.lvx2'
    
    # 2. 指定配置文件路径
    config_file = os.path.join(
        get_package_share_directory('livox_ros_driver2'),
        'config',
        'lvx2_playback_config.json'
    )

    # 3. 创建驱动节点
    livox_driver_node = Node(
        package='livox_ros_driver2',
        executable='livox_ros_driver2_node',
        name='livox_lidar_publisher',
        output='screen',
        parameters=[
            {'data_src': 2},              # 2 代表文件回放模式
            {'lvx_file_path': lvx_file_path},
            {'xfer_format': 1},           # 1 代表 Livox CustomMsg
            {'publish_freq': 10.0},
            {'frame_id': 'livox_frame'},
            {'config_file': config_file}  # 传入配置文件
        ]
    )

    return LaunchDescription([livox_driver_node])
