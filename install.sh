#!/usr/bin/env bash
# =============================================================================
# 脚本名称: install.sh
# 功能描述: xrayscript 项目的安装引导脚本。
#           负责检查/安装系统依赖、下载项目文件、解析命令行参数、
#           初始化配置、设置语言并启动主菜单。
# 依赖: bash, curl, wget, git, jq, sed, awk, grep
# Xray 官方链接:
#   - Xray-core: https://github.com/XTLS/Xray-core
#   - REALITY: https://github.com/XTLS/REALITY
#   - XHTTP: https://github.com/XTLS/Xray-core/discussions/4113
#
# =============================================================================

# --- 环境与常量设置 ---
PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}:${HOME}/bin:/snap/bin"
export PATH

# 颜色
readonly GREEN='\033[32m'
readonly YELLOW='\033[33m'
readonly RED='\033[31m'
readonly NC='\033[0m'

# 当前脚本路径
readonly CUR_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}")"

# 配置文件目录
readonly SCRIPT_CONFIG_DIR="${HOME}/.xrayscript"
readonly SCRIPT_CONFIG_PATH="${SCRIPT_CONFIG_DIR}/config.json"

# --- 全局变量声明 ---
declare -A I18N_DATA=(
    ['error']='错误'
    ['root']='请使用 root 权限运行该脚本'
    ['supported']='不支持当前系统，请切换到 Ubuntu 16+、Debian 9+、CentOS 7+'
    ['ubuntu']='不支持当前版本，请切换到 Ubuntu 16+ 重试'
    ['debian']='不支持当前版本，请切换到 Debian 9+ 重试'
    ['centos']='不支持当前版本，请切换到 CentOS 7+ 重试'
    ['tip']='更新提示'
    ['new']='发现有新脚本, 是否更新'
    ['now']='是否更新 [Y/n] '
    ['promptly']='请及时更新脚本'
    ['completed']='更新完成'
    ['download']='正在下载'
    ['failed']='下载失败'
    ['downloaded']='文件已下载到'
)
declare PROJECT_ROOT=''
declare QUICK_INSTALL=''
declare SCRIPT_CONFIG=''
declare LANG_PARAM=''
declare FORCE_CHECK_DEPS=0
declare -a ORIG_ARGS=("$@") # 更新后重启自身时保留原始参数 (如 --vision / --lang=zh)
readonly GITHUB_REPO='dakerclaw/xrayscript'
readonly GITHUB_BRANCH='main'

# =============================================================================
# 函数名称: _os
# =============================================================================
function _os() {
    local os=""
    if [[ -f "/etc/debian_version" ]]; then
        source /etc/os-release && os="${ID}"
        printf -- "%s" "${os}" && return
    fi
    if [[ -f "/etc/redhat-release" ]]; then
        printf -- "%s" "centos" && return
    fi
}

# =============================================================================
# 函数名称: _os_full
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
# =============================================================================
function _os_ver() {
    local main_ver
    main_ver="$(echo "$(_os_full)" | grep -oE "[0-9.]+" | head -1)"
    printf -- "%s" "${main_ver%%.*}"
}

# =============================================================================
# 函数名称: cmd_exists
# =============================================================================
function cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: parse_args
# =============================================================================
function parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --lang=*) LANG_PARAM="${1}" ;;
        --check-deps) FORCE_CHECK_DEPS=1 ;;
        esac
        shift
    done
}

