#!/bin/bash
# =============================================================================
# deploy_app_tmp.sh — 把刚编译的 app 传到设备 /tmp 试跑,并做一轮自检。
#
# 为什么先 /tmp 而不是直接烧 flash:设备 /usr 是只读 squashfs(mtd6),试跑新版本不该先动
#   flash —— /tmp 是 27MB tmpfs,重启自动回滚成 flash 里的版本。自检通过后再用
#   imaging/flash_usr.sh 烧 mtd6 持久化。
#
# 真机踩出来的规矩(2026-09-24,都验证过原因):
#   1) **控制通道走 telnet(devctl.py),不走 HTTP /api/exec**。/api/exec 是阻塞的:上面跑
#      nc 拉文件会把 app 的 web 线程占住,之后所有 HTTP 请求排队超时(实测整片 web 卡死、
#      响应丢失);而且 app 被停掉时 HTTP 通道直接没了,telnetd 是系统服务一直在。
#   2) **拉取要在设备后台 setsid 跑**。telnet 前台跑 nc 会随会话关闭被 SIGHUP 掐断
#      (实测总在 ~1.1MB 处断,三次都一样)。
#   3) **先杀 app 再传**:tmpfs 页面不可回收,6MB 文件 + 运行中的 app(RAM 只剩 ~12MB)
#      会让传输中途失败;杀掉后 RAM/tmp/端口一起腾出来。
#   4) **杀进程要按两个名字杀**:试跑版进程名是 leelen_new(不是 leelen_intercom),
#      只 killall leelen_intercom 会漏掉它 → 8080 被占 → 新实例 bind errno=98 自杀。
#   5) 启动用 setsid 脱离会话;起之前等端口真空出来。
#
# 用法:
#   bash imaging/deploy_app_tmp.sh [设备IP]        # 部署 + 自检
#   bash imaging/deploy_app_tmp.sh --rollback      # 杀掉 /tmp 版,退回 flash 里的版本
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="192.168.50.239"; ROLLBACK=0
for a in "$@"; do
    case "$a" in
        --rollback) ROLLBACK=1 ;;
        *)          DEV="$a" ;;
    esac
done
APP="${IC_APP_BIN:-$ROOT/app/build/leelen_intercom}"
SEND="$ROOT/imaging/captures/tcpsend.py"
DEVC="$ROOT/imaging/devctl.py"
TMPD="$ROOT/imaging/output/_deploy"
PORT="${IC_DEPLOY_PORT:-9973}"
fsize() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }   # macOS 的 stat 无 -c
log() { printf '%s\n' "$*"; }
die() { printf '[ERR] %s\n' "$*"; exit 1; }
dev() { python3 "$DEVC" --wait "${1:-4}" "$2" 2>/dev/null | tr -d '\000\r' | tail -n +1; }
say_alive() { curl -s -m 5 "http://$DEV:8080/api/version" 2>/dev/null | grep -q version; }

if [ "$ROLLBACK" = 1 ]; then
    log "== 回滚:停 /tmp 版,起 flash 里的 /usr/bin/leelen_intercom =="
    dev 4 'rm -f /tmp/newapp.log; cd /tmp; setsid /usr/bin/leelen_intercom > /tmp/app.log 2>&1 & echo ROLLBACK_STARTED'
    for i in $(seq 1 15); do
        sleep 3
        say_alive && { log "web 已回: $(curl -s -m 3 http://$DEV:8080/api/version)"; exit 0; }
    done
    die "回滚后 web 仍未回;设备上看 /tmp/app.log"
fi

[ -f "$APP" ]  || die "找不到 app 产物:$APP (先跑 imaging/build_app_docker.sh)"
[ -f "$SEND" ] || die "找不到发送器:$SEND"
[ -f "$DEVC" ] || die "找不到控制工具:$DEVC"
EXPECT="$(md5sum "$APP" | cut -d' ' -f1)"
HOST="$(python3 -c "
import socket
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try: s.connect(('$DEV',9)); print(s.getsockname()[0])
except Exception: print('')
finally: s.close()")"
[ -n "$HOST" ] || die "无法判断本机到设备的路由源地址"
mkdir -p "$TMPD"

