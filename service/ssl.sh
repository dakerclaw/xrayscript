#!/usr/bin/env bash
# =============================================================================
# 脚本名称: ssl.sh
# 功能描述: 使用 acme.sh 管理 SSL 证书：安装/更新/卸载 acme.sh，
#           签发/续期/停止续期证书，检查证书状态与信息。
#           支持 CA 厂商显式指定 (--ca=zerossl|letsencrypt)。
# 依赖: bash, curl, wget, git, jq, sed, awk, grep, nginx, systemctl, acme.sh
# 配置:
#   - ${HOME}/.acme.sh/
#   - ${NGINX_CONFIG_PATH}/
#   - ${ACME_WEBROOT_PATH}/: HTTP-01 验证目录
#   - ${SSL_CERT_PATH}/: 证书存放目录
# 相关链接:
#   - https://github.com/acmesh-official/acme.sh
#   - https://zerossl.com/
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')"
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)"

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

readonly NGINX_CONFIG_PATH='/usr/local/nginx/conf'
readonly ACME_WEBROOT_PATH='/var/www/_zerossl'
readonly SSL_CERT_PATH="${NGINX_CONFIG_PATH}/certs"
readonly ACME_CMD="${HOME}/.acme.sh/acme.sh"

# --- 全局变量声明 ---
declare ACTION=''
declare DOMAIN=''
declare ACCOUNT_EMAIL=''
declare CA_SERVER=''
declare CA_SERVER_EXPLICIT=0

# =============================================================================
# 函数名称: t
# 功能描述: 取本脚本的 i18n 文本，支持 ${name} 占位符替换。
# 参数:
#   $1: 键名；其余为 name value 对
# =============================================================================
function t() {
    local key="$1"
    local text=''
    local name=''
    local value=''

    shift
    i18n_fill text "${CUR_FILE}.${key}"
    while [[ $# -ge 2 ]]; do
        name="$1"
        value="${2//\\/\\\\}"
        value="${value//&/\\&}"
        text="${text//\$\{${name}\}/${value}}"
        shift 2
    done
    printf '%s' "${text}"
}

# =============================================================================
# 函数名称: normalize_ca_server
# 功能描述: 规范化 CA 参数，仅允许 zerossl / letsencrypt，非法值回落 zerossl。
# =============================================================================
function normalize_ca_server() {
    case "${1,,}" in
    zerossl | letsencrypt) echo "${1,,}" ;;
    *) echo 'zerossl' ;;
    esac
}

# =============================================================================
# 函数名称: get_config_ca_server
# =============================================================================
function get_config_ca_server() {
    local config_ca_server=''
    config_ca_server="$(json_get "${SCRIPT_CONFIG_PATH}" 'nginx.ca_server')"
    normalize_ca_server "${config_ca_server}"
}

# =============================================================================
# 函数名称: resolve_ca_server
# 功能描述: 解析当前生效 CA (命令行优先，其次配置文件)。
# =============================================================================
function resolve_ca_server() {
    if [[ -z "${CA_SERVER}" ]]; then
        CA_SERVER="$(get_config_ca_server)"
    fi
    CA_SERVER="$(normalize_ca_server "${CA_SERVER}")"
}

# =============================================================================
# 函数名称: set_default_ca
# =============================================================================
function set_default_ca() {
    resolve_ca_server
    [[ -x "${ACME_CMD}" ]] || _error "$(t set_ca.not_installed)"
    "${ACME_CMD}" --set-default-ca --server "${CA_SERVER}" || _error "$(t install.fail_set_ca)"
}

# =============================================================================
# 函数名称: issue_args
# 功能描述: 输出签证书的公共参数。
# =============================================================================
function issue_args() {
    printf '%s\n' \
        --issue \
        -d "${DOMAIN}" \
        --webroot "${ACME_WEBROOT_PATH}" \
        --keylength ec-256 \
        --accountkeylength ec-256 \
        --server "${CA_SERVER}"
}

# =============================================================================
# 函数名称: run_issue_with_retry
# 功能描述: 带重试地调用 acme.sh 签发，输出合并后的日志。
# 参数:
#   $1: 重试次数
# =============================================================================
function run_issue_with_retry() {
    local attempts="${1:-3}"
    local issue_retry=1
    local issue_output=''
    local issue_status=1
    local msg=''
    local -a args=()

    mapfile -t args < <(issue_args)
    [[ "${CA_SERVER}" == 'zerossl' ]] && args+=(--ocsp)
    [[ ${CA_SERVER_EXPLICIT} -eq 1 ]] && args+=(--force)

    for ((issue_retry = 1; issue_retry <= attempts; issue_retry++)); do
        msg="$(t issue.letsencrypt_retry "attempt" "${issue_retry}")"
        _warn "${msg}"
        issue_output="$("${ACME_CMD}" "${args[@]}" 2>&1)"
        issue_status=$?
        [[ -n "${issue_output}" ]] && printf "%s\n" "${issue_output}" >&2
        [[ ${issue_status} -eq 0 ]] && break
    done

    printf '%s' "${issue_output}"
    return ${issue_status}
}

