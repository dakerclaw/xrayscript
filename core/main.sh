#!/usr/bin/env bash
# =============================================================================
# 脚本名称: main.sh
# 功能描述: xrayscript 项目的主要管理脚本。
#           提供交互式菜单和命令行接口，用于安装、配置、管理 Xray-core
#           和相关服务（如 Nginx, GeoIP, WARP 等），支持多语言。
# 依赖: bash, jq, cut, sed
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言设置 (language) 和脚本配置
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的提示文本 (i18n 数据文件)
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')" # 当前脚本文件名 (不含扩展名)
PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# 引入公共函数库 (颜色、路径、i18n、日志、cmd_exists、json_get 等)
# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

# 定义子脚本路径
readonly MENU_PATH="${CUR_DIR}/menu.sh"                        # 菜单脚本路径
readonly HANDLER_PATH="${CUR_DIR}/handler.sh"                  # 处理器脚本路径
readonly READ_PATH="${CUR_DIR}/read.sh"                        # 用户输入读取脚本

# --- 全局变量声明 ---
declare LANG_PARAM=''    # 当前语言参数
declare SCRIPT_CONFIG='' # 存储脚本配置内容

# =============================================================================
# 函数名称: exec_menu
# 功能描述: 执行菜单脚本 (menu.sh)，并把用户选择作为返回值。
#           注意: 必须先保存退出码再执行其他命令，否则 $? 会被覆盖。
# =============================================================================
function exec_menu() {
    local OPTION=0
    bash "${MENU_PATH}" "$@"
    OPTION=$?
    return "${OPTION}"
}

# =============================================================================
# 函数名称: exec_handler
# 功能描述: 执行处理器脚本 (handler.sh)，失败时不直接退出，
#           而是把错误抛给调用方 (由 _error 统一提示)，避免误伤外层流程。
# =============================================================================
function exec_handler() {
    local exit_code=0
    bash "${HANDLER_PATH}" "$@"
    exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        local msg=''
        i18n_fill msg "main.handler_failed"
        _error "${msg}"
    fi
}

function exec_read() {
    bash "${READ_PATH}" "$@"
}

# =============================================================================
# 函数名称: processes_web_config
# 功能描述: 处理 Web 配置相关的流程。
# 参数:
#   $1: is_change - 'y' 仅更改 web 配置；'n' 执行完整安装流程 (默认 'y')
# =============================================================================
function processes_web_config() {
    local is_change="${1:-y}"
    local current_tag=''
    local choose=0
    local web='normal'

    current_tag="$(json_get "${SCRIPT_CONFIG_PATH}" 'xray.tag')"

    exec_menu '--web'
    choose=$?

    case ${choose} in
    2) web='v3' ;;
    3) web='v4' ;;
    *) web='normal' ;;
    esac

    if [[ "${is_change}" == 'y' ]]; then
        exec_handler '--web' "${web}"
    else
        if [[ "${current_tag,,}" != 'sni' ]]; then
            exec_handler '--sni-ports'
        fi
        exec_handler '--script-config' 'SNI'  # 设置脚本配置为 SNI
        exec_handler '--install'              # 安装核心组件
        exec_handler '--nginx-install'        # 安装 Nginx
        exec_handler '--xray-config' "${web}" # 配置 Xray 使用选定的 web 类型
        exec_handler '--restart'              # 重启 Xray 服务
        exec_handler '--share'                # 显示分享链接
    fi
}

# =============================================================================
# 函数名称: processes_ca_vendor
# 功能描述: 处理 CA 厂商选择。
# 参数:
#   $1: apply_mode - 'preview' 仅选择；'init' 初始化写入；'switch' 带确认的切换
# =============================================================================
function processes_ca_vendor() {
    local apply_mode="${1:-preview}"
    local choose=0
    local ca_server='zerossl'
    local current_ca_server=''
    local switch_confirm='n'

    exec_menu '--ca'
    choose=$?

    current_ca_server="$(json_get "${SCRIPT_CONFIG_PATH}" 'nginx.ca_server')"
    [[ -z "${current_ca_server}" || "${current_ca_server}" == 'null' ]] && current_ca_server='zerossl'

    case ${choose} in
    2) ca_server='letsencrypt' ;;
    *) ca_server='zerossl' ;;
    esac

    if [[ "${apply_mode}" != 'preview' ]]; then
        if [[ "${apply_mode}" == 'switch' && "${ca_server}" != "${current_ca_server}" ]]; then
            switch_confirm="$(exec_read '--switch-ca')"
            [[ "${switch_confirm,,}" == 'y' ]] || return 0
        fi
        exec_handler '--ca-server' "${ca_server}"
    fi
}

