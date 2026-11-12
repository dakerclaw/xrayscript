#!/usr/bin/env bash
# =============================================================================
# 脚本名称: menu.sh
# 功能描述: 提供交互式菜单界面，用于 xrayscript 项目的主控制台。
#           显示各种配置选项、状态信息和操作菜单，支持多语言。
#           i18n 文本走内存缓存，避免每次取词都启动 jq 子进程。
# 依赖: bash, jq, sed, base64
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 用于读取语言、Xray 版本、配置标签等设置
#   - ${I18N_DIR}/${lang}.json: 用于读取具体的菜单文本 (i18n 数据文件)
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')" # 当前脚本文件名 (不含扩展名)
PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"


# --- 全局变量声明 ---
declare SCRIPT_CONFIG='' # 脚本配置缓存 (避免反复读盘)

# =============================================================================
# 函数名称: menu_item
# 功能描述: 打印一行菜单项 "1. 选项文本"。
#           文本已缓存于 I18N_CACHE，不会启动子进程。
# 参数:
#   $1: 序号
#   $2: i18n 键名 (不含 CUR_FILE 前缀)
#   $3 (可选): 颜色 (默认绿色)
#   $4 (可选): 后缀文本 (例如 "(默认)")
# =============================================================================
function menu_item() {
    local index="$1"
    local key="$2"
    local color="${3:-${GREEN}}"
    local suffix="${4:-}"
    local text=''

    i18n_fill text "${CUR_FILE}.${key}"

    if [[ -n "${suffix}" ]]; then
        printf "%b%s.%b %s%b%s%b\n" "${color}" "${index}" "${NC}" "${text}" "${GREEN}" "${suffix}" "${NC}"
    else
        printf "%b%s.%b %s\n" "${color}" "${index}" "${NC}" "${text}"
    fi
}

# =============================================================================
# 函数名称: menu_title
# 功能描述: 打印形如 "------ 标题 ------" 的分隔标题。
# 参数:
#   $1: i18n 键名 (不含 CUR_FILE 前缀)
# =============================================================================
function menu_title() {
    local text=''
    i18n_fill text "${CUR_FILE}.$1"
    echo "------------------ ${text} ------------------"
}

# =============================================================================
# 函数名称: menu_line
# 功能描述: 打印分隔线。
# =============================================================================
function menu_line() {
    echo "------------------------------------------------------"
}

# =============================================================================
# 函数名称: menu_banner
# 功能描述: 打印主菜单顶部的彩色 VISION 横幅。
#           每个字母独立 ANSI 颜色并独立复位，颜色互不串染；
#           纯 printf 字面转义，不依赖 figlet 等外部工具。
# =============================================================================
function menu_banner() {
    printf '%b\n' \
        "${YELLOW}__     __${NC}  ${GREEN} ___ ${NC}  ${CYAN} ____  ${NC}  ${PURPLE} ___ ${NC}  ${BLUE}  ___  ${NC}  ${RED} _   _ ${NC}" \
        "${YELLOW}\\ \\   / /${NC}  ${GREEN}|_ _|${NC}  ${CYAN}/ ___| ${NC}  ${PURPLE}|_ _|${NC}  ${BLUE} / _ \\ ${NC}  ${RED}| \\ | |${NC}" \
        "${YELLOW} \\ \\ / / ${NC}  ${GREEN} | | ${NC}  ${CYAN}\\___ \\ ${NC}  ${PURPLE} | | ${NC}  ${BLUE}| | | |${NC}  ${RED}|  \\| |${NC}" \
        "${YELLOW}  \\ V /  ${NC}  ${GREEN} | | ${NC}  ${CYAN} ___) |${NC}  ${PURPLE} | | ${NC}  ${BLUE}| |_| |${NC}  ${RED}| |\\  |${NC}" \
        "${YELLOW}   \\_/   ${NC}  ${GREEN}|___|${NC}  ${CYAN}|____/ ${NC}  ${PURPLE}|___|${NC}  ${BLUE} \\___/ ${NC}  ${RED}|_| \\_|${NC}"
}

# =============================================================================
# 函数名称: menu_language
# 功能描述: 显示语言选择菜单。
# =============================================================================
function menu_language() {
    printf "%b1.%b中文\n" "${GREEN}" "${NC}"
    printf "%b2.%bEnglish\n" "${GREEN}" "${NC}"
}

# =============================================================================
# 函数名称: menu_index
# 功能描述: 显示主菜单。
# =============================================================================
function menu_index() {
    local version=''
    local description=''

    menu_banner
    version="$(json_get "${SCRIPT_CONFIG_PATH}" 'version')"
    i18n_fill description "${CUR_FILE}.index.description"

    echo "--------------- xrayscript ------------------"
    printf "Version      : %b%s%b\n" "${GREEN}" "${version}" "${NC}"
    echo "Description  : ${description}"

    menu_title 'index.installation'
    menu_item 1 'index.option1'
    menu_item 2 'index.option2'
    menu_item 3 'index.option3'

    menu_title 'index.operation'
    menu_item 4 'index.option4'
    menu_item 5 'index.option5'
    menu_item 6 'index.option6'

    menu_title 'index.configuration'
    menu_item 7 'index.option7'
    menu_item 8 'index.option8'
    menu_item 9 'index.option9'

    menu_line
    menu_item 0 'index.option0' "${RED}"
}

