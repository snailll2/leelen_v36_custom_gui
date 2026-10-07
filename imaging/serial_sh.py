#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""serial_sh.py — 通过 USB 串口控制台在设备上跑命令(登录 root/空密码,带重试)。

为什么需要它:设备可能临时没有网络服务(比如 /usr 被换成缺 telnetd/wpa_supplicant 的镜像、
或 wlan0 掉了),这时**串口控制台是唯一可靠通道**。telnetd 会随镜像变化,串口不会。

老坑(memory 里记过):
  * 登录有竞态 —— 用户名/密码打早了会被吞,telnetd/getty 偶尔吞第一次输入。这里用
    "发 echo 探针 → 看到 __SOK__ 才算登录成功,失败重试 3 次" 兜住。
  * **读必须固定窗口**,不要续期等待:设备日志刷屏时永远等不到静默。
  * 登录后有回显,输出里会混着命令本身,这里按行过滤掉。

用法:
    python3 imaging/serial_sh.py "cmd1" "cmd2" ...
    python3 imaging/serial_sh.py --port /dev/cu.usbserial-1110 --wait 6 "ps"
    INTERCOM_SERIAL=/dev/cu.usbserial-XXXX python3 imaging/serial_sh.py "df -h"
"""
import os, sys, time

def default_port():
    p = os.environ.get("INTERCOM_SERIAL")
    if p:
        return p
    for c in ("/dev/cu.usbserial-1110", "/dev/cu.usbserial"):
        if os.path.exists(c):
            return c
    return None


class SerialSh:
    def __init__(self, port=None, baud=115200, debug=False):
        import serial
        port = port or default_port()
        if not port or not os.path.exists(port):
            raise SystemExit(f"串口不存在: {port}(用 INTERCOM_SERIAL 指定)")
        self.s = serial.Serial(port, baud, timeout=0.3)
        self.debug = debug

    def _read(self, t):
        b = b''
        t0 = time.time()
        while time.time() - t0 < t:                 # 固定窗口,不续期
            d = self.s.read(8192)
            if d:
                b += d
        return b.decode("utf8", "replace")

    def _write(self, s):
        self.s.write(s.encode() + b"\r")

    def login(self, tries=6):
        """一直折腾到看见 shell 提示符为止。
        串口控制台的真实状态是会跳的:可能是 login:、可能是 Password:、也可能停在上一次
        遗留的 shell 里(带未结束的命令)。所以不猜状态,循环:每轮发 Ctrl-C 唤醒 + 回车,
        看回来的是什么再决定下一步 —— 直到出现 `[root@anyka ~]$`。"""
        for i in range(tries):
            self.s.write(b"\x03"); time.sleep(0.3)
            self._write("")                      # 回车
            b = self._read(1.5)
            if "assword" in b:
                self.s.write(b"\r"); time.sleep(1.0); b += self._read(1.5)
            if "login:" in b:
                self.s.write(b"root\r"); time.sleep(1.0)
                b2 = self._read(1.5)
                if "assword" in b2:
                    self.s.write(b"\r"); time.sleep(1.0); b2 += self._read(1.5)
                b += b2
            if "[root@" in b or "] $" in b or "# " in b:
                # 见到提示符,再用探针确认真的能执行
                self._write("echo __SOK__")
                if "__SOK__" in self._read(1.8):
                    return True
            if self.debug:
                print(f"[login 第 {i+1} 轮] {b[-200:]!r}", file=sys.stderr)
            time.sleep(0.5)
        return False

    def run(self, cmd, wait=5.0):
        self._write(cmd)
        raw = self._read(wait)
        out = []
        for line in raw.replace("\r", "").splitlines():
            t = line.strip()
            if not t or t == cmd or t.startswith("[root@") or "__SOK__" in t:
                continue
            out.append(line.rstrip())
        return "\n".join(out)

    def close(self):
        try: self.s.close()
        except Exception: pass


def main():
    args = sys.argv[1:]
    port = None; wait = 5.0; debug = False
    while args and args[0].startswith("--"):
        if args[0] == "--port":  port = args[1]; args = args[2:]
        elif args[0] == "--wait": wait = float(args[1]); args = args[2:]
        elif args[0] == "--debug": debug = True; args = args[1:]
        else: break
    if not args:
        print(__doc__ or ""); return 2
    sh = SerialSh(port, debug=debug)
    try:
        if not sh.login():
            print("[ERR] 串口登录失败(重试 3 次)。检查:串口是否被别的终端占着? 设备是否在跑?", file=sys.stderr)
            return 1
        for c in args:
            print(f"$ {c}", flush=True)
            print(sh.run(c, wait), flush=True)
    finally:
        sh.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())