# =============================================================================
# 函数名称: restore_nginx_conf
# =============================================================================
function restore_nginx_conf() {
    local nginx_conf="${NGINX_CONFIG_PATH}/nginx.conf"
    local nginx_conf_bak="${nginx_conf}.ssl_script.bak"

    [[ -f "${nginx_conf_bak}" ]] && mv -f "${nginx_conf_bak}" "${nginx_conf}"
}

# =============================================================================
# 函数名称: use_letsencrypt_fallback
# 功能描述: ZeroSSL 卡在 Pending 时，切换为 Let's Encrypt 继续申请。
# =============================================================================
function use_letsencrypt_fallback() {
    local msg=''

    msg="$(t issue.zerossl_pending_switch)"
    _warn "${msg}"
    CA_SERVER='letsencrypt'
    jq --arg caServer "${CA_SERVER}" '.nginx.ca_server = $caServer' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
        mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"
}

# =============================================================================
# 函数名称: install_acme_sh
# =============================================================================
function install_acme_sh() {
    if [[ -e "${ACME_CMD}" ]]; then
        _info "$(t install.already_installed)"
        return 0
    fi

    _info "$(t install.start)"
    resolve_ca_server

    curl -fsSL https://get.acme.sh | sh -s "email=${ACCOUNT_EMAIL}" || _error "$(t install.fail_download)"
    "${ACME_CMD}" --upgrade --auto-upgrade || _error "$(t install.fail_autoupgrade)"
    "${ACME_CMD}" --set-default-ca --server "${CA_SERVER}" || _error "$(t install.fail_set_ca)"
}

function update_acme_sh() {
    _info "$(t update.start)"
    "${ACME_CMD}" --upgrade || _error "$(t update.fail)"
}

function purge_acme_sh() {
    _info "$(t purge.start)"

    if [[ -e "${ACME_CMD}" ]]; then
        "${ACME_CMD}" --upgrade --auto-upgrade 0 || _warn "$(t purge.fail_disable_autoupgrade)"
        "${ACME_CMD}" --uninstall || _warn "$(t purge.fail_uninstall_cmd)"
    fi

    rm -rf "${HOME}/.acme.sh" "${ACME_WEBROOT_PATH}" "${SSL_CERT_PATH}"
    _info "$(t purge.success)"
}

# =============================================================================
# 函数名称: prepare_acme_webroot
# 功能描述: 生成用于 HTTP-01 验证的临时 Nginx 配置并启动/重载 Nginx。
# =============================================================================
function prepare_acme_webroot() {
    local nginx_conf="${NGINX_CONFIG_PATH}/nginx.conf"
    local nginx_conf_bak="${nginx_conf}.ssl_script.bak"

    [[ -d "${ACME_WEBROOT_PATH}" ]] || mkdir -vp "${ACME_WEBROOT_PATH}" || _error "$(t issue.fail_create_acme_dir "ACME_WEBROOT_PATH" "${ACME_WEBROOT_PATH}")"
    [[ -f "${nginx_conf}" ]] && cp -f "${nginx_conf}" "${nginx_conf_bak}" || true

    cat >"${nginx_conf}" <<EOF
user                 root;
pid                  /run/nginx.pid;
worker_processes     1;
events {
    worker_connections  1024;
}
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen       80;
        location ^~ /.well-known/acme-challenge/ {
            root ${ACME_WEBROOT_PATH};
        }
    }
}
EOF

    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl reload nginx || _error "$(t issue.fail_reload_nginx)"
    else
        nginx -t && systemctl start nginx || _error "$(t issue.fail_start_nginx)"
    fi
}

