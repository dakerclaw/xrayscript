#!/usr/bin/env bash
# =============================================================================
# 脚本名称: bbr.sh
# 功能描述: 开启/关闭/查看 TCP BBR 拥塞控制加速。
#           配置写入 /etc/sysctl.d/99-xrayscript-bbr.conf 持久化，并立即生效。
#           由 handler.sh 调用，也可直接执行。
# 用法:
#   bash bbr.sh --status      显示当前拥塞控制/队列/可用算法
#   bash bbr.sh --is-enabled  已开启 BBR 时退出码为 0
#   bash bbr.sh --enable      开启 BBR (拥塞控制 bbr + 队列 fq)
#   bash bbr.sh --disable     关闭 BBR (恢复 cubic + fq_codel)
# =============================================================================

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}"
export PATH

readonly BBR_CONF='/etc/sysctl.d/99-xrayscript-bbr.conf'
readonly CC_PATH='/proc/sys/net/ipv4/tcp_congestion_control'
readonly AVAIL_PATH='/proc/sys/net/ipv4/tcp_available_congestion_control'
readonly QDISC_PATH='/proc/sys/net/core/default_qdisc'

function current_cc() {
    tr -d '[:space:]' <"${CC_PATH}" 2>/dev/null
}

function current_qdisc() {
    tr -d '[:space:]' <"${QDISC_PATH}" 2>/dev/null
}

function sysctl_set() {
    # 统一入口: 优先 sysctl，失败时直接写 /proc/sys
    local key="$1"
    local value="$2"
    local path=''

    if command -v sysctl >/dev/null 2>&1; then
        sysctl -q -w "${key}=${value}" >/dev/null 2>&1 && return 0
    fi

    path="/proc/sys/$(printf '%s' "${key}" | tr '.' '/')"
    printf '%s' "${value}" >"${path}" 2>/dev/null
}

function status() {
    local cc=''
    local qdisc=''
    local avail=''

    cc="$(current_cc)"
    qdisc="$(current_qdisc)"
    avail="$(tr -s '[:space:]' ' ' <"${AVAIL_PATH}" 2>/dev/null | sed 's/^ //; s/ $//')"

    printf 'congestion_control : %s\n' "${cc:-unknown}"
    printf 'default_qdisc      : %s\n' "${qdisc:-unknown}"
    printf 'available          : %s\n' "${avail:-unknown}"
    printf 'persistent_config  : %s\n' "$([[ -f "${BBR_CONF}" ]] && echo "${BBR_CONF}" || echo '(none)')"
    # 状态查询本身永远返回 0，是否开启由 --is-enabled 判断
    printf 'enabled            : %s\n' "$([[ "${cc}" == 'bbr' ]] && echo yes || echo no)"
    return 0
}

function is_enabled() {
    [[ "$(current_cc)" == 'bbr' ]]
}

function bbr_available() {
    # 模块可能未加载，先尝试加载再读可用列表
    [[ -r "${AVAIL_PATH}" ]] || return 1
    grep -qw 'bbr' "${AVAIL_PATH}" 2>/dev/null && return 0
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null
    grep -qw 'bbr' "${AVAIL_PATH}" 2>/dev/null
}

function enable() {
    local cc=''

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo 'bbr: root privileges required' >&2
        return 1
    fi

    if ! bbr_available; then
        echo 'bbr: kernel does not support tcp_bbr' >&2
        return 1
    fi

    cat >"${BBR_CONF}" <<'EOF' || return 1
# Managed by xrayscript: TCP BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    # 先设队列再设拥塞控制，顺序与大多数发行版推荐做法一致
    sysctl_set 'net.core.default_qdisc' 'fq' || true
    sysctl_set 'net.ipv4.tcp_congestion_control' 'bbr' || true

    cc="$(current_cc)"
    if [[ "${cc}" != 'bbr' ]]; then
        # 设置失败时不留下无用的持久化配置，避免下次开机再失败一次
        rm -f "${BBR_CONF}"
        echo "bbr: failed to switch congestion control (current: ${cc:-unknown})" >&2
        return 1
    fi

    printf 'bbr enabled (congestion_control=%s, default_qdisc=%s)\n' "${cc}" "$(current_qdisc)"
}

function disable() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo 'bbr: root privileges required' >&2
        return 1
    fi

    rm -f "${BBR_CONF}"
    sysctl_set 'net.ipv4.tcp_congestion_control' 'cubic' || true
    sysctl_set 'net.core.default_qdisc' 'fq_codel' || true

    printf 'bbr disabled (congestion_control=%s, default_qdisc=%s)\n' \
        "$(current_cc)" "$(current_qdisc)"
}

case "${1:---status}" in
--status) status ;;
--is-enabled) is_enabled ;;
--enable) enable ;;
--disable) disable ;;
*)
    echo "usage: $0 [--status|--is-enabled|--enable|--disable]" >&2
    exit 1
    ;;
esac
