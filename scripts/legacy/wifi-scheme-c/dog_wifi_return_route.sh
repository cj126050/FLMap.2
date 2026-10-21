#!/usr/bin/env bash
# =============================================================
#  dog_wifi_return_route.sh —— 给拓展坞补一条「回程路由」
#
#  为什么需要它
#  ------------
#  实测：运控（192.168.12.1 / 192.168.123.161）会把 PC 的包转进 192.168.123.0/24，
#  但它做的是**纯转发，不是 NAT**。于是拓展坞收到的包源地址是 192.168.12.122，
#  而拓展坞的路由表里没有 192.168.12.0/24 —— 回复包交给默认网关 192.168.123.1，
#  那个网关是幽灵（ARP 不完整），包就这么丢了。
#
#  现象：PC 能 ping 通运控 .161（它自己回包，不经过转发），
#        但 ping 不通拓展坞 .18，也不通雷达 .20。
#
#  在狗上加这一条，回程就通了：
#     ip route add 192.168.12.0/24 via 192.168.123.161 dev eth0
#
#  注意 via 必须是 123.161（运控），不是 123.1。
#
#  用法（在拓展坞上执行）
#  --------------------
#    ssh unitree@192.168.123.18
#    sudo ./dog_wifi_return_route.sh            # 看一眼现状
#    sudo ./dog_wifi_return_route.sh --add      # 加路由（临时，重启失效）
#    sudo ./dog_wifi_return_route.sh --remove   # 删掉
#    sudo ./dog_wifi_return_route.sh --install  # 装成 systemd 服务，开机自动加
#    sudo ./dog_wifi_return_route.sh --uninstall
# =============================================================
set -uo pipefail

WIFI_NET="192.168.12.0/24"
CTRL="192.168.123.161"
IFACE="${DOG_IFACE:-eth0}"
UNIT=/etc/systemd/system/go2-wifi-return-route.service

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_d=$'\033[2m'; c_0=$'\033[0m'
sec() { printf '\n%s── %s%s\n' "$c_b" "$1" "$c_0"; }
ok()  { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"; }
bad() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1"; }
warn(){ printf '  %s!%s %s\n' "$c_y" "$c_0" "$1"; }
dim() { printf '     %s%s%s\n' "$c_d" "$1" "$c_0"; }

ACTION=show
for a in "$@"; do
    case "$a" in
        --add) ACTION=add ;;
        --remove) ACTION=remove ;;
        --install) ACTION=install ;;
        --uninstall) ACTION=uninstall ;;
        --show|"") ACTION=show ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "未知参数: $a"; exit 2 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    bad "需要 root： sudo $0 $*"
    exit 1
fi

show_state() {
    sec "1. 本机网络"
    if ip -4 -br addr show "$IFACE" 2>/dev/null | grep -q .; then
        ip -4 -br addr show "$IFACE" | sed 's/^/  /'
    else
        bad "$IFACE 上没有 IPv4 地址"
    fi
    printf '  默认路由: %s\n' "$(ip route | awk '/^default/{print; exit}')"

    sec "2. 转发开关（在运控上，这里是只读参考）"
    dim "本机 ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
    dim "本机不负责转发，转发是运控在做"

    sec "3. 回程路由"
    if ip route show "$WIFI_NET" | grep -q .; then
        ok "已存在： $(ip route show "$WIFI_NET" | head -1)"
    else
        warn "没有 $WIFI_NET 的回程路由 —— PC 走狗热点时 ping 不通本机"
    fi

    sec "4. 到运控是否可达（下一跳）"
    if ping -c 2 -W 1 "$CTRL" >/dev/null 2>&1; then
        ok "$CTRL 可达，可以作为下一跳"
    else
        bad "$CTRL 不可达 —— 运控没上电或网线没插"
    fi

    sec "5. systemd 服务"
    if [ -f "$UNIT" ]; then
        printf '  已安装: %s\n' "$UNIT"
        printf '  状态: %s\n' "$(systemctl is-enabled go2-wifi-return-route 2>/dev/null || echo unknown)"
    else
        dim "未安装（--install 可装，开机自动加路由）"
    fi
}

case "$ACTION" in
show)
    printf '%s\n' "============================================================"
    printf ' 拓展坞回程路由体检   %s\n' "$(date '+%F %T')"
    printf '%s\n' "============================================================"
    show_state
    sec "结论"
    if ip route show "$WIFI_NET" | grep -q .; then
        ok "回程路由齐了，PC 走无线应该能 ping 通 $(ip -4 -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)"
    else
        warn "缺回程路由，执行： sudo $0 --add"
    fi
    ;;
add)
    if ip route show "$WIFI_NET" | grep -q .; then
        ok "已经存在，不重复添加： $(ip route show "$WIFI_NET" | head -1)"
    elif ip route add "$WIFI_NET" via "$CTRL" dev "$IFACE" 2>/dev/null; then
        ok "已添加 $WIFI_NET via $CTRL dev $IFACE（重启失效）"
        dim "想持久化： sudo $0 --install"
    else
        bad "添加失败"
        dim "检查： ip link show $IFACE / ping $CTRL"
        exit 1
    fi
    sec "验证"
    dim "回到 PC（连着狗的热点）执行： ping -c3 192.168.123.18"
    ;;
remove)
    if ip route del "$WIFI_NET" 2>/dev/null; then ok "已删除 $WIFI_NET 的路由"
    else warn "没有可删的路由"; fi
    ;;
install)
    cat > "$UNIT" <<EOF
[Unit]
Description=Return route for Go2 AP clients ($WIFI_NET)
Documentation=file:///home/unitree/flmap2_ws/docs/09-wireless-link.md
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace $WIFI_NET via $CTRL dev $IFACE
ExecStop=/sbin/ip route del $WIFI_NET

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if systemctl enable --now go2-wifi-return-route >/dev/null 2>&1; then
        ok "已安装并启动： $UNIT"
        printf '  当前路由: %s\n' "$(ip route show "$WIFI_NET" | head -1)"
    else
        bad "安装后启动失败，检查： systemctl status go2-wifi-return-route"
        exit 1
    fi
    ;;
uninstall)
    systemctl disable --now go2-wifi-return-route >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
    ok "已卸载（路由本身若还在，用 --remove 删掉）"
    ;;
esac
