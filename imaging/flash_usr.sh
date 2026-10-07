#!/bin/bash
# =============================================================================
# flash_usr.sh — 把新 /usr 分区(含新 app)烧到设备 mtd6(APP 分区,squashfs),持久化。
#
# 背景:设备 /usr 是独立 mtd6 squashfs(5MB),装 SDK 库/内核模块/工具 + app。
#   烧 mtd6 即持久更新 app(重启不丢),无需整片重刷。
#
# 用法: bash imaging/flash_usr.sh [设备IP]
# 前置: ① imaging/output/usr.sqsh4.new 存在(跑 imaging/make_release.sh 生成,内含最新 app)
#       ② 设备在线(web 8080 可达)
# 依赖: imaging/captures/tcpsend.py + imaging/captures/mtdw + imaging/devctl.py
#
# 2026-09-24 修传输(原版两个毛病,真机踩过):
#   1) 原来让设备 `nc $DEV $p` —— 那是连**设备自己**,Mac 的监听根本收不到;改成用
#      本机到设备的路由源地址(HOST 自动探测)。
#   2) 原来把阻塞 nc 塞进 /api/exec:一是会把 app 的 web 线程占住(实测整片 web 卡死),
#      二是 4.8MB 在 ~62KB/s 的 WiFi 上要 ~78s,原 curl -m 90 太紧 → 改成设备侧
#      **后台** nc + 轮询 md5(不阻塞任何请求),对不上 md5 绝不烧。
#
# 回滚: 烧之前先备份 mtd6(见文件末尾提示),要回滚就 mtdw /dev/mtd6 <备份文件> + 重启。
# =============================================================================
set -u
DEV="${1:-192.168.50.239}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQUASH="$ROOT/imaging/output/usr.sqsh4.new"
MTDW="$ROOT/imaging/captures/mtdw"
SEND="$ROOT/imaging/captures/tcpsend.py"
DEVC="$ROOT/imaging/devctl.py"
fsize() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }
log() { printf '%s\n' "$*"; }
die() { printf '[ERR] %s\n' "$*"; exit 1; }
api() { curl -s -m "${2:-15}" -X POST "http://$DEV:8080/api/exec" -d "{\"cmd\":\"$1\"}" 2>/dev/null; }
# 控制原语走 **telnet**(devctl):传输 5MB 镜像进 /tmp(tmpfs=RAM)时,内存紧会把 app 挤成 OOM
# 死掉 —— 此时 /api/exec 就没了,而 telnetd 是系统服务一直在。md5 校验/写 flash 都用它。
con() { python3 "$DEVC" --wait "${2:-8}" "$1" 2>/dev/null; }
# 设备侧 md5:读不到(telnetd 单连接被占/瞬断)重试几次再认 —— 2026-09-28 踩过一次
# "得到 无"被当成传输出错,白走一轮 200s 的 nc 兜底。
devmd5() {
    local f="$1" M k
    for k in 1 2 3; do
        M="$(con "md5sum $f 2>/dev/null" 8 | grep -oE '[0-9a-f]{32}' | head -1)"
        [ -n "$M" ] && { echo "$M"; return 0; }
        sleep 2
    done
    echo ""
}

[ -f "$SQUASH" ] || die "缺 $SQUASH (先跑 bash imaging/make_release.sh 生成)"
[ -f "$MTDW" ]   || die "缺 mtdw: $MTDW"
[ -f "$SEND" ]   || die "缺发送器: $SEND"
EXPECT="$(md5sum "$SQUASH" | cut -d' ' -f1)"
HOST="$(python3 -c "
import socket
s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try: s.connect(('$DEV',9)); print(s.getsockname()[0])
except Exception: print('')
finally: s.close()")"
[ -n "$HOST" ] || die "无法判断本机到设备的路由源地址"
log "== 设备 $DEV   宿主 $HOST =="
log "== usr.sqsh4.new: $(fsize "$SQUASH") B  md5 $EXPECT =="

log "== 0) 确认设备在线 =="
if curl -s -m 5 "http://$DEV:8080/api/version" >/dev/null 2>&1; then log "web OK"
elif con 'echo ALIVE' 6 | grep -q ALIVE; then log "app 不在,但 telnet 通(继续:传输/校验/写 flash 都走 telnet)"
else die "设备不可达:web 与 telnet 都不通"; fi

