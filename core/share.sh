#!/usr/bin/env bash
# =============================================================================
# 脚本名称: share.sh
# 功能描述: 生成 Xray 客户端的配置信息与分享链接 (VLESS / Trojan)，
#           并根据服务端配置计算 Reality、XHTTP、mKCP、TLS 等链接参数。
#           所有取值均来自一次 jq 调用，避免逐字段启动子进程。
# 依赖: bash, jq, curl, qrencode
# 配置:
#   - ${XRAY_CONFIG_PATH}: Xray 服务端配置文件
#   - ${SCRIPT_CONFIG_PATH}: 脚本自身配置文件
#   - ${I18N_DIR}/${lang}.json: 国际化文件
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')"
PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

readonly GENERATE_PATH="${CUR_DIR}/generate.sh"
readonly XRAY_CONFIG_PATH="/usr/local/etc/xray/config.json"

# --- 全局变量声明 ---
declare -A CLIENT_CONFIG    # 当前客户端配置
declare XRAY_CONFIG=''      # Xray 配置 JSON
declare SCRIPT_CONFIG=''    # 脚本配置 JSON
declare XHTTP_EXTRA=''      # 额外下行配置 JSON
declare XHTTP_EXTRA_ENCODED='' # URL 编码后的额外配置
declare SHARE_LINK=''       # 最终分享链接
declare REMOTE_HOST=''      # 缓存的公网 IP

# jq 程序常量: 放到单行双引号字符串中，避免多行单引号被 shell 提前截断
readonly JQ_TLS_DOWN='{
  downloadSettings: {
    address: $s, port: 443, network: "xhttp", security: "tls",
    tlsSettings: {serverName: $s, allowInsecure: false, alpn: ["h2"], fingerprint: "chrome"},
    xhttpSettings: {host: $s, path: $p, mode: "auto"}
  }
}'

readonly JQ_REALITY_DOWN='{
  downloadSettings: {
    address: $s, port: 443, network: "xhttp", security: "reality",
    realitySettings: {show: false, serverName: $s, fingerprint: "chrome", publicKey: $k, shortId: $i, spiderX: "/"},
    xhttpSettings: {host: "", path: $p, mode: "auto"}
  }
}'

# =============================================================================
# 函数名称: get_remote_host
# 功能描述: 获取本机公网 IPv4 (只请求一次)。
# =============================================================================
function get_remote_host() {
    if [[ -z "${REMOTE_HOST}" ]]; then
        REMOTE_HOST="$(curl -fsSL --max-time 10 ipv4.icanhazip.com 2>/dev/null)"
    fi
    printf '%s' "${REMOTE_HOST}"
}

# =============================================================================
# 函数名称: cache_json_data
# 功能描述: 一次性把入站所需字段全部解析出来，避免每个字段一次 jq。
# =============================================================================
function cache_json_data() {
    XRAY_CONFIG="$(jq '.' "${XRAY_CONFIG_PATH}" 2>/dev/null)"
    SCRIPT_CONFIG="$(jq '.' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
}

