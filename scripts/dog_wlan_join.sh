#!/usr/bin/env bash
# =============================================================
#  dog_wlan_join.sh —— 让狗端 wlan0 连上 PC 的热点（走一次有线）
#
#  前提
#  ----
#    1. PC 已开热点： sudo ./scripts/pc_hotspot.sh
#    2. PC 有线口已经能到狗： sudo ./scripts/dog_wlan_probe.sh --keep
#
#  它做什么
#  --------
#    · 狗端 wlan0 连上 PC 热点，配静态地址（默认 10.42.0.18/24）
#    · 网关指向 PC（10.42.0.1），这样狗端顺带恢复外网（PC 的 shared 模式做 NAT）
#    · 关无线省电、设成开机自动连
#    · 在狗端生成 dds_wifi.xml（只绑 wlan0，Peer 指 PC），避免发现包从 eth0 出去
#
#  为什么不用 DHCP
#  --------------
#  地址固定，EDGE_HOST 才不用每次改。10.42.0.18 故意和 eth0 的 123.18 尾号一致。
#
#  用法
#  ----
#    sudo ./scripts/dog_wlan_join.sh
#    sudo ./scripts/dog_wlan_join.sh --ssid=FLMap3 --pass=flmap2026 --ip=10.42.0.18
# =============================================================
set -uo pipefail

HOST_IF="${HOST_IF:-enp131s0}"
HOST_IP="192.168.123.10"
EDGE="192.168.123.18"
EDGE_USER="${EDGE_USER:-unitree}"
SSID="${SSID:-FLMap3}"
PASS="${PASS:-flmap2026}"
DOG_IP="${DOG_IP:-10.42.0.18}"
PC_IP="${PC_IP:-10.42.0.1}"

for a in "$@"; do
    case "$a" in
        --ssid=*) SSID="${a#*=}" ;;
        --pass=*) PASS="${a#*=}" ;;
        --ip=*)   DOG_IP="${a#*=}" ;;
        --pc=*)   PC_IP="${a#*=}" ;;
        --iface=*) HOST_IF="${a#*=}" ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
