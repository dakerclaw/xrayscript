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

# 是否重启 Xray:
#   - cron 自动执行 (父进程为 cron/crond): 更新后立即重启, 此时无人在线操作
#   - 菜单手动触发: 不重启, 避免切断正在使用的 SSH/代理会话
#     (本地 22 端口被封时, SSH 本身走 Reality 入站, 重启 Xray 会直接断线)
#     数据文件已就位, 下次重启或每日 6:30 cron 执行时自动生效
NEED_RESTART='0'
if [[ "${PPID:-0}" -gt 1 ]]; then
    parent_comm="$(ps -o comm= -p "${PPID}" 2>/dev/null | tr -d '[:space:]')"
    case "${parent_comm,,}" in
    cron | crond) NEED_RESTART='1' ;;
    esac
else
    # PPID=1 通常是 daemon/cron 派生的孤儿进程, 视为自动执行
    NEED_RESTART='1'
fi

if [[ "${NEED_RESTART}" == '1' ]] && systemctl -q is-active xray 2>/dev/null; then
    systemctl restart xray
elif [[ "${NEED_RESTART}" != '1' ]]; then
    echo "geodata updated; xray not restarted (manual run). It will take effect after next xray restart or the daily cron." >&2
fi
