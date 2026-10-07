#!/bin/bash
# dev_powercycle.sh — 通过 HA 控制门口机/对讲机的供电开关,实现远程断电重启
#   开关: switch.zimi_cn_94588282_v2_on_p_2_1  (HA 192.168.50.130:8123)
#   凭证: 读本地 ~/.config/leelen/ha_token(不入库),或环境变量 HA_TOKEN 覆盖
# 用法: bash imaging/dev_powercycle.sh [设备IP]
#   关电 → 等 5 秒 → 上电 → 等设备回来(web 可用) ;打印耗时
set -u
HA="${HA_URL:-http://192.168.50.130:8123}"
TOK="${HA_TOKEN:-$(cat "$HOME/.config/leelen/ha_token" 2>/dev/null)}"
ENT="${HA_ENTITY:-switch.zimi_cn_94588282_v2_on_p_2_1}"
# 防呆(2026-09-28 真实事故:带 --status 查询也被当成断电重启执行了):
#   --status 只查开关/设备状态,绝不动开关;不认识的 --参数 直接拒绝,防止误断电。
case "${1:-}" in
  --status)
    echo "[pw] 开关状态: $(curl -s -m 8 "$HA/api/states/$ENT" -H "Authorization: Bearer $TOK" | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p')"
    curl -s -m 5 "http://192.168.50.239:8080/api/version" && echo " (设备 web 在线)" || echo "(设备 web 无响应)"
    exit 0 ;;
  --*) echo "[ERR] 未知选项 $1 —— 本脚本只接受 [设备IP],或 --status 只查不动。"; exit 2 ;;
esac
DEV="${1:-192.168.50.239}"
HA="${HA_URL:-http://192.168.50.130:8123}"
TOK="${HA_TOKEN:-$(cat "$HOME/.config/leelen/ha_token" 2>/dev/null)}"
[ -n "$TOK" ] || { echo "[ERR] 缺 HA 令牌:放 ~/.config/leelen/ha_token 或 export HA_TOKEN=..."; exit 2; }
ENT="${HA_ENTITY:-switch.zimi_cn_94588282_v2_on_p_2_1}"
svc() { curl -s -m 8 -X POST "$HA/api/services/switch/$1" \
        -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
        -d "{\"entity_id\":\"$ENT\"}"; }

echo "[pw] 断电…"; svc turn_off; echo
sleep 5
echo "[pw] 上电…"; svc turn_on; echo
echo -n "[pw] 等设备回来"
for i in $(seq 1 40); do
  sleep 5
  V="$(curl -s -m 4 "http://$DEV:8080/api/version" 2>/dev/null)"
  if [ -n "$V" ]; then echo " → $((i*5))s: $V"; exit 0; fi
  echo -n "."
done
echo " → 超时未回(需人工)"
exit 1
