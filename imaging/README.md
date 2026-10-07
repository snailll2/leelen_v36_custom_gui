# imaging/ — 镜像分区与刷写工具

本目录是**可开箱使用的刷写套件**(脚本相对路径与源码仓一致,clone 后无需改动):
全部生成的镜像分区 + 在线/本地刷写、部署、救砖脚本。

## 分区布局(16MB SPI NOR,NEW layout)

```
UBOOT 464K@0x0 | ENV 4K@0x74000 | DTB 64K@0x75000 | KERNEL 2M@0x85000 |
ROOTFS 2M@0x285000 | CONFIG 300K@0x485000(jffs2) | APP 5M@0x4D0000 | DATA 6.2M@0x9D0000(jffs2)
```

## output/ — 镜像分区(1.0.117,脱敏版)

| 文件 | 分区 | 说明 |
|---|---|---|
| `usr.sqsh4.new` | APP(mtd6) | **应用固件**(app+驱动+工具),最常更新的分区 |
| `root.sqsh4` | ROOTFS(mtd4) | 根文件系统(含厂方工具/wpa) |
| `config.jffs2` | CONFIG(mtd5) | app 自启脚本 + **WiFi 配置占位**(`_change_me_`,烧后经 Web 设置 WiFi) |
| `data.jffs2` | DATA(mtd8) | 主题素材 |
| `dtb_flash_wifi.dtb` | DTB(mtd2) | 设备树 |
| `env_v4.img` | ENV(mtd1) | u-boot 环境(**示例网段 192.168.168.x**,现场用 `fw_setenv` 改) |
| `uImage` | KERNEL(mtd3) | 内核 |
| `u-boot.bin` | UBOOT(mtd0) | 引导(默认参数已可启动) |
| `B_full_16MB_v4.bin` | **整片** | 16MB 一步到位(救砖;含上述全部分区) |
| `initramfs_mini.cpio.gz` / `uImage.initrd` / `dtb.initrd4` | — | RAM 内存启动三件套(开发期,零写 flash) |
| `_imgwork/slices/` | — | 整片切出的单分区切片(burn_parts_v4.py 使用) |

> **脱敏说明**:`config.jffs2`/`root.sqsh4`/整片内的 WiFi 配置均为占位
> (`psk="_change_me_"`),ENV 为示例网段 —— 烧后经 Web 控制台「网络与联网」配置。
> 本机要打含真实 WiFi 的版本用 `make_release_public.sh` 的反操作(见源码仓)。

## 三种刷写场景

### ① 日常更新 APP 分区(最常用,设备在线即可)

```bash
bash imaging/flash_usr.sh <设备IP>      # FTP+nc 双通道传输,md5 门,VERIFY OK+回读复核后重启
```

或者不用电脑——设备直连 GitHub 在线更新:Web 控制台 → 设置 → 系统更新(见仓库根 README)。

### ② 分区烧(u-boot 串口 + tftp,新板/精刷)

```bash
python3 imaging/burn_parts_v4.py --dry --host auto     # 先看计划(macOS 自动探测串口/宿主 IP)
sudo python3 imaging/burn_parts_v4.py --serve          # 自带 TFTP;默认烧七区,跳过 UBOOT/ENV 生死区
python3 imaging/burn_parts_v4.py --parts APP           # 只重烧 APP(板子须停在 u-boot 提示符)
```

### ③ 整片救砖(16MB 一步到位)

```bash
# u-boot 下: tftp 拉整片 → sf erase + sf update(u-boot 内联命令见 flash_rootfs.sh 尾注)
python3 imaging/split_v4.py    # 切片再生成工具在源码仓;本仓 _imgwork/slices/ 已备好单分区切片
```

## 其他脚本

| 脚本 | 用途 |
|---|---|
| `flash_rootfs.sh` | ROOTFS 分区烧写(改动根文件系统后用) |
| `flash_ram_boot.sh` + `boot_v4.py` | RAM 内存启动(开发迭代,零写 flash) |
| `deploy_app_tmp.sh` | /tmp 热部署(重启回滚,调试用) |
| `deploy_theme.sh` | 主题素材部署 |
| `dev_powercycle.sh` | 经 Home Assistant 开关远程断电重启(可选) |
| `devctl.py` / `icdev.py` / `serial_sh.py` | 设备 telnet/串口控制通道 |
| `ftp_xfer.py` / `captures/tcpsend.py` / `captures/mtdw` | 文件传输与 NOR 写入器 |
| `env.sh` / `env.py` | 路径单点(仅 `burn_parts_v4.py` 需要;设备 IP 用环境变量/参数覆盖) |

> ⚠️ 脚本内**默认设备 IP `192.168.50.239`、默认宿主 IP 取自路由** —— 用你自己的设备 IP 传参即可
> (如 `bash imaging/flash_usr.sh 192.168.1.100`)。

## 刷写纪律(真机踩坑总结,务必遵守)

1. **VERIFY OK + 回读 md5 数值一致才准重启**——烧写中途断电会写坏分区;
2. 传镜像前清理设备 /tmp(tmpfs=RAM,残留大文件会 OOM);
3. 烧 APP 分区前**停掉设备上的 app**(killall),否则 squashfs 边跑边写有页错误风险;
4. 首次烧 ROOTFS/CONFIG 后,先验证 WiFi 再动其他分区。
