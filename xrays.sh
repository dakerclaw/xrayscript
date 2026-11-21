#!/usr/bin/env bash
# =============================================================================
# 脚本名称: xrays.sh (简化版, 单文件)
# 功能描述: VLESS + Vision + REALITY 一键安装脚本。
#             - Xray 官方稳定版安装
#             - VLESS + Vision + REALITY 入站
#             - 交互式手动输入参数（回车使用默认值）
#             - TCP BBR 加速（默认开启）
#             - 客户端分享链接（自动检测 IPv6，有则同时输出 IPv6 链接）
# 依赖: bash, jq, curl/wget, openssl, unzip, systemd
# 用法:
#   bash xrays.sh              交互式安装
#   wget -qO- <raw-url> | bash 非交互安装（全部使用默认值）
# =============================================================================

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}"
export PATH

# --- 常量 -------------------------------------------------------------------
readonly CONFIG_DIR='/usr/local/etc/xray'
readonly CONFIG_PATH="${CONFIG_DIR}/config.json"
readonly SHARE_PATH="${CONFIG_DIR}/share.txt"

readonly UUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly DOMAIN_REGEX='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'

# 官方安装脚本镜像，依次尝试
readonly INSTALLER_URLS=(
    'https://github.com/XTLS/Xray-install/raw/main/install-release.sh'
    'https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
    'https://ghproxy.net/https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
    'https://gh-proxy.com/https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
)

# REALITY 伪装域名候选池（均支持 TLS 1.3），回车时随机选择
readonly TARGET_POOL=(
    'www.fandom.com'
    'www.tidal.com'
    'www.pixiv.co.jp'
    'mora.jp'
    'booth.pm'
    'www.ivi.tv'
    'www.sky.com'
)

# --- 全局变量 ---------------------------------------------------------------
OS=''
OS_VERSION=''
TARGET=''
PORT='443'
UUID_RAW=''
UUID=''
PRIVATE_KEY=''
PUBLIC_KEY=''
SHORT_IDS=()
IPV6_HOST=''
PREVIOUS_INSTALL='n'
KEYS_REGENERATED='n'
INSTALLER_TMP=''

# =============================================================================
# 日志
# =============================================================================
function info() { printf '\033[32m[信息]\033[0m %s\n' "$*" >&2; }
function ok() { printf '\033[32m[通过]\033[0m %s\n' "$*" >&2; }
function warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
function err() { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
function die() {
    err "$*"
    exit 1
}

function cmd_exists() { command -v "$1" >/dev/null 2>&1; }

function cleanup() {
    [[ -n "${INSTALLER_TMP}" && -f "${INSTALLER_TMP}" ]] && rm -f "${INSTALLER_TMP}"
}
trap cleanup EXIT

# =============================================================================
# 系统检查
# =============================================================================
function check_root() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || die '请使用 root 权限运行该脚本'
}

function detect_os() {
    if [[ -f '/etc/debian_version' ]]; then
        OS="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-debian}")"
        case "${OS}" in
        ubuntu | debian) ;;
        *) OS='debian' ;;
        esac
    elif [[ -f '/etc/redhat-release' ]]; then
        OS='centos'
    else
        OS=''
    fi
}

function check_os() {
    if [[ -z "${OS}" ]]; then
        die '不支持当前系统，请切换到 Ubuntu 16+、Debian 9+、CentOS 7+'
    fi

    case "${OS}" in
    ubuntu)
        OS_VERSION="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID%%.*}")"
        [[ "${OS_VERSION}" =~ ^[0-9]+$ ]] && ((OS_VERSION >= 16)) ||
            die '不支持当前版本，请切换到 Ubuntu 16+ 重试'
        ;;
    debian)
        OS_VERSION="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID%%.*}")"
        [[ "${OS_VERSION}" =~ ^[0-9]+$ ]] && ((OS_VERSION >= 9)) ||
            die '不支持当前版本，请切换到 Debian 9+ 重试'
        ;;
    centos)
        OS_VERSION="$(grep -oE '[0-9]+' /etc/redhat-release 2>/dev/null | head -1)"
        [[ "${OS_VERSION}" =~ ^[0-9]+$ ]] && ((OS_VERSION >= 7)) ||
            die '不支持当前版本，请切换到 CentOS 7+ 重试'
        ;;
    esac
}