# =============================================================================
# 函数名称: get_common_config
# 功能描述: 提取指定 inbound 的通用客户端参数到 CLIENT_CONFIG。
# 参数:
#   $1: inbound 索引
# =============================================================================
function get_common_config() {
    local inbound_index=$1
    local field=''
    local value=''
    local random=''

    random="$(bash "${GENERATE_PATH}" '--random')"

    CLIENT_CONFIG[remote_host]="$(get_remote_host)"
    CLIENT_CONFIG[port]="$(json_get - '.xray.port' SCRIPT_CONFIG)"
    CLIENT_CONFIG[public_key]="$(json_get - '.xray.publicKey' SCRIPT_CONFIG)"
    CLIENT_CONFIG[tag]="$(json_get - '.xray.tag' SCRIPT_CONFIG)"

    # 单次 jq：把 inbound 需要的字段整理成 key=value 行
    while IFS='=' read -r field value; do
        [[ -n "${field}" ]] && CLIENT_CONFIG["${field}"]="${value}"
    done < <(printf '%s' "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson r "${random}" '
        .inbounds[$i] as $in
        | [
            ("protocol=" + ($in.protocol // "")),
            ("uuid=" + ($in.settings.clients[0].id // "")),
            ("password=" + ($in.settings.clients[0].password // "")),
            ("seed=" + ($in.streamSettings.kcpSettings.seed // "")),
            ("type=" + ($in.streamSettings.network // "")),
            ("flow=" + ($in.settings.clients[0].flow // "")),
            ("security=" + ($in.streamSettings.security // "")),
            ("path=" + ($in.streamSettings.xhttpSettings.path // "")),
            ("server_name=" + ($in.streamSettings.realitySettings.serverNames // [] | if length == 0 then "" else .[$r % length] end)),
            ("short_id=" + ($in.streamSettings.realitySettings.shortIds // [] | if length == 0 then "" else .[$r % length] end))
        ] | .[]')
}

# =============================================================================
# 函数名称: get_tls_down_json
# 功能描述: 生成 SNI + TLS + CDN 下行模式的额外配置。
# =============================================================================
function get_tls_down_json() {
    local server_name=''
    local sni_path=''

    server_name="$(json_get - '.nginx.cdn' SCRIPT_CONFIG)"
    sni_path="$(json_get - '.xray.path' SCRIPT_CONFIG)"

    XHTTP_EXTRA="$(jq -n \
        --arg s "${server_name}" \
        --arg p "${sni_path}" \
        "$JQ_TLS_DOWN")"

    XHTTP_EXTRA_ENCODED="$(urlencode "$(printf '%s' "${XHTTP_EXTRA}" | jq -c .)")"
}

# =============================================================================
# 函数名称: get_reality_down_json
# 功能描述: 生成 SNI + Reality 下行模式的额外配置。
# =============================================================================
function get_reality_down_json() {
    local server_name=''
    local public_key=''
    local sni_path=''
    local short_id=''
    local random=''

    server_name="$(json_get - '.nginx.domain' SCRIPT_CONFIG)"
    public_key="$(json_get - '.xray.publicKey' SCRIPT_CONFIG)"
    sni_path="$(json_get - '.xray.path' SCRIPT_CONFIG)"
    random="$(bash "${GENERATE_PATH}" '--random')"
    short_id="$(printf '%s' "${XRAY_CONFIG}" | jq -r --argjson r "${random}" '.inbounds[1].streamSettings.realitySettings.shortIds // [] | if length == 0 then "" else .[$r % length] end')"

    XHTTP_EXTRA="$(jq -n \
        --arg s "${server_name}" \
        --arg k "${public_key}" \
        --arg i "${short_id}" \
        --arg p "${sni_path}" \
        "$JQ_REALITY_DOWN")"

    XHTTP_EXTRA_ENCODED="$(urlencode "$(printf '%s' "${XHTTP_EXTRA}" | jq -c .)")"
}

# =============================================================================
# 函数名称: build_share_link
# 功能描述: 按需组合基础链接与各参数片段。
# 参数:
#   $1 (可选): 连接地址，默认使用服务端公网 IP (CDN 场景传 CDN 域名)
#   $2 (可选): 额外参数 (形如 &extra=...)
# =============================================================================
function build_share_link() {
    local host="${1:-${CLIENT_CONFIG[remote_host]}}"
    local extra="${2:-}"
    local auth="${CLIENT_CONFIG[uuid]}"
    local params="type=${CLIENT_CONFIG[type]}"

    [[ "${CLIENT_CONFIG[protocol]}" == 'trojan' ]] && auth="${CLIENT_CONFIG[password]}"

    params+="&security=${CLIENT_CONFIG[security]}"

    case "${CLIENT_CONFIG[security]}" in
    reality)
        params+="&sni=${CLIENT_CONFIG[server_name]}&pbk=${CLIENT_CONFIG[public_key]}&sid=${CLIENT_CONFIG[short_id]}&spx=%2F&fp=chrome"
        ;;
    tls)
        params+="&sni=${CLIENT_CONFIG[server_name]}&alpn=h2&fp=chrome"
        ;;
    esac

    case "${CLIENT_CONFIG[type]}" in
    kcp) params+="&seed=${CLIENT_CONFIG[seed]}" ;;
    xhttp) params+="&path=%2F${CLIENT_CONFIG[path]#/}" ;;
    esac

    [[ "${CLIENT_CONFIG[flow]}" == 'xtls-rprx-vision' ]] && params+="&flow=${CLIENT_CONFIG[flow]}"

    SHARE_LINK="${CLIENT_CONFIG[protocol]}://${auth}@${host}:${CLIENT_CONFIG[port]}?${params}${extra}"
}

# =============================================================================
# 分享链接生成器 (保留原有函数名，语义不变)
# =============================================================================
function get_mkcp_share_link() { CLIENT_CONFIG[security]='none'; build_share_link; }
function get_vision_share_link() { build_share_link; }
function get_xhttp_share_link() { build_share_link; }
function get_trojan_share_link() { build_share_link; }

# =============================================================================
# 函数名称: get_fallback_xhttp_share_link
# 功能描述: 为 fallback inbound (index 1) 生成 XHTTP + Reality 链接。
# =============================================================================
function get_fallback_xhttp_share_link() {
    local inbound_index=1
    local random=''

    random="$(bash "${GENERATE_PATH}" '--random')"
    while IFS='=' read -r field value; do
        [[ -n "${field}" ]] && CLIENT_CONFIG["${field}"]="${value}"
    done < <(printf '%s' "${XRAY_CONFIG}" | jq -r --argjson i "${inbound_index}" --argjson r "${random}" '
        .inbounds[$i].streamSettings as $s
        | [
            ("security=" + ($s.security // "reality")),
            ("server_name=" + ($s.realitySettings.serverNames // [] | if length == 0 then "" else .[$r % length] end)),
            ("short_id=" + ($s.realitySettings.shortIds // [] | if length == 0 then "" else .[$r % length] end))
        ] | .[]')

    get_xhttp_share_link
}

# =============================================================================
# 函数名称: get_sni_tls_share_link
# 功能描述: 生成 SNI + TLS (过 CDN) 分享链接。
# =============================================================================
function get_sni_tls_share_link() {
    CLIENT_CONFIG[security]='tls'
    CLIENT_CONFIG[server_name]="$(json_get - '.nginx.cdn' SCRIPT_CONFIG)"
    CLIENT_CONFIG[remote_host]="${CLIENT_CONFIG[server_name]}"
    build_share_link
}

function get_sni_tls_down_share_link() {
    get_fallback_xhttp_share_link
    SHARE_LINK="${SHARE_LINK}&extra=${XHTTP_EXTRA_ENCODED}"
}

function get_sni_reality_down_share_link() {
    get_sni_tls_share_link
    SHARE_LINK="${SHARE_LINK}&extra=${XHTTP_EXTRA_ENCODED}"
}

# =============================================================================
# 函数名称: show_client_config
# 功能描述: 打印客户端配置。
# =============================================================================
function show_client_config() {
    local title=''
    i18n_fill title "${CUR_FILE}.client"

    cat <<EOF
------------------ ${title}(${CLIENT_CONFIG[tag]}) ------------------
address          : ${CLIENT_CONFIG[remote_host]}
port             : ${CLIENT_CONFIG[port]}
protocol         : ${CLIENT_CONFIG[protocol]}
uuid             : ${CLIENT_CONFIG[uuid]}
password(trojan) : ${CLIENT_CONFIG[password]}
seed(mKCP)       : ${CLIENT_CONFIG[seed]}
flow             : ${CLIENT_CONFIG[flow]}
network          : ${CLIENT_CONFIG[type]}
security         : ${CLIENT_CONFIG[security]}
ServerName       : ${CLIENT_CONFIG[server_name]}
path             : ${CLIENT_CONFIG[path]}
Fingerprint      : chrome
PublicKey        : ${CLIENT_CONFIG[public_key]}
ShortId          : ${CLIENT_CONFIG[short_id]}
SpiderX          : /
EOF
}

# =============================================================================
# 函数名称: show_config
# 功能描述: 打印客户端配置、额外配置、分享链接与二维码。
# =============================================================================
function show_config() {
    local title=''

    SHARE_LINK="${SHARE_LINK}#${CLIENT_CONFIG[tag]}"
    show_client_config

    if [[ -n "${XHTTP_EXTRA}" ]]; then
        i18n_fill title "${CUR_FILE}.extra"
        echo "------------------ ${title} ------------------"
        printf '%s' "${XHTTP_EXTRA}" | jq .
    fi

    i18n_fill title "${CUR_FILE}.link"
    echo "------------------ ${title} ------------------"
    echo "${SHARE_LINK}"

    i18n_fill title "${CUR_FILE}.qr"
    echo "------------------ ${title} ------------------"
    if cmd_exists 'qrencode'; then
        echo "${SHARE_LINK}" | qrencode -t ansiutf8
    fi

    echo "------------------------------------------------------"
}

# =============================================================================
# 函数名称: show_fallback_config
# 功能描述: 生成 Fallback 模式的多组配置。
# =============================================================================
function show_fallback_config() {
    CLIENT_CONFIG[tag]='fallback_vision_reality'
    get_vision_share_link
    show_config

    get_common_config 2
    CLIENT_CONFIG[tag]='fallback_xhttp_reality'
    get_fallback_xhttp_share_link
}

# =============================================================================
# 函数名称: show_sni_config
# 功能描述: 生成 SNI 模式的多组配置。
# =============================================================================
function show_sni_config() {
    CLIENT_CONFIG[tag]='sni_vision_reality'
    get_vision_share_link
    show_config

    get_common_config 2
    CLIENT_CONFIG[tag]='sni_xhttp_reality'
    get_fallback_xhttp_share_link
    show_config

    get_common_config 2
    CLIENT_CONFIG[tag]='sni_tls_down'
    get_tls_down_json
    get_sni_tls_down_share_link
    show_config

    get_common_config 2
    CLIENT_CONFIG[tag]='sni_xhttp_cdn'
    XHTTP_EXTRA=''
    get_sni_tls_share_link
    show_config

    get_common_config 2
    CLIENT_CONFIG[tag]='sni_reality_down'
    get_reality_down_json
    get_sni_reality_down_share_link
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    local tag=''

    load_i18n
    cache_json_data
    get_common_config 1

    tag="$(json_get - '.xray.tag' SCRIPT_CONFIG)"
    case "${tag,,}" in
    mkcp) get_mkcp_share_link ;;
    xhttp) get_xhttp_share_link ;;
    trojan) get_trojan_share_link ;;
    fallback) show_fallback_config ;;
    sni) show_sni_config ;;
    *) get_vision_share_link ;;
    esac

    show_config >&2
}

# --- 脚本执行入口 ---
main "$@"
