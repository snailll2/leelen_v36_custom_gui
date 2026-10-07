#!/bin/bash
# =============================================================================
# flash_ram_boot.sh — AK37E 立林对讲机「RAM 内存启动」完整一键刷写
# -----------------------------------------------------------------------------
# 原则(安全红线, 不可违反):
#   * 只做 RAM boot —— tftp 载入内存后用 bootm 启动, 零写 SPI flash
#   * 不使用 saveenv —— u-boot 侧只用一次性 setenv, 掉电即还原
#   * 保留 original B_full_16MB.bin 不动; 整个流程不 touch flash 分区
#
# 流程(全自动, git-bash 以管理员/普通权限皆可):
#   1) WSL 编译 leelen_intercom        (build_arm.sh, 产出 build/leelen_intercom)
#   2) 拷新 app 进 SDK rootfs           (/usr/bin/leelen_intercom + chmod 755)
#   3) 重建"瘦身版" initramfs          (发布树 imaging/sdk_patch/mk_initramfs_mini.sh)
#   4) 重打 dtb.initrd4                (发布树 imaging/sdk_patch/_mk_wifi_dtb.sh:
#                                      usb_wifi+ION 4M+注入 initrd start/end)
#   5) 同步启动三件套 -> imaging/output (TFTP 根; 不再写 WS/tftpboot)
#
# 用法:
#   bash flash_ram_boot.sh             # 全流程: 编译 + 打包 + 同步
#   bash flash_ram_boot.sh --no-build  # 跳过编译(仅重新打包现有二进制)
#   bash flash_ram_boot.sh --flash     # 同步后同时打印 u-boot 侧 RAM boot 命令
#     (默认 --flash, 每次都会打印命令)
#
# 注意: 与 make_release.sh 同源 —— 步骤 3/4/5 调用发布树 sdk_patch/ 版本,
#       SDK 侧旧副本(rebuild_dtb_initrd.sh / mk_initramfs_mini.sh / sync_tftpboot.sh)
#       已弃用,勿再使用。
# =============================================================================
set -uo pipefail

# ---------------- 路径(改这里即可搬迁) ----------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/env.sh"   # WS/SDK/ROOTFS/APP_SRC/IC_INPUTS/IC_OUT: 发布树自包含布局
REPO="$APP_SRC"      # app 源码(与 make_release.sh 一致)
OUT="$IC_OUT"
WSL_BIN="bash"        # 换成 wsl -d Ubuntu -- 亦可

USE_BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) USE_BUILD=0 ;;
    --flash)    ;;
    *) echo "未知参数: $arg (可用 --no-build)"; exit 2 ;;
  esac
done

echo "============================================================"
echo "AK37E RAM Boot 一键刷写  /app + initramfs + dtb + output"
echo "  REPO = $REPO"
echo "  SDK  = $SDK"
echo "  OUT  = $OUT (TFTP 根) = $IC_OUT"
echo "============================================================"

# 前置检查: 输出目录必须存在(设备 tftp 抓取目录;先跑 make_release.sh 或不)
[ -d "$OUT" ] || mkdir -p "$OUT"

