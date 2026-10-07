#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自包含 TCP 单次发送器:监听端口,接受一个连接,把整个文件发过去。
解决 Mac `nc -l < file &` 后台化后 stdin fd 被关导致只发 1KB 的问题。
用法: python3 tcpsend.py <file> <port> [rate_kbps]
  rate_kbps: 可选限速(设备 nc 接收慢时用,如 400=400KB/s 防截断)"""
import socket, sys, time

def main():
    path, port = sys.argv[1], int(sys.argv[2])
    rate_kbps = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    data = open(path, "rb").read()
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(1)
    print(f"listening :{port}, file={path} ({len(data)}B) rate={rate_kbps}KB/s", flush=True)
    c, a = s.accept()
    print(f"conn from {a}", flush=True)
    if rate_kbps > 0:
        # 限速:按块发送 + 微睡眠,给慢速设备 nc 时间跟上
        chunk = max(1024, rate_kbps // 20)          # 每次 ~1/20 秒的量
        for i in range(0, len(data), chunk):
            c.sendall(data[i:i+chunk])
            time.sleep(0.05)
    else:
        c.sendall(data)
    c.shutdown(socket.SHUT_WR)
    c.close()
    s.close()
    print(f"sent {len(data)}B", flush=True)

if __name__ == "__main__":
    main()
