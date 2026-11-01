#!/usr/bin/env bash
# =============================================================================
# 脚本名称: common.sh
# 功能描述: 各脚本共享的公共函数库，通过 `source` 引入，避免同一份代码在
#           10 个脚本中重复复制。本文件不单独执行，也不应在末尾调用 main。
#
# 使用方式:
#   readonly PROJECT_ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
#   # shellcheck source=core/common.sh
#   source "${PROJECT_ROOT}/core/common.sh"
#
# 包含:
#   - 公共路径与常量 (SCRIPT_CONFIG_DIR / I18N_DIR / SCRIPT_CONFIG_PATH 等)
#   - 操作系统检测 (_os / _os_full / _os_ver / check_os)
#   - 国际化加载 (load_i18n) 与缓存 (i18n / i18n_get)
#   - 日志输出 (_error / _info / _warn / _pass / _fail / _test / print_info ...)
#   - 命令检测 (cmd_exists)
#   - 脚本配置读写 (json_get / json_get_array / persist_script_config)
#   - 通用编码 (urlencode)
#
# =============================================================================

# --- 环境与常量设置 ---
# 幂等保护: 重复 source 时直接返回，避免 readonly 变量重复赋值报错
if [[ -n "${COMMON_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
readonly COMMON_SH_SOURCED=1

# 将常用系统路径补充到 PATH 末尾 (保留调用方已有路径，避免覆盖用户自定义的工具路径)
PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}:${HOME}/bin:/snap/bin"
export PATH

# 定义颜色代码 (已存在时不再重复声明)
[[ -n "${GREEN:-}" ]] || GREEN='\033[32m'   # 绿色
[[ -n "${YELLOW:-}" ]] || YELLOW='\033[33m' # 黄色
[[ -n "${RED:-}" ]] || RED='\033[31m'       # 红色
[[ -n "${NC:-}" ]] || NC='\033[0m'          # 无颜色（重置）
readonly GREEN YELLOW RED NC

# 公共目录路径 (调用方需先定义 PROJECT_ROOT；此处不再用 readonly，避免重复 source 冲突)
PROJECT_ROOT="${PROJECT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"

# HOME 未设置 (sudo su / env -i 等场景) 时回退到 /root，避免路径解析成 "/.xrayscript"
if [[ -z "${HOME:-}" ]]; then
    if [[ "$(id -u 2>/dev/null)" == "0" ]]; then
        export HOME='/root'
    else
        export HOME="$(cd -P -- ~ 2>/dev/null && pwd -P || pwd -P)"
    fi
fi

SCRIPT_CONFIG_DIR="${SCRIPT_CONFIG_DIR:-${HOME}/.xrayscript}"                                              # 主配置文件目录
I18N_DIR="${I18N_DIR:-${PROJECT_ROOT}/i18n}"                                                                # 国际化文件目录
CONFIG_DIR="${CONFIG_DIR:-${PROJECT_ROOT}/config}"                                                          # 配置文件目录
SERVICE_DIR="${SERVICE_DIR:-${PROJECT_ROOT}/service}"                                                       # 服务管理脚本目录
TOOL_DIR="${TOOL_DIR:-${PROJECT_ROOT}/tool}"                                                                # 工具脚本目录
SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_PATH:-${SCRIPT_CONFIG_DIR}/config.json}"                                 # 脚本主配置文件路径

# 全局变量声明 (declare 可重复执行，不会报错)
declare I18N_DATA=''      # i18n 数据对象 (jq 不可用时回退使用)
declare -A I18N_CACHE     # i18n 扁平化缓存: 键 "a.b.c"，值文本
declare -A I18N_TITLES    # i18n 标题缓存: error/info/warn -> 文本
declare I18N_LANG=''      # 当前已加载的语言代码