# =============================================================================
# 函数名称: processes_xray_config
# 功能描述: 处理 Xray 协议配置流程。
# =============================================================================
function processes_xray_config() {
    local choose=0
    local XTLS_CONFIG='Vision'

    exec_menu '--config'
    choose=$?

    case ${choose} in
    2) XTLS_CONFIG='XHTTP' ;;
    3) XTLS_CONFIG='Trojan' ;;
    4) XTLS_CONFIG='Fallback' ;;
    5) XTLS_CONFIG='SNI' ;;
    *) XTLS_CONFIG='Vision' ;;
    esac

    if [[ "${XTLS_CONFIG}" == 'SNI' ]]; then
        processes_ca_vendor 'init'
        processes_web_config 'n'
    else
        exec_handler '--script-config' "${XTLS_CONFIG}" # 设置脚本配置
        exec_handler '--install'                        # 安装核心组件
        exec_handler '--xray-config'                    # 配置 Xray
        exec_handler '--restart'                        # 重启 Xray 服务
        exec_handler '--share'                          # 显示分享链接
    fi
}

# =============================================================================
# 函数名称: processes_xray
# 功能描述: 处理 Xray 安装相关的流程。
# 参数:
#   $1: is_exec - 'y' 立即执行安装；'n' 仅设置版本后进入配置流程
# =============================================================================
function processes_xray() {
    local is_exec="${1:-y}"
    local version='release'
    local choose=0

    exec_menu '--xray'
    choose=$?

    case ${choose} in
    1) version='latest' ;;
    3) version='custom' ;;
    *) version='release' ;;
    esac

    if [[ "${is_exec}" == 'y' ]]; then
        exec_handler '--install' "${version}" 'y'
    else
        exec_handler '--version' "${version}"
        processes_xray_config
    fi
}

# =============================================================================
# 函数名称: processes_full_installation
# 功能描述: 处理一键安装相关的流程。
# =============================================================================
function processes_full_installation() {
    local choose=0

    exec_menu '--full'
    choose=$?

    case ${choose} in
    2) processes_xray 'n' ;;
    *) exec_handler '--quick' 'Vision' ;;
    esac
}

# =============================================================================
# 函数名称: processes_routing
# 功能描述: 处理路由规则配置流程。
# =============================================================================
function processes_routing() {
    local choose=0

    exec_menu '--route'
    choose=$?

    case ${choose} in
    1) exec_handler '--warp' ;;
    2) exec_handler '--reset-warp' ;;
    3) exec_handler '--routing' 'block' 'ip' ;;
    4) exec_handler '--routing' 'block' 'domain' ;;
    5) exec_handler '--routing' 'warp' 'ip' ;;
    6) exec_handler '--routing' 'warp' 'domain' ;;
    *) return 0 ;;
    esac

    exec_handler '--restart' # 重启 Xray 服务
}

# =============================================================================
# 函数名称: processes_custom_sites
# 功能描述: 处理自定义站点管理流程。
# =============================================================================
function processes_custom_sites() {
    local choose=0

    exec_menu '--custom-sites'
    choose=$?

    case ${choose} in
    1) exec_handler '--custom-sites' 'list' ;;
    2) exec_handler '--custom-sites' 'add' ;;
    3) exec_handler '--custom-sites' 'update' ;;
    4) exec_handler '--custom-sites' 'delete' ;;
    *) return 0 ;;
    esac
}