log "== 设备 $DEV   宿主 $HOST =="
log "== app $APP  md5 $EXPECT ($(fsize "$APP") B) =="

# --- 1) 需要时先杀 app 腾资源,再传 ------------------------------------------
ONDEV="$(dev 4 'md5sum /tmp/leelen_new 2>/dev/null' | grep -oE '[0-9a-f]{32}' | head -1)"
if [ "$ONDEV" = "$EXPECT" ]; then
    log; log "== [1/4] 设备上已有同版本(md5 一致),跳过传输 =="
else
    log; log "== [1/4] 停 app 腾出 RAM//tmp,再传 =="
    dev 5 'killall leelen_new leelen_intercom 2>/dev/null; sleep 2; rm -f /tmp/leelen_new; free | head -2'
    OK=0
    for t in 1 2 3; do
        p=$((PORT + t))
        (python3 "$SEND" "$APP" "$p" 400 > "$TMPD/send_$p.log" 2>&1 &)
        sleep 1
        dev 4 "killall nc 2>/dev/null; rm -f /tmp/leelen_new; setsid sh -c 'nc $HOST $p > /tmp/leelen_new' >/dev/null 2>&1 & echo NC_BG_STARTED"
        for i in $(seq 1 30); do            # 实测 ~60KB/s,6MB 约 95s
            sleep 5
            M="$(dev 4 'md5sum /tmp/leelen_new 2>/dev/null' | grep -oE '[0-9a-f]{32}' | head -1)"
            [ "$M" = "$EXPECT" ] && { OK=1; break; }
            S="$(dev 4 'wc -c < /tmp/leelen_new 2>/dev/null' | tr -dc 0-9)"
            [ "$((i % 3))" = 0 ] && log "   [$((i*5))s] 已收 ${S:-0} / $(fsize "$APP") B"
        done
        [ "$OK" = 1 ] && { log "   传输完整(md5 一致,尝试 $t)"; break; }
        log "   尝试 $t 未完成,重来"
        pkill -f "$SEND" 2>/dev/null; dev 4 'killall nc 2>/dev/null; true'; sleep 2
    done
    [ "$OK" = 1 ] || die "三次都没传完整(期望 $EXPECT);网络在截断,未启动新 app"
fi
dev 4 'chmod +x /tmp/leelen_new; md5sum /tmp/leelen_new'

# --- 2) 停旧实例 + 等端口释放 -------------------------------------------------
log; log "== [2/4] 停旧实例,等 8080 释放 =="
dev 5 'killall leelen_new leelen_intercom 2>/dev/null; sleep 2; true'
FREED=0
for i in $(seq 1 10); do
    sleep 2
    dev 4 'grep -qi 1F90 /proc/net/tcp && echo BUSY' | grep -q BUSY || { log "   8080 已释放(第 $((i*2))s)"; FREED=1; break; }
done
# ★2026-09-27 真机教训:会话进行中被 SIGTERM 的旧 app 可能卡在 teardown(vdec/VO/SDK)里不退出,
#   于是 8080 不放、单实例锁不松 → 新实例的 supervisor 永远"等它退出" → 设备变成**没有 app**
#   (web/telnet 都没人应答,只剩 ping),只能断电。所以这里必须升级到 SIGKILL:再脏也比哑掉好,
#   而且新版 app 已给 SIGTERM 加了 6s 兜底期限(见 main.c ic_term),正常情况走不到这一步。
if [ "$FREED" != 1 ]; then
    log "   8080 20s 未释放 → 有旧实例卡在退出路径,升级 SIGKILL"
    dev 5 'killall -9 leelen_new leelen_intercom 2>/dev/null; sleep 3; true'
    dev 4 'ps | grep -E "leelen" | grep -v grep'
    for i in $(seq 1 8); do
        sleep 2
        dev 4 'grep -qi 1F90 /proc/net/tcp && echo BUSY' | grep -q BUSY || { log "   SIGKILL 后 8080 已释放(第 $((i*2))s)"; FREED=1; break; }
    done
    [ "$FREED" = 1 ] || die "SIGKILL 后 8080 仍被占,别往下走了:先人工看设备(可能需断电重启)"