# =============================================================================
# 函数名称: load_i18n
# =============================================================================
function load_i18n() {
    local lang="${LANG_PARAM#*=}"
    local key=''
    local value=''

    if [[ -z "${lang}" && -f "${SCRIPT_CONFIG_PATH}" ]]; then
        cmd_exists "jq" && lang="$(jq -r '.language // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
    fi

    if [[ "${lang}" == "auto" || -z "${lang}" ]]; then
        lang="${LANG%%_*}"
    fi

    if [[ "$lang" == "en" ]]; then
        I18N_DATA=(
            ['error']='Error'
            ['root']='This script must be run as root'
            ['supported']='Not supported OS'
            ['ubuntu']='Not supported OS, please change to Ubuntu 16+ and try again.'
            ['debian']='Not supported OS, please change to Debian 9+ and try again.'
            ['centos']='Not supported OS, please change to CentOS 7+ and try again.'
            ['tip']='Update Notice'
            ['new']='A new version of the script is available. Do you want to update?'
            ['now']='Update now? [Y/n]'
            ['promptly']='Please update the script promptly.'
            ['completed']='Update completed'
            ['download']='Downloading'
            ['failed']='Download failed'
            ['downloaded']='The file has been downloaded to'
        )
    fi

    # 预热 i18n 键，避免重复展开
    for key in "${!I18N_DATA[@]}"; do value="${I18N_DATA[$key]}"; done
}

# =============================================================================
# 函数名称: _error
# =============================================================================
function _error() {
    printf "${RED}[${I18N_DATA['error']}] ${NC}" >&2
    printf "%s\n" "$*" >&2
    exit 1
}

# =============================================================================
# 函数名称: check_os
# =============================================================================
function check_os() {
    case "$(_os)" in
    centos)
        [[ "$(_os_ver)" -lt 7 ]] && _error "${I18N_DATA['centos']}"
        ;;
    ubuntu)
        [[ "$(_os_ver)" -lt 16 ]] && _error "${I18N_DATA['ubuntu']}"
        ;;
    debian)
        [[ "$(_os_ver)" -lt 9 ]] && _error "${I18N_DATA['debian']}"
        ;;
    *)
        _error "${I18N_DATA['supported']}"
        ;;
    esac
}

# =============================================================================
# 函数名称: missing_packages
# 功能描述: 输出缺失的软件包列表 (空格分隔)，不修改任何东西。
# =============================================================================
function missing_packages() {
    local -a packages=("ca-certificates" "openssl" "curl" "wget" "git" "jq" "tzdata" "qrencode" "socat")
    local -a missing=()
    local installed=''
    local pkg=''

    case "$(_os)" in
    centos)
        packages+=("crontabs" "util-linux" "iproute" "procps-ng" "bind-utils")
        installed="$(rpm -qa 2>/dev/null)"
        ;;
    debian | ubuntu)
        packages+=("cron" "bsdmainutils" "iproute2" "procps" "dnsutils")
        installed="$(dpkg-query -W -f='${Package}\n' 2>/dev/null)"
        ;;
    esac

    for pkg in "${packages[@]}"; do
        echo "${installed}" | grep -qx "${pkg}" || missing+=("${pkg}")
    done

    printf '%s\n' "${missing[*]}"
}

# =============================================================================
# 函数名称: install_dependencies
# 功能描述: 一次性安装缺失的依赖 (原实现会对每个包单独调用包管理器)。
# =============================================================================
function install_dependencies() {
    local missing=''
    local pkg=''
    local installed=''

    missing="$(missing_packages)"
    [[ -z "${missing}" ]] && return 0

    case "$(_os)" in
    centos)
        if cmd_exists "dnf"; then
            dnf install -y dnf-plugins-core epel-release >/dev/null 2>&1 || true
            dnf install -y ${missing} && return 0
        fi
        yum install -y epel-release yum-utils >/dev/null 2>&1 || true
        yum install -y ${missing}
        ;;
    ubuntu | debian)
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y ${missing} && return 0
        # 个别发行版没有 qrencode 包，允许失败后重试其余依赖
        for pkg in ${missing}; do
            [[ "${pkg}" == "qrencode" ]] && continue
            installed="$(dpkg-query -W -f='${Package}\n' 2>/dev/null)"
            echo "${installed}" | grep -qx "${pkg}" || apt-get install -y "${pkg}" || _warn "failed to install ${pkg}"
        done
        ;;
    esac
}

function _warn() {
    printf "${YELLOW}[%s] ${NC}%s\n" "${I18N_DATA['tip']}" "$*" >&2
}

