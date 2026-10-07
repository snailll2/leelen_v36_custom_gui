#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""devctl.py — 在设备上跑 shell 命令(telnet 通道,root 空密码),支持自定义等待时长。

和 icdev.py 的区别:icdev.py 是给人看的交互助手(等待时长写死 2.5s),
devctl.py 是给脚本用的原语 —— 等待时长可调,输出按命令分段打印,退出码反映连接是否成功。

为什么控制通道用 telnet 而不是 HTTP /api/exec:
  * /api/exec 是**阻塞**的:上面跑长命令(nc 拉文件、大文件校验)会把 app 的 web 线程占住,
    之后所有 HTTP 请求排队超时(真机实测:整片 web 卡死、响应丢失);
  * app 被停掉时(部署中途)HTTP 通道直接没了,而 telnetd 是系统服务,一直在。

用法:
    python3 imaging/devctl.py [--wait N] "cmd1" ["cmd2" ...]
    python3 imaging/devctl.py --wait 5 'ls -la /tmp/leelen_new'
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from icdev import Dev

def main():
    wait = 3.0
    host = os.environ.get("INTERCOM_DEV")          # 设备可能在不同网段(现场网/办公网),允许覆盖
    args = sys.argv[1:]
    while args and args[0].startswith("--"):
        if args[0] == "--wait":
            wait = float(args[1]); args = args[2:]
        elif args[0] == "--host":
            host = args[1]; args = args[2:]
        else:
            print("未知参数:", args[0]); return 2
    if not args:
        print(__doc__ or ""); return 2
    d = Dev(host=host) if host else Dev()
    try:
        for c in args:
            out = d.run(c, wait=wait)
            if len(args) > 1:
                print(f"$ {c}")
            print(out, flush=True)
    finally:
        d.close()
    return 0

if __name__ == "__main__":
    sys.exit(main())