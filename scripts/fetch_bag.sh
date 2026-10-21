#!/usr/bin/env bash
# 把狗端已导出的任务目录（bag + map.pcd）拉回主机，并逐文件校验。
#
#   ./scripts/fetch_bag.sh                        # 取狗端最新的一个任务
#   ./scripts/fetch_bag.sh 2026-10-21_15-36-56    # 取指定时间戳（可只写后段，如 15-36-56）
#   ./scripts/fetch_bag.sh --list                 # 只列出狗端有哪些任务，不传
#   ./scripts/fetch_bag.sh --dest ~/FLMap --no-md5
#
# 为什么要有这个脚本：手敲
#   rsync -a --no-owner --no-group -e ssh unitree@10.42.0.18:~/bags/<TS> ~/Desktop/FLMap/
# 有两处极易错 —— 源和目标之间少一个空格（远端路径就被拼成
# "...56~/Desktop/FLMap"），以及漏掉 --no-owner --no-group（退出码 23 假报错）。
# 这里把空格固定下来，并在传完后做 md5 + 大小双重校验。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(dirname "$HERE")
# shellcheck source=lib_link.sh
source "$REPO_DIR/scripts/lib_link.sh"

DEST="$HOME/Desktop/FLMap"
WANT=""
LIST=0
MD5=1

while [ $# -gt 0 ]; do
    case "$1" in
        --dest)    DEST="${2:-$DEST}"; shift 2 ;;
        --no-md5)  MD5=0; shift ;;
        --list)    LIST=1; shift ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)        echo "未知参数: $1（--help 看用法）"; exit 2 ;;
        *)         WANT="$1"; shift ;;
    esac
done