# =============================================================================
# 依赖安装
# =============================================================================
function install_dependencies() {
    info '正在检查并安装依赖...'

    case "${OS}" in
    ubuntu | debian)
        apt-get update -y >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates curl wget unzip openssl iproute2 jq >/dev/null 2>&1 ||
            die '依赖安装失败，请检查软件源后重试'
        ;;
    centos)
        local pm='yum'
        cmd_exists 'dnf' && pm='dnf'
        ${pm} install -y ca-certificates curl wget unzip openssl iproute jq \
            >/dev/null 2>&1 ||
            die '依赖安装失败，请检查软件源后重试'
        ;;
    esac

    cmd_exists 'curl' || cmd_exists 'wget' || die 'curl / wget 均不可用'
    cmd_exists 'openssl' || die 'openssl 不可用'
    cmd_exists 'jq' || die 'jq 不可用'
    ok '依赖检查完成'
}

# =============================================================================
# 交互输入
# =============================================================================
function trim() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    text="${text%"${text##*[![:space:]]}"}"
    printf '%s' "${text}"
}

# 打印提示并从标准输入读取；非交互环境（无终端）直接返回默认值
function ask() {
    local prompt_text="$1"
    local default_value="$2"
    local value=''

    if [[ -t 0 ]]; then
        printf '%s' "${prompt_text}" >&2
        read -r value || value=''
    fi

    value="$(trim "${value}")"
    printf '%s' "${value:-${default_value}}"
}

function valid_domain() {
    [[ "$1" =~ ${DOMAIN_REGEX} ]]
}

function check_target_tls() {
    local domain="$1"

    if ! getent hosts "${domain}" >/dev/null 2>&1; then
        warn "域名 ${domain} 解析失败，REALITY 可能无法工作"
        return 0
    fi

    if ! cmd_exists 'openssl' || ! cmd_exists 'timeout'; then
        return 0
    fi

    info "正在检测 ${domain}:443 的 TLS 1.3 支持..."
    if timeout 10 openssl s_client -connect "${domain}:443" -servername "${domain}" \
        -tls1_3 </dev/null 2>/dev/null | grep -q 'TLSv1.3'; then
        ok 'TLS 1.3 检测通过'
    else
        warn "未能确认 ${domain} 支持 TLS 1.3；REALITY 要求目标站点支持 TLS 1.3，若后续无法连接请更换伪装域名"
    fi
}

function ask_target() {
    local default_target=''
    local input=''

    default_target="${TARGET_POOL[RANDOM % ${#TARGET_POOL[@]}]}"

    while true; do
        input="$(ask "请输入 REALITY 伪装域名 (SNI，需支持 TLS 1.3) [${default_target}]: " "${default_target}")"
        if valid_domain "${input}"; then
            TARGET="${input}"
            break
        fi
        err '域名格式不合法，请重新输入'
    done

    check_target_tls "${TARGET}"
    ok "伪装域名: ${TARGET}"
}

function port_in_use() {
    cmd_exists 'ss' || return 1
    ss -ltn 2>/dev/null | awk 'NR > 1 {print $4}' | grep -qE "[:.]${1}$"
}

function port_held_by_xray() {
    cmd_exists 'ss' || return 1
    ss -ltnp 2>/dev/null | awk -v p=":${1}" '$4 ~ p "$" {print}' | grep -q 'xray'
}

