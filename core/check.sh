#!/usr/bin/env bash
# =============================================================================
# 脚本名称: check.sh
# 功能描述: 提供一系列验证函数，用于检查 IP、端口、UUID、密码、路径、Short ID、
#           域名安全性、DNS 解析、Xray 配置/版本以及邮箱地址的有效性。
#           所有提示统一输出到标准错误，标准输出仅用于返回结果。
# 依赖: bash, jq, dig, curl, openssl, stdbuf
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language)
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')"
PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

readonly CONFIG_XRAY_DIR="${CONFIG_DIR}/xray" # Xray 配置模板目录

# --- 正则表达式常量 ---
readonly DOMAIN_REGEX="^([a-zA-Z0-9]([-a-zA-Z0-9]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$"                      # 域名
readonly IPV4_REGEX='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$' # IPv4
readonly IPV6_REGEX='^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$'                                            # IPv6 (简化版)
readonly HEX_REGEX='^[0-9a-fA-F]+$'                                                                         # 十六进制字符串
readonly UUID_REGEX='^[0-9a-fA-F]{8}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{4}\b-[0-9a-fA-F]{12}$' # UUID
readonly EMAIL_REGEX='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'                                     # 邮箱地址
readonly SPACE_REGEX='[[:space:]]'                                                                          # 空白字符

# --- 全局变量声明 ---
declare SCRIPT_CONFIG='' # 脚本配置缓存 (首次使用时读取)