G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
say()  { printf '%s[fetch]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
dim()  { printf '     %s%s%s\n' "$D" "$1" "$N"; }
die()  { bad "$*"; exit 1; }

SSH_OPTS=(-o ConnectTimeout=8 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new -o BatchMode=yes)
[ -n "${FLMAP_SSH_OPTS:-}" ] && read -r -a _extra <<< "$FLMAP_SSH_OPTS" && SSH_OPTS+=("${_extra[@]}")
ssh_run() { ssh "${SSH_OPTS[@]}" "$@"; }

printf '%s\n' "============================================================"
printf ' 取回狗端数据   %s\n' "$(date '+%F %T')"
printf '%s\n' "============================================================"

# ---- 1. 定位狗端 ----
EDGE_HOST=$(link_resolve 10)
say "狗端 ${EDGE_HOST}（${LINK_KIND}）"
ssh_run "unitree@${EDGE_HOST}" true 2>/dev/null \
    || die "ssh 不通 —— 先 ./scripts/link_probe.sh 看链路，或 ssh-copy-id unitree@${EDGE_HOST}"

# ---- 2. 选定任务 ----
TASKS=$(ssh_run "unitree@${EDGE_HOST}" 'ls -1t ~/bags 2>/dev/null' || true)
[ -n "$TASKS" ] || die "狗端 ~/bags 是空的 —— 还没跑过 edge_control.sh 的 start/stop"

if [ "$LIST" = "1" ]; then
    # 一次远端调用把全部任务的大小/PCD 是否导出一并取回。
    # 不要在 while read 循环里调 ssh：ssh 会吃掉循环的 stdin，只会跑第一个。
    n=$(printf '%s\n' "$TASKS" | wc -l | tr -d ' ')
    printf '\n狗端 ~/bags 下有 %s 个任务（新的在上）：\n' "$n"
    printf '  %-26s %8s  %s\n' "任务" "大小" "内容"
    ssh_run "unitree@${EDGE_HOST}" '
        for t in ~/bags/*/; do
            [ -d "$t" ] || continue
            n=$(basename "$t")
            s=$(du -sh "$t" 2>/dev/null | cut -f1)
            c=""
            [ -e "$t/map.pcd" ] && c="pcd $(stat -c %s "$t/map.pcd" 2>/dev/null | awk "{printf \"%.0fM\", \$1/1048576}")"
            ls "$t"scan/*.db3 >/dev/null 2>&1 && c="${c:+$c + }bag"
            printf "  %-26s %8s  %s\n" "$n" "${s:-?}" "${c:-空}"
        done | sort -r | head -20' </dev/null 2>/dev/null
    printf '\n取最新一个： ./scripts/fetch_bag.sh\n取指定一个： ./scripts/fetch_bag.sh <时间戳>\n'
    exit 0
fi

if [ -z "$WANT" ]; then
    TASK=$(printf '%s\n' "$TASKS" | head -1)
    say "未指定时间戳，取狗端最新的一个"
else
    # 允许只写后段（15-36-56 就能匹配 2026-10-21_15-36-56），减少手敲出错
    TASK=$(printf '%s\n' "$TASKS" | grep -F -- "$WANT" | head -1)
    [ -n "$TASK" ] || { bad "狗端没有匹配「$WANT」的任务"; dim "可用的： $(printf '%s\n' "$TASKS" | head -5 | tr '\n' ' ')"; exit 1; }
fi
ok "任务 ${TASK}"

# ---- 3. 传前统计 ----
REPORT=$(ssh_run "unitree@${EDGE_HOST}" \
    "cd ~/bags/$TASK 2>/dev/null || exit 0
     printf 'size=%s\n' \"\$(du -sh . | cut -f1)\"
     printf 'bytes=%s\n' \"\$(du -sb . | cut -f1)\"
     printf 'pcd=%s\n'  \"\$(stat -c %s map.pcd 2>/dev/null || echo 0)\"
     printf 'pcdmd5=%s\n' \"\$(md5sum map.pcd 2>/dev/null | cut -d' ' -f1)\"
     for d in scan/*.db3; do [ -e \"\$d\" ] && printf 'db3=%s\n' \"\$(stat -c %s \"\$d\")\" && printf 'db3md5=%s\n' \"\$(md5sum \"\$d\" | cut -d' ' -f1)\"; done" 2>/dev/null || true)
rget() { printf '%s\n' "$REPORT" | sed -n "s/^$1=//p" | head -1; }
R_SIZE=$(rget size); R_BYTES=$(rget bytes); R_PCD=$(rget pcd); R_PCDMD5=$(rget pcdmd5)
R_DB3=$(rget db3);   R_DB3MD5=$(rget db3md5)
[ "${R_PCD:-0}" -gt 0 ] 2>/dev/null || warn "狗端这份没有 map.pcd（可能只录了包没 stop 导出）"
dim "狗端 ${R_SIZE:-?}   pcd ${R_PCD:-0} B   db3 ${R_DB3:-0} B"

mkdir -p "$DEST"
# 空间预检：狗端单份 100 MB ~ 3 GB，/tmp 或小分区上跑到一半 "No space left" 很常见
if [ -n "$R_BYTES" ] && [ "$R_BYTES" -gt 0 ] 2>/dev/null; then
    # 别让 awk 算 $4*1024：结果超出 double 精度会打印成 8.2356e+11，bash 整数比较直接报错
    avail_kb=$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2{print $4}')
    avail=$(( ${avail_kb:-0} * 1024 ))
    if [ -n "$avail_kb" ] && [ "$avail" -lt "$R_BYTES" ]; then
        need=$(( (R_BYTES - avail) / 1048576 + 1 ))
        bad "空间不足：${DEST} 只剩 $((avail/1048576)) MB，这份要 $((R_BYTES/1048576)) MB（差约 ${need} MB）"
        dim "换目标目录： ./scripts/fetch_bag.sh $TASK --dest ~/Desktop/FLMap"
        dim "清狗端旧任务： ssh unitree@${EDGE_HOST} 'rm -rf ~/bags/<旧时间戳>'"
        exit 1
    fi
fi

say "拉回 ${DEST}/${TASK}/"
# 源末尾的 / 和后面那个空格必须都在：少了空格远端路径会被拼成 "<TS>~/Desktop/..."
rsync -a --no-owner --no-group --partial --inplace \
      -e "ssh ${SSH_OPTS[*]}" \
      "unitree@${EDGE_HOST}:~/bags/${TASK}/" "${DEST}/${TASK}/"
rc=$?
# 23：传完了但有文件没完全搬过来（属主/权限之类）。内容交给下面逐文件校验判。
[ "$rc" = "0" ] || [ "$rc" = "23" ] || die "rsync 失败（exit $rc）"

# ---- 4. 校验 ----
fail=0
L_PCD="$DEST/$TASK/map.pcd"
if [ "${R_PCD:-0}" -gt 0 ] 2>/dev/null; then
    if [ -e "$L_PCD" ]; then
        l_size=$(stat -c %s "$L_PCD")
        pts=$(sed -n 's/^POINTS //p' "$L_PCD" | head -1)
        if [ "$l_size" = "$R_PCD" ]; then
            ok "map.pcd 大小一致（${l_size} B，${pts:-?} 点）"
        else
            bad "map.pcd 大小不一致：本地 ${l_size} ≠ 远端 ${R_PCD}（重跑本脚本会续传）"
            fail=1
        fi
        if [ "$MD5" = "1" ] && [ -n "$R_PCDMD5" ]; then
            l_md5=$(md5sum "$L_PCD" | cut -d' ' -f1)
            [ "$l_md5" = "$R_PCDMD5" ] && ok "map.pcd md5 一致（${l_md5:0:8}…）" \
                                       || { bad "map.pcd md5 不一致"; fail=1; }
        fi
    else
        bad "缺 map.pcd"; fail=1
    fi
fi

L_DB3=$(ls "$DEST/$TASK"/scan/*.db3 2>/dev/null | head -1)
if [ -n "$L_DB3" ]; then
    l_size=$(stat -c %s "$L_DB3")
    if [ -n "$R_DB3" ] && [ "$l_size" != "$R_DB3" ]; then
        bad "bag 大小不一致：本地 ${l_size} ≠ 远端 ${R_DB3}"; fail=1
    else
        ok "bag 大小一致（${l_size} B）"
    fi
    if [ "$MD5" = "1" ] && [ -n "$R_DB3MD5" ]; then
        l_md5=$(md5sum "$L_DB3" | cut -d' ' -f1)
        [ "$l_md5" = "$R_DB3MD5" ] && ok "bag md5 一致（${l_md5:0:8}…）" \
                                   || { bad "bag md5 不一致"; fail=1; }
    fi
else
    warn "本地没有 .db3（狗端这份可能只导出了 PCD）"
fi

# ---- 5. 收尾 ----
echo
if [ "$fail" = "0" ]; then
    ok "完成：${DEST}/${TASK}/"
    dim "出预览图： /usr/bin/python3 ${REPO_DIR}/scripts/pcd_preview.py ${L_PCD:-<pcd>}"
    dim "查规范：   source /opt/ros/humble/setup.bash && /usr/bin/python3 ${REPO_DIR}/scripts/diag_bag_timing.py ${DEST}/${TASK}/scan"
else
    warn "有校验未通过，重跑本脚本会续传补齐（rsync --partial）"
fi
exit "$fail"