log "== 0.5) 清理设备 /tmp 并预检空间 =="
# 2026-09-24 实机踩过:/tmp 是 tmpfs(27MB,RAM 盘)。传输前不清就等着被坑 —— 残留的大
# 文件(mtd6 备份 dump、上一版镜像、app 日志)会把 RAM 挤爆,dmesg 出现一串 OOM 杀进程,
# app 被 OOM 掉之后传输永远对不上 md5(好在没写 mtd6,分区安全)。所以先删再查空间。
con 'rm -f /tmp/usr.sqsh4.new /tmp/mtd6.bin /tmp/newapp.log /tmp/app.log' 8 >/dev/null
# 镜像要写进 /tmp(tmpfs,占用的是 RAM):先把内核 page cache 丢掉,多腾几 MB,
# 否则传输中途 OOM 会把 app 杀掉、传输被截断(今天反复踩)。
con 'sync; echo 1 > /proc/sys/vm/drop_caches; free | head -2' 8 | tr -d '\000' | sed 's/^/   /' 
# 取可用 KB:走 telnet 原语(devctl)拿**裸输出**;经 /api/exec 的话拿到的是 JSON,
# 里面的 code/时间戳等数字会被 tr 拼成一串(踩过:1130120211103153827000000000KB)。
FREE="$(python3 "$DEVC" --wait 3 'df -k /tmp | tail -1 | awk "{print \$4}"' 2>/dev/null | tr -dc 0-9)"
NEED=$(( $(fsize "$SQUASH") / 1024 + 2048 ))
if [ -n "$FREE" ]; then
    log "   /tmp 可用 ${FREE}KB,本次需要约 ${NEED}KB(镜像+余量)"
    [ "$FREE" -lt "$NEED" ] && die "/tmp 空间不足:先手工清掉 /tmp 里的大文件再烧(rm -f /tmp/*.bin /tmp/*.log)"
else
    log "   [warn] 没取到 /tmp 可用空间,继续(失败会停在 md5 校验)"
fi

# 传输:优先 FTP(实测 1333KB/s,有流控重传),失败再回落 nc(设备侧后台拉取)。
# 两者都按 md5 校验,三次都不对就不烧。
FTPX="$ROOT/imaging/ftp_xfer.py"
send_verified() {   # send_verified <本地文件> <设备落地路径> <端口基准> <期望md5> [次数]
    local src="$1" dst="$2" pbase="$3" want="$4" tries="${5:-3}"
    local t p M i
    for t in $(seq 1 "$tries"); do
        # --- 首选 FTP ---
        if [ -f "$FTPX" ]; then
            if python3 "$FTPX" "$DEV" put "$src" "$dst" > /tmp/fl_ftp_$t.log 2>&1; then
                M="$(devmd5 "$dst")"
                [ "$M" = "$want" ] && { log "   $dst 经 FTP 传输完整($(cat /tmp/fl_ftp_$t.log))"; return 0; }
                log "   FTP 传完但设备侧 md5 不符(得到 ${M:-无}),重试"
            else
                log "   FTP 失败: $(tail -1 /tmp/fl_ftp_$t.log 2>/dev/null)"
            fi
        fi
        # --- 回落 nc ---
        p=$((pbase + t))
        (python3 "$SEND" "$src" "$p" 400 > /tmp/fl_$p.log 2>&1 &)
        sleep 1
        api "sh -c 'rm -f $dst; nc $HOST $p > $dst' & echo NC_STARTED" 8 >/dev/null
        for i in $(seq 1 40); do            # 最长 ~200s(nc 实测 ~62KB/s)
            sleep 5
            M="$(con "md5sum $dst 2>/dev/null" 8 | grep -oE '[0-9a-f]{32}' | head -1)"
            [ "$M" = "$want" ] && { log "   $dst 经 nc 传输完整(第 $t 次)"; return 0; }
        done
        log "   第 $t 次没对上,重试"
        pkill -f "$SEND" 2>/dev/null; api 'killall nc 2>/dev/null; true' 8 >/dev/null; sleep 2
    done
    return 1
}

log "== 1) 传 mtdw =="
WANT_MTDW="$(md5sum "$MTDW" | cut -d' ' -f1)"
send_verified "$MTDW" /tmp/mtdw 9970 "$WANT_MTDW" 3 || die "mtdw 传输失败"
api 'chmod +x /tmp/mtdw' 10 >/dev/null

log "== 2) 传 usr.sqsh4.new =="
send_verified "$SQUASH" /tmp/usr.sqsh4.new 9960 "$EXPECT" 3 \
  || die "usr.sqsh4.new 三次都没传完整(期望 $EXPECT),中止不烧 mtd6"