fi

# --- 3) 起新实例(setsid) + 等 web -------------------------------------------
log; log "== [3/4] 起 /tmp 版 =="
# IC_NO_AUDIO=1(宿主环境变量)透传给设备侧 app:诊断用,跳过 ak_ai/ak_ao(ADC DMA 不启)。
# 必须开机后第一次拉起就带——ak_pcm 的 DMA 一旦启动,app 死后也不会停。
NA=""
[ "${IC_NO_AUDIO:-}" = "1" ] && NA="IC_NO_AUDIO=1 "
dev 4 "rm -f /tmp/newapp.log; cd /tmp; ${NA}setsid /tmp/leelen_new > /tmp/newapp.log 2>&1 & echo STARTED"
UP=0
for i in $(seq 1 20); do
    sleep 3
    say_alive && { UP=1; log "   web 已回(第 $((i*3))s): $(curl -s -m 3 http://$DEV:8080/api/version)"; break; }
done
if [ "$UP" != 1 ]; then
    log "   起不来,日志尾部:"; dev 4 'grep -E "BIND|holds lock|ERR|fail" /tmp/newapp.log | tail -6'
    die "新 app 未起来。回滚:bash imaging/deploy_app_tmp.sh --rollback"
fi

# --- 4) 自检 -----------------------------------------------------------------
log; log "== [4/4] 功能自检 =="
log "   运行身份    : $(dev 4 'ls -l /proc/*/exe 2>/dev/null | grep -oE "/tmp/leelen_new|/usr/bin/leelen_intercom" | head -1')"
log "   /api/cameras: $(curl -s -m 8 "http://$DEV:8080/api/cameras" | head -c 220)"
log "   /api/stat   : $(curl -s -m 8 "http://$DEV:8080/api/stat" | head -c 160)"
log "   内核 oops   : $(dev 4 'dmesg | grep -icE "Oops|BUG:|panic"')  app SIGSEGV: $(dev 4 'grep -icE "FAULT|SIGSEGV" /tmp/newapp.log')"

curl -s -m 15 "http://$DEV:8080/api/snap" -o "$TMPD/screen.jpg"
log "   首页截图    : $TMPD/screen.jpg ($(fsize "$TMPD/screen.jpg") B)"
curl -s -m 10 -X POST "http://$DEV:8080/api/monitor" -d '{"open":1}' >/dev/null; sleep 3
curl -s -m 15 "http://$DEV:8080/api/snap" -o "$TMPD/screen_monitor.jpg"
log "   监控页截图  : $TMPD/screen_monitor.jpg ($(fsize "$TMPD/screen_monitor.jpg") B)"
curl -s -m 10 -X POST "http://$DEV:8080/api/monitor" -d '{"open":0}' >/dev/null

# 阻塞路径回归:起会话/挂断/解锁都不许把 web 线程占死(这是修过的 bug)
while IFS='|' read -r req body; do
    m="${req%% *}"; p="${req##* }"
    T0=$(date +%s); R="$(curl -s -m 12 -X "$m" "http://$DEV:8080$p" -d "$body" | head -c 80)"; T1=$(date +%s)
    V="$(curl -s -m 6 http://$DEV:8080/api/version)"; T2=$(date +%s)
    log "   $m $p -> $R (${T1}-${T0}s);随后 /api/version: $([ -n "$V" ] && echo "活着 $((T2-T1))s" || echo 无响应)"
done <<'EOF'
POST /api/sdp/start|{"ip":"192.168.50.254","peer":"0006-0002","kind":0}
POST /api/sdp/hangup|{}
POST /api/door/unlock|{"num":"0006-0002"}
EOF

log; log "================ 部署自检完成 ================"
log "  正在运行 /tmp/leelen_new (md5 $EXPECT);重启自动回滚成 flash 里的版本"
log "  看界面: open $TMPD/screen.jpg  /  open $TMPD/screen_monitor.jpg"
log "  持久化: bash imaging/flash_usr.sh $DEV     回滚: bash imaging/deploy_app_tmp.sh --rollback"