# =============================================================================
# 函数名称: processes_sni_config
# 功能描述: 处理 SNI 配置相关的流程。
# =============================================================================
function processes_sni_config() {
    local tag=''
    local choose=0

    tag="$(json_get "${SCRIPT_CONFIG_PATH}" 'xray.tag')"

    if [[ "${tag,,}" != 'sni' ]]; then
        local msg=''
        i18n_fill msg 'main.not_support'
        _error "${msg}"
    fi

    exec_menu '--sni'
    choose=$?

    case ${choose} in
    1) exec_handler '--change-domain' 'domain' ;;
    2) exec_handler '--change-domain' 'cdn' ;;
    3) exec_handler '--renew-certificate' ;;
    4) exec_handler '--nginx-update' ;;
    5) exec_handler '--nginx-cron' ;;
    6) processes_web_config ;;
    7) exec_handler '--v3-reset' ;;
    8) processes_ca_vendor 'switch' ;;
    9) processes_custom_sites ;;
    *) return 0 ;;
    esac
}

# =============================================================================
# 函数名称: processes_language
# 功能描述: 处理语言设置相关的流程。
# =============================================================================
function processes_language() {
    local choose=0

    exec_menu '--language'
    choose=$?

    case ${choose} in
    2) LANG_PARAM="en" ;;
    *) LANG_PARAM="zh" ;;
    esac

    SCRIPT_CONFIG="$(jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}")"
    persist_script_config "${SCRIPT_CONFIG}"
    bash "${CUR_DIR}/${CUR_FILE}.sh"
    exit 0
}

# =============================================================================
# 函数名称: processes_ipv6
# 功能描述: 处理 IPv6 一键部署流程。
# =============================================================================
function processes_ipv6() {
    local choose=0

    exec_menu '--ipv6'
    choose=$?

    case ${choose} in
    1) exec_handler '--ipv6-deploy' 'dual' ;;
    2) exec_handler '--ipv6-deploy' 'v6' ;;
    3) exec_handler '--ipv6-deploy' 'default' ;;
    0) return 0 ;;
    *) return 0 ;;
    esac
}

# =============================================================================
# 函数名称: processes_config
# 功能描述: 处理主配置管理相关的流程。
# =============================================================================
function processes_config() {
    local choose=0

    exec_menu '--management'
    choose=$?

    case ${choose} in
    1) processes_xray_config ;;
    2) processes_routing ;;
    3) processes_sni_config ;;
    4) exec_handler '--change-port' ;;
    5) exec_handler '--geodata-cron' ;;
    6) processes_language ;;
    7) exec_handler '--bbr' 'toggle' ;;
    8) exec_handler '--change-address' ;;
    9) processes_ipv6 ;;
    0) return 0 ;;
    *) return 0 ;;
    esac
}

# =============================================================================
# 函数名称: processes_traffic
# 功能描述: 处理统计信息管理相关的流程。
# =============================================================================
function processes_traffic() {
    local choose=0

    exec_menu '--traffic'
    choose=$?

    case ${choose} in
    1) exec_handler '--traffic' 'show' ;;
    2) exec_handler '--traffic' 'enable' ;;
    3) exec_handler '--traffic' 'disable' ;;
    4) exec_handler '--traffic' 'reset' ;;
    0) return 0 ;;
    *) return 0 ;;
    esac
}

# =============================================================================
# 函数名称: processes_index
# 功能描述: 处理脚本主界面的流程。
# =============================================================================
function processes_index() {
    local choose=0

    # banner + status + index 一次性渲染，只启动一次子进程
    exec_menu '--scan'
    choose=$?

    case ${choose} in
    1) processes_full_installation ;;
    2) processes_xray ;;
    3) exec_handler '--purge' ;;
    4) exec_handler '--start' ;;
    5) exec_handler '--stop' ;;
    6) exec_handler '--restart' ;;
    7) exec_handler '--share' ;;
    8) processes_traffic ;;
    9) processes_config ;;
    *) exit 0 ;;
    esac
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
# =============================================================================
function main() {
    load_i18n

    case "${1,,}" in
    --vision) exec_handler '--quick' 'Vision' ;;
    --xhttp) exec_handler '--quick' 'XHTTP' ;;
    --fallback) exec_handler '--quick' 'Fallback' ;;
    *)
        # 交互模式: 每个操作结束后回到主菜单, 在主菜单选 0 退出
        # (子菜单里的 0 = 返回主菜单, 由各 processes_* 直接 return 实现)
        while true; do
            processes_index "$2"
        done
        ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
