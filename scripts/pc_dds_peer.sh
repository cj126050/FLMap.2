#!/usr/bin/env bash
# =============================================================
#  pc_dds_peer.sh —— 生成 PC 侧的单播 DDS 配置（配对 dog_wlan_join.sh）
#
#  Wi-Fi 上多播经常被丢，CycloneDDS 默认的"多播发现"会表现为
#  「两边节点都起了，ros2 topic list 却是空的」。这份配置把发现改成
#  点对点单播，并且只绑 WiFi 网卡，避免发现包从有线口/手机网卡出去。
#
#  用法
#  ----
#    ./scripts/pc_dds_peer.sh                     # 生成 ~/dds_pc.xml
#    ./scripts/pc_dds_peer.sh --peer=10.42.0.18 --iface=wlp132s0
#    eval "$(./scripts/pc_dds_peer.sh --export)"  # 直接在当前 shell 生效
# =============================================================
set -uo pipefail

PEER="${PEER:-10.42.0.18}"
IFACE="${WIFI_IFACE:-wlp132s0}"
OUT="$HOME/dds_pc.xml"
EXPORT=0

for a in "$@"; do
    case "$a" in
        --peer=*)  PEER="${a#*=}" ;;
        --iface=*) IFACE="${a#*=}" ;;
        --out=*)   OUT="${a#*=}" ;;
        --export)  EXPORT=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

if [ ! -e "/sys/class/net/$IFACE" ]; then
    echo "网卡 $IFACE 不存在，用 --iface= 指定（iw dev 查）" >&2
    exit 1
fi

cat > "$OUT" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS>
  <Domain>
    <General>
      <Interfaces>
        <NetworkInterface name="$IFACE" priority="default" multicast="false"/>
      </Interfaces>
      <AllowMulticast>false</AllowMulticast>
    </General>
    <Discovery>
      <ParticipantIndex>auto</ParticipantIndex>
      <MaxAutoParticipantIndex>120</MaxAutoParticipantIndex>
      <Peers>
        <Peer address="$PEER"/>
      </Peers>
    </Discovery>
  </Domain>
</CycloneDDS>
XML

if [ "$EXPORT" -eq 1 ]; then
    printf 'export CYCLONEDDS_URI=file://%s\n' "$OUT"
    printf 'export ROS_DOMAIN_ID=42\n'
else
    printf '已写 %s\n' "$OUT"
    printf '  网卡 %s   Peer %s\n\n' "$IFACE" "$PEER"
    printf '在当前 shell 生效：\n'
    printf '  export CYCLONEDDS_URI=file://%s\n' "$OUT"
    printf '  export ROS_DOMAIN_ID=42\n'
fi