# =============================================================================
# 函数名称: _os
# 功能描述: 检测当前操作系统的发行版名称。
# 返回值: 操作系统名称 (debian/ubuntu/centos/...)
# =============================================================================
function _os() {
    local os=""

    if [[ -f "/etc/debian_version" ]]; then
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi

    if [[ -f "/etc/redhat-release" ]]; then
        os="centos"
        printf -- "%s" "${os}" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
# 功能描述: 获取当前操作系统的完整发行版信息。
# =============================================================================
function _os_full() {
    if [[ -f /etc/redhat-release ]]; then
        awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    fi

    if [[ -f /etc/os-release ]]; then
        awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    fi

    if [[ -f /etc/lsb-release ]]; then
        awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
    fi
}

# =============================================================================
# 函数名称: _os_ver
# 功能描述: 获取当前操作系统的主版本号。
# =============================================================================
function _os_ver() {
    local main_ver
    main_ver="$(echo "$(_os_full)" | grep -oE "[0-9.]+" | head -1)"
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: check_os
# 功能描述: 检查操作系统是否受支持（各脚本按需覆盖 MIN_UBUNTU 等变量）。
# 可选变量:
#   MIN_UBUNTU (默认 16) / MIN_DEBIAN (默认 9) / MIN_CENTOS (默认 7)
#   OS_MSG_UNSUPPORTED / OS_MSG_UBUNTU / OS_MSG_DEBIAN / OS_MSG_CENTOS
# =============================================================================
function check_os() {
    local min_ubuntu="${MIN_UBUNTU:-16}"
    local min_debian="${MIN_DEBIAN:-9}"
    local min_centos="${MIN_CENTOS:-7}"
    local msg_unsupported="${OS_MSG_UNSUPPORTED:-Unsupported operating system}"
    local msg_ubuntu="${OS_MSG_UBUNTU:-Unsupported operating system, please change to Ubuntu ${min_ubuntu}+ and try again.}"
    local msg_debian="${OS_MSG_DEBIAN:-Unsupported operating system, please change to Debian ${min_debian}+ and try again.}"
    local msg_centos="${OS_MSG_CENTOS:-Unsupported operating system, please change to CentOS ${min_centos}+ and try again.}"
    local ver
    ver="$(_os_ver)"

    case "$(_os)" in
    ubuntu)
        [[ -n "${ver}" && "${ver}" -lt "${min_ubuntu}" ]] && _error "${msg_ubuntu}"
        ;;
    debian)
        [[ -n "${ver}" && "${ver}" -lt "${min_debian}" ]] && _error "${msg_debian}"
        ;;
    centos)
        [[ -n "${ver}" && "${ver}" -lt "${min_centos}" ]] && _error "${msg_centos}"
        ;;
    *)
        _error "${msg_unsupported}"
        ;;
    esac
}

