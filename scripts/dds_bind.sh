#!/bin/bash
# =============================================================
#  dds_bind.sh —— 生成"只绑一张网卡"的 CycloneDDS 配置
#
#  为什么需要：CycloneDDS 在多网卡机器上会**自己挑一张**，日志里写
#      using network interface eth0 (udp/192.168.123.18)
#      selected arbitrarily from: eth0, docker0, wlan0
#  "arbitrarily" 就是字面意思。挑错卡时多播发现只在那一段上发，
#  对面根本收不到 —— 现象和"没启动"一模一样：
#  ros2 topic hz 报 "does not appear to be published yet"，而狗端本机是好的。
#
#  ★ 本文件与链路类型无关：选哪张卡由"到链路目标的路由"决定，
#    目标地址来自 scripts/lib_link.sh。所以有线包/无线包共用同一份。
#
#  用法：
#      bash scripts/dds_bind.sh pc             # 主机侧
#      bash scripts/dds_bind.sh dog            # 狗端
#      bash scripts/dds_bind.sh pc --iface enp131s0
#      EVAL=$(bash scripts/dds_bind.sh pc)     # 只打印 xml 路径
#
#  成功时把 xml 路径打到 stdout（--print 时打 export 语句），失败退出码 1。
#  xml 用的是 CycloneDDS 0.7 就认的 <NetworkInterfaceAddress>，
#  0.10 也接受（已实测），所以两侧共用同一份模板。
# =============================================================

set -o pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_DIR/scripts/lib_link.sh" ]; then
    # shellcheck source=lib_link.sh
    source "$REPO_DIR/scripts/lib_link.sh"
fi

ROLE="${1:-}"; shift || true
IFACE=""; PRINT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="${2:-}"; shift 2 ;;
        --print) PRINT=1; shift ;;
        *) shift ;;
    esac
done

if [ -z "${EDGE_HOST:-}" ]; then
    if declare -F link_resolve >/dev/null 2>&1; then
        EDGE_HOST=$(link_resolve)
    fi
fi
OUT="$HOME/dds_flmap.xml"

# 网卡名 → 第一个 IPv4 地址
addr_of() { ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | head -1; }

pick_iface() {
    local n
    # 1) 到链路目标的路由 —— 最可靠：链路由 lib_link 定义，路由由内核算。
    #    "local … dev lo" 说明目标就是本机自己（狗端跑这个脚本时必然如此），
    #    lo 不能拿去绑 DDS，落到下面按网段兜底。
    n=$(ip route get "$EDGE_HOST" 2>/dev/null |
        awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ "$n" = "lo" ] && n=""
    if [ -n "$n" ] && [ -e "/sys/class/net/$n" ]; then
        echo "$n"; return 0
    fi
    # 2) 兜底：本机持有目标网段地址的那张卡
    for d in /sys/class/net/*; do
        [ -e "$d" ] || continue
        n=$(basename "$d")
        case "$n" in lo|docker*|veth*|br-*|dummy*|can*|usb*) continue ;; esac
        case "$(addr_of "$n")" in $LINK_LOCAL_PREFIX*) echo "$n"; return 0 ;; esac
    done
    return 1
}

if [ -z "$IFACE" ]; then
    case "$ROLE" in
        pc|dog) IFACE=$(pick_iface) ;;
        *) echo "用法: $0 pc|dog [--iface NAME] [--print]" >&2; exit 2 ;;
    esac
fi

if [ -z "$IFACE" ] || [ ! -e "/sys/class/net/$IFACE" ]; then
    echo "找不到可用网卡（role=$ROLE, iface=${IFACE:-空}, 目标=${EDGE_HOST:-空}）" >&2
    exit 1
fi

IP=$(addr_of "$IFACE")
PKG=$(basename "$REPO_DIR")
cat > "$OUT" <<XML
<?xml version="1.0" encoding="UTF-8" ?>
<!-- 由 ${PKG}/scripts/dds_bind.sh 生成（role=$ROLE, iface=$IFACE${IP:+, ip=${IP%/*}}） -->
<!-- 只绑一张网卡，禁止 CycloneDDS "selected arbitrarily" 挑错网段 -->
<CycloneDDS>
  <Domain>
    <General>
      <NetworkInterfaceAddress>$IFACE</NetworkInterfaceAddress>
    </General>
  </Domain>
</CycloneDDS>
XML

if [ "$PRINT" = "1" ]; then
    printf 'export CYCLONEDDS_URI=file://%s\n' "$OUT"
else
    echo "$OUT"
fi