# =============================================================================
# 函数名称: t
# 功能描述: 取本脚本的 i18n 文本并做变量替换，例如 ${domain} / ${total}。
#           支持可变参数: t key name value [name value ...]
# 参数:
#   $1: i18n 键名 (不含 CUR_FILE 前缀)，其余为 name/value 对
# 返回值: 处理后的文本 (printf 到标准输出，调用方自行决定去向)
# =============================================================================
function t() {
    local key="$1"
    local text=''
    local name=''
    local value=''

    shift
    i18n_fill text "${CUR_FILE}.${key}"
    while [[ $# -ge 2 ]]; do
        name="${1//./_}"
        value="${2//\\/\\\\}"
        value="${value//&/\\&}"
        text="${text//\$\{${name}\}/${value}}"
        shift 2
    done
    printf '%s' "${text}"
}

# =============================================================================
# 函数名称: load_script_config
# 功能描述: 懒加载脚本配置到 SCRIPT_CONFIG，避免每个检查项都读盘。
# =============================================================================
function load_script_config() {
    if [[ -z "${SCRIPT_CONFIG}" ]]; then
        SCRIPT_CONFIG="$(cat "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
    fi
}

# =============================================================================
# 函数名称: valid_domain
# =============================================================================
function valid_domain() {
    local domain="$1"
    [[ "$domain" =~ $DOMAIN_REGEX ]]
}

# =============================================================================
# 函数名称: resolve_domain
# =============================================================================
function resolve_domain() {
    dig +short "$1" | grep -q '.'
}

# =============================================================================
# 函数名称: dns_resolution
# 功能描述: 检查域名是否解析到本机公网 IP (IPv4/IPv6 任一匹配)。
# =============================================================================
function dns_resolution() {
    local domain=$1
    local expected_ipv4=''
    local expected_ipv6=''
    local actual_ipv4=''
    local actual_ipv6=''

    expected_ipv4="$(curl -fsSL --max-time 10 ipv4.icanhazip.com 2>/dev/null)"
    expected_ipv6="$(curl -fsSL --max-time 6 ipv6.icanhazip.com 2>/dev/null)"

    actual_ipv4="$(dig +short A "${domain}")"
    actual_ipv6="$(dig +short AAAA "${domain}")"

    if [[ -n "${expected_ipv4}" ]] && echo "${actual_ipv4}" | grep -qxF "${expected_ipv4}"; then
        return 0
    fi
    if [[ -n "${expected_ipv6}" ]] && echo "${actual_ipv6}" | grep -qxF "${expected_ipv6}"; then
        return 0
    fi
    return 1
}

# =============================================================================
# 函数名称: test_tcp_connection
# 功能描述: 测试到指定主机端口的 TCP 连接 (带超时，避免长时间挂起)。
# =============================================================================
function test_tcp_connection() {
    local host="$1"
    local port="$2"

    if cmd_exists 'timeout'; then
        timeout 5 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
    else
        echo >/dev/tcp/"${host}"/"${port}" 2>/dev/null
    fi
}

# =============================================================================
# 函数名称: get_listening_process_by_port
# 功能描述: 获取指定端口的监听进程标识 (优先 ss，回退 lsof)。
# =============================================================================
function get_listening_process_by_port() {
    local port="$1"
    local process=''

    if cmd_exists 'ss'; then
        process="$(ss -lntp "( sport = :${port} )" 2>/dev/null | awk 'NR > 1 {print $NF; exit}')"
    fi
    if [[ -z "${process}" ]] && cmd_exists 'lsof'; then
        process="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1"/"$2; exit}')"
    fi
    [[ "${process}" == '-' ]] && process=''
    echo "${process}"
}

# =============================================================================
# 函数名称: check_firewall_tcp_port_open
# 返回值: 0 已放行, 1 未放行, 2 未检测到活动防火墙
# =============================================================================
function check_firewall_tcp_port_open() {
    local port="$1"

    if cmd_exists 'ufw' && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw status 2>/dev/null | grep -Eiq "^${port}(/tcp)?[[:space:]]+ALLOW"
        return $?
    fi
    if cmd_exists 'firewall-cmd' && cmd_exists 'systemctl' && systemctl -q is-active firewalld; then
        firewall-cmd --quiet --query-port="${port}/tcp"
        return $?
    fi
    return 2
}

# =============================================================================
# 函数名称: detect_active_firewalls
# 功能描述: 检测当前已激活的防火墙名称 (空格分隔)
# =============================================================================
function detect_active_firewalls() {
    local -a active_firewalls=()

    if cmd_exists 'ufw' && ufw status 2>/dev/null | grep -q '^Status: active'; then
        active_firewalls+=('ufw')
    fi
    if cmd_exists 'firewall-cmd' && cmd_exists 'systemctl' && systemctl -q is-active firewalld; then
        active_firewalls+=('firewalld')
    fi
    echo "${active_firewalls[*]}"
}

# =============================================================================
# 函数名称: allow_firewall_tcp_port
# 功能描述: 尝试放行指定 TCP 端口
# =============================================================================
function allow_firewall_tcp_port() {
    local firewall="$1"
    local port="$2"

    case "${firewall}" in
    ufw)
        ufw allow "${port}/tcp" >/dev/null 2>&1
        ;;
    firewalld)
        firewall-cmd --quiet --permanent --add-port="${port}/tcp" && firewall-cmd --quiet --reload
        ;;
    *)
        return 1
        ;;
    esac
}

# =============================================================================
# 函数名称: ensure_firewall_tcp_port_open
# 功能描述: 确保指定端口在活动防火墙中放行；若未放行则自动尝试放行。
# =============================================================================
function ensure_firewall_tcp_port_open() {
    local port="$1"
    local firewall_check_rc=0
    local active_firewalls_raw=''
    local -a active_firewalls=()
    local firewall=''
    local allow_failed=0

    _test "$(t sni_ports.open_check)${port}"
    check_firewall_tcp_port_open "${port}"
    firewall_check_rc=$?
    if [[ ${firewall_check_rc} -eq 0 ]]; then
        _pass "$(t sni_ports.open_pass)${port}"
        return 0
    fi

    active_firewalls_raw="$(detect_active_firewalls)"
    if [[ -z "${active_firewalls_raw}" ]]; then
        _info "$(t sni_ports.open_skip)${port}"
        return 0
    fi
    read -r -a active_firewalls <<<"${active_firewalls_raw}"

    _info "$(t sni_ports.firewall_active)${active_firewalls_raw}"
    _test "$(t sni_ports.allow_try)${port}"
    for firewall in "${active_firewalls[@]}"; do
        if ! allow_firewall_tcp_port "${firewall}" "${port}"; then
            allow_failed=1
        fi
    done

    check_firewall_tcp_port_open "${port}"
    firewall_check_rc=$?
    if [[ ${allow_failed} -eq 0 && ${firewall_check_rc} -eq 0 ]]; then
        _pass "$(t sni_ports.allow_pass)${port}"
        return 0
    fi

    _fail "$(t sni_ports.allow_fail)${port}"
    _info "$(t sni_ports.manual_allow)${port}"
    return 1
}