# 路径 -> WSL 可访问路径(/mnt/<驱动盘>/...)。处理三种输入:
#   D:\x\y  Windows 反斜杠盘符    -> /mnt/d/x/y
#   D:/x/y  Windows 正斜杠盘符    -> /mnt/d/x/y
#   /d/x/y  git-bash 正斜杠/MSYS  -> /mnt/d/x/y  (无冒号, 判断首段单字母)
#   /mnt/d/x/y 已是 WSL 形式原样返回
to_wsl() {
  local w d disc rest
  w="$(printf '%s' "$1" | sed 's#\\#/#g')"          # D:\x -> D:/x
  case "$w" in
    /mnt/*) printf '%s' "$w"; return ;;              # 已是 WSL 路径
    [A-Za-z]:/*)                                      # 含盘符冒号: D:/x/y
      d="${w%%:*}"; rest="${w#*:}"
      printf '/mnt/%s%s' "$(printf '%s' "$d" | tr 'A-Z' 'a-z')" "$rest"; return ;;
    /[A-Za-z]/*)                                      # /d/x/y: 首段单字母当盘符
      disc="${w#/}"; disc="${disc%%/*}"               # d
      rest="${w#/$disc}"
      printf '/mnt/%s%s' "$(printf '%s' "$disc" | tr 'A-Z' 'a-z')" "$rest"; return ;;
  esac
  printf '%s' "$w"                                    # 其它(相对路径等)原样
}
# WSL 内可访问的等价路径(脚本主体只用 Windows 路径, 只有进 WSL 的命令用这些)
WSL_REPO="$(to_wsl "$REPO")"
WSL_SDK="$(to_wsl "$SDK")"

# ---------------- 1) 编译 app ----------------
APP="$REPO/build/leelen_intercom"
if [ "$USE_BUILD" = "1" ]; then
  echo; echo "== [1/5] 编译 leelen_intercom (WSL) =="
  MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -s <<EOF | tail -8
set -euo pipefail
cd "$WSL_REPO" || exit 1
bash build_arm.sh
EOF
  [ -f "$APP" ] || { echo "ERROR: 编译失败, 无 $APP"; exit 1; }
else
  [ -f "$APP" ] || { echo "ERROR: --no-build 但无 $APP"; exit 1; }
  echo; echo "== [1/5] 跳过编译, 复用: $APP =="
fi
echo "  app = $(stat -c%s "$APP") B @ $(date -r "$APP" +%H:%M:%S)"

# ---------------- 2+3) 拷贝 app + 重建 mini initramfs (WSL) ----------------
# 全部走 stdin heredoc, 在 WSL 内以 /mnt/d 路径执行(WSL 的 /tmp 与 git-bash 的 /tmp 是两个世界)
echo; echo "== [2/5]+[3/5] 打包 initramfs (WSL) =="
WSL_SP="$(to_wsl "$ROOT/imaging/sdk_patch")"
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -s <<EOF
set -euo pipefail
SDK="$WSL_SDK"
# 2) 拷贝新 app 进 rootfs(initramfs 打包源)
cp -f "$WSL_REPO/build/leelen_intercom" "\$SDK/rootfs/rootfs/usr/bin/leelen_intercom"
chmod 755 "\$SDK/rootfs/rootfs/usr/bin/leelen_intercom"
echo "  [2/5] app 已入 rootfs: \$(stat -c %s "\$SDK/rootfs/rootfs/usr/bin/leelen_intercom") B"
# 3) 重建瘦身 initramfs(发布树版本;内含 .so.0 符号链接修复)
if bash "$WSL_SP/mk_initramfs_mini.sh" >/tmp/mk_initramfs_mini.log 2>&1; then
  echo "  [3/5] initramfs_mini.cpio.gz 生成 OK"
else
  echo "  [3/5] mk_initramfs_mini 失败:"; tail -20 /tmp/mk_initramfs_mini.log; exit 1
fi
stat -c '%n %s B' "\$SDK/rootfs/initramfs_mini.cpio.gz"
EOF
[ $? -eq 0 ] || exit 1

# ---------------- 4) 重打 dtb.initrd4 (WSL, 发布树 _mk_wifi_dtb.sh) ----------------
echo; echo "== [4/5] 重打 dtb.initrd4 (usb_wifi + ION 4M + 注入 initrd start/end) =="
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash "$WSL_SP/_mk_wifi_dtb.sh" \
  | grep -E "usb_wifi|mmc[12]/|chosen|initrd|dtb.initrd4|ERROR|DONE|decompile" | head -25
[ -f "$SDK/image/dtb.initrd4" ] || { echo "ERROR: dtb.initrd4 未生成"; exit 1; }

# ---------------- 5) 同步三件套到 output (git-bash 直跑) ----------------
echo; echo "== [5/5] 同步 output (git-bash) =="
mkdir -p "$OUT"
cp -f "$SDK/rootfs/initramfs_mini.cpio.gz" "$OUT/initramfs_mini.cpio.gz"
cp -f "$SDK/image/dtb.initrd4" "$OUT/dtb.initrd4"
[ -f "$OUT/uImage.initrd" ] || { echo "WARN: 无 uImage.initrd(先跑 make_release.sh 同步黄金输入)"; }
echo "  -> $OUT/initramfs_mini.cpio.gz / dtb.initrd4 / uImage.initrd"

echo
echo "============================================================"
echo " ✅ RAM Boot 三件套已就绪, 需先查 ELECTRON/SDK 侧最新尺寸:"
echo "=========== u-boot 侧 RAM boot 命令(粘贴) ==========="
SZ_CPIO=$(stat -c%s "$OUT/initramfs_mini.cpio.gz")
SZ_DTB=$(stat -c%s "$OUT/dtb.initrd4")
SZ_KERN=$(stat -c%s "$OUT/uImage.initrd")
# 注意 bootm 第二参必须用 "-" : initrd 指针已注入 dtb /chosen, 内核自读。
# 若写 0x82800000, u-boot 会按 legacy ramdisk uImage(magic 0x27051956)解析裸 cpio.gz -> Wrong Ramdisk Image Format。
printf 'tftp 0x80008000 uImage.initrd; tftp 0x82800000 initramfs_mini.cpio.gz; tftp 0x81300000 dtb.initrd4; setenv bootargs console=ttySAK0,115200n8 init=/sbin/init rdinit=/sbin/init mem=64M memsize=64M; bootm 0x80008000 - 0x81300000\n'
echo "=========== 尺寸核对(应与上面 tftp 下载字节一致) ==========="
printf '  uImage.initrd          %8d B\n  initramfs_mini.cpio.gz %8d B\n  dtb.initrd4            %8d B\n' "$SZ_KERN" "$SZ_CPIO" "$SZ_DTB"
END=$((0x82800000 + SZ_CPIO))
printf '  initrd end=0x%x  %s\n' "$END" "$([ $END -lt $((0x83000000)) ] && echo '< CMA 0x83000000 OK' || echo '!! 撞 CMA, 需缩 initramfs')"
echo "============ 设备端启动后的自检(可选) ============="
echo "  # uptime / free 看内存; 访问 http://<ip>:8080 看新控制台"
echo "============================================================"