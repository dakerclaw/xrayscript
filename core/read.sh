#!/usr/bin/env bash
# =============================================================================
# 脚本名称: read.sh
# 功能描述: 根据传入的参数，从国际化 (i18n) 配置文件中读取对应的提示信息，
#           并从标准输入读取用户输入，把用户输入输出到标准输出。
#           提示文本走内存缓存，避免每次输入都启动 jq 子进程。
# 依赖: bash, jq
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

# --- 参数映射表 ---
# 键是命令行选项，值是 "类型,字段名"；类型用于区分提示样式 (config/rule)
declare -A param_map=(
    ["--version"]="config,version"
    ["--rules"]="config,rules"
    ["--block-bt"]="config,block_bt"
    ["--block-cn"]="config,block_cn"
    ["--block-ad"]="config,block_ad"
    ["--port"]="config,port"
    ["--uuid"]="config,uuid"
    ["--fallback"]="config,fallback"
    ["--password"]="config,password"
    ["--target"]="config,target"
    ["--only-change-domain"]="config,only_change_domain"
    ["--domain"]="config,domain"
    ["--cdn"]="config,cdn"
    ["--custom-domain"]="config,custom_domain"
    ["--proxy-target"]="config,proxy_target"
    ["--site-index"]="config,site_index"
    ["--email"]="config,email"
    ["--switch-ca"]="config,switch_ca"
    ["--short"]="config,short"
    ["--path"]="config,path"
    ["--address"]="config,address"
    ["--warp-ip"]="rule,warp_ip"
    ["--warp-domain"]="rule,warp_domain"
    ["--block-ip"]="rule,block_ip"
    ["--block-domain"]="rule,block_domain"
)

# =============================================================================
# 函数名称: read_input
# 功能描述: 打印格式化的提示信息到标准错误。
# 参数:
#   $1: 类型 ("config" 或 "rule")
#   $2: 消息内容
# =============================================================================
function read_input() {
    local type="$1"
    local msg="$2"
    local color="${GREEN}"
    local title=''
    local suffix=''

    if [[ "$type" == "rule" ]]; then
        color="${YELLOW}"
        i18n_fill title 'title.route'
        i18n_fill suffix 'title.multiple_values'
        msg="${msg} (${suffix})"
    else
        i18n_fill title 'title.config'
    fi

    printf "%b[%s]%b %s " "${color}" "${title}" "${NC}" "${msg}" >&2
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
# =============================================================================
function main() {
    load_i18n

    local option="$1"
    local type=''
    local field=''
    local key=''
    local prompt=''
    local short_tip=''
    local tip_text=''
    local input=''

    # 兼容调用方直接传入裸参数名，例如 custom-domain
    if [[ -n "${option}" && "${option}" != --* ]]; then
        option="--${option}"
    fi

    [[ -z "${param_map[${option}]}" ]] && return 0

    IFS=',' read -r type field <<<"${param_map[${option}]}"
    key="${CUR_FILE}.${field}"

    i18n_fill prompt "${key}"

    if [[ "${option}" == "--short" ]]; then
        i18n_fill short_tip "${CUR_FILE}.short_id_tip"
        i18n_fill tip_text 'title.tip'
        printf "%b[%s]%b %s\n" "${YELLOW}" "${tip_text}" "${NC}" "${short_tip}" >&2
    fi

    read_input "$type" "$prompt"

    # 读取失败 (EOF / Ctrl-D) 时按空输入处理，避免死循环
    read -r input || input=''

    printf '%s\n' "${input}"
}

# --- 脚本执行入口 ---
main "$@"