# =============================================================================
# 函数名称: cmd_exists
# 功能描述: 检查指定的命令是否存在于系统中。
# 参数:
#   $1: 要检查的命令名称
# 返回值: 0-命令存在 非0-命令不存在
# =============================================================================
function cmd_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: load_i18n
# 功能描述: 加载国际化数据。
#           1. 从 config.json 读取 language；"auto" 时按 $LANG 推断。
#           2. 用一次 jq 调用把 i18n 扁平化为关联数组 I18N_CACHE，
#              后续 i18n_get 不再启动子进程。
#           3. jq 不可用时回退为把整个 JSON 存入 I18N_DATA。
# 参数:
#   $1 (可选): 显式语言代码，优先级最高
# =============================================================================
function load_i18n() {
    local lang="${1:-}"
    local i18n_file=''
    local line=''
    local key=''
    local value=''

    if [[ -z "${lang}" ]]; then
        if [[ -f "${SCRIPT_CONFIG_PATH}" ]] && cmd_exists 'jq'; then
            lang="$(jq -r '.language // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
        fi
    fi

    if [[ "${lang}" == "auto" || -z "${lang}" ]]; then
        lang="${LANG%%_*}"
    fi
    [[ -n "${lang}" ]] || lang='zh'

    # 已经是当前语言且缓存完整，直接返回
    if [[ "${lang}" == "${I18N_LANG}" && ${#I18N_CACHE[@]} -gt 0 ]]; then
        return 0
    fi

    i18n_file="${I18N_DIR}/${lang}.json"
    if [[ ! -f "${i18n_file}" ]]; then
        if [[ "$lang" == "zh" ]]; then
            echo -e "${RED}[错误]${NC} 文件不存在: ${i18n_file}" >&2
        else
            echo -e "${RED}[Error]${NC} File Not Found: ${i18n_file}" >&2
        fi
        exit 1
    fi

    I18N_CACHE=()
    I18N_TITLES=()
    if cmd_exists 'jq'; then
        # 单次 jq 调用完成扁平化，输出 "key<TAB>value"
        while IFS=$'\t' read -r key value; do
            [[ -n "${key}" ]] || continue
            # 兼容 Windows 版 jq 输出的 CRLF
            key="${key%$'\r'}"
            value="${value%$'\r'}"
            I18N_CACHE["${key}"]="${value}"
            # 同时缓存 一级.二级 与 二级 形式的标题，便于快速取用
            case "${key}" in
            *.title.*)
                I18N_TITLES["${key#*.title.}"]="${value}"
                ;;
            esac
        done < <(jq -r 'paths(scalars) as $p | "\($p | join("."))\t\(getpath($p) | tostring)"' "${i18n_file}" 2>/dev/null)
        I18N_LANG="${lang}"
    else
        I18N_DATA="$(cat "${i18n_file}")"
        I18N_LANG="${lang}"
    fi
}

# =============================================================================
# 函数名称: i18n_fill
# 功能描述: 按 "a.b.c" 填充一个调用方传入的变量名 (不启动子进程)。
#           缓存命中时直接赋值，因此热路径上几乎零开销。
# 参数:
#   $1: 目标变量名 (例如 msg)
#   $2: 键名 (例如 handler.custom_sites.added)
#   $3 (可选): 缺省值
# 返回值: 0
# =============================================================================
function i18n_fill() {
    local __target="$1"
    local __key="$2"
    local __default="${3:-}"

    if [[ -n "${I18N_CACHE[${__key}]+x}" ]]; then
        printf -v "${__target}" '%s' "${I18N_CACHE[${__key}]}"
        return 0
    fi

    local __value=''
    if [[ -n "${I18N_LANG}" ]]; then
        __value="$(i18n_get "${__key}" "${__default}")"
    else
        __value="${__default}"
    fi
    printf -v "${__target}" '%s' "${__value}"
}

# =============================================================================
# 函数名称: i18n_get
# 功能描述: 按 "a.b.c" 取值，优先走内存缓存，缺失时回退 jq。
#           注意: 会启动子进程，循环/高频场景请改用 i18n_fill。
# 参数:
#   $1: 键名 (例如 handler.custom_sites.added)
#   $2 (可选): 缺省值
# 返回值: 翻译文本 (echo 输出)
# =============================================================================
function i18n_get() {
    local key="$1"
    local default="${2:-}"
    local value=''

    if [[ -n "${I18N_CACHE[${key}]+x}" ]]; then
        printf -- "%s" "${I18N_CACHE[${key}]}"
        return 0
    fi

    if [[ -f "${I18N_DIR}/${I18N_LANG:-zh}.json" ]] && cmd_exists 'jq'; then
        value="$(jq -r --arg k "$key" 'getpath($k | split(".")) // empty' "${I18N_DIR}/${I18N_LANG:-zh}.json" 2>/dev/null)"
        if [[ -n "${value}" ]]; then
            I18N_CACHE["${key}"]="${value}"
            printf -- "%s" "${value}"
            return 0
        fi
    fi

    # 最后回退到原始 JSON（jq 不可用场景）
    if [[ -n "${I18N_DATA}" ]] && cmd_exists 'jq'; then
        value="$(echo "$I18N_DATA" | jq -r --arg k "$key" 'getpath($k | split(".")) // empty' 2>/dev/null)"
        [[ -n "${value}" ]] && printf -- "%s" "${value}" && return 0
    fi

    printf -- "%s" "${default}"
}

# =============================================================================
# 函数名称: i18n_title
# 功能描述: 取标题文本 (tip/info/warn/error/...)，返回值带颜色前缀。
# 参数:
#   $1: 标题名 (error/info/warn/tip/pass/fail/test)
# 返回值: 形如 "[错误]" 的彩色文本
# =============================================================================
function i18n_title() {
    local name="$1"
    local color="${GREEN}"
    local text=''

    case "${name}" in
    error) color="${RED}" ;;
    warn | tip | test) color="${YELLOW}" ;;
    info | pass | config | route) color="${GREEN}" ;;
    fail) color="${RED}" ;;
    esac

    if [[ -n "${I18N_TITLES[${name}]+x}" ]]; then
        text="${I18N_TITLES[${name}]}"
    else
        text="$(i18n_get "${I18N_TITLE_PREFIX:-title}.${name}" "${name}")"
    fi
    printf -- "${color}[%s]${NC}" "${text}"
}

