#!/bin/bash
# =============================================================================
# deploy_theme.sh — 把主题素材恢复到设备 /data/theme/theme_default(回落位)。
#
# 2026-09-28 晚起:主题主落点已改 **/usr/share/theme_default**(随 app 分区发布,
#   ic_theme_resolve 主落点;实测挪走 /data 副本后 /bg 照常出图)。/data 副本降级为
#   回落/手工覆盖位 —— 本脚本仅用于应急补缺失 key 或临时覆盖验证,日常不需要跑。
#
# 背景(2026-09-28):设备 /data(mtd8, yaffs2)只剩 lost+found,主题目录整体丢失 →
#   首页实体图标全部回落成 LV_SYMBOL_HOME(房子字形)。/data 整卷被清空的既往原因:
#   mtd8 是 yaffs2,而 release 管线产的是 data.jffs2,烧进 DATA 分区 = 空卷
#   (见 memory「dtb-panel-and-vendor-incompat」)。本脚本即恢复手段。
#
# 用法:  bash imaging/deploy_theme.sh [设备IP]
# 素材:  imaging/inputs/theme_default_dedup.tgz(772KB,311 张 PNG + config.json)
# 落点:  /data/theme/theme_default/{config.json,homepage/...}
# 传输:  captures/tcpsend.py + 设备 nc(同 deploy_app_tmp.sh 规矩:后台 setsid 拉取)。
#        设备无 gzip applet → 先在 Mac 解包成裸 tar 再传,tar xf 落盘。
# =============================================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="${1:-192.168.50.239}"
TGZ="$ROOT/imaging/inputs/theme_default_dedup.tgz"
SEND="$ROOT/imaging/captures/tcpsend.py"
DEVC="$ROOT/imaging/devctl.py"
TMPD="$ROOT/imaging/output/_deploy"
PORT="${IC_THEME_PORT:-9975}"

log() { printf '%s\n' "$*"; }
die() { printf '[ERR] %s\n' "$*"; exit 1; }
dev() { python3 "$DEVC" --host "$DEV" --wait "${1:-4}" "$2" 2>/dev/null | tr -d '\000\r'; }

[ -f "$TGZ" ]  || die "素材缺失:$TGZ"
[ -f "$SEND" ] || die "发送器缺失:$SEND"
mkdir -p "$TMPD"

HOST="$(python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try: s.connect(('$DEV',9)); print(s.getsockname()[0])
except Exception: print('')
finally: s.close()")"
[ -n "$HOST" ] || die "无法判断本机到设备的路由源地址"

log "== 设备 $DEV   宿主 $HOST =="
log "== [1/4] Mac 侧解包(设备无 gzip)成裸 tar =="
rm -f "$TMPD/theme.tar"
gunzip -c "$TGZ" > "$TMPD/theme.tar" || die "gunzip 失败:$TGZ"
EXPECT="$(md5 -q "$TMPD/theme.tar" 2>/dev/null || md5sum "$TMPD/theme.tar" | cut -d' ' -f1)"
log "   theme.tar $(wc -c < "$TMPD/theme.tar" | tr -d ' ') B  md5 $EXPECT"

log "== [2/4] 传输到设备 /tmp/theme.tar =="
dev 5 'killall nc 2>/dev/null; rm -f /tmp/theme.tar; true'
(python3 "$SEND" "$TMPD/theme.tar" "$PORT" 400 > "$TMPD/theme_send.log" 2>&1 &)
sleep 1
dev 4 "setsid sh -c 'nc $HOST $PORT > /tmp/theme.tar' >/dev/null 2>&1 & echo NC_BG_STARTED"
OK=0
for i in $(seq 1 24); do
    sleep 4
    M="$(dev 4 'md5sum /tmp/theme.tar 2>/dev/null' | grep -oE '[0-9a-f]{32}' | head -1)"
    [ "$M" = "$EXPECT" ] && { OK=1; break; }
    S="$(dev 4 'wc -c < /tmp/theme.tar 2>/dev/null' | tr -dc 0-9)"
    [ "$((i % 3))" = 0 ] && log "   [$((i*4))s] 已收 ${S:-0} B"
done
[ "$OK" = 1 ] || { pkill -f "$SEND" 2>/dev/null; die "传输不完整(期望 $EXPECT)"; }
log "   传输完整(md5 一致)"

log "== [3/4] 解包到 /data/theme/theme_default =="
dev 8 'mkdir -p /data/theme/theme_default && tar xf /tmp/theme.tar -C /data/theme/theme_default && rm -f /tmp/theme.tar && echo EXTRACT_OK'

log "== [4/4] 校验 =="
dev 6 'N=$(ls /data/theme/theme_default/homepage/screen 2>/dev/null | grep -c png); L=$(ls /data/theme/theme_default/homepage/layout 2>/dev/null | wc -l); echo "screen PNG=$N  layout dirs=$L"; ls /data/theme/theme_default | head -4'
log "DONE"
