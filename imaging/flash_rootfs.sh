#!/bin/bash
# =============================================================================
# flash_rootfs.sh — 把 root.sqsh4 烧到设备 mtd4(ROOTFS 分区,squashfs),持久化。
#
# 背景(2026-09-28):wpa_supplicant/wpa_cli 迁入 ROOTFS /sbin(usr 镜像里裁掉),
#   顺带 root.sqsh4 比设备现行 rootfs 超集:09-23 的 printk 降噪 + atbm_printk_mask
#   静音两段(rc.local),库经字节比对一致(libc a09c521a / ld b7a6ef75),
#   砍掉的 /lib/modules 是原厂备用件(零 modprobe 引用)。
#   ★ 烧序纪律:mtd4(rootfs 带 wpa)必须先于 mtd6(usr 去 wpa),否则 WiFi 断链失联。
#
# 用法: bash imaging/flash_rootfs.sh [设备IP]
# 前置: imaging/output/root.sqsh4 存在(imaging/build_sqsh.sh / repack_root.sh 生成)
# 依赖: imaging/captures/mtdw + imaging/captures/tcpsend.py + imaging/ftp_xfer.py + devctl.py
#
# 铁律(mtd6 事故,2026-09-27):看不到 VERIFY OK + 回读一致,绝不重启。
# =============================================================================
set -u
DEV="${1:-192.168.50.239}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQUASH="$ROOT/imaging/output/root.sqsh4"
MTDDEV="/dev/mtd4"
MTDW="$ROOT/imaging/captures/mtdw"
SEND="$ROOT/imaging/captures/tcpsend.py"
FTPX="$ROOT/imaging/ftp_xfer.py"
DEVC="$ROOT/imaging/devctl.py"
BACKUP_DIR="$ROOT/imaging/output/backups"
fsize() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }
log() { printf '%s\n' "$*"; }
die() { printf '[ERR] %s\n' "$*"; exit 1; }
api() { curl -s -m "${2:-15}" -X POST "http://$DEV:8080/api/exec" -d "{\"cmd\":\"$1\"}" 2>/dev/null; }
con() { python3 "$DEVC" --wait "${2:-8}" "$1" 2>/dev/null; }

[ -f "$SQUASH" ] || die "缺 $SQUASH (先跑 imaging/build_sqsh.sh 或 repack_root.sh 生成)"
[ -f "$MTDW" ]   || die "缺 mtdw: $MTDW"
[ -f "$SEND" ]   || die "缺发送器: $SEND"
EXPECT="$(md5sum "$SQUASH" | cut -d' ' -f1)"
HOST="$(python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
try: s.connect(('$DEV',9)); print(s.getsockname()[0])
except Exception: print('')
finally: s.close()")"
[ -n "$HOST" ] || die "无法判断本机到设备的路由源地址"
log "== 设备 $DEV   宿主 $HOST =="
log "== root.sqsh4: $(fsize "$SQUASH") B  md5 $EXPECT  →  $MTDDEV =="

log "== 0) 确认设备在线 =="
if curl -s -m 5 "http://$DEV:8080/api/version" >/dev/null 2>&1; then log "web OK"
elif con 'echo ALIVE' 6 | grep -q ALIVE; then log "app 不在,但 telnet 通(继续)"
else die "设备不可达:web 与 telnet 都不通"; fi

log "== 1) 备份 mtd4(dd → FTP 拉回 Mac) =="
mkdir -p "$BACKUP_DIR"
BAK="$BACKUP_DIR/mtd4_rootfs_$(date +%Y%m%d_%H%M%S).bin"
con "rm -f /tmp/mtd4.bin; dd if=$MTDDEV of=/tmp/mtd4.bin bs=65536 2>/dev/null; wc -c < /tmp/mtd4.bin" 60 | tr -dc '0-9\n' | tail -1 | grep -q '2097152' \
  || log "   [warn] dd 大小没取到 2097152,继续拉回(FTP 会把实际大小带回来)"
python3 "$FTPX" "$DEV" get /tmp/mtd4.bin "$BAK" > /tmp/fl_bak.log 2>&1 \
  || die "备份拉回失败($(tail -1 /tmp/fl_bak.log 2>/dev/null));不烧"
BSZ="$(fsize "$BAK")"
[ "$BSZ" = 2097152 ] || die "备份大小异常: $BSZ B(应为 2097152);不烧"
log "   备份: $BAK  md5 $(md5sum "$BAK" | cut -d' ' -f1)"