# =============================================================================
# 函数名称: _error
# 功能描述: 打印错误并退出脚本。
# =============================================================================
function _error() {
    printf "%b" "$(i18n_title error)" >&2
    printf " %s\n" "$*" >&2
    exit 1
}

# =============================================================================
# 函数名称: _info / _warn / _pass / _fail / _test
# 功能描述: 打印带标题的日志到标准错误，不污染标准输出。
# =============================================================================
function _info() { printf "%b %s\n" "$(i18n_title info)" "$*" >&2; }
function _warn() { printf "%b %s\n" "$(i18n_title warn)" "$*" >&2; }
function _tip() { printf "%b %s\n" "$(i18n_title tip)" "$*" >&2; }
function _pass() { printf "%b %s\n" "$(i18n_title pass)" "$*" >&2; }
function _fail() { printf "%b %s\n" "$(i18n_title fail)" "$*" >&2; }
function _test() { printf "%b %s\n" "$(i18n_title test)" "$*" >&2; }

# 兼容旧命名
function print_info() { _info "$*"; }
function print_warn() { _warn "$*"; }
function print_error() { _error "$*"; }

# =============================================================================
# 函数名称: json_get
# 功能描述: 用 object-path 语法 (a.b.c) 从 JSON 文件或字符串中取值。
#           优先使用调用方已加载的 SCRIPT_CONFIG 字符串，避免重复读盘。
# 参数:
#   $1: JSON 文件路径，或 "-" 表示使用调用方变量 SCRIPT_CONFIG / XRAY_CONFIG
#   $2: 路径 (例如 nginx.ca_server)
#   $3 (可选): JSON 来源变量名，默认 SCRIPT_CONFIG
# 返回值: 取值 (echo 输出)，null 会被转换为空字符串
# =============================================================================
function json_get() {
    local source="$1"
    local path="$2"
    local var_name="${3:-SCRIPT_CONFIG}"
    local json=""

    if ! cmd_exists 'jq'; then
        printf ''
        return 0
    fi

    if [[ -n "${var_name}" ]]; then
        json="${!var_name}"
    fi

    if [[ -n "${json}" && "${json}" != "null" ]]; then
        printf '%s' "${json}" | jq -r --arg p "$path" '(try getpath($p | split(".")) catch null) | if . == null then "" else (if type == "string" then . else tojson end) end' | tr -d '\r'
    elif [[ "${source}" != "-" && -f "${source}" ]]; then
        jq -r --arg p "$path" '(try getpath($p | split(".")) catch null) | if . == null then "" else (if type == "string" then . else tojson end) end' "${source}" | tr -d '\r'
    else
        printf ''
    fi
}

# =============================================================================
# 函数名称: json_get_array
# 功能描述: 取 JSON 数组并展开为多行输出。
# =============================================================================
function json_get_array() {
    local source="$1"
    local path="$2"
    local var_name="${3:-SCRIPT_CONFIG}"
    local json=""

    [[ -n "${var_name}" ]] && json="${!var_name}"

    if [[ -n "${json}" && "${json}" != "null" ]]; then
        printf '%s' "${json}" | jq -r --arg p "$path" '(try getpath($p | split(".")) catch null) // [] | .[]'
    elif [[ "${source}" != "-" && -f "${source}" ]]; then
        jq -r --arg p "$path" '(try getpath($p | split(".")) catch null) // [] | .[]' "${source}"
    fi
}

