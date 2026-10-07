#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ftp_xfer.py — 用设备自带 ftpd(端口 21,root 空密码,`tcpsvd 0 21 ftpd -w /`)收发文件。

为什么用 FTP 而不是 nc / tftp(2026-09-24 实测):
  * **速度差 20 倍**:同一个 4.8MB 镜像,FTP 3.5s(1333KB/s),设备侧 busybox nc 只有
    ~62KB/s 且经常中途截断 —— busybox 的 nc 读写缓冲极小,TCP 窗口撑不开。
  * TFTP 走不通:设备 busybox `tftp` 客户端不支持 blksize 协商 → 512B/块 + 每块一 ACK,
    4.8MB 要近万次往返,丢包链路上必然超时(上轮记录"busybox tftp 传 5MB 必失败")。
    imaging/tftp_min.py 那套(带 blksize/tsize)是给 u-boot 整片刷机用的,设备侧不协商。
  * FTP 有真正的流控与重传,ftpd 常驻(telnetd/ftpd 都是系统服务,不依赖 app 活着)。

用法:
    python3 imaging/ftp_xfer.py <host> put <本地文件> <设备路径>
    python3 imaging/ftp_xfer.py <host> get <设备路径> <本地文件>
退出码 0 = 传完且(put 时)打印字节数;非 0 = 失败。
"""
import os, sys, hashlib, time
from ftplib import FTP


def main():
    if len(sys.argv) < 5:
        print(__doc__ or ""); return 2
    host, op, a, b = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    if op == "put":
        local, remote = a, b
    elif op == "get":
        remote, local = a, b
    else:
        print("op 只能是 put / get"); return 2

    f = FTP()
    f.connect(host, 21, timeout=30)
    f.login("root", "")
    t0 = time.time()
    if op == "put":
        with open(local, "rb") as fp:
            f.storbinary("STOR " + remote, fp, blocksize=65536)
        n = os.path.getsize(local)
        md5 = hashlib.md5(open(local, "rb").read()).hexdigest()[:8]
    else:
        with open(local, "wb") as fp:
            f.retrbinary("RETR " + remote, fp.write, blocksize=65536)
        n = os.path.getsize(local)
        md5 = hashlib.md5(open(local, "rb").read()).hexdigest()[:8]
    f.quit()
    dt = max(time.time() - t0, 1e-3)
    print(f"{op} OK {n}B {dt:.1f}s {n/dt/1024:.0f}KB/s md5={md5} {local if op=='put' else remote}")
    return 0


if __name__ == "__main__":
    sys.exit(main())