# =============================================================================
# 函数名称: menu_full_installation
# 功能描述: 显示完整安装选项菜单。
# =============================================================================
function menu_full_installation() {
    local default_text=''
    i18n_fill default_text "${CUR_FILE}.status.default"

    menu_title 'full_installation.title'
    menu_item 1 'full_installation.option1' "${GREEN}" "(${default_text})"
    menu_item 2 'full_installation.option2'

    menu_line
    menu_info_block 'full_installation' 1 2
    menu_line
}

# =============================================================================
# 函数名称: menu_info_block
# 功能描述: 批量打印 "序号. 说明" 形式的说明文字。
#           子条目 (a_b 形式) 展示为 "a.b"，如 2_1 → 2.1，对用户友好。
# 参数:
#   $1: i18n 键名前缀
#   $@: (从 $2 开始) 说明项序号列表
# =============================================================================
function menu_info_block() {
    local prefix="$1"
    local index=''
    local text=''
    shift

    for index in "$@"; do
        local suffix=''
        local display="${index}"
        if [[ "${index}" == *_* ]]; then
            suffix="_${index#*_}"
            index="${index%%_*}"
            display="${index}.${suffix#_}"
        fi
        i18n_fill text "${CUR_FILE}.${prefix}.info${index}${suffix}"
        echo "${display}. ${text}"
    done
}

# =============================================================================
# 函数名称: menu_xray
# 功能描述: 显示 Xray 版本选择菜单。
# =============================================================================
function menu_xray() {
    local default_text=''
    i18n_fill default_text "${CUR_FILE}.status.default"

    menu_title 'xray_version.title'
    menu_item 1 'xray_version.option1'
    menu_item 2 'xray_version.option2' "${GREEN}" "(${default_text})"
    menu_item 3 'xray_version.option3'

    menu_line
    menu_info_block 'xray_version' 1 2 3
    menu_line
}

# =============================================================================
# 函数名称: menu_xray_config
# 功能描述: 显示协议配置菜单。
# =============================================================================
function menu_xray_config() {
    local default_text=''
    i18n_fill default_text "${CUR_FILE}.status.default"

    menu_title 'protocol_config.title'
    menu_item 1 'protocol_config.option1' "${GREEN}" "(${default_text})"
    menu_item 2 'protocol_config.option2'
    menu_item 3 'protocol_config.option3'
    menu_item 4 'protocol_config.option4'
    menu_item 5 'protocol_config.option5'

    menu_line
    menu_info_block 'protocol_config' 1 2_1 2_2 3 4 5
    menu_line
}

# =============================================================================
# 函数名称: menu_web_config
# 功能描述: 显示 Web 服务器配置菜单。
# =============================================================================
function menu_web_config() {
    local default_text=''
    i18n_fill default_text "${CUR_FILE}.status.default"

    menu_title 'web_config.title'
    menu_item 1 'web_config.option1' "${GREEN}" "(${default_text})"
    menu_item 2 'web_config.option2'
    menu_item 3 'web_config.option3'

    menu_line
    menu_info_block 'web_config' 2 3
    menu_line
}

# =============================================================================
# 函数名称: menu_ca_vendor
# 功能描述: 显示 CA 厂商选择菜单。
# =============================================================================
function menu_ca_vendor() {
    local default_text=''
    i18n_fill default_text "${CUR_FILE}.status.default"

    menu_title 'ca_vendor.title'
    menu_item 1 'ca_vendor.option1' "${GREEN}" "(${default_text})"
    menu_item 2 'ca_vendor.option2'
    menu_line
    menu_info_block 'ca_vendor' 1 2
    menu_line
}

# =============================================================================
# 函数名称: menu_config
# 功能描述: 显示配置管理菜单。
# =============================================================================
function menu_config() {
    menu_title 'config_management.title'
    menu_item 1 'config_management.option1'
    menu_item 2 'config_management.option2'
    menu_item 3 'config_management.option3'
    menu_item 4 'config_management.option4'
    menu_item 5 'config_management.option5'
    menu_item 6 'config_management.option6'
    menu_item 7 'config_management.option7'

    menu_line
    menu_info_block 'config_management' 1 2 3 4 5 6 7
    menu_line
    menu_item 0 'back' "${RED}"
}

