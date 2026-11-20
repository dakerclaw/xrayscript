#!/usr/bin/env bash
# =============================================================================
# 脚本名称: bbr.sh
# 功能描述: 开启/关闭/查看 TCP 加速 (BBR 拥塞控制 + 大管道缓冲区调优)。
#           配置写入 /etc/sysctl.d/ 持久化，并立即生效。
#           由 handler.sh 调用，也可直接执行。
#
#           缓冲区调优说明:
#             代理服务器普遍是跨境高延迟链路 (如 CN->US, RTT 约 200ms)。
#             此时带宽时延积(BDP)很大, 内核默认 tcp_rmem/wmem 上限不足以
#             跑满带宽; 而 net.core.rmem_max 默认仅 208KB, 会直接把窗口
#             卡在 208KB —— 这是"能连但很慢"的常见原因。
#             本脚本把上限放宽到 16MB, 并开启服务端 TFO / MTU 探测。
# 用法:
#   bash bbr.sh --status      显示拥塞控制/队列/缓冲区/可用算法
#   bash bbr.sh --is-enabled  已开启加速时退出码为 0
#   bash bbr.sh --enable      开启 (bbr + fq + TCP 缓冲区调优)
#   bash bbr.sh --disable     关闭 (恢复 cubic + fq_codel + 默认缓冲区)
# =============================================================================

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}"
export PATH

readonly BBR_CONF='/etc/sysctl.d/99-xrayscript-bbr.conf'
readonly TCP_CONF='/etc/sysctl.d/99-xrayscript-tcp.conf'
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
    printf 'rmem_max           : %s\n' "$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo unknown)"
    printf 'wmem_max           : %s\n' "$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo unknown)"
    printf 'tcp_fastopen       : %s\n' "$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || echo unknown)"
    printf 'mtu_probing        : %s\n' "$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || echo unknown)"
    printf 'persistent_config  : %s\n' "$([[ -f "${BBR_CONF}" ]] && echo "${BBR_CONF}" || echo '(none)')"
    printf 'tcp_config         : %s\n' "$([[ -f "${TCP_CONF}" ]] && echo "${TCP_CONF}" || echo '(none)')"
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

# =============================================================================
# 函数名称: tune_buffers
# 功能描述: 写入并应用 TCP 缓冲区调优参数 (高延迟链路提速)。
#           独立于 BBR: 即使内核不支持 bbr, 缓冲区调优依然有效。
# =============================================================================
function tune_buffers() {
    cat >"${TCP_CONF}" <<'EOF' || return 1
# Managed by xrayscript: TCP buffer tuning for high-latency proxy links
# 高延迟链路(如 CN->US, RTT 约 200ms)需要更大窗口才能跑满带宽

# 缓冲区上限: 默认 208KB -> 16MB
# 注意: 若不放开 rmem_max/wmem_max, 下面 tcp_rmem/wmem 的大值不会生效
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 突发报文缓冲, 降低瞬时丢包
net.core.netdev_max_backlog = 5000

# TCP Fast Open: 3 = 客户端 + 服务端 (默认 1 仅客户端)
net.ipv4.tcp_fastopen = 3

# 空闲后不重置拥塞窗口, 保持长连接速率
net.ipv4.tcp_slow_start_after_idle = 0

# MTU 探测, 应对路径 MTU 不一致导致的卡顿
net.ipv4.tcp_mtu_probing = 1
EOF

    local key=''
    local value=''
    while IFS='=' read -r key value; do
        key="$(printf '%s' "${key}" | tr -d '[:space:]')"
        value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        sysctl_set "${key}" "${value}" || true
    done <"${TCP_CONF}"

    printf 'tcp buffers tuned (rmem_max=%s, tcp_fastopen=%s)\n' \
        "$(cat /proc/sys/net/core/rmem_max 2>/dev/null)" \
        "$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null)"
}

function enable() {
    local cc=''

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo 'bbr: root privileges required' >&2
        return 1
    fi

    # 缓冲区调优与 bbr 无关, 先做, 即使内核不支持 bbr 也能生效
    tune_buffers || true

    if ! bbr_available; then
        echo 'bbr: kernel does not support tcp_bbr, buffer tuning applied only' >&2
        return 0
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

    rm -f "${BBR_CONF}" "${TCP_CONF}"
    sysctl_set 'net.ipv4.tcp_congestion_control' 'cubic' || true
    sysctl_set 'net.core.default_qdisc' 'fq_codel' || true

    # 恢复内核默认缓冲区, 避免调优参数残留
    sysctl_set 'net.core.rmem_max' '212992' || true
    sysctl_set 'net.core.wmem_max' '212992' || true
    sysctl_set 'net.ipv4.tcp_rmem' '4096 131072 6291456' || true
    sysctl_set 'net.ipv4.tcp_wmem' '4096 16384 4194304' || true
    sysctl_set 'net.ipv4.tcp_fastopen' '1' || true
    sysctl_set 'net.ipv4.tcp_slow_start_after_idle' '1' || true
    sysctl_set 'net.ipv4.tcp_mtu_probing' '0' || true

    printf 'acceleration disabled (congestion_control=%s, default_qdisc=%s)\n' \
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
