#!/usr/bin/env python3
"""burn_parts_v4.py — 串口(COM3)分区烧录器,按区烧、不必全片擦写(jffs2 区除外,见下)。

设计要点:
  * 默认只烧 DTB/KERNEL/ROOTFS/CONFIG/APP/DATA —— UBOOT 与 ENV 是生死区,
    板上已是新 u-boot + 已 saveenv 新布局,动它们唯一后果是万一断电上电即死。
    除非 --all,否则绝不碰 0x0~0x75000。
  * jffs2 分区(CONFIG/DATA)必须先"整区 sf erase"再写,理由见 JFFS2_PARTS 注释。
    其余区(squashfs/裸二进制)沿用 sf update。
  * 每区独立原子链: tftp -> 校验 RAM crc -> [jffs2: 整区 erase] -> 写 ->
    sf read(异区RAM) -> crc32 回读校验。
    u-boot 的 crc32 与宿主 binascii.crc32 同为 zlib CRC32,比对 hex 即知字节是否一致。
  * 擦除前必须先确认 tftp 装载正确(校验 LF 处的 crc,不看 u-boot 措辞):
    否则 tftp 失败也会把分区擦空、再把 LF 里的陈旧数据写进去 —— 比不擦更糟。
  * 坏哪区重烧哪区: 命令行过滤用什么区例子里就烧什么区,其余跳过。
  * 断电提示: tftp 到 RAM(写前)期间掉电无损失;写入中途掉电只坏该区,
    u-boot 完好,可重跑本脚本重烧。

用法:
  python burn_parts_v4.py                 # 烧默认集 (DTB KERNEL ROOTFS CONFIG APP LOGO DATA)
  python burn_parts_v4.py --parts DTB APP # 只烧指定区
  python burn_parts_v4.py --parts DATA    # 只烧 DATA(jffs2:会先整区擦除)
  python burn_parts_v4.py --all           # 连 UBOOT+ENV 一起(不推荐)
  python burn_parts_v4.py --no-erase      # jffs2 也不整区擦除(不建议,见 JFFS2_PARTS)
  python burn_parts_v4.py --dry           # 只打印计划(含解析出的串口/宿主 IP),不碰硬件

串口 / 网络三项默认值是为 Windows(Git Bash) + tftpd64 写的,换机器时按优先级覆盖:
  命令行 --port/--baud/--ser-ip/--host  >  环境变量 INTERCOM_SERIAL /
  INTERCOM_UBOOT_IP / INTERCOM_TFTP_HOST  >  默认值。
macOS 上 --port 不给会**自动探测**(只有一个 /dev/cu.usbserial-* 时直接用它);
--host auto 按到板子的路由自动取宿主 IP(本机换网段/换机器最省事)。
宿主不想/不会配 tftp 服务时加 **--serve**:脚本自带极简 TFTP(RRQ/blksize 协商,
见 imaging/tftp_min.py),根目录自动 = 产物目录;端口 69 是特权端口,u-boot 又固定
请求 69,所以 --serve 要 sudo。例:
  python burn_parts_v4.py --dry --host auto
  python burn_parts_v4.py --parts APP --port /dev/cu.usbserial-1110
  sudo python burn_parts_v4.py --serve --host auto      # 不依赖系统 tftpd(macOS 常用)

前置: B_full_16MB_v4.bin 已 split 到 _imgwork/slices/;tftp 服务器在 192.168.50.220
     根目录 = imaging/output(env.py 的 IC_OUT;旧 tftpboot 不再使用)
"""
import sys, os, time, hashlib, json, binascii, re
import logging; logging.disable(logging.CRITICAL)
try:
    import serial
except ImportError:
    sys.exit('need pyserial: pip install pyserial')

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import threading
import tftp_min                     # 自带极简 TFTP 服务(--serve 时用,不依赖系统 tftpd)
from env import TFTP as TFTP_ROOT   # env.py:INTERCOM_WS 覆盖工作区根
SLICES = os.path.join(TFTP_ROOT, '_imgwork', 'slices')
MAN = os.path.join(SLICES, 'manifest.json')
LF = 0x80008000    # tftp 下载 RAM
RB = 0x80100000    # 回读暂存(与 LF 不重叠:最大分区块 5.2M -> 0x80600000 < RAM顶)