function ask_port() {
    local input=''

    while true; do
        input="$(ask '请输入监听端口 [443]: ' '443')"
        if [[ "${input}" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= 65535)); then
            PORT="${input}"
            break
        fi
        err '端口必须是 1-65535 之间的整数，请重新输入'
    done

    if port_in_use "${PORT}"; then
        if port_held_by_xray "${PORT}"; then
            info "端口 ${PORT} 由现有 Xray 占用，将继续覆盖安装"
        else
            warn "端口 ${PORT} 当前已被其他程序占用"
            if [[ -t 0 ]]; then
                local answer=''
                read -r -p "仍要继续安装? [y/N]: " answer || answer=''
                [[ "${answer}" =~ ^[Yy]$ ]] || die '已取消安装'
            else
                die "端口 ${PORT} 已被占用，非交互模式无法继续"
            fi
        fi
    fi

    ok "监听端口: ${PORT}"
}

function ask_uuid() {
    UUID_RAW="$(ask '请输入 UUID（可填任意字符串，留空自动生成）: ' '')"
    if [[ -n "${UUID_RAW}" ]]; then
        ok "UUID 输入: ${UUID_RAW}"
    else
        ok 'UUID: 自动生成'
    fi
}

function parse_short_ids() {
    local raw="$1"
    local -a parts=()
    local part=''

    SHORT_IDS=()
    IFS=',' read -r -a parts <<<"${raw}"

    for part in "${parts[@]}"; do
        part="$(trim "${part}")"

        if [[ -z "${part}" ]]; then
            SHORT_IDS+=('')
            continue
        fi

        # 0-8 视为自动生成对应字节长度的十六进制串，0 表示空 shortId
        if [[ "${part}" =~ ^[0-8]$ ]]; then
            if [[ "${part}" == '0' ]]; then
                SHORT_IDS+=('')
            else
                SHORT_IDS+=("$(openssl rand -hex "${part}")")
            fi
            continue
        fi

        if [[ "${part}" =~ ^[0-9a-fA-F]{2,16}$ ]] && ((${#part} % 2 == 0)); then
            SHORT_IDS+=("${part}")
            continue
        fi

        return 1
    done

    ((${#SHORT_IDS[@]} > 0)) || SHORT_IDS=('')
    return 0
}

function ask_short_ids() {
    local input=''

    while true; do
        input="$(ask '请输入 shortId（0-8 自动生成对应长度，多个用英文逗号分隔，留空生成 8 位）: ' '')"
        [[ -n "${input}" ]] || input='4'

        if parse_short_ids "${input}"; then
            break
        fi
        err 'shortId 不合法：请输入 0-8 的数字，或 2-16 位偶数长度的十六进制串'
    done

    ok "shortId: ${SHORT_IDS[*]}"
}

# =============================================================================
# 检测已有安装
# =============================================================================
# 从现有 Xray 配置中读取 VLESS + Vision + REALITY 入站参数。
# 只有找到完整可用的参数（端口 / UUID / SNI / 私钥）时才返回成功。
function load_previous_install() {
    local line=''
    local port=''
    local uuid=''
    local target=''
    local server_name=''
    local private_key=''
    local short_raw=''

    [[ -f "${CONFIG_PATH}" ]] || return 1
    cmd_exists 'jq' || return 1

    line="$(jq -r '
        (.inbounds // [])[]
        | select((.protocol // "") == "vless")
        | select((.streamSettings.security // "") == "reality")
        | select((.settings.clients[0].flow // "") == "xtls-rprx-vision")
        | [
            ((.port // "") | tostring),
            (.settings.clients[0].id // ""),
            (.streamSettings.realitySettings.target // ""),
            ((.streamSettings.realitySettings.serverNames // [])[0] // ""),
            (.streamSettings.realitySettings.privateKey // ""),
            ((.streamSettings.realitySettings.shortIds // []) | map(tostring) | join(","))
          ]
        | join("\u001f")
    ' "${CONFIG_PATH}" 2>/dev/null | head -1)"

    [[ -n "${line}" ]] || return 1
    IFS=$'\x1f' read -r port uuid target server_name private_key short_raw <<<"${line}"

    port="$(trim "${port}")"
    uuid="$(trim "${uuid}")"
    target="$(trim "${target}")"
    server_name="$(trim "${server_name}")"
    private_key="$(trim "${private_key}")"

    [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
    [[ "${uuid}" =~ ${UUID_REGEX} ]] || return 1
    [[ -n "${private_key}" ]] || return 1

    # serverNames 优先；缺失时从 target 去掉端口后取域名
    if ! valid_domain "${server_name}"; then
        case "${target}" in
        \[*\]:*) server_name='' ;;      # IPv6 目标，不能作为 SNI
        *:*) server_name="${target%:*}" ;; # 域名:端口
        *) server_name="${target}" ;;
        esac
    fi
    valid_domain "${server_name}" || return 1

    PORT="${port}"
    UUID="${uuid}"
    TARGET="${server_name}"
    PRIVATE_KEY="${private_key}"

    SHORT_IDS=()
    if [[ -n "${short_raw}" ]]; then
        IFS=',' read -r -a SHORT_IDS <<<"${short_raw}"
    else
        SHORT_IDS=('')
    fi

    PREVIOUS_INSTALL='y'
    return 0
}

function show_previous_install() {
    info '检测到已有安装，直接沿用原参数'
    printf '  端口   : %s\n' "${PORT}" >&2
    printf '  SNI    : %s\n' "${TARGET}" >&2
    printf '  UUID   : %s\n' "${UUID}" >&2
    printf '  shortId: %s\n' "${SHORT_IDS[*]}" >&2
    printf '  密钥   : 沿用原 REALITY 密钥\n' >&2
}

# =============================================================================
# 安装 Xray
# =============================================================================
function fetch_installer() {
    local url=''

    INSTALLER_TMP="$(mktemp "${TMPDIR:-/tmp}/xray-install.XXXXXX")" ||
        die '无法创建临时文件'

    for url in "${INSTALLER_URLS[@]}"; do
        if cmd_exists 'curl'; then
            curl -fsSL --max-time 60 -o "${INSTALLER_TMP}" "${url}" 2>/dev/null || continue
        else
            wget -qO "${INSTALLER_TMP}" --timeout=60 --no-check-certificate "${url}" 2>/dev/null || continue
        fi

        if grep -q 'Xray' "${INSTALLER_TMP}" 2>/dev/null &&
            grep -q 'INSTALL' "${INSTALLER_TMP}" 2>/dev/null; then
            printf '%s' "${INSTALLER_TMP}"
            return 0
        fi
    done

    rm -f "${INSTALLER_TMP}"
    INSTALLER_TMP=''
    return 1
}

function install_xray() {
    local installer=''

    installer="$(fetch_installer)" || die 'Xray 安装脚本下载失败，请检查网络或 DNS'
    INSTALLER_TMP="${installer}"

    info '正在安装 Xray 稳定版...'
    if ! bash "${installer}" install; then
        die 'Xray 安装失败，请查看上方输出'
    fi
    rm -f "${installer}"
    INSTALLER_TMP=''

    cmd_exists 'xray' || die 'Xray 安装结束但未找到 xray 命令'
    ok "Xray 已安装: $(xray version 2>/dev/null | head -1)"
}

# =============================================================================
# BBR
# =============================================================================
function sysctl_set() {
    local key="$1"
    local value="$2"
    local path=''

    if cmd_exists 'sysctl'; then
        sysctl -q -w "${key}=${value}" >/dev/null 2>&1 && return 0
    fi

    path="/proc/sys/$(printf '%s' "${key}" | tr '.' '/')"
    printf '%s' "${value}" >"${path}" 2>/dev/null
}

# 写入并应用 TCP 缓冲区调优参数。
# 代理服务器多为跨境高延迟链路（如 CN->US，RTT 约 200ms），此时带宽时延积
# 很大，而内核默认 net.core.rmem_max 仅 208KB 会把窗口卡死，是"能连但很慢"
# 的常见原因。放开上限到 16MB 后 tcp_rmem/tcp_wmem 的大值才能真正生效。
# 与 BBR 解耦：即使内核不支持 BBR，缓冲区调优依然有效。
function tune_buffers() {
    local conf='/etc/sysctl.d/99-xrayscript-tcp.conf'
    local key=''
    local value=''

    cat >"${conf}" <<'EOF'
# Managed by xrayscript: TCP buffer tuning for high-latency proxy links
# 高延迟链路(如 CN->US, RTT 约 200ms)需要更大窗口才能跑满带宽

# 缓冲区上限: 默认 208KB -> 16MB
# 注意: 若不放开 rmem_max/wmem_max, tcp_rmem/wmem 的大值不会生效
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 突发报文缓冲
net.core.netdev_max_backlog = 5000

# TCP Fast Open: 3 = 客户端 + 服务端
net.ipv4.tcp_fastopen = 3

# 空闲后不重置拥塞窗口
net.ipv4.tcp_slow_start_after_idle = 0

# MTU 探测
net.ipv4.tcp_mtu_probing = 1
EOF

    if [[ ! -f "${conf}" ]]; then
        warn 'TCP 缓冲区配置写入失败，已跳过'
        return 0
    fi

    while IFS='=' read -r key value; do
        key="$(printf '%s' "${key}" | tr -d '[:space:]')"
        value="$(printf '%s' "${value}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        sysctl_set "${key}" "${value}" || true
    done <"${conf}"

    ok "TCP 缓冲区已调优（rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null)）"
}

function enable_bbr() {
    local conf='/etc/sysctl.d/99-xrayscript-bbr.conf'
    local available='/proc/sys/net/ipv4/tcp_available_congestion_control'
    local current=''

    # 缓冲区调优与 BBR 无关，先应用；内核不支持 BBR 时这一步仍然有效
    tune_buffers

    if ! grep -qw 'bbr' "${available}" 2>/dev/null; then
        cmd_exists 'modprobe' && modprobe tcp_bbr 2>/dev/null || true
    fi

    if ! grep -qw 'bbr' "${available}" 2>/dev/null; then
        warn '当前内核不支持 TCP BBR，仅应用了缓冲区调优'
        return 0
    fi

    cat >"${conf}" <<'EOF'
# Managed by xrayscript: TCP BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if [[ ! -f "${conf}" ]]; then
        warn 'BBR 持久化配置写入失败，已跳过'
        return 0
    fi

    sysctl_set 'net.core.default_qdisc' 'fq' || true
    sysctl_set 'net.ipv4.tcp_congestion_control' 'bbr' || true

    current="$(tr -d '[:space:]' </proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    if [[ "${current}" == 'bbr' ]]; then
        ok 'TCP BBR 已开启'
    else
        rm -f "${conf}"
        warn "TCP BBR 开启失败（当前: ${current:-unknown}），已跳过"
    fi
}

# =============================================================================
# 生成配置
# =============================================================================
function resolve_uuid() {
    local mapped=''

    if [[ -n "${UUID_RAW}" ]]; then
        mapped="$(xray uuid -i "${UUID_RAW}" 2>/dev/null)" || mapped=''
        if [[ "${mapped}" =~ ${UUID_REGEX} ]]; then
            UUID="${mapped}"
            return 0
        fi
        warn 'UUID 字符串映射失败，改用随机 UUID'
    fi

    UUID="$(xray uuid 2>/dev/null)" || UUID=''
    [[ "${UUID}" =~ ${UUID_REGEX} ]] || die 'UUID 生成失败'
}

function extract_public_key() {
    local output="$1"
    local key=''

    key="$(printf '%s\n' "${output}" | sed -n \
        -e 's/^.*[Pp]assword:[[:space:]]*//p' \
        -e 's/^.*[Pp]ublic[[:space:]]*[Kk]ey:[[:space:]]*//p' |
        head -1 | tr -d '[:space:]')"

    if [[ -z "${key}" ]]; then
        key="$(printf '%s\n' "${output}" | sed -n '2p' |
            sed 's/^.*:[[:space:]]*//' | tr -d '[:space:]')"
    fi

    printf '%s' "${key}"
}

function generate_keys() {
    local output=''

    output="$(xray x25519 2>/dev/null)" || die 'X25519 密钥生成失败'

    PRIVATE_KEY="$(printf '%s\n' "${output}" | sed -n '1s/.*:[[:space:]]*//p' | tr -d '[:space:]')"
    PUBLIC_KEY="$(extract_public_key "${output}")"

    [[ -n "${PRIVATE_KEY}" ]] || die '未能解析 REALITY 私钥'
    [[ -n "${PUBLIC_KEY}" ]] || die '未能解析 REALITY 公钥'
}

# 读取与旧私钥匹配的公钥。
# 从私钥推导公钥依赖 xray x25519 的参数语义，不同版本行为不一致，
# 因此这里只信任之前保存下来的公钥，并尽量校验它对应的私钥。
function read_saved_public_key() {
    local key=''
    local saved_private=''
    local old_config="${HOME}/.xrayscript/config.json"

    if [[ -f "${SHARE_PATH}" ]]; then
        key="$(sed -n 's/^publicKey *: *//p' "${SHARE_PATH}" 2>/dev/null | head -1 | tr -d '[:space:]')"
        saved_private="$(sed -n 's/^privateKey *: *//p' "${SHARE_PATH}" 2>/dev/null | head -1 | tr -d '[:space:]')"
        # 旧版 share.txt 没有 privateKey 字段，无法校验，按历史记录直接使用
        if [[ -n "${key}" && (-z "${saved_private}" || "${saved_private}" == "${PRIVATE_KEY}") ]]; then
            PUBLIC_KEY="${key}"
            return 0
        fi
    fi

    # 兼容原 xrayscript 项目的配置文件，要求私钥与当前配置一致
    if cmd_exists 'jq' && [[ -f "${old_config}" ]]; then
        key="$(jq -r --arg pk "${PRIVATE_KEY}" \
            'select((.xray.privateKey // "") == $pk) | (.xray.publicKey // empty)' \
            "${old_config}" 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "${key}" ]]; then
            PUBLIC_KEY="${key}"
            return 0
        fi
    fi

    return 1
}

function load_previous_keys() {
    if read_saved_public_key; then
        ok '已沿用之前保存的 REALITY 公钥'
        return 0
    fi

    # 找不到可校验的公钥时只能重新生成密钥对，避免把错误的公钥发给客户端
    warn '旧配置中没有可用的 REALITY 公钥，将重新生成密钥对'
    warn '重新生成后，之前分发的旧链接会失效，请使用本次输出的新链接'
    generate_keys
    KEYS_REGENERATED='y'
}

function short_ids_json() {
    local output=''
    local id=''

    for id in "${SHORT_IDS[@]}"; do
        output+="\"${id}\","
    done
    output="${output%,}"

    printf '[%s]' "${output}"
}

function write_config() {
    local short_json=''
    local listen='0.0.0.0'

    # 检测到公网 IPv6 时改用 :: 监听，同时接收 IPv4 与 IPv6
    [[ -n "${IPV6_HOST}" ]] && listen='::'

    short_json="$(short_ids_json)"
    mkdir -p "${CONFIG_DIR}" || die '无法创建配置目录'

    if [[ -f "${CONFIG_PATH}" ]]; then
        cp -f "${CONFIG_PATH}" "${CONFIG_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi

    cat >"${CONFIG_PATH}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "${listen}",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${TARGET}:443",
          "xver": 0,
          "serverNames": [
            "${TARGET}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ${short_json}
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "sockopt": {
        "domainStrategy": "UseIPv4v6"
      }
    }
  ]
}
EOF

    chmod 644 "${CONFIG_PATH}"
    ok "Xray 配置已写入: ${CONFIG_PATH}"
}

function start_xray() {
    xray -test -config "${CONFIG_PATH}" >/dev/null 2>&1 ||
        die "Xray 配置校验失败，请执行 xray -test -config ${CONFIG_PATH} 查看详情"

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray || die 'Xray 服务启动失败，请执行 journalctl -u xray -n 50 查看日志'

    sleep 1
    systemctl is-active --quiet xray ||
        die 'Xray 服务未处于运行状态，请执行 journalctl -u xray -n 50 查看日志'

    ok 'Xray 服务已启动并设置为开机自启'
}

# =============================================================================
# 分享链接
# =============================================================================
function get_public_host() {
    local host=''

    host="$(curl -4 -fsSL --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
    if [[ -z "${host}" ]]; then
        host="$(curl -4 -fsSL --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
    fi
    if [[ -z "${host}" ]]; then
        host="$(ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    fi
    if [[ -z "${host}" ]]; then
        host="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    # 只接受 IPv4 地址，避免在纯 IPv6 主机上把 IPv6 当成 IPv4
    if [[ ! "${host}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        host=''
    fi
    [[ -n "${host}" ]] || host='YOUR_SERVER_IP'

    printf '%s' "${host}"
}

function ipv6_is_global() {
    local addr="$1"

    [[ -n "${addr}" ]] || return 1
    [[ "${addr}" == *:* ]] || return 1
    [[ "${addr}" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    # 排除回环、链路本地与 ULA 地址
    [[ "${addr}" == '::' || "${addr}" == '::1' || "${addr}" == fe80* || "${addr}" == fc* || "${addr}" == fd* ]] && return 1
    return 0
}

function get_public_host_v6() {
    local host=''

    # 优先读取本机全局 IPv6（无需联网，纯 IPv4 主机可立即返回）
    host="$(ip -6 addr show scope global 2>/dev/null |
        awk '/inet6/ {print $2}' | cut -d/ -f1 | head -1)"

    if ! ipv6_is_global "${host}"; then
        host="$(curl -6 -fsSL --max-time 8 https://ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
    fi
    if ! ipv6_is_global "${host}"; then
        host="$(curl -6 -fsSL --max-time 8 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]')"
    fi
    if ! ipv6_is_global "${host}"; then
        host="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
    fi
    if ! ipv6_is_global "${host}"; then
        host="$(hostname -I 2>/dev/null | tr ' ' '\n' |
            grep -i ':' | grep -viE '^(fe80|fc|fd|::1)' | head -1)"
    fi

    ipv6_is_global "${host}" && printf '%s' "${host}"
}

function detect_ipv6() {
    IPV6_HOST="$(get_public_host_v6)"

    if [[ -n "${IPV6_HOST}" ]]; then
        ok "检测到公网 IPv6: ${IPV6_HOST}，入站将使用双栈监听"
    else
        info '未检测到公网 IPv6，仅使用 IPv4'
    fi
}

function bracket_host() {
    local host="$1"

    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
        printf '[%s]' "${host}"
    else
        printf '%s' "${host}"
    fi
}

function build_share_link() {
    local host="$1"
    local short_id=''
    local id=''

    for id in "${SHORT_IDS[@]}"; do
        if [[ -n "${id}" ]]; then
            short_id="${id}"
            break
        fi
    done

    printf 'vless://%s@%s:%s?type=raw&security=reality&sni=%s&pbk=%s&sid=%s&spx=%%2F&fp=chrome&flow=xtls-rprx-vision#VLESS-Reality-Vision' \
        "${UUID}" "${host}" "${PORT}" "${TARGET}" "${PUBLIC_KEY}" "${short_id}"
}

function show_result() {
    local host4=''
    local host6=''
    local link4=''
    local link6=''

    host4="$(get_public_host)"
    host6="${IPV6_HOST}"

    # 没有 IPv4 时不要在链接里留下占位地址，优先使用 IPv6
    [[ "${host4}" == 'YOUR_SERVER_IP' && -n "${host6}" ]] && host4=''

    [[ -n "${host4}" ]] && link4="$(build_share_link "$(bracket_host "${host4}")")"
    [[ -n "${host6}" ]] && link6="$(build_share_link "$(bracket_host "${host6}")")"

    if [[ -z "${link4}" && -z "${link6}" ]]; then
        host4='YOUR_SERVER_IP'
        link4="$(build_share_link "${host4}")"
    fi

    cat >"${SHARE_PATH}" <<EOF
address_ipv4: ${host4}
address_ipv6: ${host6}
port        : ${PORT}
protocol    : vless
uuid        : ${UUID}
flow        : xtls-rprx-vision
network     : raw
security    : reality
serverName  : ${TARGET}
publicKey   : ${PUBLIC_KEY}
privateKey  : ${PRIVATE_KEY}
shortId     : ${SHORT_IDS[*]}
link_ipv4   : ${link4}
link_ipv6   : ${link6}
EOF
    chmod 600 "${SHARE_PATH}"

    echo
    echo '==================== 安装完成 ===================='
    printf '地址(IPv4)  : %s\n' "${host4:-无}"
    printf '地址(IPv6)  : %s\n' "${host6:-无}"
    printf '端口        : %s\n' "${PORT}"
    printf '协议        : VLESS\n'
    printf 'UUID        : %s\n' "${UUID}"
    printf '流控        : xtls-rprx-vision\n'
    printf '传输        : raw\n'
    printf '安全        : REALITY\n'
    printf 'SNI         : %s\n' "${TARGET}"
    printf '公钥        : %s\n' "${PUBLIC_KEY}"
    printf 'shortId     : %s\n' "${SHORT_IDS[*]}"
    if [[ "${KEYS_REGENERATED}" == 'y' ]]; then
        echo '注意        : 本次重新生成了 REALITY 密钥，旧客户端链接已失效'
    fi

    if [[ -n "${link4}" ]]; then
        echo '--------------------------------------------------'
        printf 'IPv4 分享链接:\n%s\n' "${link4}"
    fi
    if [[ -n "${link6}" ]]; then
        echo '--------------------------------------------------'
        printf 'IPv6 分享链接:\n%s\n' "${link6}"
    fi

    echo '--------------------------------------------------'
    printf '分享信息已保存到: %s\n' "${SHARE_PATH}"
    printf '请确保防火墙/安全组已放行 TCP %s 端口。\n' "${PORT}"
    echo '如果服务器位于 NAT 或端口映射之后，请把链接中的地址换成实际公网地址。'
    echo '=================================================='
}

# =============================================================================
# 主流程
# =============================================================================
function main() {
    check_root
    detect_os
    check_os

    echo '--------------------------------------------------'
    echo '     VLESS + Vision + REALITY 一键安装脚本'
    echo '--------------------------------------------------'

    install_dependencies

    if load_previous_install; then
        show_previous_install
    else
        info '未检测到可复用的旧安装，进入手动配置'
        ask_target
        ask_port
        ask_uuid
        ask_short_ids
    fi

    install_xray
    enable_bbr
    detect_ipv6

    if [[ "${PREVIOUS_INSTALL}" == 'y' ]]; then
        load_previous_keys
    else
        resolve_uuid
        generate_keys
    fi

    write_config
    start_xray

    show_result
}

main "$@"
