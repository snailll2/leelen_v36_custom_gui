import serial, sys, time, socket
sys.stdout.reconfigure(encoding='utf8', errors='replace')
s=serial.Serial('COM3',115200,timeout=0.15,exclusive=True); s.reset_input_buffer()
def rd(t=0.8):
    b=b'';e=time.time()+t
    while time.time()<e:
        if s.in_waiting: b+=s.read(s.in_waiting)
        time.sleep(0.03)
    return b
def wait_for(needle, t):
    b=b'';t0=time.time()
    while time.time()-t0<t:
        b+=rd(0.4)
        if needle in b: return b.decode('utf8','replace')
    return b.decode('utf8','replace')
# ensure at boot prompt or uboot
o=wait_for(b'=> ', 30)
if '=> ' in o:
    print('AT UBOOT')
else:
    print('not uboot, tail:', repr(o[-200:]))
    # maybe kernel running? reboot via web
    try:
        c=socket.create_connection(('192.168.50.199',8080),timeout=2); c.settimeout(2)
        c.sendall(b'POST /api/act HTTP/1.1\r\nHost: x\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{"op":"reboot"}')
        time.sleep(1); c.close()
        print('web reboot sent')
        o=wait_for(b'=> ', 60)
        print('after reboot:', 'UBOOT' if '=>' in o else 'no')
    except Exception as e:
        print('web fail', e); s.close(); sys.exit(2)
# tftp trio
for name,addr in (('uImage.initrd','0x80008000'),('initramfs_mini.cpio.gz','0x82800000'),('dtb.initrd4','0x81300000')):
    ok=False
    for att in range(2):
        s.write(f'tftp {addr} {name}\r'.encode())
        o=wait_for(b'=> ', 55)
        ok=any('Bytes transferred' in L for L in o.splitlines())
        print(name, 'OK' if ok else f'FAIL{att}', [L.strip() for L in o.splitlines() if 'Bytes transferred' in L or 'Error' in L][-1:])
        if ok: break
    if not ok:
        print('ABORT'); s.close(); sys.exit(3)
s.write(b'bootm 0x80008000 - 0x81300000\r')
print('bootm fired', flush=True)
bt=time.time(); out=b''; ev=[]; seen=set()
KEY=[(b'Starting kernel','KERN'),(b'panic','PANIC'),(b'atbm_usb_module_init','ATBM'),
     (b'wifi_guard started','GSTART'),(b'wlan0','WLAN0'),(b'Password','PW'),(b'login:','LOGIN'),
     (b'RecvLength 0','RX0'),(b'disconnent','DIS'),(b'registered as','REGD'),(b'leelen_intercom','APP')]
while time.time()-bt<180:
    if s.in_waiting:
        x=s.read(s.in_waiting); out+=x
        for k,n in KEY:
            if k in x and n not in seen:
                seen.add(n); ev.append(n+'@%ds'%(time.time()-bt))
    time.sleep(0.05)
print('EVENTS:', ev)
print('tail:', out.decode('utf8','replace')[-200:].replace(chr(10),'\n'))
s.close()
