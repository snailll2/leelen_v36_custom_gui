#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tftp_min.py — 极简只读 TFTP 服务端(RRQ),给 u-boot 的 tftp 直接用。

为什么自带:省掉"宿主上装/配一个 tftp 服务"(Windows tftpd64、macOS 的
launchd tftpd + /private/tftpboot 软链)。实现取自 burn_vendor_restore.py 里
跑通过的那份(2026-09-18 恢复原厂镜像时验证),这里抽出来共用。

要点:
  * 支持 blksize/tsize 选项协商 + 停等重传。u-boot 会请求 blksize(=1468),
    协商成功后 5MB 分区只需 ~3.5k 块;**不协商**死守 512B,传大区会超时失败。
  * 端口:u-boot 的 tftp 固定把 RRQ 发到 69(实测本板 u-boot 无 tftpdstp 之类
    的自定义端口 env),所以用本服务要提权:sudo 跑,否则换用你自己的 tftp 服务。
  * 只读、只服务 root 目录下的普通文件;RRQ 路径里的前导 / 会被剥掉。

用法(两个层次,便于调用方区分"绑定失败"和"传输失败"):
    sock, err = open_server(host, port)     # 主线程绑定,失败立刻知道
    threading.Thread(target=serve_forever, args=(sock, root, stop), daemon=True).start()
或一把梭(绑定失败只打印提示,不抛):
    serve(root, host, port=69, stop=None)
"""
import os
import socket
import struct
import sys

OP_RRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 3, 4, 5, 6
DEFAULT_BLKSIZE = 512
MAX_BLKSIZE = 1468          # 与 u-boot 请求值一致;再大会超以太网 MTU 分片


def open_server(host, port=69):
    """绑定 UDP 端口。返回 (socket, None) 或 (None, 错误说明字符串)。

    host 不是本机地址时(常见:沿用别的机器的 serverip)自动退化为绑 0.0.0.0 ——
    谁发 RRQ 都能收;u-boot 侧的 serverip 仍由调用方决定,与本绑定无关。
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((host, port))
    except OSError as e:
        if e.errno in (49, 99):                  # EADDRNOTAVAIL:该 IP 不属于本机
            print(f"  注:{host} 不是本机地址,改为监听 0.0.0.0:{port}"
                  f"(u-boot 的 serverip 请用 --host 指到本机真实 IP)", file=sys.stderr, flush=True)
            try:
                s.bind(("0.0.0.0", port))
            except OSError as e2:
                s.close()
                return None, _explain(host, port, e2)
        else:
            s.close()
            return None, _explain(host, port, e)
    s.settimeout(1.0)
    return s, None


def _explain(host, port, e):
    if port < 1024:
        return (f"绑定 {host}:{port} 失败({e})—— {port} 是特权端口,且可能已被系统 tftpd 占用。"
                f"用 sudo 跑,或去掉 --serve 用你自己的 tftp(根目录指向产物目录)")
    return f"绑定 {host}:{port} 失败({e})—— 端口被占用?换 --tftp-port 或关掉占用的服务"


def serve_forever(sock, root, stop=None):
    """在已绑定的 socket 上循环响应 RRQ,直到 stop(threading.Event)置位。"""
    while not (stop and stop.is_set()):
        try:
            data, peer = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) < 4 or data[:2] != b"\x00\x01":
            continue
        # RRQ 体:filename\0mode\0[opt\0val\0]... —— 选项对从 mode 之后开始配对,
        # 别把 filename 混进去(踩过:opts 变成 {'octet': 'blksize', ...},协商全废)
        body = data[2:].split(b"\x00")
        fname = body[0].decode("latin1")
        rest = [f for f in body[1:] if f]                      # rest[0]=mode
        opts = {}
        for i in range(1, len(rest) - 1, 2):
            opts[rest[i].decode("latin1").lower()] = rest[i + 1].decode("latin1")
        path = os.path.join(root, fname.lstrip("/"))
        if not os.path.isfile(path):
            sock.sendto(b"\x00\x05\x00\x01not found\x00", peer)
            print(f"  TFTP RRQ {fname} ⊘ 不存在(根={root})", file=sys.stderr, flush=True)
            continue
        blob = open(path, "rb").read()
        print(f"  TFTP RRQ {fname} ({len(blob)} B) from {peer} opts={opts}",
              file=sys.stderr, flush=True)
        _send_one(blob, peer, opts)
    sock.close()


def _send_one(blob, peer, opts):
    """单客户端停等发送:OACK 协商 → DATA/ACK 循环 → 尾块收尾。"""
    cs = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cs.settimeout(3.0)
    blksize = DEFAULT_BLKSIZE
    oack = b""
    if "blksize" in opts:
        try:
            blksize = max(8, min(int(opts["blksize"]), MAX_BLKSIZE))
        except ValueError:
            blksize = DEFAULT_BLKSIZE
        oack += b"blksize\x00%d\x00" % blksize
    if "tsize" in opts:
        oack += b"tsize\x00%d\x00" % len(blob)
    if oack:                                    # 选项协商:OACK 后等 ACK 0
        for _ in range(10):
            cs.sendto(b"\x00\x06" + oack, peer)
            try:
                a, _p = cs.recvfrom(1024)
            except socket.timeout:
                continue
            if a[:2] == b"\x00\x04" and struct.unpack("!H", a[2:4])[0] == 0:
                break
    blk, pos = 1, 0
    while True:
        chunk = blob[pos:pos + blksize]
        pkt = b"\x00\x03" + struct.pack("!H", blk) + chunk
        acked = False
        for _ in range(12):                     # 本块最多重传 12 次
            cs.sendto(pkt, peer)
            try:
                a, _p = cs.recvfrom(1024)
            except socket.timeout:
                continue
            if a[:2] == b"\x00\x05":
                break
            if a[:2] != b"\x00\x04":
                continue
            if struct.unpack("!H", a[2:4])[0] == blk:
                acked = True
                break
            # 重复 ACK(上一块):继续重发本块
        if not acked:
            print(f"  !! TFTP 传输在块 {blk} 失败(客户端无 ACK)", file=sys.stderr, flush=True)
            break
        pos += len(chunk)
        blk = (blk + 1) & 0xffff
        if len(chunk) < blksize:
            break
    cs.close()


def serve(root, host, port=69, stop=None):
    """便捷入口:绑定后阻塞服务(绑定失败只打印提示,不抛异常)。"""
    sock, err = open_server(host, port)
    if err:
        print("!! " + err, file=sys.stderr)
        return
    print(f"TFTP 服务: {host}:{port} 根={root}", file=sys.stderr, flush=True)
    serve_forever(sock, root, stop)


if __name__ == "__main__":
    serve(sys.argv[1] if len(sys.argv) > 1 else ".",
          sys.argv[2] if len(sys.argv) > 2 else "0.0.0.0",
          int(sys.argv[3]) if len(sys.argv) > 3 else 69)