PORT = 'COM3'; BAUD = 115200          # 默认维持 Windows(Git Bash)/WSL 习惯
SER_IP = '192.168.50.199'             # 运行期给板子设的临时 IP(不 saveenv)
HOST_IP = '192.168.50.220'            # tftp server(宿主);换机器可用 --host/env 覆盖

# 覆盖优先级:命令行 > 环境变量 > 默认值(macOS 上再自动探测一次串口)。
# 这些值只影响本次运行,不写进任何持久配置。
ENV_PORT = 'INTERCOM_SERIAL'
ENV_HOST = 'INTERCOM_TFTP_HOST'
ENV_SER_IP = 'INTERCOM_UBOOT_IP'


def auto_port():
    """macOS:只有一个 USB 串口时直接用它(免去手改 COM3)。"""
    import glob
    cands = sorted(glob.glob('/dev/cu.usbserial-*') + glob.glob('/dev/cu.SLAB_USBtoUART*')
                   + glob.glob('/dev/cu.wchusbserial*'))
    return cands[0] if len(cands) == 1 else None


def auto_host(ser_ip):
    """本机到板子那条路由的源地址(= 与板子同网段的宿主 IP),用作 tftp serverip。"""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((ser_ip, 9))        # UDP connect 不真发包,只让内核选路由
        ip = s.getsockname()[0]; s.close()
        return ip
    except Exception:
        return None


def resolve_port(cli):
    if cli:
        return cli
    if os.environ.get(ENV_PORT):
        return os.environ[ENV_PORT]
    return auto_port() or PORT


def resolve_host(cli, ser_ip):
    """--host auto:按到板子的路由自动取宿主 IP(换机器最省事)。"""
    if cli and cli != 'auto':
        return cli
    if not cli and os.environ.get(ENV_HOST):
        return os.environ[ENV_HOST]
    if cli == 'auto':
        h = auto_host(ser_ip)
        if not h:
            sys.exit(f'--host auto 失败:取不到到 {ser_ip} 的源地址,请显式给 --host')
        return h
    return HOST_IP        # 默认不变(Windows/WSL 的 tftpd64 就在 .220)


def resolve_ser_ip(cli):
    return cli or os.environ.get(ENV_SER_IP) or SER_IP

DEFAULT = ['DTB', 'KERNEL', 'ROOTFS', 'CONFIG', 'APP', 'LOGO', 'DATA']
LOGO_REQ = ['ENV', 'LOGO']   # mtdparts 加了 300K(LOGO):ENV 必须一起烧,u-boot 才能认 LOGO 分区
ALL = ['UBOOT', 'ENV'] + DEFAULT

# ---------------------------------------------------------------------------
# jffs2 分区:必须先【整区 sf erase】再写,不能只靠 sf update 增量写。
# 原因:jffs2 是日志式文件系统,每个节点自带版本号,挂载时"版本号大的赢"。
#   在旧内容之上增量写新镜像时,分区里残留的旧节点版本号可能更高 →
#   挂载后旧文件"压过"新镜像。实机后果(2026-09-18 现场):
#     /data 主题素材 212 张里 77 张内容被抹成 256B 零块、150 个名字缺失
#     (整棵 homepage/layout)、一个 /usr/bin/wifi_guard.sh 副本占着目录名 ——
#     全部指向"旧节点存活 + 新镜像未真正落地",即 data.jffs2 刷了等于没刷。
#   整区 erase(全 0xFF)后再写,分区里只有本次镜像的节点,不存在旧版本竞争。
# CONFIG 同为 jffs2(config.jffs2),同理。
# ---------------------------------------------------------------------------
JFFS2_PARTS  = ('CONFIG', 'DATA')
ERASE_BLOCK  = 0x1000    # /proc/mtd 实测 erasesize=4K;off/cap 须按它对齐才允许整擦


