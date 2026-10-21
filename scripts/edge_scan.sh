#!/bin/bash
# =============================================================
#  edge_scan.sh —— PC 端一条命令跑完整条链路
#
#  链路：狗端起驱动/LIO/桥 → 录包 N 秒 → 停录 → 导出 PCD
#        → PCD + bag 拉回主机 → 校验点数与大小
#
#  和交互式控制台（edge_control.sh）的分工：
#    · 现场边走边看、要暂停/继续 → 用交互式控制台
#    · 只想按固定时长跑一趟、拿结果走人 → 用本脚本
#
#  ★ 本文件在 FLMap.2（无线包）和 FLMap.3（有线包）里是**同一份**。
#    目标地址与远端工作空间由 scripts/lib_link.sh 提供。
#
#  用法:
#    ./scripts/edge_scan.sh                 # 录 120 秒，结果放 ~/Desktop/FLMap
#    ./scripts/edge_scan.sh --secs 300      # 录 5 分钟
#    ./scripts/edge_scan.sh --no-view       # 不顺手开 RViz
#    ./scripts/edge_scan.sh --dest /data/fl  # 换落盘位置
#
#  为什么不用 `ssh edge_control.sh` + 管道喂 start/stop：
#    交互控制台靠 stdin 读命令，ssh 的 stdin 是管道，读到 EOF 会立刻
#    do_quit 把建图关掉；用 sleep 卡时序又会跟节点启动速度赛跑
#    （抢跑被当成"未知命令"，晚到被体检问答吃掉）。所以远端走 --auto。
# =============================================================

set -o pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib_link.sh
source "$REPO_DIR/scripts/lib_link.sh"

SECS=120
WITH_BAG=1
DEST="$HOME/Desktop/FLMap"
OPEN_VIEW=1

while [ $# -gt 0 ]; do
    case "$1" in
        --secs)    SECS="${2:-120}"; shift 2 ;;
        --no-bag)  WITH_BAG=0; shift ;;
        --dest)    DEST="${2:-$DEST}"; shift 2 ;;
        --no-view) OPEN_VIEW=0; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "未知参数: $1（--help 看用法）"; exit 2 ;;
    esac
done

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
say() { echo -e "${C}[scan]${N} $*"; }
ok()  { echo -e "${G}[ ok ]${N} $*"; }
warn(){ echo -e "${Y}[warn]${N} $*"; }
die() { echo -e "${R}[fail]${N} $*"; exit 1; }

# 允许外部追加 ssh 选项（换密钥、跳板机、指定 known_hosts 都靠它）
SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new)
[ -n "${FLMAP_SSH_OPTS:-}" ] && read -r -a _extra <<< "$FLMAP_SSH_OPTS" && SSH_OPTS+=("${_extra[@]}")
ssh_run() { ssh "${SSH_OPTS[@]}" "$@"; }

# ---- 1. 目标解析 + 连通性 ----
EDGE_HOST=$(link_resolve 10)
say "狗端 ${EDGE_HOST}（${LINK_KIND}：${LINK_DESC}）"
ping -c1 -W1 "$EDGE_HOST" >/dev/null 2>&1 || die "ping 不通 ${EDGE_HOST} —— 链路没起来，先跑 ./scripts/link_probe.sh"
ssh_run -o BatchMode=yes "unitree@${EDGE_HOST}" true 2>/dev/null || die "ssh 免密不通 —— 先 ssh-copy-id，或设 FLMAP_SSH_OPTS 指定密钥"
ok "ssh 免密可用"

# 远端工作空间由 lib_link.sh 决定（每个包有自己的默认值）。不存在时直接说清楚怎么办，
# 别让它走到底再报一句 "No such file or directory"，那种错要往回翻十几行才知道原因。
if ! ssh_run -o BatchMode=yes "unitree@${EDGE_HOST}" "test -d ${LINK_EDGE_WS}" 2>/dev/null; then
    die "狗端 ${LINK_EDGE_WS} 不存在 —— 先跑 ./scripts/deploy_edge.sh；或 EDGE_WS=<已有工作空间> 复用"
fi

# ---- 2. DDS 绑定（只在 view 模式有意义，这里统一先绑好）----
# CycloneDDS 在多网卡机器上会随机挑一张卡（主机有手机 RNDIS 那块），挑错就收不到点云。
if DDS_XML=$(bash "$REPO_DIR/scripts/dds_bind.sh" pc 2>/dev/null); then
    export CYCLONEDDS_URI="file://$DDS_XML"
fi
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-42}"
export RMW_IMPLEMENTATION="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
export ROS_LOCALHOST_ONLY=0

mkdir -p "$REPO_DIR/log" "$DEST"
LOG="$REPO_DIR/log/scan_$(date +%Y-%m-%d_%H-%M-%S).log"

