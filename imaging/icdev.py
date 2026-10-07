#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""icdev.py — 设备交互助手(telnet 通道,root 空密码)。

为什么用 telnet 而不是串口:串口控制台被 atbm WiFi 驱动日志刷屏(dmesg 级别),
读出命令结果要跟噪声打架;telnetd 在本固件上常开,管道干净、可脚本化。
串口仍保留给"内核崩溃时抓 oops"这一个用途。

用法:
    python3 icdev.py "命令" [更多命令 ...]        # 逐条执行并打印
    python3 icdev.py --raw "命令"                 # 只打印最后一条命令的输出
"""
import socket
import sys
import time

HOST = "192.168.50.239"
PORT = 23
USER = "root"
PASS = ""


class Dev:
    def __init__(self, host=HOST, port=PORT, timeout=8.0):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(0.4)
        self.buf = b""
        self._login()

    def _read(self, t=1.2, until=None):
        t0 = time.time()
        out = b""
        while time.time() - t0 < t:
            try:
                d = self.s.recv(8192)
                if d:
                    out += d
                    t0 = time.time()
                    if until and until in out:
                        break
            except socket.timeout:
                continue
            except OSError:
                break
        self.buf += out
        return out

    def _login(self):
        # 等到明确提示符再动手(2026-09-29 修:telnetd 忙时 banner 迟到,固定节奏
        # 会把 "root" 提前发出去被丢掉,会话卡在 Password: —— 改为按状态机响应:
        # 看到 login: 发用户名,看到 Password: 发空密码,看到 shell 提示符即完成。
        for _ in range(5):
            self._read(2.0, until=b"login:")
            tail = self.buf[-400:]
            if b"$ " in tail or b"# " in tail:
                return
            if b"Password:" in tail:
                self.s.sendall(PASS.encode() + b"\r\n")
                time.sleep(0.6)
                self._read(1.5, until=b"$ ")
                return
            if b"login:" in tail:
                self.s.sendall(USER.encode() + b"\r\n")
                time.sleep(0.6)
                self._read(1.5, until=b"Password:")
                self.s.sendall(PASS.encode() + b"\r\n")
                time.sleep(0.6)
                self._read(1.5, until=b"$ ")
                return
            time.sleep(0.5)

    def run(self, cmd, wait=2.5, quiet_echo=True):
        """执行命令,返回输出(去掉命令自身回显与提示符)。"""
        self.buf = b""
        self.s.sendall(cmd.encode() + b"\r\n")
        out = self._read(wait, until=b"$ ")
        text = out.decode("utf8", "replace").replace("\r", "")
        lines = [l for l in text.splitlines() if l.strip()]
        if quiet_echo:
            lines = [l for l in lines if l.strip() != cmd and not l.strip().startswith("[root@")]
        return "\n".join(lines)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def main():
    args = [a for a in sys.argv[1:] if a != "--raw"]
    raw = "--raw" in sys.argv
    d = Dev()
    outs = []
    for c in args:
        o = d.run(c)
        outs.append(o)
    d.close()
    if raw:
        print(outs[-1])
    else:
        for c, o in zip(args, outs):
            print(f"$ {c}\n{o}\n{'-'*54}")


if __name__ == "__main__":
    main()