# =============================================================================
# 函数名称: issue_certificate
# 功能描述: 为指定域名签发证书。
# =============================================================================
function issue_certificate() {
    local cert_path=''
    local issue_output=''
    local issue_status=1
    local lower_output=''
    local nginx_conf="${NGINX_CONFIG_PATH}/nginx.conf"
    local nginx_conf_bak="${nginx_conf}.ssl_script.bak"

    [[ ${#DOMAIN} -gt 0 ]] || _error "$(t issue.no_domain)"
    resolve_ca_server

    cert_path="${SSL_CERT_PATH}/${DOMAIN}"
    _info "$(t issue.start)"

    mkdir -vp "${cert_path}" || _error "$(t issue.fail_create_cert_dir "cert_path" "${cert_path}")"

    trap restore_nginx_conf EXIT

    prepare_acme_webroot

    if [[ "${CA_SERVER}" == 'letsencrypt' ]]; then
        run_issue_with_retry 3 >/dev/null || _error "$(t issue.letsencrypt_fail)"
    else
        issue_output="$(run_issue_with_retry 1)"
        issue_status=$?
        if [[ ${issue_status} -ne 0 ]]; then
            lower_output="${issue_output,,}"
            if [[ ${CA_SERVER_EXPLICIT} -eq 0 && "${lower_output}" == *"pending"* && "${lower_output}" == *"the ca is processing your order"* ]]; then
                use_letsencrypt_fallback
                run_issue_with_retry 3 >/dev/null || _error "$(t issue.letsencrypt_fail)"
            else
                _warn "$(t issue.fail_first_attempt)"
                local -a debug_args=()
                mapfile -t debug_args < <(issue_args)
                "${ACME_CMD}" "${debug_args[@]}" --debug
                _error "$(t issue.fail_ecc_issue)"
            fi
        fi
    fi

    restore_nginx_conf
    trap - EXIT

    "${ACME_CMD}" --install-cert --ecc -d "${DOMAIN}" \
        --key-file "${cert_path}/privkey.pem" \
        --fullchain-file "${cert_path}/fullchain.pem" \
        --reloadcmd "nginx -t && systemctl reload nginx" || _error "$(t issue.fail_install_cert)"
}

function renew_certificates() {
    _info "$(t renew.start)"
    "${ACME_CMD}" --cron --force || _error "$(t renew.fail)"
}

function stop_renew_certificates() {
    _info "$(t stop_renew.start)"

    if [[ ${#DOMAIN} -gt 0 ]]; then
        # 修正: 变量统一加引号，避免特殊字符导致路径/参数错乱
        "${ACME_CMD}" --remove -d "${DOMAIN}" --ecc || _warn "$(t stop_renew.fail_cmd)"
        rm -rf "${HOME}/.acme.sh/${DOMAIN}_ecc"
        rm -rf "${SSL_CERT_PATH}/${DOMAIN}"
    else
        _warn "$(t stop_renew.no_domain)"
    fi
}

function check_cron_jobs() {
    _info "$(t check_cron.start)"
    "${ACME_CMD}" --cron --home "${HOME}/.acme.sh"
}

function check_certificate_status() {
    local main_domain=''

    [[ ${#DOMAIN} -gt 0 ]] || _error "$(t status.no_domain)"

    main_domain="$("${ACME_CMD}" --list --home "${HOME}/.acme.sh" | grep -E "^${DOMAIN//./\\.}" | awk '{print $1}')"
    [[ "${main_domain}" == "${DOMAIN}" ]]
}

function show_certificate_info() {
    [[ ${#DOMAIN} -gt 0 ]] || _error "$(t info.no_domain)"
    _info "$(t info.start)"
    "${ACME_CMD}" --info -d "${DOMAIN}"
}

# =============================================================================
# 函数名称: show_help
# =============================================================================
function show_help() {
    local usage='' commands_title='' options_title=''
    local -a cmds=(
        "--install:cmd_install"
        "--update:cmd_update"
        "--purge:cmd_purge"
        "--issue:cmd_issue"
        "--renew:cmd_renew"
        "--stop-renew:cmd_stop_renew"
        "--check-cron:cmd_check_cron"
        "--info:cmd_info"
        "--status:cmd_status"
        "--set-ca:cmd_set_ca"
        "--help:cmd_help"
    )
    local item=''

    usage="$(t help.usage "script_name" "$0")"
    commands_title="$(t help.commands_title)"
    options_title="$(t help.options_title)"

    printf '%s\n' "${usage}"
    printf '%s:\n' "${commands_title}"
    for item in "${cmds[@]}"; do
        printf '  %-18s %s\n' "${item%%:*}" "$(t "help.${item#*:}")"
    done
    printf '%s:\n' "${options_title}"
    printf '  %-18s %s\n' "--domain" "$(t help.opt_domain)"
    printf '  %-18s %s\n' "--email" "$(t help.opt_email)"
    printf '  %-18s %s\n' "--ca" "$(t help.opt_ca)"
    exit 0
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    load_i18n

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --install | --update | --purge | --issue | --renew | --stop-renew | --check-cron | --status | --info | --set-ca)
            ACTION="${1#--}"
            ;;
        --domain=*) DOMAIN="${1#*=}" ;;
        --email=*) ACCOUNT_EMAIL="${1#*=}" ;;
        --ca=*)
            CA_SERVER="${1#*=}"
            CA_SERVER_EXPLICIT=1
            ;;
        --help | *) show_help ;;
        esac
        shift
    done

    [[ -z "${ACTION}" ]] && show_help

    case "${ACTION}" in
    install) install_acme_sh ;;
    update) update_acme_sh ;;
    purge) purge_acme_sh ;;
    issue) issue_certificate ;;
    renew) renew_certificates ;;
    stop-renew) stop_renew_certificates ;;
    check-cron) check_cron_jobs ;;
    status) check_certificate_status ;;
    info) show_certificate_info ;;
    set-ca) set_default_ca ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