# =============================================================================
# 函数名称: init_script_config
# 功能描述: 确保配置目录与配置文件存在。
#           HOME 未设置 (如某些 sudo 场景) 时回退到 /root，
#           避免把配置写到 /.xrayscript 这类错误路径。
#           配置文件缺失时从项目模板 (config.json) 初始化。
# 返回值: 0-就绪 1-失败
# =============================================================================
function init_script_config() {
    # HOME 为空时回退到 /root (仅 root 场景有意义)
    if [[ -z "${HOME:-}" ]]; then
        if [[ "$(id -u 2>/dev/null)" == "0" ]]; then
            HOME='/root'
        else
            return 1
        fi
        export HOME
    fi

    if ! mkdir -p "${SCRIPT_CONFIG_DIR}" 2>/dev/null; then
        return 1
    fi

    # 配置文件不存在时，用项目自带模板初始化 (config.json 与本文件同位于 PROJECT_ROOT)
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        local template="${PROJECT_ROOT}/config.json"
        if [[ -f "${template}" ]]; then
            cp -f "${template}" "${SCRIPT_CONFIG_PATH}" 2>/dev/null || return 1
        else
            # 无模板可用时写一份最小骨架，保证后续流程能继续
            printf '{\n  "version": "",\n  "language": "",\n  "xray": {},\n  "nginx": {}\n}\n' \
                >"${SCRIPT_CONFIG_PATH}" 2>/dev/null || return 1
        fi
    fi
    return 0
}

# =============================================================================
# 函数名称: persist_script_config
# 功能描述: 原子写入脚本配置 (写临时文件后 mv)，不再依赖 sleep 等待。
#           HOME 异常时先调用 init_script_config 自救。
# 参数:
#   $1 (可选): 要写入的 JSON 内容，默认使用全局变量 SCRIPT_CONFIG
# 返回值: 0-成功 1-失败
# =============================================================================
function persist_script_config() {
    local content="${1:-${SCRIPT_CONFIG}}"
    local tmp_file=''

    if [[ -z "${content}" ]] || [[ "${content}" == "null" ]]; then
        return 1
    fi

    # 目录或配置文件未就绪时尝试初始化 (首次运行 / HOME 被重置等场景)
    if [[ ! -d "${SCRIPT_CONFIG_DIR}" || ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        init_script_config || return 1
    fi

    # 临时文件放在配置同目录，保证 mv 是同文件系统原子操作；
    # mktemp 失败时退回 $$ 后缀 (并发概率极低)
    tmp_file="$(mktemp "${SCRIPT_CONFIG_PATH}.XXXXXX" 2>/dev/null)" ||
        tmp_file="${SCRIPT_CONFIG_PATH}.tmp.$$"

    if printf '%s\n' "${content}" >"${tmp_file}" && mv -f "${tmp_file}" "${SCRIPT_CONFIG_PATH}"; then
        return 0
    fi
    rm -f "${tmp_file}"
    return 1
}

# =============================================================================
# 函数名称: urlencode
# 功能描述: 对输入字符串进行 URL 编码 (RFC 3986 unreserved 字符保持不变)。
#           超出 ASCII 范围的 UTF-8 字节逐个编码，避免被截断。
# 参数:
#   $1 (可选): 待编码字符串；不传则从标准输入读取
# =============================================================================
function urlencode() {
    local input=''
    local encoded=''
    local i c hex

    if [[ $# -eq 0 ]]; then
        input="$(cat)"
    else
        input="$1"
    fi

    for ((i = 0; i < ${#input}; i++)); do
        c="${input:$i:1}"
        case "$c" in
        [a-zA-Z0-9.~_-])
            encoded+="$c"
            ;;
        *)
            # 逐字节编码，兼容多字节 UTF-8
            while IFS= read -r -n1 -d '' byte; do
                printf -v hex '%02X' "'$byte"
                encoded+="%$hex"
            done < <(printf '%s' "$c")
            ;;
        esac
    done

    printf '%s\n' "$encoded"
}

# =============================================================================
# 函数名称: cpu_count
# 功能描述: 获取 CPU 核心数 (兼容没有 nproc 的系统)。
# =============================================================================
function cpu_count() {
    if cmd_exists 'nproc'; then
        nproc
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1
    fi
}

# HOME 异常时先做一次自救 (只补目录/文件，不改动已有内容)。
# 必须放在所有函数定义之后执行，保证 init_script_config 已可用。
[[ -d "${SCRIPT_CONFIG_DIR}" && -f "${SCRIPT_CONFIG_PATH}" ]] || init_script_config 2>/dev/null || true