# =============================================================================
# 函数名称: download_files
# 功能描述: 下载项目文件 (tarball 解压)。
# =============================================================================
function download_files() {
    local target_dir="$1"
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/tarball/${GITHUB_BRANCH}"
    local tmp_tar=''
    local final_url=''
    local revision=''

    mkdir -p "${target_dir}"
    echo -e "${GREEN}[${I18N_DATA['download']}]${NC} ${api_url}"

    tmp_tar="$(mktemp "${TMPDIR:-/tmp}/xrayscript-tarball.XXXXXX")" || _error "failed to create temp file"
    if ! final_url="$(curl -fsSL --retry 3 -o "${tmp_tar}" -w '%{url_effective}' "${api_url}")"; then
        rm -f "${tmp_tar}"
        _error "${I18N_DATA['failed']}: ${api_url}"
    fi
    if ! tar xz --strip-components=1 -C "${target_dir}" <"${tmp_tar}"; then
        rm -f "${tmp_tar}"
        _error "${I18N_DATA['failed']}: ${api_url}"
    fi

    # 记录这次下载的 commit SHA，供 check_version 判断已装代码是否过期。
    # 优先从 codeload 最终 URL (.../legacy.tar.gz/<sha>) 提取，不受 API 限流影响
    revision="$(printf '%s' "${final_url}" | grep -Eo '[0-9a-f]{40}' | tail -1)"
    [[ -n "${revision}" ]] || revision="$(fetch_remote_revision)"
    if [[ -n "${revision}" ]]; then
        printf '%s\n' "${revision}" >"${target_dir}/.revision"
    fi
    rm -f "${tmp_tar}"
}

# =============================================================================
# 函数名称: fetch_remote_revision
# 功能描述: 取远端分支最新 commit SHA。
#           只比较 config.json 的 version 会漏掉代码更新 (版本号忘记提升时)，
#           导致用户重跑安装脚本后仍在用旧代码。
# 返回值: commit SHA；取不到时输出空 (调用方需容忍)
# =============================================================================
function fetch_remote_revision() {
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/commits/${GITHUB_BRANCH}"

    curl -fsSL --max-time 15 "${api_url}" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null
}