# ---- 3. 可选：顺手把 RViz 开起来（窗口 C）----
VIEW_PID=""
if [ "$OPEN_VIEW" = "1" ] && [ -n "${DISPLAY:-}" ]; then
    # 启动会先等 /flmap/cloud，狗端还没 start 时必然超时 10 秒，属正常
    setsid nohup "$REPO_DIR/scripts/pc_view.sh" > "$REPO_DIR/log/pcview_last.log" 2>&1 &
    VIEW_PID=$!
    say "RViz 已拉起（PID ${VIEW_PID}，日志 log/pcview_last.log）"
fi

# ---- 4. 远端无人值守扫描 ----
ARGS=(--auto "$SECS")
[ "$WITH_BAG" = "0" ] && ARGS+=(--no-bag)
say "开始扫描 ${SECS}s（远端 edge_control ${ARGS[*]}），日志 ${LOG}"
echo "-------------------------------------------------------------"
# stdbuf：远端日志经 ssh 过来会被块缓冲，不加就只能等结束才看到输出
ssh_run "unitree@${EDGE_HOST}" \
    "stdbuf -oL -eL bash ${LINK_EDGE_WS}/scripts/edge_control.sh ${ARGS[*]}" 2>&1 |
    tee "$LOG" | sed -u 's/\x1b\[[0-9;]*m//g'
RC=${PIPESTATUS[0]}
echo "-------------------------------------------------------------"
[ "$RC" = "0" ] || die "远端扫描失败（exit ${RC}），看 ${LOG}"

TASK=$(grep -o 'TASK_DIR=[^ ]*' "$LOG" | tail -1 | cut -d= -f2)
# --no-bag 时远端不建任务目录（不录包就没有可导的东西），TASK_DIR 只是照样打印。
# 以前这里只在"TASK 为空"时才放行，于是 no-bag 会带着一个不存在的目录去 rsync，
# 报 "change_dir failed" 让人以为传输坏了。
if [ "$WITH_BAG" = "0" ]; then
    ok "只建图不录包（--no-bag），没有需要回传的文件"
    exit 0
fi
[ -n "$TASK" ] && [ "$TASK" != "none" ] || die "没拿到任务目录，看 ${LOG}"
say "任务目录 ${TASK}"

# ---- 5. 拉回主机 ----
name=$(basename "$TASK")
mkdir -p "$DEST/$name"
say "拉回 ${DEST}/${name}/（rsync 续传，断了重跑本脚本即可续）"
# 不用 --info=progress2：它靠 \r 刷同一行，tee 进日志后变成一团看不清的数字。
# 传输速率本来也不稳定，宁可安静点，最后打大小。
#
# --no-owner --no-group：`-a` 会尝试把远端的 unitree:unitree 属主也搬过来。
# 目标盘不支持 chown 时（容器 overlay、exFAT、部分网络盘）每个文件都报
# "chown … failed: Invalid argument"，而 rsync 最后退出码是 23 —— 看着像传输失败，
# 其实数据全在。拷到自己机器上用，属主本来就该是本地用户，没有保留的必要。
rsync -a --no-owner --no-group --partial --inplace -e "ssh ${SSH_OPTS[*]}" \
    "unitree@${EDGE_HOST}:${TASK}/" "$DEST/$name/"
RSYNC_RC=$?
# 23 = 传完了但有文件没完全传（极少数情况）。内容交给下面的逐文件校验去判。
[ "$RSYNC_RC" = "0" ] || [ "$RSYNC_RC" = "23" ] || die "rsync 失败（exit ${RSYNC_RC}）"

# ---- 6. 校验 ----
fail=0
for f in "$DEST/$name/map.pcd" "$DEST/$name/scan/metadata.yaml"; do
    [ -e "$f" ] && ok "$(basename "$(dirname "$f")")/$(basename "$f")  $(du -h "$f" | cut -f1)" || { warn "缺 $f"; fail=1; }
done
PCD="$DEST/$name/map.pcd"
if [ -e "$PCD" ]; then
    pts=$(sed -n 's/^POINTS //p' "$PCD" | head -1)
    ok "PCD 点数 ${pts:-?}（≈$(awk -v p="${pts:-0}" 'BEGIN{printf "%.1f", p/1e6}') M）"
    [ "${pts:-0}" -gt 1000 ] 2>/dev/null || { warn "点数异常偏少，可能雷达没出图"; fail=1; }
    # 远端大小对比：本地短了就是断点没补齐（scp 中途被杀过）
    rsize=$(ssh_run "unitree@${EDGE_HOST}" "stat -c %s '$PCD' 2>/dev/null" || true)
    lsize=$(stat -c %s "$PCD")
    if [ -n "$rsize" ] && [ "$rsize" != "$lsize" ]; then
        warn "本地 ${lsize} B ≠ 远端 ${rsize} B —— 重跑一次本脚本会续传补齐"
        fail=1
    else
        ok "PCD 大小与远端一致（${lsize} B）"
    fi
fi

echo
if [ "$fail" = "0" ]; then
    ok "全链路完成：${DEST}/${name}/"
else
    warn "跑完了但有告警，见上"
fi
[ -n "$VIEW_PID" ] && say "RViz 还在跑（kill ${VIEW_PID} 关掉）"
exit "$fail"