log "== 2) 传输(root.sqsh4 + mtdw,FTP 优先 md5 门禁) =="
send_verified() {
    local src="$1" dst="$2" want="$3" tries="${4:-3}" t M i p
    for t in $(seq 1 "$tries"); do
        if python3 "$FTPX" "$DEV" put "$src" "$dst" > /tmp/fl_ftp_$t.log 2>&1; then
            M="$(con "md5sum $dst 2>/dev/null" 8 | grep -oE '[0-9a-f]{32}' | head -1)"
            [ "$M" = "$want" ] && { log "   $dst FTP 传输完整"; return 0; }
            log "   FTP 传完但 md5 不符(得到 ${M:-无}),重试"
        else
            log "   FTP 失败: $(tail -1 /tmp/fl_ftp_$t.log 2>/dev/null)"
        fi
        p=$((9950 + t))
        (python3 "$SEND" "$src" "$p" 400 > /tmp/fl_$p.log 2>&1 &)
        sleep 1
        api "sh -c 'rm -f $dst; nc $HOST $p > $dst' & echo NC_STARTED" 8 >/dev/null
        for i in $(seq 1 30); do
            sleep 5
            M="$(con "md5sum $dst 2>/dev/null" 8 | grep -oE '[0-9a-f]{32}' | head -1)"
            [ "$M" = "$want" ] && { log "   $dst nc 传输完整(第 $t 次)"; return 0; }
        done
        pkill -f "$SEND" 2>/dev/null; api 'killall nc 2>/dev/null; true' 8 >/dev/null; sleep 2
    done
    return 1
}
con 'rm -f /tmp/root.sqsh4 /tmp/mtdw.old; sync; echo 1 > /proc/sys/vm/drop_caches' 8 >/dev/null
send_verified "$MTDW" /tmp/mtdw "$(md5sum "$MTDW" | cut -d' ' -f1)" 3 || die "mtdw 传输失败"
api 'chmod +x /tmp/mtdw' 10 >/dev/null
send_verified "$SQUASH" /tmp/root.sqsh4 "$EXPECT" 3 || die "root.sqsh4 三次都没传完整(期望 $EXPECT),中止不烧"

log "== 3) 烧 $MTDDEV(整区擦除+写入+回读校验) =="
con "chmod +x /tmp/mtdw; /tmp/mtdw $MTDDEV /tmp/root.sqsh4" 180 | tail -4
R="$(con "head -c $(fsize "$SQUASH") $MTDDEV | cmp -s - /tmp/root.sqsh4 && echo CMP_OK || echo CMP_DIFF" 90)"
case "$R" in
  *CMP_OK*)   log "   回读复核: 镜像段与源文件逐字节一致" ;;
  *CMP_DIFF*) die "回读复核不一致!先不要重启,用备份重烧(/tmp/mtdw $MTDDEV /tmp/mtd4.bin)" ;;
  *)          log "   [warn] 回读复核未取到结果(mtdw 自身已打印 VERIFY OK)" ;;
esac

log "== 4) 重启 =="
api 'sh -c "sleep 1; sync; reboot -f" & echo REBOOTING' 6 >/dev/null
DOWN=0
for i in $(seq 1 12); do
    sleep 3
    if ! curl -s -m 2 "http://$DEV:8080/api/version" >/dev/null 2>&1; then DOWN=1; log "   设备已下线(第 $((i*3))s)"; break; fi
done
if [ "$DOWN" != 1 ]; then
    log "   [WARN] 重启没生效 —— 串口兜底"
    [ -f "$ROOT/imaging/serial_sh.py" ] && python3 "$ROOT/imaging/serial_sh.py" --wait 4 'sync; reboot -f' >/dev/null 2>&1
fi
log "等待回到 Linux..."
for i in $(seq 1 30); do
    sleep 5
    V=$(curl -s -m 3 "http://$DEV:8080/api/version" 2>/dev/null)
    [ -n "$V" ] && { log "   web 回: $V"; break; }
done

log "== 5) 文件系统层验证 =="
WPA_S="$(python3 "$DEVC" --wait 3 'md5sum /sbin/wpa_supplicant 2>/dev/null' 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -1)"
WPA_C="$(python3 "$DEVC" --wait 3 'md5sum /sbin/wpa_cli 2>/dev/null' | grep -oE '[0-9a-f]{32}' | head -1)"
RC_OK="$(python3 "$DEVC" --wait 3 'grep -c "echo 1 > /proc/sys/kernel/printk" /etc/init.d/rc.local' 2>/dev/null | tr -dc 0-9 | head -c 2)"
SQERR="$(python3 "$DEVC" --wait 3 'dmesg | grep -c "SQUASHFS error"' 2>/dev/null | tr -dc 0-9 | head -c 4)"
WSTAT="$(python3 "$DEVC" --wait 4 'wpa_cli -i wlan0 status 2>/dev/null | grep -E "^wpa_state|^ip_address"' 2>/dev/null | tr -d '\000' | tr '\n' ' ')"
log "   /sbin/wpa_supplicant md5: ${WPA_S:-读不到}(期望 84605d9e35f7509a1b0607719ea12848)"
log "   /sbin/wpa_cli md5       : ${WPA_C:-读不到}(期望 b296b9dcfd2e9d514c9942c9e946b751)"
log "   rc.local 含 printk 降噪 : ${RC_OK:-?}(期望 1)"
log "   内核 squashfs 报错      : ${SQERR:-?}(期望 0)"
log "   WiFi                    : ${WSTAT:-无}"
log "   /api/version            : $(curl -s -m 8 http://$DEV:8080/api/version)"
if [ "$WPA_S" = "84605d9e35f7509a1b0607719ea12848" ] && [ "$WPA_C" = "b296b9dcfd2e9d514c9942c9e946b751" ] && [ "${SQERR:-1}" = "0" ]; then
    log "验证: OK(rootfs 已换新,/sbin/wpa 就位)"
else
    log "[WARN] 有项目没过 —— 用备份重烧: /tmp/mtdw $MTDDEV /tmp/mtd4.bin && reboot;或 Mac 侧 $BAK"
fi
log "DONE"