# =============================================================================
# 函数名称: check_version
# 功能描述: 判断已安装代码是否需要更新。
#           判定依据: 已安装代码记录的 commit SHA 与远端不一致
#           (只比 config.json 的 version 会漏更新: 版本号忘记提升、raw 有 CDN
#           缓存时都会让用户重跑安装脚本后仍在用旧代码)。
# =============================================================================
function check_version() {
    local config_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/config.json"
    local local_version=''
    local remote_version=''
    local local_revision=''
    local remote_revision=''
    local need_update='n'
    local is_update='n'
    local temp_dir=''

    local_version="$(jq -r '.version // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
    remote_version="$(curl -fsSL --max-time 15 "${config_url}" 2>/dev/null | jq -r '.version // empty')"
    local_revision="$(tr -d '[:space:]' <"${PROJECT_ROOT}/.revision" 2>/dev/null)"
    remote_revision="$(fetch_remote_revision)"

    # 以 commit SHA 为准 (raw.githubusercontent 有 CDN 缓存，version 会短暂读到旧值，
    # 拿它反复比对会在一次运行里连续触发多次更新)。
    # SHA 取不到 (API 限流/网络) 时，退回 version 比较，且只用于没有 .revision 的旧安装。
    if [[ -n "${remote_revision}" ]]; then
        [[ "${local_revision}" == "${remote_revision}" ]] || need_update='y'
    elif [[ -n "${remote_version}" && -z "${local_revision}" && "${local_version}" != "${remote_version}" ]]; then
        need_update='y'
    fi

    [[ "${need_update}" == 'y' ]] || return 0

    # 开发用的 git 工作副本不覆盖 (会连同 .git 与本地改动一起删掉)
    if [[ -d "${PROJECT_ROOT}/.git" ]]; then
        _warn "${PROJECT_ROOT} is a git working copy, skip auto update (run git pull manually)"
        return 0
    fi

    echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['new']}"
    if [[ -t 0 ]]; then
        read -rp "${I18N_DATA['now']}" -e -i "Y" is_update || is_update='n'
    else
        # 非交互 (快速安装/自动化) 默认更新，避免继续使用过期代码
        is_update='y'
    fi

    case "${is_update,,}" in
    y | yes)
        cd "${HOME}" || true
        temp_dir="${SCRIPT_CONFIG_DIR}/xrayscript-temp"
        rm -rf "${temp_dir}"
        mkdir -vp "${temp_dir}"
        download_files "${temp_dir}"
        [[ -n "${PROJECT_ROOT}" && "${PROJECT_ROOT}" != '/' ]] ||
            _error "invalid install dir: '${PROJECT_ROOT}'"
        rm -rf "${PROJECT_ROOT}"
        mv -f "${temp_dir}" "${PROJECT_ROOT}"
        rm -f "${CUR_DIR}/${CUR_FILE}"
        cp -f "${PROJECT_ROOT}/install.sh" "${CUR_DIR}/${CUR_FILE}"
        if [[ -n "${remote_version}" && -n "${remote_revision}" ]]; then
            jq --arg v "${remote_version}" '.version = $v' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
                mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"
        fi
        echo -e "${GREEN}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['completed']}"
        # 保留原始参数重跑，否则快速安装 (--vision 等) 会退化成交互菜单
        bash "${CUR_DIR}/${CUR_FILE}" "${ORIG_ARGS[@]}"
        exit 0
        ;;
    *)
        echo -e "${YELLOW}[${I18N_DATA['tip']}]${NC} ${I18N_DATA['promptly']}"
        ;;
    esac
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    parse_args "$@"
    load_i18n

    [[ ${EUID} -ne 0 ]] && _error "${I18N_DATA['root']}"

    check_os

    local is_first_run=0
    [[ -f "${SCRIPT_CONFIG_PATH}" ]] || is_first_run=1

    if [[ "${is_first_run}" -eq 1 || "${FORCE_CHECK_DEPS}" -eq 1 ]]; then
        if [[ -n "$(missing_packages)" ]]; then
            install_dependencies
        fi
    fi

    mkdir -p "${SCRIPT_CONFIG_DIR}"
    if [[ ! -f "${SCRIPT_CONFIG_PATH}" ]]; then
        wget -q -O "${SCRIPT_CONFIG_PATH}" "https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_BRANCH}/config.json" ||
            _error "${I18N_DATA['failed']}: config.json"
    fi

    # 快速安装与自定义目录
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --vision | --xhttp | --fallback | --trojan) QUICK_INSTALL="${1}" ;;
        -d)
            shift
            PROJECT_ROOT="${1:-}"
            ;;
        esac
        shift
    done

    local script_path=''
    script_path="$(jq -r '.path // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"

    if [[ -n "${PROJECT_ROOT}" ]]; then
        jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
            mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"
    elif [[ -n "${script_path}" ]]; then
        PROJECT_ROOT="${script_path}"
    else
        PROJECT_ROOT='/usr/local/xrayscript'
        jq --arg path "${PROJECT_ROOT}" '.path = $path' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
            mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"
    fi

    # 修正: 以核心脚本是否存在为判断依据，而不是目录是否存在，
    #       避免用户手工创建目录后直接调用一个不存在的 main.sh。
    if [[ -f "${PROJECT_ROOT}/core/main.sh" ]]; then
        check_version
    else
        download_files "${PROJECT_ROOT}"
    fi

    local lang=''
    lang="$(jq -r '.language // empty' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"

    if [[ -z "${lang}" && -z "${LANG_PARAM}" ]]; then
        bash "${PROJECT_ROOT}/core/menu.sh" '--language'
        case $? in
        2) LANG_PARAM="en" ;;
        *) LANG_PARAM="zh" ;;
        esac
        jq --arg language "${LANG_PARAM}" '.language = $language' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
            mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"
    elif [[ "${LANG_PARAM}" =~ ^--lang= ]]; then
        jq --arg language "${LANG_PARAM#*=}" '.language = $language' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
            mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"
    fi

    bash "${PROJECT_ROOT}/core/main.sh" "${QUICK_INSTALL}"
}

# --- 脚本执行入口 ---
main "$@"