# =============================================================================
# 函数名称: check_sni_ports
# 功能描述: SNI 初始化前检查 80/443 端口是否被占用并确保防火墙放行。
# =============================================================================
function check_sni_ports() {
    local -a required_ports=(80 443)
    local port=''
    local occupied_by=''

    _info "$(t sni_ports.start)"

    for port in "${required_ports[@]}"; do
        _test "$(t sni_ports.occupied_check)${port}"
        occupied_by="$(get_listening_process_by_port "${port}")"
        if [[ -n "${occupied_by}" ]]; then
            _fail "$(t sni_ports.occupied_fail)${port} (${occupied_by})"
            return 1
        fi
        _pass "$(t sni_ports.occupied_pass)${port}"

        if ! ensure_firewall_tcp_port_open "${port}"; then
            return 1
        fi
    done

    _pass "$(t sni_ports.all_pass)"
    return 0
}

# =============================================================================
# 函数名称: get_tls_info
# 功能描述: 使用 openssl s_client 获取指定域名的 TLS 信息。
# =============================================================================
function get_tls_info() {
    local host="$1"
    local openssl_cmd='openssl'

    cmd_exists 'stdbuf' && openssl_cmd="stdbuf -oL openssl"

    if cmd_exists 'timeout'; then
        echo QUIT | timeout 10 ${openssl_cmd} s_client -connect "${host}:443" -tls1_3 -alpn h2 2>&1 | tr -d '\0'
    else
        echo QUIT | ${openssl_cmd} s_client -connect "${host}:443" -tls1_3 -alpn h2 2>&1 | tr -d '\0'
    fi
}

# =============================================================================
# 函数名称: check_ip
# =============================================================================
function check_ip() {
    local ip="$1"

    _info "$(t ip.check)${ip}"

    if [[ "$ip" =~ $IPV4_REGEX ]]; then
        _pass "$(t ip.ipv4_valid)$ip"
        return 0
    elif [[ "$ip" =~ $IPV6_REGEX ]]; then
        _pass "$(t ip.ipv6_valid)$ip"
        return 0
    fi

    _fail "$(t ip.invalid)$ip"
    return 1
}

# =============================================================================
# 函数名称: check_port
# =============================================================================
function check_port() {
    local port="$1"

    _info "$(t port.check)${port}"

    if [[ -z "${port}" ]]; then
        _pass "$(t port.empty)"
    elif [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)); then
        _pass "$(t port.valid)$port"
    else
        _fail "$(t port.range_error)$port"
        return 1
    fi
    return 0
}

# =============================================================================
# 函数名称: check_uuid
# 功能描述: 校验 UUID；空值或普通字符串都视为可用 (由 Xray 映射生成)。
# =============================================================================
function check_uuid() {
    local uuid="$1"

    _info "$(t uuid.check)${uuid}"

    if [[ -z "${uuid}" ]]; then
        _pass "$(t uuid.empty)"
    elif ! [[ "$uuid" =~ $UUID_REGEX ]]; then
        _pass "$(t uuid.string)$uuid"
    else
        _pass "$(t uuid.valid)$uuid"
    fi
    return 0
}