# =============================================================================
# 函数名称: menu_route
# 功能描述: 显示路由规则管理菜单。
# =============================================================================
function menu_route() {
    menu_title 'route_management.title'
    menu_item 1 'route_management.option1'
    menu_item 2 'route_management.option2'
    menu_item 3 'route_management.option3'
    menu_item 4 'route_management.option4'
    menu_item 5 'route_management.option5'
    menu_item 6 'route_management.option6'

    menu_line
    menu_info_block 'route_management' 1 2 3 4 5 6 7 8
    menu_line
}

# =============================================================================
# 函数名称: menu_sni_config
# 功能描述: 显示 SNI 配置菜单。
# =============================================================================
function menu_sni_config() {
    local text=''

    menu_title 'sni_config.title'
    menu_item 1 'sni_config.option1'
    menu_item 2 'sni_config.option2'
    menu_item 3 'sni_config.option3'
    menu_item 4 'sni_config.option4'
    menu_item 5 'sni_config.option5'
    menu_item 6 'sni_config.option6'
    menu_item 7 'sni_config.option7'
    menu_item 8 'sni_config.option8'
    menu_item 9 'sni_config.option9'

    menu_line
    menu_info_block 'sni_config' 1 2
    i18n_fill text "${CUR_FILE}.sni_config.info3"
    echo "8. ${text}"
    i18n_fill text "${CUR_FILE}.sni_config.info4"
    echo "9. ${text}"
    menu_line
}

# =============================================================================
# 函数名称: menu_custom_sites
# 功能描述: 显示自定义站点管理菜单。
# =============================================================================
function menu_custom_sites() {
    menu_title 'custom_sites.title'
    menu_item 1 'custom_sites.option1'
    menu_item 2 'custom_sites.option2'
    menu_item 3 'custom_sites.option3'
    menu_item 4 'custom_sites.option4'

    menu_line
    menu_info_block 'custom_sites' 1 2 3 4
    menu_line
}

# =============================================================================
# 函数名称: menu_traffic
# 功能描述: 显示统计信息管理菜单，并标注当前开关状态。
# =============================================================================
function menu_traffic() {
    local xray_config='/usr/local/etc/xray/config.json'
    local status_text=''
    local status_key='traffic_management.status_off'

    if [[ -f "${xray_config}" ]] &&
        jq -e 'has("stats") and ((.api.services // []) | index("StatsService") != null)' \
            "${xray_config}" >/dev/null 2>&1; then
        status_key='traffic_management.status_on'
    fi

    menu_title 'traffic_management.title'
    menu_item 1 'traffic_management.option1'
    menu_item 2 'traffic_management.option2'
    menu_item 3 'traffic_management.option3'
    menu_item 4 'traffic_management.option4'

    menu_line
    menu_info_block 'traffic_management' 1 2 3 4
    i18n_fill status_text "${CUR_FILE}.${status_key}"
    printf "%b%s%b\n" "${YELLOW}" "${status_text}" "${NC}"
    menu_line
    menu_item 0 'back' "${RED}"
}


# =============================================================================
# 函数名称: get_choose
# 功能描述: 提示用户输入选择，并返回对应的数字。
#           返回值必须 <= 255，因此超大数字统一按 0 (退出) 处理。
# 参数:
#   $1: 菜单类型 (例如 '--language')
# =============================================================================
function get_choose() {
    local i18n="$1"
    local choose=''
    local prompt=''
    local tip=''

    if [[ "$i18n" == '--language' ]]; then
        printf "请选择你的语言(默认: 中文): " >&2
    else
        i18n_fill prompt "${CUR_FILE}.choose"
        i18n_fill tip 'title.tip'
        printf "%b[%s]%b %s: " "${YELLOW}" "${tip}" "${NC}" "${prompt}" >&2
    fi

    read -r choose || choose=''

    # 去前导零并校验范围 (函数返回值只能是 0-255)
    if [[ "${choose}" =~ ^[0-9]{1,3}$ ]]; then
        choose=$((10#${choose}))
        ((choose <= 255)) && return "${choose}"
    fi
    return 0
}

# =============================================================================
# 函数名称: main
# 功能描述: 脚本的主入口函数。
# =============================================================================
function main() {
    if [[ "$1" == "--language" ]]; then
        menu_language >&2
    else
        load_i18n
    fi

    case "$1" in
    --scan | --index | --banner | --status)
        # --scan 与 --index 等价；banner/status 已移除，保留参数以兼容旧调用
        menu_index >&2
        ;;
    --full) menu_full_installation >&2 ;;
    --xray) menu_xray >&2 ;;
    --config) menu_xray_config >&2 ;;
    --web) menu_web_config >&2 ;;
    --ca) menu_ca_vendor >&2 ;;
    --management) menu_config >&2 ;;
    --route) menu_route >&2 ;;
    --sni) menu_sni_config >&2 ;;
    --custom-sites) menu_custom_sites >&2 ;;
    --traffic) menu_traffic >&2 ;;
    esac

    get_choose "$1"
}

# --- 脚本执行入口 ---
main "$@"