def fire(parts, no_erase=False, port=PORT, baud=BAUD, ser_ip=SER_IP, host_ip=HOST_IP,
         serve=False, tftp_port=69):
    man = json.load(open(MAN))

    # ---- 0) 自带 TFTP 服务(可选)----
    # u-boot 的 tftp 固定请求 69 端口,所以 --serve 要 sudo;绑不上就别往下走,
    # 否则每个区都会卡在 "tftp 装载未通过校验" 上白等。
    tstop = None
    if serve:
        sock, err = tftp_min.open_server(host_ip, tftp_port)
        if err:
            print('!! ' + err, file=sys.stderr)
            print('   换你自己的 tftp(根目录 %s)后去掉 --serve,或用 sudo 重跑。' % TFTP_ROOT,
                  file=sys.stderr)
            sys.exit(3)
        tstop = threading.Event()
        threading.Thread(target=tftp_min.serve_forever, args=(sock, TFTP_ROOT, tstop),
                         daemon=True).start()
        print(f'== 自带 TFTP 服务已起: 监听 {sock.getsockname()[0]}:{sock.getsockname()[1]}'
              f' 根={TFTP_ROOT} ==', file=sys.stderr, flush=True)

    print(f'== opening {port} @{baud} ==', file=sys.stderr, flush=True)
    try:
        s = serial.Serial(port, baud, timeout=0.2, exclusive=True)
    except Exception as e:
        # 串口被终端/串口助手占着是这里最常见的情况(macOS 尤其:read failed / 打不开)
        print(f'!! 打不开串口 {port}: {e}', file=sys.stderr)
        print('   先关掉占用它的程序(串口助手/MobaXterm/另开的会话),或用 --port 指定别的口。',
              file=sys.stderr)
        sys.exit(3)
    s.reset_input_buffer()

    def d(t):
        b = b''; t0 = time.time()
        while time.time() - t0 < t:
            if s.in_waiting:
                b += s.read(s.in_waiting)
            time.sleep(0.02)
        try: return b.decode('utf8', 'replace')
        except Exception: return ''
    def send(c): s.write(c.encode() + b'\r')
    def cmd(c, t=3):
        send(c); b = ''; t0 = time.time()
        while time.time() - t0 < t:
            if s.in_waiting:
                b += s.read(s.in_waiting).decode('utf8', 'replace')
                if '=>' in b:
                    time.sleep(0.2)               # 提示符已回,收干净再算完成
                    while s.in_waiting:
                        b += s.read(s.in_waiting).decode('utf8', 'replace')
                        time.sleep(0.02)
                    break
            else:
                time.sleep(0.02)
        time.sleep(0.15); b += d(0.3)
        return b

    # ---- 1) 起手:换行看是否已在 u-boot 提示符 ----
    print('== settle console ==', file=sys.stderr, flush=True)
    d(0.5); send(''); time.sleep(3); d(0.5)
    def at_uboot():
        b = cmd('', 0.6)
        return '=> ' in b
    if not at_uboot():
        print('!! 不在 u-boot 提示符。请先手动复位板子并在 autoboot 前打断,再重跑。', file=sys.stderr)
        print('   串口看到的最后内容:', repr(d(1))[-300:], file=sys.stderr)
        s.close(); sys.exit(2)

    # ---- 2) 网络指向宿主 tftp (runtime only, 不 saveenv) ----
    print(cmd(f'setenv ipaddr {ser_ip}', 2).strip(), file=sys.stderr)
    print(cmd(f'setenv serverip {host_ip}', 2).strip(), file=sys.stderr)
    r = cmd('ping ' + host_ip, 4)
    pong = 'is alive' in r and 'not alive' not in r
    print('ping:', ('OK' if pong else 'unreachable/' + r.strip().splitlines()[-1]), file=sys.stderr)
    if not pong:
        print(f'!! host 不可达:确认宿主在 {host_ip} 且板子与宿主同网段(可用 --host auto 自动取)。中止。', file=sys.stderr)
        s.close(); sys.exit(2)

    # ---- 3) sf probe 一次,后续命令共用 ----
    pr = cmd('sf probe', 5)
    if 'Detected' not in pr and 'SF:' not in pr:
        print('!! sf probe 无响应/未识别 flash:', pr.strip(), file=sys.stderr)

    for name in parts:
        m = man[name]; fn = os.path.join(SLICES, f'{name}.bin')
        sz = m['size']; off = int(m['off'], 16); cap = int(m['cap'], 16)
        host_crc = f"{binascii.crc32(open(fn,'rb').read()) & 0xffffffff:08x}"

        # jffs2 分区整区擦除(见 JFFS2_PARTS);off/cap 未按擦除块对齐则退化为 sf update
        full_erase = (name in JFFS2_PARTS) and (not no_erase)
        if full_erase and ((off % ERASE_BLOCK) or (cap % ERASE_BLOCK)):
            print(f'  !! {name} off/cap 未按 {ERASE_BLOCK:#x} 擦除块对齐,'
                  f'放弃整区擦除(退化为 sf update)', file=sys.stderr, flush=True)
            full_erase = False
        print(f'\n===== {name} @{off:#08x} cap={cap:#06x} size={sz}'
              f'{"  [整区擦除后再写]" if full_erase else ""} =====',
              file=sys.stderr, flush=True)

        tfile = f"_imgwork/slices/{name}.bin"

        # ---- 1) tftp 到 LF,先校验 RAM 里的内容(不依赖 u-boot 措辞)----
        # 同一份数据 u-boot crc32 与宿主 binascii.crc32 同为 zlib CRC32。
        # 必须先确认它,才允许后面擦除:否则 tftp 失败 -> 擦空分区 -> 写入陈旧 LF。
        out = cmd(f"tftp {LF:#x} {tfile}", t=240)
        print('  TFTP:', out.strip()[-160:], file=sys.stderr, flush=True)
        out2 = cmd(f"crc32 {LF:#x} {sz:#x}", t=60)
        mm = re.search(r'(?:==>|=)\s*([0-9a-fA-F]{8})', out2)
        ram_crc = mm.group(1).lower() if mm else '?'
        if ram_crc != host_crc:
            print(f'  !! tftp 装载未通过校验(LF crc={ram_crc} host={host_crc})'
                  f'—— 未擦除、未写入,跳过 {name}', file=sys.stderr, flush=True)
            print(f'     确认 tftp 服务器根目录 = {TFTP_ROOT} 后单独重烧:'
                  f' python burn_parts_v4.py --parts {name}', file=sys.stderr, flush=True)
            continue
        print(f'  RAM crc ok: {ram_crc}', file=sys.stderr, flush=True)

        # ---- 2) 写:jffs2 走 整区 erase -> sf write;其余走 sf update ----
        # 源数据 LF 全程不被覆盖;RB 与 LF 不重叠(最大 5.2M -> 0x80600000 < RAM 64M)。
        if full_erase:
            chain = (f"sf erase {off:#x} {cap:#x}; "
                     f"sf write {LF:#x} {off:#x} {sz:#x}; "
                     f"sf read {RB:#x} {off:#x} {sz:#x}")
        else:
            chain = (f"sf update {LF:#x} {off:#x} {sz:#x}; "
                     f"sf read {RB:#x} {off:#x} {sz:#x}")
        out = cmd(chain, t=300)
        print('  OUT:', out.strip()[-200:], file=sys.stderr, flush=True)

        # ---- 3) 回读到 RB 并校验 ----
        # 硬校验: u-boot 的 crc32 即 zlib CRC32,与宿主 binascii.crc32 一致;
        #        解析 '==> xxxxxxxx'(或 '= xxxxxxxx'),与 slice 文件的宿主 CRC 比对 hex。
        #        不再依赖 "Updated: OK/bytes transferred" 字样(本 u-boot 打印 'bytes written...' 变体,易误报)。
        out2 = cmd(f"crc32 {RB:#x} {sz:#x}", t=60)
        mm = re.search(r'(?:==>|=)\s*([0-9a-fA-F]{8})', out2)
        dev_crc = mm.group(1).lower() if mm else '?'
        if dev_crc == host_crc:
            print(f'  CRC ok: dev={dev_crc} host={host_crc}', file=sys.stderr, flush=True)
        else:
            print(f'  CRC MISMATCH dev={dev_crc} host={host_crc}', file=sys.stderr, flush=True)
        bad = ('Retry count exceeded' in out or 'TFTP error' in out
               or 'FAILED' in out or 'not erased' in out or 'Error' in out)
        upd_ok = dev_crc == host_crc
        ok = upd_ok and not bad
        print(f'  crc={upd_ok} bad={bad}  {"OK" if ok else "FAIL!"}',
              file=sys.stderr, flush=True)
        if not ok:
            print(f'  !! {name} 回读 CRC 不匹配,可单独重烧: python burn_parts_v4.py --parts {name}',
                  file=sys.stderr, flush=True)
    s.close()
    if tstop:
        tstop.set()
    print('\n== 完成 ==', file=sys.stderr, flush=True)


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--parts', nargs='+', default=None, help='要烧的分区名,如 DTB APP;默认 DTB KERNEL ROOTFS CONFIG APP LOGO DATA')
    ap.add_argument('--all', action='store_true', help='含 UBOOT+ENV(不推荐)')
    ap.add_argument('--no-erase', action='store_true',
                    help='jffs2 分区(CONFIG/DATA)也不整区擦除(不建议:旧节点会压过新镜像)')
    ap.add_argument('--port', default=None,
                    help=f'串口设备(macOS: /dev/cu.usbserial-1110;默认 {PORT},也可用 {ENV_PORT} 环境变量)')
    ap.add_argument('--baud', type=int, default=BAUD, help=f'波特率,默认 {BAUD}')
    ap.add_argument('--host', default=None,
                    help=f'tftp 宿主 IP;--host auto = 按到板子的路由自动取(默认 {HOST_IP},也可用 {ENV_HOST})')
    ap.add_argument('--ser-ip', default=None,
                    help=f'运行期给板子设的临时 IP(不 saveenv);默认 {SER_IP},也可用 {ENV_SER_IP}')
    ap.add_argument('--serve', action='store_true',
                    help='用脚本自带的极简 TFTP 服务(不依赖系统 tftpd;69 是特权端口,需 sudo 跑)')
    ap.add_argument('--tftp-port', type=int, default=69,
                    help='自带 TFTP 服务端口,默认 69(u-boot 固定请求 69,改这里仅调试用)')
    ap.add_argument('--dry', action='store_true', help='只打印计划')
    a = ap.parse_args()
    port = resolve_port(a.port)
    ser_ip = resolve_ser_ip(a.ser_ip)
    host_ip = resolve_host(a.host, ser_ip)
    parts = a.parts or (ALL if a.all else DEFAULT)
    if not a.parts and not a.all:
        if 'LOGO' in parts:
            print('提示: mtdparts 已加入 300K(LOGO)。首次启用 LOGO 必须同时烧 ENV(新分区表)。', file=sys.stderr)
            print('      python burn_parts_v4.py --parts ENV LOGO   # 或 --all(含 UBOOT)', file=sys.stderr)
    for p in parts:
        if p not in ALL:
            sys.exit(f'未知分区 {p};可用: {" ".join(ALL)}')
    print(f'串口={port}  板子临时IP={ser_ip}  tftp宿主={host_ip}'
          f'{"  [自带TFTP服务 :%d]" % a.tftp_port if a.serve else ""}', file=sys.stderr)
    print('燃烧计划:', ' '.join(parts), file=sys.stderr)
    je = [p for p in parts if p in JFFS2_PARTS]
    if je and not a.no_erase:
        print(f'jffs2 分区将先整区擦除再写: {" ".join(je)}', file=sys.stderr)
    if a.dry:
        sys.exit(0)
    fire(parts, no_erase=a.no_erase, port=port, baud=a.baud, ser_ip=ser_ip,
         host_ip=host_ip, serve=a.serve, tftp_port=a.tftp_port)
