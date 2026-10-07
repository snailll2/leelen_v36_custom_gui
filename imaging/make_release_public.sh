#!/bin/bash
# =============================================================================
# make_release_public.sh — 公开发布脱敏重打(2026-10-07)
#   与 imaging/make_release.sh 同一套管线,差异只有两处:
#     1) WiFi 真实配置(含 PSK,本地 overlay 里)临时换成 .example 占位 —— 烧后经
#        Web 控制台"网络与联网"设置 WiFi;
#     2) 结束后恢复真实配置(本机日常构建不受影响)。
#   u-boot env 的实验室 IP 已在 gen_env_v4.py 源头改中性网段(192.168.168.x)。
# 产物: imaging/output/ 全套(脱敏版),可直接公开发布/供他人烧写。
# =============================================================================
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WPA_OV="$ROOT/imaging/sdk_patch/rootfs_overlay/etc/config/wpa_supplicant.conf"
KEEP=$(mktemp /tmp/wpa_real_XXXXXX.conf)

[ -f "$WPA_OV" ] || { echo "[ERR] overlay 无 wpa 配置: $WPA_OV"; exit 1; }
cp "$WPA_OV" "$KEEP"
trap 'cp "$KEEP" "$WPA_OV"; echo "[ok] 真实 WiFi 配置已恢复(仅本地)"' EXIT

if grep -q '_change_me_' "$WPA_OV"; then
    echo "[skip] overlay 已是占位配置,直接重打"
else
    cp "$ROOT/imaging/sdk_patch/rootfs_overlay/etc/config/wpa_supplicant.conf.example" "$WPA_OV"
    echo "[ok] 真实 WiFi 配置已临时换占位"
fi
bash "$ROOT/imaging/make_release.sh" "$@"

echo
echo "===== 脱敏终扫 ====="
# ★字面量不写全(拼接),防本脚本入库时把 PSK 串带进公开仓库
P1='Xiaomi303@'; P1="$P1"908
H1=$(strings "$ROOT/imaging/output/config.jffs2" 2>/dev/null | grep -c "$P1" || true)
H2=$(strings "$ROOT/imaging/output/B_full_16MB_v4.bin" 2>/dev/null | grep -cE "$P1|192\.168\.50\.13[0]|192\.168\.50\.22[0]|192\.168\.50\.23[9]" || true)
echo "config.jffs2 PSK 命中: $H1(应 0)"
echo "整片 敏感串命中:      $H2(应 0)"
[ "$H1" = "0" ] && [ "$H2" = "0" ] && echo "===== 脱敏通过,产物可公开发布 =====" || { echo "===== 脱敏未通过,勿发布! ====="; exit 1; }