# =============================================================================
# 函数名称: check_password
# =============================================================================
function check_password() {
    local password="$1"

    _info "$(t password.check)${password}"

    if [[ -z "${password}" ]]; then
        _pass "$(t password.empty)"
        return 0
    fi

    # 修正: 原写法 `=~ *\ *` 是无效正则，永远为假
    if [[ "${password}" =~ $SPACE_REGEX ]]; then
        _fail "$(t password.space_error)$password"
        return 1
    fi

    if ((${#password} < 8)); then
        _fail "$(t password.length_error)$password"
        return 1
    fi

    _pass "$(t password.valid)$password"
    return 0
}

# =============================================================================
# 函数名称: check_path
# =============================================================================
function check_path() {
    local path="$1"

    _info "$(t path.check)${path}"

    if [[ -z "${path}" ]]; then
        _pass "$(t path.empty)"
        return 0
    fi

    if [[ "${path}" =~ $SPACE_REGEX ]]; then
        _fail "$(t path.space_error)$path"
        return 1
    fi

    if ((${#path} > 128)); then
        _fail "$(t path.length_error)$path"
        return 1
    fi

    if [[ "${path}" =~ [^a-zA-Z0-9_/.\-] ]]; then
        _fail "$(t path.char_error)$path"
        return 1
    fi

    if [[ "${path}" =~ // ]]; then
        _fail "$(t path.double_slash_error)$path"
        return 1
    fi

    _pass "$(t path.valid)$path"
    return 0
}

# =============================================================================
# 函数名称: check_short_id
# =============================================================================
function check_short_id() {
    local short_id="$1"

    _info "$(t short.check)${short_id}"

    if [[ -z "${short_id}" ]]; then
        _pass "$(t short.empty)"
        return 0
    fi

    if [[ ${short_id} =~ ^[0-8]$ ]]; then
        _pass "$(t short.digit)$short_id"
        return 0
    fi

    if ((${#short_id} % 2 != 0 || ${#short_id} > 16)); then
        _fail "$(t short.length_error)$short_id"
        return 1
    fi

    if ! [[ "${short_id}" =~ $HEX_REGEX ]]; then
        _fail "$(t short.hex_error)$short_id"
        return 1
    fi

    _pass "$(t short.valid)$short_id"
    return 0
}

# =============================================================================
# 函数名称: check_domain_security
# 功能描述: 检查域名格式、解析、TCP 连接与 TLS 1.3 / X25519 支持情况。
# =============================================================================
function check_domain_security() {
    local domain="$1"
    local tls_info=''

    _info "$(t domain.security_check)${domain}"

    if [[ -z "${domain}" ]]; then
        _pass "$(t domain.empty)"
        return 0
    fi

    if ! valid_domain "$domain"; then
        _fail "$(t domain.format_error)$domain"
        return 1
    fi

    _test "$(t domain.resolve)${domain}"
    if ! resolve_domain "$domain"; then
        _fail "$(t domain.resolve_fail)$domain"
        return 1
    fi

    _test "$(t tcp.connect_check): ${domain}:443"
    if ! test_tcp_connection "$domain" 443; then
        _fail "$(t tcp.connect_fail "domain" "${domain}")"
        return 1
    fi

    _test "$(t tls.info): ${domain}"
    tls_info="$(get_tls_info "$domain")"

    # 键名修正: 中英两个 i18n 文件里该键名不一致 (error / version_error)，这里都兼容
    if ! echo "$tls_info" | grep -q "TLSv1.3"; then
        _fail "$(t tls.version_error)"
        return 1
    fi
    _pass "$(t tls.pass)"

    if ! echo "$tls_info" | grep -q "X25519"; then
        _fail "$(t tls.key_exchange_warn)$domain"
        return 1
    fi
    _pass "$(t tls.key_exchange_pass)"

    _pass "$(t domain.security_pass "domain" "${domain}")"
    return 0
}

# =============================================================================
# 函数名称: check_dns_resolution
# =============================================================================
function check_dns_resolution() {
    local domain="$1"

    _info "$(t dns.check_start)${domain}"

    if ! valid_domain "$domain"; then
        _fail "$(t domain.format_error)$domain"
        return 1
    fi

    _test "$(t domain.resolve): ${domain}"
    if ! dns_resolution "$domain"; then
        _fail "$(t dns.resolution_fail)$domain"
        return 1
    fi

    _pass "$(t dns.check_pass "domain" "${domain}")"
    return 0
}

# =============================================================================
# 函数名称: check_xray_config_exists
# =============================================================================
function check_xray_config_exists() {
    local SCRIPT_FILE="$1"
    local CONFIG_FILE="${CONFIG_XRAY_DIR}/${SCRIPT_FILE}.json"

    _info "$(t config.check)${CONFIG_FILE}"

    if [[ -f "${CONFIG_FILE}" ]]; then
        _pass "$(t config.exist)${CONFIG_FILE}"
        return 0
    fi

    _fail "$(t config.not_exist)${CONFIG_FILE}"
    return 1
}

# =============================================================================
# 函数名称: check_xray_version_exists
# 功能描述: 通过 GitHub Releases 页面状态码检查版本是否存在。
# =============================================================================
function check_xray_version_exists() {
    local version="$1"
    local version_url=''
    local status_code=''

    _info "$(t version.check)v${version}"

    version_url="https://github.com/XTLS/Xray-core/releases/tag/v${version#*v}"
    status_code="$(curl -L -o /dev/null -s -w '%{http_code}' --max-time 20 "$version_url")"

    if [[ "$status_code" == "200" ]]; then
        _pass "$(t version.exist)${version}"
        return 0
    fi

    _fail "$(t version.not_exist)${version}"
    return 1
}

# =============================================================================
# 函数名称: validate_email
# =============================================================================
function validate_email() {
    local email="$1"

    _info "$(t email.check)${email}"

    if [[ -z "${email}" ]]; then
        _fail "$(t email.empty)"
        return 1
    fi

    if [[ "$email" =~ $EMAIL_REGEX ]]; then
        _pass "$(t email.valid)$email"
        return 0
    fi

    _fail "$(t email.format_error)$email"
    return 1
}

# =============================================================================
# 函数名称: check_proxy_target
# 功能描述: 校验自定义站点反代目标，仅输入端口时规范化为 http://127.0.0.1:<port>。
#           标准输出返回规范化结果，所有提示走标准错误。
# =============================================================================
function check_proxy_target() {
    local raw_target="$1"
    local normalized_target="${raw_target}"
    local scheme=''
    local authority=''
    local host=''
    local port=''

    _info "$(t proxy_target.check)${raw_target}"

    if [[ -z "${raw_target}" ]]; then
        _fail "$(t proxy_target.empty)"
        return 1
    fi

    if [[ "${raw_target}" =~ ^[0-9]+$ ]]; then
        normalized_target="http://127.0.0.1:${raw_target}"
        _info "$(t proxy_target.normalized)${normalized_target}"
    fi

    if [[ "${normalized_target}" =~ $SPACE_REGEX ]]; then
        _fail "$(t proxy_target.format_error)${normalized_target}"
        return 1
    fi

    if [[ "${normalized_target}" == *'?'* || "${normalized_target}" == *'#'* ]]; then
        _fail "$(t proxy_target.path_error)${normalized_target}"
        return 1
    fi

    if [[ "${normalized_target}" =~ ^https?://[^/]+/ ]]; then
        _fail "$(t proxy_target.path_error)${normalized_target}"
        return 1
    fi

    if ! [[ "${normalized_target}" =~ ^(https?)://([^/]+)$ ]]; then
        _fail "$(t proxy_target.format_error)${normalized_target}"
        return 1
    fi
    scheme="${BASH_REMATCH[1]}"
    authority="${BASH_REMATCH[2]}"

    if [[ "${scheme}" != 'http' && "${scheme}" != 'https' ]]; then
        _fail "$(t proxy_target.scheme_error)${normalized_target}"
        return 1
    fi

    if ! [[ "${authority}" =~ ^([^:]+):([0-9]+)$ ]]; then
        _fail "$(t proxy_target.format_error)${normalized_target}"
        return 1
    fi
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"

    if [[ "${host}" != 'localhost' ]] && ! [[ "${host}" =~ $IPV4_REGEX ]] && ! valid_domain "${host}"; then
        _fail "$(t proxy_target.host_error)${host}"
        return 1
    fi

    check_port "${port}" || return 1
    _pass "$(t proxy_target.valid)${normalized_target}"
    printf '%s\n' "${normalized_target}"
    return 0
}

# =============================================================================
# 函数名称: check_custom_site_domain
# 功能描述: 校验自定义站点域名，确保解析到本机且不与现有域名冲突。
# =============================================================================
function check_custom_site_domain() {
    local domain="$1"
    local ignore_domain="$2"
    local primary_domain=''
    local cdn_domain=''

    _info "$(t custom_domain.check)${domain}"

    if [[ -z "${domain}" ]]; then
        _fail "$(t custom_domain.empty)"
        return 1
    fi

    check_dns_resolution "${domain}" || return 1

    load_script_config
    primary_domain="$(json_get - 'nginx.domain')"
    cdn_domain="$(json_get - 'nginx.cdn')"

    if [[ -n "${primary_domain}" && "${primary_domain}" != 'null' && "${domain}" == "${primary_domain}" && "${domain}" != "${ignore_domain}" ]]; then
        _fail "$(t custom_domain.duplicate_domain)${domain}"
        return 1
    fi

    if [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' && "${domain}" == "${cdn_domain}" && "${domain}" != "${ignore_domain}" ]]; then
        _fail "$(t custom_domain.duplicate_cdn)${domain}"
        return 1
    fi

    if printf '%s' "${SCRIPT_CONFIG}" | jq -e --arg domain "${domain}" --arg ignore "${ignore_domain}" \
        '.nginx.custom_sites // [] | any(.domain == $domain and .domain != $ignore)' >/dev/null 2>&1; then
        _fail "$(t custom_domain.duplicate_custom)${domain}"
        return 1
    fi

    _pass "$(t custom_domain.valid)${domain}"
    return 0
}

# =============================================================================
# 函数名称: check_list_index
# =============================================================================
function check_list_index() {
    local index="$1"
    local total="${2:-0}"

    _info "$(t list_index.check)${index}"

    if ! [[ "${total}" =~ ^[0-9]+$ ]] || ((total < 1)); then
        _fail "$(t list_index.empty_list)"
        return 1
    fi

    if ! [[ "${index}" =~ ^[0-9]+$ ]]; then
        _fail "$(t list_index.format_error)${index}"
        return 1
    fi

    if ((index < 1 || index > total)); then
        _fail "$(t list_index.range_error "total" "${total}")${index}"
        return 1
    fi

    _pass "$(t list_index.valid)${index}"
    return 0
}

# =============================================================================
# 函数名称: check_share_address
# 功能描述: 校验分享链接使用的地址 (空 / IPv4 / IPv6 / 域名 均合法)。
#           双栈部署时可在这里指定 IPv6，使分享链接直接指向 IPv6。
# =============================================================================
function check_share_address() {
    local address="$1"

    _info "$(t address.check)${address}"

    if [[ -z "${address}" ]]; then
        _pass "$(t address.empty)"
        return 0
    fi

    # 允许 [IPv6] 形式
    if [[ "${address}" == \[*\] ]]; then
        address="${address#[}"
        address="${address%]}"
    fi

    if [[ "${address}" =~ $IPV4_REGEX ]] || [[ "${address}" =~ $IPV6_REGEX ]] || [[ "${address}" =~ $DOMAIN_REGEX ]]; then
        _pass "$(t address.valid)${address}"
        return 0
    fi

    _fail "$(t ip.invalid)$1"
    return 1
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
# =============================================================================
function main() {
    load_i18n

    local option="$1"
    shift

    case "${option}" in
    --ip) check_ip "$@" ;;
    --port) check_port "$@" ;;
    --uuid) check_uuid "$@" ;;
    --password) check_password "$@" ;;
    --path) check_path "$@" ;;
    --short) check_short_id "$@" ;;
    --domain) check_domain_security "$@" ;;
    --dns) check_dns_resolution "$@" ;;
    --tag) check_xray_config_exists "$@" ;;
    --xray) check_xray_version_exists "$@" ;;
    --email) validate_email "$@" ;;
    --sni-ports) check_sni_ports "$@" ;;
    --proxy-target) check_proxy_target "$@" ;;
    --custom-domain) check_custom_site_domain "$@" ;;
    --list-index) check_list_index "$@" ;;
    --address) check_share_address "$@" ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