log "== 3) 烧 mtd6(整区擦除+写入+回读校验) =="
# 2026-09-28 真机踩坑:step1 传好并 md5 验过的 /tmp/mtdw 在 step2 传 4.8MB 镜像期间
# 消失(tmpfs 被整锅端/中途重启洗掉的典型症状),step3 直接 chmod 报 not found 却没拦住
# —— 而且回读判据 `echo CMP_OK` 是**假阳性**:telnet 把敲进去的命令行原样回显,命令文本
# 里就含 CMP_OK,CMP_DIFF 也含,*CMP_OK* 永远命中。铁律改成:
#   ① 写之前再验一次 mtdw(不在/不对就地重传);② 只认 mtdw 自己打的 "VERIFY OK";
#   ③ 回读用 md5 数值比对(比对物里不含期望值字面量,回显骗不了它)。
[ -f "$MTDW" ] || die "本地 mtdw 不见了"
WANT_MTDW="$(md5sum "$MTDW" | cut -d' ' -f1)"
MW="$(devmd5 /tmp/mtdw)"
if [ "$MW" != "$WANT_MTDW" ]; then
    log "   [补] 写前复核发现 /tmp/mtdw 不对(设备 ${MW:-无} / 期望 $WANT_MTDW),就地重传"
    send_verified "$MTDW" /tmp/mtdw 9985 "$WANT_MTDW" 2 || die "mtdw 重传失败,中止不烧"
fi
MV="$(devmd5 /tmp/usr.sqsh4.new)"
[ "$MV" = "$EXPECT" ] || die "写前复核 /tmp/usr.sqsh4.new 不对(设备 ${MV:-无} / 期望 $EXPECT),中止不烧"
WOUT="$(con 'chmod +x /tmp/mtdw && /tmp/mtdw /dev/mtd6 /tmp/usr.sqsh4.new; echo "WRC=$?"' 150)"
printf '%s\n' "$WOUT" | tail -6 | sed 's/^/   | /'
case "$WOUT" in
  *"VERIFY OK"*) : ;;
  *) die "mtdw 没打出 VERIFY OK —— 写入失败,先不要重启;重跑本脚本再烧,连续失败再查 flash" ;;
esac
RB="$(con "head -c $(fsize "$SQUASH") /dev/mtd6 | md5sum" 60 | grep -oE '[0-9a-f]{32}' | head -1)"
if [ "$RB" = "$EXPECT" ]; then
    log "   回读复核: mtd6 镜像段 md5 == 源文件($EXPECT)"
else
    die "回读复核不一致!回读=${RB:-无} 期望=$EXPECT —— 先不要重启,用备份重烧(/tmp/mtdw /dev/mtd6 <备份>)"
fi

log "== 4) 重启(必须确认真的重启了) =="
# ★ 2026-09-25 教训:/usr 是**挂载中**的 squashfs。在挂载状态下重写 mtd6 之后,内核里缓存的
#   块/元数据与 flash 不再一致 —— 不重启就直接读,会看到"旧内容 + 随机 xz 解压失败",很容易
#   误判成"flash 坏块/镜像坏了"。所以:①发重启 ②**等它真的掉下去**(web 不可达) ③再等回来。
#   实测遇到过"重启请求发了但没生效"(设备从未 down,脚本的轮询以为已回来),这里必须判 down。
# 走 telnet 原语拿裸数字(经 /api/exec 是 JSON,数字会被 tr 拼成一串)
UP_BEFORE="$(python3 "$DEVC" --wait 3 'cut -d. -f1 /proc/uptime' 2>/dev/null | tr -dc 0-9 | head -c 6)"
api 'sh -c "sleep 1; sync; reboot -f" & echo REBOOTING' 6 >/dev/null
DOWN=0
for i in $(seq 1 12); do
    sleep 3
    if ! curl -s -m 2 "http://$DEV:8080/api/version" >/dev/null 2>&1; then DOWN=1; log "   设备已下线(第 $((i*3))s)"; break; fi
done
if [ "$DOWN" != 1 ]; then
    log "   [WARN] 发了重启但设备一直在线 —— 走**串口兜底**强制重启"
    # 为什么必须兜底:实测 /api/exec 里的 reboot 有时不生效,而"不重启就继续"比不刷更糟 ——
    # /usr 是挂载中的 squashfs,重写 mtd6 后 app 的代码页会读到被改写的页 → app 自己崩掉
    # (2026-09-25 就这样把 app 弄死过一次)。串口控制台是最后一条可靠通道。
    if [ -f "$ROOT/imaging/serial_sh.py" ]; then
        python3 "$ROOT/imaging/serial_sh.py" --wait 4 'sync; reboot -f' >/dev/null 2>&1
        for i in $(seq 1 12); do
            sleep 3
            if ! curl -s -m 2 "http://$DEV:8080/api/version" >/dev/null 2>&1; then DOWN=1; log "   设备已下线(串口重启,第 $((i*3))s)"; break; fi
        done
    fi
fi
[ "$DOWN" = 1 ] || log "   [WARN] 串口兜底也没让它重启 —— 请断电重启后再验第 5 步"
log "等待回到 Linux..."
for i in $(seq 1 25); do
    sleep 5
    V=$(curl -s -m 3 "http://$DEV:8080/api/version" 2>/dev/null)
    [ -n "$V" ] && { log "   web 回: $V"; break; }