sec()  { printf '\n%s── %s%s\n' "$c_b" "$1" "$c_0"; }
ok()   { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
dim()  { printf '     %s%s%s\n' "$c_d" "$1" "$c_0"; }

[ "$(id -u)" -eq 0 ] || { bad "需要 root：sudo $0 $*"; exit 1; }

# sudo 下 HOME 会变成 /root，ssh 找不到用户自己的密钥 → 「ping 通但 ssh 不通」
REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
[ -n "${REAL_HOME:-}" ] || REAL_HOME="$HOME"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$REAL_HOME/.ssh/known_hosts")
[ -f "$REAL_HOME/.ssh/id_ed25519" ] && SSH_OPTS+=(-i "$REAL_HOME/.ssh/id_ed25519")

printf '%s\n' "============================================================"
printf ' 狗端接入 PC 热点   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ------------------------------------------------ 1. 有线通道
sec "1. 经有线到狗"
if ! ping -c 2 -W 2 "$EDGE" >/dev/null 2>&1; then
    # 可能是 PC 有线口还没配地址，顺手补上
    if [ "$(cat /sys/class/net/$HOST_IF/carrier 2>/dev/null || echo 0)" = "1" ]; then
        ip link set "$HOST_IF" up
        ip addr replace "$HOST_IP/24" dev "$HOST_IF"
        warn "有线口没地址，已临时补 $HOST_IP/24"
        sleep 1
    fi
fi
ping -c 2 -W 2 "$EDGE" >/dev/null 2>&1 || {
    bad "$EDGE 不通 —— 先插网线并跑 sudo ./scripts/dog_wlan_probe.sh --keep"
    exit 1
}
ok "有线到 $EDGE 通"

SSH_BASE=(ssh "${SSH_OPTS[@]}" "$EDGE_USER@$EDGE")
timeout 10 "${SSH_BASE[@]}" true 2>/dev/null || { bad "ssh 不通"; exit 1; }
ok "ssh 可用"

if ! timeout 10 "${SSH_BASE[@]}" 'command -v nmcli >/dev/null' 2>/dev/null; then
    bad "狗端没有 nmcli（NetworkManager 没装？）"
    dim "确认： ssh $EDGE_USER@$EDGE 'which nmcli; systemctl is-active NetworkManager'"
    exit 1
fi

if ! timeout 10 "${SSH_BASE[@]}" 'sudo -n true' 2>/dev/null; then
    bad "狗端 sudo 需要密码，脚本没法自动跑"
    dim "一次配好免密（会提示输一次狗端密码）："
    dim "  ssh -t $EDGE_USER@$EDGE \"echo '$EDGE_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/010-$EDGE_USER >/dev/null && sudo chmod 440 /etc/sudoers.d/010-$EDGE_USER && echo SUDO_OK\""
    dim "配好后重跑本脚本即可"
    exit 1
fi
ok "狗端 sudo 免密可用"

# ------------------------------------------------ 2. 狗端网卡
sec "2. 狗端网卡"
WLAN=$(timeout 15 "${SSH_BASE[@]}" 'for w in /sys/class/net/*; do [ -e "$w/wireless" ] && basename "$w"; done' 2>/dev/null | head -1)
if [ -z "$WLAN" ]; then
    bad "狗端没有无线接口 —— 网卡没被识别，先跑 ./scripts/dog_wlan_probe.sh 查原因"
    exit 1
fi
ok "无线接口 $WLAN"
timeout 10 "${SSH_BASE[@]}" "iw dev $WLAN link 2>/dev/null | head -2" 2>/dev/null | sed 's/^/     /'

# ------------------------------------------------ 3. 连热点
sec "3. 连接热点 $SSID"
OUT=$(timeout 140 "${SSH_BASE[@]}" "SSID='$SSID' PASS='$PASS' WLAN='$WLAN' DOGIP='$DOG_IP' PCIP='$PC_IP' bash -s" <<'EOS' 2>&1
set -u
sudo nmcli device set "$WLAN" managed yes 2>/dev/null
# 热点刚起来时 beacon 可能还没发出来（NM 显示 completed 后还要 1~3 秒），
# 而 rtw89 的 AP 在长时间无客户端时又会静默，所以不能扫一次就判死：
# 每 4 秒重扫一次，最多 10 次（≈40 秒窗口）。
for i in 1 2 3 4 5 6 7 8 9 10; do
    sudo nmcli device wifi rescan ifname "$WLAN" 2>/dev/null
    sleep 4
    if sudo nmcli -t -f SSID device wifi list ifname "$WLAN" 2>/dev/null | grep -qx "$SSID"; then
        echo "SCAN_HIT 第 $i 次扫描命中"
        break
    fi
    echo "SCAN_RETRY 第 $i 次未出现"
    if [ "$i" -eq 10 ]; then
        echo "SCAN_MISS"
        exit 11
    fi
done
sudo nmcli connection delete flmap-wifi 2>/dev/null
sudo nmcli connection add type wifi ifname "$WLAN" con-name flmap-wifi ssid "$SSID" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS" \
    ipv4.method manual ipv4.addresses "$DOGIP/24" ipv4.gateway "$PCIP" \
    connection.autoconnect yes >/dev/null 2>&1 || { echo "ADD_FAIL"; exit 12; }
sudo nmcli connection up flmap-wifi >/dev/null 2>&1 || { echo "UP_FAIL"; exit 13; }
sudo iw dev "$WLAN" set power_save off 2>/dev/null
sleep 2
echo "LINK_OK"
ip -4 -o addr show dev "$WLAN" | awk '{print "ADDR=" $4}'
EOS
)
printf '%s\n' "$OUT" | sed 's/^/     /'

if printf '%s' "$OUT" | grep -q "SCAN_MISS"; then
    bad "狗端扫不到 $SSID"
    # 先给出狗端真实的扫描画像：能看见多少 5G / 2.4G，判断是"收不到"还是"扫不到"
    N5=$(timeout 25 "${SSH_BASE[@]}" "sudo -n iw dev $WLAN scan 2>/dev/null | grep -c 'freq: 5' || true" 2>/dev/null)
    N2=$(timeout 25 "${SSH_BASE[@]}" "sudo -n iw dev $WLAN scan 2>/dev/null | grep -cE 'freq: 24' || true" 2>/dev/null)
    dim "狗端本次扫描：5G 频点 $N5 个，2.4G 频点 $N2 个"
    if [ "${N5:-0}" -gt 0 ]; then
        dim "→ 5G 接收正常，说明热点在该信道上没有 beacon 或信号过强被压制"
    else
        dim "→ 狗端一个 5G 都收不到，先查监管域： iw reg get"
    fi
    dim "首选处置（自动逐个信道试，并从狗端验证）："
    dim "    sudo ./scripts/ap_chan_probe.sh"
    dim "手动确认热点状态（注意用无线口，不是有线口）："
    dim "    iw dev ${WIFI_IFACE:-wlp132s0} info | grep -E 'ssid|type|channel'"
    dim "近距离饱和时把狗挪到 1.5–2 m 外，或 sudo ./scripts/ap_chan_probe.sh --tx=300"
    exit 1
elif ! printf '%s' "$OUT" | grep -q "LINK_OK"; then
    bad "连接失败（看上面输出）"
    dim "手动观察： ssh $EDGE_USER@$EDGE 'sudo nmcli device wifi list; sudo nmcli connection up flmap-wifi'"
    exit 1
fi
ok "wlan0 已连上 $SSID，地址 $DOG_IP"

# ------------------------------------------------ 4. DDS 配置
sec "4. 狗端 DDS 绑定"
timeout 20 "${SSH_BASE[@]}" "WLAN='$WLAN' PCIP='$PC_IP' bash -s" <<'EOS' 2>&1 | sed 's/^/     /'
cat > "$HOME/dds_wifi.xml" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS>
  <Domain>
    <General>
      <Interfaces>
        <NetworkInterface name="$WLAN" priority="default" multicast="false"/>
      </Interfaces>
      <AllowMulticast>false</AllowMulticast>
    </General>
    <Discovery>
      <ParticipantIndex>auto</ParticipantIndex>
      <MaxAutoParticipantIndex>120</MaxAutoParticipantIndex>
      <Peers>
        <Peer address="$PCIP"/>
      </Peers>
    </Discovery>
  </Domain>
</CycloneDDS>
XML
echo "已写 $HOME/dds_wifi.xml"
grep -E "NetworkInterface|Peer address" "$HOME/dds_wifi.xml"
EOS

# ------------------------------------------------ 5. 验证
sec "5. 验证"
if ping -c 3 -W 2 "$DOG_IP" >/dev/null 2>&1; then
    ok "$DOG_IP 可达"
    if timeout 8 "${SSH_BASE[@]}" true 2>/dev/null; then
        ok "有线 ssh 仍在（配完可以拔网线了）"
    fi
else
    warn "$DOG_IP 暂时 ping 不通 —— 可能狗端默认路由还没切"
    dim "等 5 秒再试： ping -c3 $DOG_IP"
fi

sec "下一步（拔掉网线）"
dim "1) 拔网线，然后："
dim "     ping -c3 $DOG_IP && ssh $EDGE_USER@$DOG_IP"
dim "2) 狗端启动前加： export CYCLONEDDS_URI=file://\$HOME/dds_wifi.xml"
dim "3) PC 侧也用单播（同一个 Peer 表，只是网卡和地址互换）："
dim "     ./scripts/pc_dds_peer.sh"
dim "4) 之后所有脚本： EDGE_HOST=$DOG_IP ./scripts/link_probe.sh"
