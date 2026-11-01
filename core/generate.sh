#!/usr/bin/env bash
# =============================================================================
# 脚本名称: generate.sh
# 功能描述: 生成各种随机或唯一标识符，如端口、UUID、密码、路径等，用于项目配置。
# 依赖: bash, od, jq, xray (可选), openssl
# 配置: 需要 ${SCRIPT_CONFIG_DIR}/config.json 支持 generate_target 与 generate_server_names
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

# =============================================================================
# 函数名称: generate_random
# 功能描述: 生成随机数。无参数时输出 32 位无符号随机整数；
#           提供合法 min/max 时输出该闭区间内的随机整数。
# 参数:
#   $1 (可选): 最小值
#   $2 (可选): 最大值
# =============================================================================
function generate_random() {
    local custom_min="${1:-}"
    local custom_max="${2:-}"
    local random=''

    random="$(od -An -N4 -tu4 </dev/urandom | tr -d ' ')"
    random="${random:-0}"

    if [[ ${custom_min} =~ ^[0-9]+$ && ${custom_max} =~ ^[0-9]+$ ]] && ((custom_min < custom_max)); then
        local range=$((custom_max - custom_min + 1))
        echo $((random % range + custom_min))
    else
        echo "${random}"
    fi
}

# =============================================================================
# 函数名称: generate_port
# 功能描述: 生成 1025-65535 之间的随机端口。
# =============================================================================
function generate_port() {
    generate_random 1025 65535
}

# =============================================================================
# 函数名称: generate_uuid
# 功能描述: 生成 UUID。安装了 xray 时优先用 xray 生成 (支持字符串映射)。
# 参数:
#   $1 (可选): 输入字符串，用于生成基于该输入的 UUID
# =============================================================================
function generate_uuid() {
    local input="${1:-}"

    if cmd_exists 'xray'; then
        if [[ -z "${input}" ]]; then
            xray uuid
        elif [[ "${input}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            echo "${input}"
        else
            xray uuid -i "${input}"
        fi
        return 0
    fi

    # xray 未安装时回退：优先 /proc，其次 openssl，最后用 urandom 手工拼装，
    # 兼容容器 / 精简系统（原实现只认 /proc，缺失时报错中断整个流程）
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi

    if cmd_exists 'openssl'; then
        openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
        return 0
    fi

    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' |
        sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

# =============================================================================
# 函数名称: generate_password
# 功能描述: 生成 16-64 位随机密码 (数字、大小写字母及 !@$%*)。
# =============================================================================
function generate_password() {
    local length=''
    length="$(generate_random 16 64)"
    tr -dc '0-9a-zA-Z!@$%*' </dev/urandom 2>/dev/null | head -c "${length}"
    echo
}

# =============================================================================
# 函数名称: generate_target
# 功能描述: 从配置文件的 .target 键中随机选择一个键名。
#           修正: .target 为空时不再触发 jq 错误。
# =============================================================================
function generate_target() {
    local random=''
    local target=''

    random="$(generate_random)"
    target="$(jq -r --argjson random "${random}" '.target // {} | keys | if length == 0 then "" else .[$random % length] end' "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"

    if [[ -z "${target}" ]]; then
        # 配置缺失时回退到内置的默认目标，保证流程不中断
        target='www.fandom.com'
    fi
    echo "${target}"
}

# =============================================================================
# 函数名称: generate_server_names
# 功能描述: 获取 target 对应的 serverNames；不存在则写入配置后返回。
# 参数:
#   $1: 目标名称 (target)
# =============================================================================
function generate_server_names() {
    local target="${1:-}"

    [[ -n "${target}" ]] || return 0

    jq --arg key "${target}" '
        .target = (.target // {}) |
        if .target | has($key) then . else .target += { ($key): [$key] } end
    ' "${SCRIPT_CONFIG_PATH}" >"${SCRIPT_CONFIG_PATH}.tmp" &&
        mv -f "${SCRIPT_CONFIG_PATH}.tmp" "${SCRIPT_CONFIG_PATH}"

    jq --arg key "${target}" '.target[$key] // [$key]' "${SCRIPT_CONFIG_PATH}"
}

# =============================================================================
# 函数名称: generate_x25519
# 功能描述: 生成 X25519 密钥对，输出 "私钥,公钥,Hash32"。
# =============================================================================
function generate_x25519() {
    local X25519_KEY=''
    local PRIVATE_KEY=''
    local PUBLIC_KEY=''
    local HASH32=''

    X25519_KEY="$(xray x25519)"
    PRIVATE_KEY="$(echo "${X25519_KEY}" | sed -ne '1s/.*:\s*//p')"
    PUBLIC_KEY="$(echo "${X25519_KEY}" | sed -ne '2s/.*:\s*//p')"
    HASH32="$(echo "${X25519_KEY}" | sed -ne '3s/.*:\s*//p')"

    echo "${PRIVATE_KEY},${PUBLIC_KEY},${HASH32}"
}

# =============================================================================
# 函数名称: generate_short_id
# 功能描述: 生成指定长度的 shortId (十六进制)。
#           输入 0-8 时按该长度生成；输入 0 返回空串；其他情况随机 0-8 位。
# =============================================================================
function generate_short_id() {
    local input="${1:-}"
    local trimmed_input=''
    local length=''

    trimmed_input="${input#"${input%%[![:space:]]*}"}"
    trimmed_input="${trimmed_input%"${trimmed_input##*[![:space:]]}"}"

    if [[ ${trimmed_input} =~ ^[0-8]$ ]]; then
        length="${trimmed_input}"
    else
        length="$(generate_random 0 8)"
    fi

    if [[ ${length} -eq 0 ]]; then
        echo ""
    else
        openssl rand -hex "${length}"
    fi
}

# =============================================================================
# 函数名称: generate_short_ids
# 功能描述: 批量生成 shortId，输出去重并按长度排序的 JSON 数组。
#           修正: 原实现用 `IFS=' ' read -a <<<"$@"` 只会拿到第一个参数。
# 参数:
#   $@: 每个参数为长度数字 (0-8) 或现成的十六进制 shortId
# =============================================================================
function generate_short_ids() {
    local -a ids=()
    local arg=''

    for arg in "$@"; do
        [[ -n "${arg}" ]] || continue
        if [[ ${arg} =~ ^[0-8]$ ]]; then
            ids+=("$(generate_short_id "${arg}")")
        else
            ids+=("${arg}")
        fi
    done

    [[ ${#ids[@]} -eq 0 ]] && ids=('8' '8')

    printf '%s\n' "${ids[@]}" | jq -R . | jq -s 'unique | sort_by(length)'
}

# =============================================================================
# 函数名称: generate_path
# 功能描述: 生成以 '/' 开头的 16-64 位随机路径。
# =============================================================================
function generate_path() {
    local length=''
    local domain_path=''

    length="$(generate_random 16 64)"
    domain_path="$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "${length}")"

    echo "/${domain_path}"
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    local option="$1"
    shift

    case "${option}" in
    --random) generate_random ;;
    --port) generate_port ;;
    --uuid) generate_uuid "$@" ;;
    --password) generate_password ;;
    --target) generate_target "$@" ;;
    --server-names) generate_server_names "$@" ;;
    --x25519) generate_x25519 ;;
    --short-id) generate_short_id "$@" ;;
    --short-ids) generate_short_ids "$@" ;;
    --path) generate_path ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