done
UP_AFTER="$(python3 "$DEVC" --wait 3 'cut -d. -f1 /proc/uptime' 2>/dev/null | tr -dc 0-9 | head -c 6)"
if [ -n "$UP_BEFORE" ] && [ -n "$UP_AFTER" ] && [ "$UP_AFTER" -ge "$UP_BEFORE" ]; then
    log "   [WARN] uptime 没有回退(${UP_BEFORE}s → ${UP_AFTER}s)=其实没重启 → 串口兜底强制重启"
    # 为什么必须兜底:web 掉线≠设备重启 —— 重写挂载中的 mtd6 会让 app 读到被改写的代码页而崩,
    # 于是 web 掉了但设备还在(uptime 继续涨)。此时若不当场重启,第 5 步读到的全是坏状态。
    if [ -f "$ROOT/imaging/serial_sh.py" ]; then
        python3 "$ROOT/imaging/serial_sh.py" --wait 4 'sync; reboot -f' >/dev/null 2>&1
        for i in $(seq 1 25); do
            sleep 5
            V=$(curl -s -m 3 "http://$DEV:8080/api/version" 2>/dev/null)
            [ -n "$V" ] && { log "   串口重启完成,web 回: $V"; break; }
        done
    fi
fi

log "== 5) 验证(应在 /usr/bin,持久 + 文件系统层自检) =="
# ★ 2026-09-25 教训:光靠 mtdw 的原始回读(mtdw VERIFY OK)不够 —— 实测出现过
#  "回读逐字节一致、但重启后内核解不开某些块"(dmesg: SQUASHFS error: xz decompression
#  failed;读整个大文件 EIO)。那是这块 NOR 的边际写/读。所以这里在**文件系统层**复核:
#  ① 从本地镜像里取出 app 的期望 md5;② 设备上读同一个文件比 md5;③ 数内核 squashfs 报错。
TMPX="$(mktemp -d)"
unsquashfs -d "$TMPX" -f "$SQUASH" >/dev/null 2>&1
EXPECT_APP="$(md5sum "$TMPX/bin/leelen_intercom" 2>/dev/null | cut -d' ' -f1)"
rm -rf "$TMPX"
log "   镜像内 app 期望 md5: ${EXPECT_APP:-取不到}"
# 注意:api() 的 body 是 {"cmd":"..."},命令里出现双引号会截断 JSON(busybox grep 报过
# Usage)。这里用 readlink+无引号 pattern,同样能报出在跑哪个二进制。
api 'readlink /proc/*/exe 2>/dev/null | grep leelen | head -1' 10 | tr -d '\000'
# 走 telnet 原语拿**裸输出**:经 /api/exec 拿到的是 JSON,里面的 code/时间戳数字会被 tr 拼成
# 一串(踩过:2130120211103153827000000000)。devctl 有 telnetd 就能用(厂方镜像自带)。
DEV_APP="$(python3 "$DEVC" --wait 3 'md5sum /usr/bin/leelen_intercom 2>/dev/null' 2>/dev/null | grep -oE '[0-9a-f]{32}' | head -1)"
SQERR="$(python3 "$DEVC" --wait 3 'dmesg | grep -c "SQUASHFS error"' 2>/dev/null | tr -dc 0-9 | head -c 4)"
log "   设备上 app md5     : ${DEV_APP:-读不到(EIO?)}"
log "   内核 squashfs 报错 : ${SQERR:-?}"
if [ -n "$EXPECT_APP" ] && [ "$DEV_APP" != "$EXPECT_APP" ]; then
    log "   [WARN] app md5 与镜像不一致 —— 这块 NOR 可能写边际/读不稳。"
    log "          处理:重跑本脚本再烧一遍(实测重写一次即好);连续两次不行再查 flash 健康。"
elif [ "${SQERR:-0}" != "0" ]; then
    log "   [WARN] 内核报 squashfs 解压失败(${SQERR} 次)—— 同上,重烧一遍。"
else
    log "   文件系统层自检: OK(可完整读出且无解压错误)"
fi
log "   /api/version   : $(curl -s -m 8 http://$DEV:8080/api/version)"
log "DONE"
log ""
log "回滚办法(若新 app 有问题):"
log "  ① 有备份镜像: bash -c 'cd $ROOT && python3 imaging/devctl.py --wait 60 \"setsid sh -c \\\"nc <本机IP> <端口> < /tmp/mtd6.bin\\\" &\"' 之类把备份传上去,"
log "     再 /tmp/mtdw /dev/mtd6 /tmp/mtd6.bin && reboot;简单说=传备份 + mtdw 写回 + 重启"
log "  ② 没有备份: 用 imaging/output/B_full_16MB_v4.bin 整片重刷(imaging/burn_parts_v4.py)"