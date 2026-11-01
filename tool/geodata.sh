#!/usr/bin/env bash
# =============================================================================
# 脚本名称: geodata.sh
# 功能描述: 下载并原子替换 geoip.dat / geosite.dat，成功后重启 Xray。
#           数据来源: https://github.com/Loyalsoldier/v2ray-rules-dat
# 注意: 本脚本由 cron 直接执行，不依赖 core/common.sh。
# =============================================================================

set -euo pipefail

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}"
export PATH

XRAY_DIR="/usr/local/share/xray"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/raw/release/geosite.dat"

# 清理残留临时文件
cleanup() {
    rm -f "${XRAY_DIR}/geoip.dat.new" "${XRAY_DIR}/geosite.dat.new"
}
trap cleanup EXIT

mkdir -p "${XRAY_DIR}"
cd "${XRAY_DIR}"

# 先下载到临时文件，全部成功后再替换，避免中途失败导致数据文件缺失
curl -fsSL --retry 3 --retry-delay 2 -o geoip.dat.new "${GEOIP_URL}"
curl -fsSL --retry 3 --retry-delay 2 -o geosite.dat.new "${GEOSITE_URL}"

# 简单校验：dat 文件不应为空且带有魔数 "DAT" 之外的合理大小
[[ -s geoip.dat.new && -s geosite.dat.new ]] || {
    echo "downloaded geo data is empty" >&2
    exit 1
}

mv -f geoip.dat.new geoip.dat
mv -f geosite.dat.new geosite.dat

if systemctl -q is-active xray 2>/dev/null; then
    systemctl restart xray
fi
