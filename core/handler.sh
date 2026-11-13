#!/usr/bin/env bash
# =============================================================================
# 脚本名称: handler.sh
# 功能描述: xrayscript 项目的处理器脚本，执行具体的操作：安装/卸载 Xray 与 Nginx、
#           生成配置、启停服务、管理 Docker 容器与路由规则等。
#           由 main.sh 调用，根据传入参数执行相应功能。
# 依赖: bash, jq, curl, systemctl, crontab, sed, awk, grep, cut, tr
# 配置:
#   - ${SCRIPT_CONFIG_DIR}/config.json: 脚本配置
#   - ${I18N_DIR}/${lang}.json: 提示文本
#   - ${CONFIG_DIR}/xray/*.json: Xray 配置模板
#   - ${CONFIG_DIR}/nginx/conf/*: Nginx 配置模板
#   - /usr/local/etc/xray/config.json: Xray 最终配置
#   - /usr/local/nginx/conf/*: Nginx 最终配置
#   - ${HOME}/.acme.sh/: SSL 证书相关文件
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')"
PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)" # 项目根目录

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

# 项目内子脚本路径
readonly SCRIPT_XRAY_DIR="${CONFIG_DIR}/xray"
NGINX_CONFIG_DIR="${NGINX_CONFIG_DIR:-/usr/local/nginx/conf}"                # Nginx 配置目录 (可覆盖)
readonly GENERATE_PATH="${CUR_DIR}/generate.sh"
readonly CHECK_PATH="${CUR_DIR}/check.sh"
readonly SHARE_PATH="${CUR_DIR}/share.sh"
readonly READ_PATH="${CUR_DIR}/read.sh"
readonly NGINX_PATH="${SERVICE_DIR}/nginx.sh"
readonly SSL_PATH="${SERVICE_DIR}/ssl.sh"
readonly DOCKER_PATH="${SERVICE_DIR}/docker.sh"
readonly TRAFFIC_PATH="${TOOL_DIR}/traffic.sh"
readonly GEODATA_PATH="${TOOL_DIR}/geodata.sh"
readonly BBR_PATH="${TOOL_DIR}/bbr.sh"

# 外部配置文件路径
XRAY_CONFIG_PATH="${XRAY_CONFIG_PATH:-/usr/local/etc/xray/config.json}" # Xray 最终配置 (可覆盖，便于测试)
readonly ACME_PATH="${HOME}/.acme.sh/acme.sh"
readonly ACME_CMD="${HOME}/.acme.sh/acme.sh"

# 统计开关的 jq 定义: 同时用于整体生成配置与就地修改现有配置
# shellcheck disable=SC2016 # $s 是 jq 变量, 不是 shell 变量
readonly STATS_JQ_DEF='
def _stats($s):
  (if $s == 1 then
       .stats = (.stats // {})
       | .api.services = (((.api.services // []) + ["StatsService"]) | unique)
       | .policy.levels["0"].statsUserUplink = true
       | .policy.levels["0"].statsUserDownlink = true
       | .policy.system.statsInboundUplink = true
       | .policy.system.statsInboundDownlink = true
       | .policy.system.statsOutboundUplink = true
       | .policy.system.statsOutboundDownlink = true
   else
       del(.stats)
       | .api.services = ((.api.services // []) | map(select(. != "StatsService")))
       | .policy.levels["0"].statsUserUplink = false
       | .policy.levels["0"].statsUserDownlink = false
       | .policy.system.statsInboundUplink = false
       | .policy.system.statsInboundDownlink = false
       | .policy.system.statsOutboundUplink = false
       | .policy.system.statsOutboundDownlink = false
   end);'

# --- 全局变量声明 ---
declare SCRIPT_CONFIG='' # 脚本配置 JSON (运行时从文件加载，避免读写不一致)
declare XRAY_CONFIG=''   # Xray 配置 JSON
declare -A CONFIG_DATA   # 用户输入的临时配置
declare -A CFG           # 脚本配置的扁平快照 (path -> 标量字符串)

# =============================================================================
# 内部工具
# =============================================================================

# =============================================================================
# 函数名称: load_config
# 功能描述: 读取脚本配置到 SCRIPT_CONFIG 与 CFG (单次 jq 扁平化)。
#           所有热路径取值走 CFG 关联数组，不再启动子进程。
# =============================================================================
function load_config() {
    SCRIPT_CONFIG="$(cat "${SCRIPT_CONFIG_PATH}" 2>/dev/null)"
    refresh_cfg_snapshot
}

# =============================================================================
# 函数名称: refresh_cfg_snapshot
# 功能描述: 仅根据当前内存中的 SCRIPT_CONFIG 重建 CFG 快照。
#           与 load_config 的区别: 不重新读取文件，因此不会覆盖未持久化的修改。
# =============================================================================
function refresh_cfg_snapshot() {
    local key=''
    local value=''

    CFG=()
    [[ -n "${SCRIPT_CONFIG}" ]] || return 0
    while IFS=$'\t' read -r key value; do
        [[ -n "${key}" ]] || continue
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        CFG["${key}"]="${value}"
    done < <(printf '%s' "${SCRIPT_CONFIG}" | jq -r 'paths(scalars) as $p | "\($p | join("."))\t\(getpath($p) | tostring)"' 2>/dev/null)
}

# =============================================================================
# 函数名称: cfg
# 功能描述: 从 CFG 快照取值，缺失时回退到实时 jq。
# 参数:
#   $1: 路径 (例如 xray.tag)
#   $2 (可选): 默认值
# =============================================================================
function cfg() {
    local key="$1"
    local default="${2:-}"
    if [[ -n "${CFG[${key}]+x}" ]]; then
        printf -- '%s' "${CFG[${key}]}"
    elif [[ -n "${default}" ]]; then
        printf -- '%s' "${default}"
    else
        json_get - "${key}"
    fi
}

# =============================================================================
# 函数名称: cfg_set
# 功能描述: 用一个 jq 表达式更新 SCRIPT_CONFIG 并同步 CFG。
# 参数:
#   $1: jq 表达式 (作用于整个对象)
#   $@: 透传给 jq 的 --arg / --argjson / --slurpfile 等选项
# =============================================================================
function cfg_set() {
    local filter="$1"
    shift
    SCRIPT_CONFIG="$(printf '%s' "${SCRIPT_CONFIG}" | jq "$@" "${filter}")" || return 1
    # 只刷新内存快照，不能调用 load_config——那会从文件重读并覆盖刚修改的内容
    refresh_cfg_snapshot
}

# =============================================================================
# 函数名称: exec_generate / exec_docker / exec_ssl / exec_check
# =============================================================================
function exec_generate() { bash "${GENERATE_PATH}" "$@"; }

function exec_docker() {
    bash "${DOCKER_PATH}" "$@" || exit 1
}

function exec_ssl() {
    bash "${SSL_PATH}" "$@"
    return $?
}

function exec_check() {
    bash "${CHECK_PATH}" "$@"
    return $?
}

# =============================================================================
# 函数名称: exec_read
# 功能描述: 读取并校验用户输入，结果写入 CONFIG_DATA。
# 参数:
#   $1: 配置项名称
# =============================================================================
function exec_read() {
    local opt="$1"
    local result=''
    local value=''
    local attempts=0
    local max_attempts=5

    while true; do
        # 防止校验始终失败 (如网络不可用) 时无限循环
        attempts=$((attempts + 1))
        if ((attempts > max_attempts)); then
            _warn "input validation failed ${max_attempts} times, aborting"
            CONFIG_DATA["$1"]=''
            return 1
        fi

        result="$(bash "${READ_PATH}" "--${opt}")"

        # 输入为空且非必填项时直接采用默认值，避免空提交反复校验
        case "${opt}" in
        version)
            if [[ -z "${result}" ]]; then
                _warn "version cannot be empty"
                continue
            fi
            exec_check '--xray' "${result}" || continue
            ;;
        email) exec_check '--email' "${result}" || continue ;;
        block-bt | block-cn | block-ad) result="${result:-Y}" ;;
        rules) result="${result:-N}" ;;
        port) exec_check '--port' "${result}" || continue ;;
        uuid | fallback) exec_check '--uuid' "${result}" ;;
        password) exec_check '--password' "${result}" || continue ;;
        target) exec_check '--domain' "${result}" || continue ;;
        only-change-domain) result="${result:-Y}" ;;
        domain | cdn)
            exec_check '--dns' "${result}" || continue
            # 修正: 原代码用 $1 判断，在 while 循环里 $1 是函数自己的参数，行为不稳定
            [[ "${opt}" == 'domain' ]] && CONFIG_DATA['target']="${result}"
            ;;
        custom-domain)
            exec_check '--custom-domain' "${result}" "${CONFIG_DATA['ignore-domain']}" || continue
            ;;
        proxy-target)
            result="$(exec_check '--proxy-target' "${result}")" || continue
            ;;
        site-index)
            exec_check '--list-index' "${result}" "${CONFIG_DATA['site-count']}" || continue
            ;;
        short)
            # 修正: 原逻辑遇到非法值时不会重新读取，会死循环
            [[ -z "${result}" ]] && exec_check '--short' "${result}" && break
            CONFIG_DATA['short_ids']=''
            IFS=',' read -r -a values <<<"${result}"
            local all_valid=1
            for value in "${values[@]}"; do
                value="${value//[[:space:]]/}"
                [[ -n "${value}" ]] || continue
                if exec_check '--short' "${value}"; then
                    CONFIG_DATA['short_ids']+=" ${value}"
                else
                    all_valid=0
                fi
            done
            [[ ${all_valid} -eq 1 ]] && break
            continue
            ;;
        path) exec_check '--path' "${result}" || continue ;;
        address) exec_check '--address' "${result}" || continue ;;
        esac

        break
    done

    CONFIG_DATA["$1"]="${result}"
}

# =============================================================================
# 函数名称: reset_json_fields
# 功能描述: 重置指定键下的字段，保留 $3 起的字段。
# =============================================================================
function reset_json_fields() {
    local raw_json="$1"
    local target_key="$2"

    shift 2
    printf '%s' "${raw_json}" | jq --arg key "${target_key}" --argjson keep "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '
        def clear_recursive:
            if type == "object" then with_entries(.value |= clear_recursive)
            elif type == "array" then map(clear_recursive) | unique
            elif type == "number" then 0
            elif type == "boolean" then false
            else ""
            end;
        def exec_clear:
            if .key | IN($keep[]) then .
            else .value |= clear_recursive
            end;
        if $key != "null" then .[$key] |= with_entries(exec_clear)
        else . |= with_entries(exec_clear)
        end
    '
}

# =============================================================================
# 函数名称: get_custom_site_socket_name
# 功能描述: 生成自定义站点 UDS 名称: SHA-256(域名) 前 12 位 + 端口。
# =============================================================================
function get_custom_site_socket_name() {
    local domain="$1"
    local port="$2"
    local hash=''

    hash="$(printf '%s' "${domain}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-12)"
    [[ -n "${hash}" ]] || hash="$(printf '%s' "${domain}" | shasum -a 256 2>/dev/null | awk '{print $1}' | cut -c1-12)"
    [[ -n "${hash}" ]] || _error "failed to generate custom site socket name"
    echo "${hash}${port}"
}

function get_custom_site_upstream_name() {
    echo "custom_site_$(get_custom_site_socket_name "$1" "$2")"
}

# =============================================================================
# 函数名称: parse_proxy_target
# 功能描述: 解析 http(s)://host:port，输出 "scheme<TAB>host<TAB>port"。
# =============================================================================
function parse_proxy_target() {
    local proxy_target="$1"

    if [[ "${proxy_target}" =~ ^(https?)://([^:]+):([0-9]+)$ ]]; then
        printf '%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

# =============================================================================
# 函数名称: sync_nginx_support_dir
# 功能描述: 把模板目录同步到目标目录 (仅限支持类配置，覆盖同名文件)。
#           修正: 原实现只补缺失文件，模板更新后不会生效；且每次启动都全量 find。
# 参数:
#   $1: 源目录
#   $2: 目标目录
# =============================================================================
function sync_nginx_support_dir() {
    local source_dir="$1"
    local target_dir="$2"
    local source_path=''
    local relative_path=''
    local target_path=''

    [[ -d "${source_dir}" ]] || return 0
    mkdir -p "${target_dir}" || return 1

    while IFS= read -r -d '' source_path; do
        relative_path="${source_path#${source_dir}/}"
        target_path="${target_dir}/${relative_path}"
        if [[ -f "${target_path}" ]] && cmp -s "${source_path}" "${target_path}"; then
            continue
        fi
        mkdir -p "$(dirname "${target_path}")" || return 1
        cp -f "${source_path}" "${target_path}" || return 1
    done < <(find "${source_dir}" -type f -print0)
}

# =============================================================================
# 函数名称: ensure_nginx_support_files
# 功能描述: 确保 Nginx 支持目录与配置片段存在且为最新。
# =============================================================================
function ensure_nginx_support_files() {
    mkdir -p \
        "${NGINX_CONFIG_DIR}/sites-available" \
        "${NGINX_CONFIG_DIR}/sites-enabled" \
        "${NGINX_CONFIG_DIR}/modules-enabled" \
        "${NGINX_CONFIG_DIR}/conf.d" \
        "${NGINX_CONFIG_DIR}/web" \
        "${NGINX_CONFIG_DIR}/nginxconfig.io" || return 1

    sync_nginx_support_dir "${CONFIG_DIR}/nginx/conf/conf.d" "${NGINX_CONFIG_DIR}/conf.d" || return 1
    sync_nginx_support_dir "${CONFIG_DIR}/nginx/conf/web" "${NGINX_CONFIG_DIR}/web" || return 1
    sync_nginx_support_dir "${CONFIG_DIR}/nginx/conf/nginxconfig.io" "${NGINX_CONFIG_DIR}/nginxconfig.io" || return 1
}

# =============================================================================
# 函数名称: write_stream_config
# 功能描述: 生成 stream.conf (SNI 分流 + 自定义站点 upstream)。
# =============================================================================
function write_stream_config() {
    local target_path="$1"
    local source_config="${2:-${SCRIPT_CONFIG}}"
    local domain=''
    local cdn_domain=''
    local site_domain=''
    local site_port=''
    local socket_name=''
    local upstream_name=''
    local default_backend=''

    domain="$(printf '%s' "${source_config}" | jq -r '.nginx.domain // ""')"
    cdn_domain="$(printf '%s' "${source_config}" | jq -r '.nginx.cdn // ""')"
    # 修正: 原实现固定指向 default_backend.sock，但没有任何 server 监听该 socket，
    #       导致未知 SNI 握手直接失败。这里回落到 Reality(domain) 站点。
    default_backend='default_backend'
    if [[ -n "${domain}" && "${domain}" != 'null' ]]; then
        default_backend='nginx_to_xray_vision'
    elif [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' ]]; then
        default_backend='cdn_to_nginx'
    fi

    {
        echo 'stream {'
        echo '    map $ssl_preread_server_name $tcpsni_name {'
        [[ -n "${domain}" && "${domain}" != 'null' ]] && printf '        %-30s %s;\n' "${domain}" 'nginx_to_xray_vision'
        [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' ]] && printf '        %-30s %s;\n' "${cdn_domain}" 'cdn_to_nginx'
        while IFS=$'\t' read -r site_domain site_port; do
            [[ -n "${site_domain}" ]] || continue
            upstream_name="$(get_custom_site_upstream_name "${site_domain}" "${site_port}")"
            printf '        %-30s %s;\n' "${site_domain}" "${upstream_name}"
        done < <(printf '%s' "${source_config}" | jq -r '.nginx.custom_sites // [] | .[] | [.domain, (.port | tostring)] | @tsv')
        printf '        %-30s %s;\n' 'default' "${default_backend}"
        echo '    }'
        echo
        echo '    upstream nginx_to_xray_vision {'
        echo '        server unix:/dev/shm/nginx/nginx_to_xray_vision.sock;'
        echo '    }'
        echo
        echo '    upstream cdn_to_nginx {'
        echo '        server unix:/dev/shm/nginx/cdn_to_nginx.sock;'
        echo '    }'
        echo
        while IFS=$'\t' read -r site_domain site_port; do
            [[ -n "${site_domain}" ]] || continue
            socket_name="$(get_custom_site_socket_name "${site_domain}" "${site_port}")"
            upstream_name="$(get_custom_site_upstream_name "${site_domain}" "${site_port}")"
            echo "    upstream ${upstream_name} {"
            echo "        server unix:/dev/shm/nginx/${socket_name}.sock;"
            echo '    }'
            echo
        done < <(printf '%s' "${source_config}" | jq -r '.nginx.custom_sites // [] | .[] | [.domain, (.port | tostring)] | @tsv')
        echo '    server {'
        echo '        listen         443 reuseport;'
        echo '        listen         [::]:443 reuseport;'
        echo '        ssl_preread    on;'
        echo '        proxy_protocol on;'
        echo '        proxy_pass     $tcpsni_name;'
        echo '    }'
        echo '}'
    } >"${target_path}"
}

function rebuild_stream_config() {
    local source_config="${1:-${SCRIPT_CONFIG}}"
    write_stream_config "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${source_config}"
}

# =============================================================================
# 函数名称: render_custom_site_config
# 功能描述: 由模板渲染自定义站点配置。
#           修正: 模板缺失或 cp/sed 失败时返回错误，避免后续 reload 拿到半成品。
# =============================================================================
function render_custom_site_config() {
    local domain="$1"
    local scheme="$2"
    local host="$3"
    local port="$4"
    local output_path="$5"
    local template="${CONFIG_DIR}/nginx/conf/sites-available/custom-site.example.com.conf"
    local socket_name=''
    local proxy_target="${scheme}://${host}:${port}"

    [[ -f "${template}" ]] || return 1
    ensure_nginx_support_files || return 1
    socket_name="$(get_custom_site_socket_name "${domain}" "${port}")" || return 1

    cp -f "${template}" "${output_path}" || return 1
    sed -i "s|example.com|${domain}|g" "${output_path}" &&
        sed -i "s|unix:/dev/shm/nginx/custom_site.sock|unix:/dev/shm/nginx/${socket_name}.sock|g" "${output_path}" &&
        sed -i "s|PROXY_TARGET|${proxy_target}|g" "${output_path}" || {
        rm -f "${output_path}"
        return 1
    }
}

function sync_custom_sites_config() {
    local source_config="${1:-${SCRIPT_CONFIG}}"
    local domain=''
    local scheme=''
    local host=''
    local port=''
    local conf_path=''

    while IFS=$'\t' read -r domain scheme host port; do
        [[ -n "${domain}" ]] || continue
        conf_path="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
        render_custom_site_config "${domain}" "${scheme}" "${host}" "${port}" "${conf_path}" || return 1
        ln -sf "${conf_path}" "${NGINX_CONFIG_DIR}/sites-enabled/${domain}.conf" || return 1
    done < <(printf '%s' "${source_config}" | jq -r '.nginx.custom_sites // [] | .[] | [.domain, .scheme, .host, (.port | tostring)] | @tsv')
}

# =============================================================================
# 函数名称: test_nginx_config / reload_nginx
# 功能描述: 合并为一次检测 + 一次热加载；回滚路径使用 reload_nginx_silent。
# =============================================================================
function test_nginx_config() {
    ensure_nginx_support_files || return 1
    nginx -t >/dev/null 2>&1
}

function reload_nginx() {
    if systemctl -q is-active nginx; then
        systemctl -q reload nginx
    else
        systemctl -q start nginx
    fi
}

function test_and_reload_nginx() {
    test_nginx_config || return 1
    reload_nginx
}

# 回滚专用：失败时只返回错误码，不打印、不中断，保证回滚流程能走完
function reload_nginx_silent() {
    test_nginx_config >/dev/null 2>&1 || return 1
    reload_nginx >/dev/null 2>&1
}

function get_custom_sites_count() {
    printf '%s' "${SCRIPT_CONFIG}" | jq -r '(.nginx.custom_sites // []) | length'
}

function show_custom_sites_list() {
    local custom_site_count=''
    local index=''
    local domain=''
    local scheme=''
    local host=''
    local port=''
    local socket_name=''
    local msg=''

    custom_site_count="$(get_custom_sites_count)"

    if ((custom_site_count == 0)); then
        i18n_fill msg "${CUR_FILE}.custom_sites.empty"
        _info "${msg}"
        return 0
    fi

    i18n_fill msg "${CUR_FILE}.custom_sites.list_header"
    _info "${msg}"
    while IFS=$'\t' read -r index domain scheme host port; do
        socket_name="$(get_custom_site_socket_name "${domain}" "${port}")"
        printf '%s | %s | %s://%s:%s | %s.sock\n' "${index}" "${domain}" "${scheme}" "${host}" "${port}" "${socket_name}" >&2
    done < <(printf '%s' "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | to_entries[] | [(.key + 1 | tostring), .value.domain, .value.scheme, .value.host, (.value.port | tostring)] | @tsv')
}

function read_custom_site_domain_update() {
    local current_domain="$1"
    local result=''
    local msg=''

    i18n_fill msg "${CUR_FILE}.custom_sites.keep_current"
    _tip "${msg}"
    while true; do
        result="$(bash "${READ_PATH}" '--custom-domain')"
        [[ -z "${result}" ]] && echo "${current_domain}" && return 0
        if exec_check '--custom-domain' "${result}" "${current_domain}"; then
            echo "${result}"
            return 0
        fi
    done
}

function read_custom_site_proxy_target_update() {
    local current_proxy_target="$1"
    local result=''
    local msg=''

    i18n_fill msg "${CUR_FILE}.custom_sites.keep_current"
    _tip "${msg}"
    while true; do
        result="$(bash "${READ_PATH}" '--proxy-target')"
        [[ -z "${result}" ]] && echo "${current_proxy_target}" && return 0
        result="$(exec_check '--proxy-target' "${result}")" || continue
        echo "${result}"
        return 0
    done
}

function rollback_stream_config_backup() {
    local backup_path="$1"
    local stream_path="${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"
    if [[ -f "${backup_path}" ]]; then
        mv -f "${backup_path}" "${stream_path}"
    else
        rm -f "${stream_path}"
    fi
}

function get_custom_site_json_by_index() {
    local site_index="$1"
    printf '%s' "${SCRIPT_CONFIG}" | jq -c --argjson idx "$((site_index - 1))" '.nginx.custom_sites // [] | .[$idx]'
}

# =============================================================================
# 函数名称: add_rule
# 功能描述: 在 routing.rules 中添加或更新规则。
# 参数:
#   $1: ruleTag
#   $2: domain / ip / protocol
#   $3: 值 (逗号分隔)
#   $4: outboundTag
#   $5: 位置 (before/after/数字索引，可选)
#   $6: 参考 ruleTag (可选)
# =============================================================================
function add_rule() {
    local rule_tag="$1"
    local domain_or_ip="$2"
    local value="$3"
    local outboundTag="$4"
    local position="${5:-}"
    local target_tag="${6:-}"

    XRAY_CONFIG="${XRAY_CONFIG:-$(cat "${XRAY_CONFIG_PATH}" 2>/dev/null)}"
    [[ -n "${XRAY_CONFIG}" ]] || XRAY_CONFIG='{}'

    XRAY_CONFIG="$(printf '%s' "${XRAY_CONFIG}" | jq \
        --arg ruleTag "${rule_tag}" \
        --arg field "${domain_or_ip}" \
        --argjson value "$(printf '%s' "${value}" | tr ',' '\n' | jq -R . | jq -s .)" \
        --arg outboundTag "${outboundTag}" \
        --arg position "${position}" \
        --arg targetTag "${target_tag}" '
        .routing.rules = (.routing.rules // []) |
        if any(.routing.rules[]; .ruleTag == $ruleTag) then
            .routing.rules |= map(
                if .ruleTag == $ruleTag then
                    (.[$field] // []) as $old | .[$field] = (($old + $value) | unique)
                else . end
            )
        else
            (
                {ruleTag: $ruleTag, outboundTag: $outboundTag}
                + {( $field ): $value}
            ) as $new_rule |
            (
                .routing.rules | to_entries
                | map(select(.value.ruleTag == $targetTag))
                | .[0].key
            ) as $target_index |
            if $targetTag != "" and $target_index != null then
                if $position == "before" then
                    .routing.rules = .routing.rules[:$target_index] + [$new_rule] + .routing.rules[$target_index:]
                elif $position == "after" then
                    .routing.rules = .routing.rules[:($target_index + 1)] + [$new_rule] + .routing.rules[($target_index + 1):]
                else
                    .routing.rules += [$new_rule]
                end
            elif $position != "" and ($position | test("^[0-9]+$")) then
                ($position | tonumber) as $pos |
                .routing.rules = .routing.rules[:$pos] + [$new_rule] + .routing.rules[$pos:]
            else
                .routing.rules += [$new_rule]
            end
        end')"
}

# =============================================================================
# 函数名称: handler_routing
# 功能描述: 处理路由规则配置 (屏蔽 / WARP)。
#           修正: 原实现用 "${XRAY_CONFIG[${rule_tag}]}" 取值为空，规则从未写入。
# =============================================================================
function handler_routing() {
    local WARP_STATUS=''
    local rule_type="$1"
    local rule_target="$2"
    local rule_tag="${rule_type}-${rule_target}"
    local user_input=''
    local msg=''

    WARP_STATUS="$(cfg 'xray.warp' '0')"

    if [[ "${rule_type}" == 'warp' && "${WARP_STATUS}" != '1' ]]; then
        i18n_fill msg "${CUR_FILE}.warp.status"
        _error "${msg}"
    fi

    exec_read "${rule_tag}"
    user_input="${CONFIG_DATA[${rule_tag}]}"

    if [[ -z "${user_input//[[:space:]]/}" ]]; then
        _warn "empty rule value, nothing changed"
        return 0
    fi

    XRAY_CONFIG="$(cat "${XRAY_CONFIG_PATH}" 2>/dev/null)"
    add_rule "${rule_tag}" "${rule_target}" "${user_input}" "${rule_type}"
    printf '%s\n' "${XRAY_CONFIG}" >"${XRAY_CONFIG_PATH}" || _error "failed to write xray config"
}

# =============================================================================
# 函数名称: handler_reset_script_config
# =============================================================================
function handler_reset_script_config() {
    local TARGET_CONFIG="${1:-xray}"

    case "${TARGET_CONFIG,,}" in
    xray) SCRIPT_CONFIG="$(reset_json_fields "${SCRIPT_CONFIG}" 'xray' 'version' 'warp' 'rules')" ;;
    nginx) SCRIPT_CONFIG="$(reset_json_fields "${SCRIPT_CONFIG}" 'nginx' 'version' 'ca' 'ca_server')" ;;
    esac

    persist_script_config || _error "failed to persist script config"
    load_config
}

# =============================================================================
# 函数名称: handler_update_ocsp_config
# 功能描述: 根据 CA 厂商开关 nginx.conf 中的 OCSP Stapling。
# =============================================================================
function handler_update_ocsp_config() {
    local ca_server="${1:-zerossl}"
    local need_reload="${2:-n}"
    local nginx_conf="${NGINX_CONFIG_DIR}/nginx.conf"

    case "${ca_server,,}" in
    zerossl | letsencrypt) ;;
    *) ca_server='zerossl' ;;
    esac
    [[ -f "${nginx_conf}" ]] || return 0

    if [[ "${ca_server,,}" == 'letsencrypt' ]]; then
        sed -i -E 's|^([[:space:]]*)ssl_stapling([[:space:]]+on;)|\1# ssl_stapling\2|' "${nginx_conf}"
        sed -i -E 's|^([[:space:]]*)ssl_stapling_verify([[:space:]]+on;)|\1# ssl_stapling_verify\2|' "${nginx_conf}"
    else
        sed -i -E 's|^([[:space:]]*)#([[:space:]]*)ssl_stapling([[:space:]]+on;)|\1ssl_stapling\3|' "${nginx_conf}"
        sed -i -E 's|^([[:space:]]*)#([[:space:]]*)ssl_stapling_verify([[:space:]]+on;)|\1ssl_stapling_verify\3|' "${nginx_conf}"
    fi

    if [[ "${need_reload}" == 'y' ]] && cmd_exists 'nginx' && systemctl -q is-active nginx; then
        nginx -t && systemctl -q reload nginx || _error "nginx.conf check failed after OCSP toggle"
    fi
}

# =============================================================================
# 函数名称: handler_ca_server
# 功能描述: 切换 CA 厂商，事务化重签所有域名证书。
#           修正: 先续签再写配置，最后才 --set-ca，任何一步失败都回滚。
# =============================================================================
function handler_ca_server() {
    local target_ca_server="${1:-zerossl}"
    local current_ca_server=''
    local domain=''
    local cdn_domain=''
    local reissue_domain=''
    local -a reissue_targets=()
    local -a switched_domains=()

    case "${target_ca_server,,}" in
    zerossl | letsencrypt) target_ca_server="${target_ca_server,,}" ;;
    *) target_ca_server='zerossl' ;;
    esac

    current_ca_server="$(cfg 'nginx.ca_server' 'zerossl')"
    case "${current_ca_server,,}" in
    zerossl | letsencrypt) current_ca_server="${current_ca_server,,}" ;;
    *) current_ca_server='zerossl' ;;
    esac

    if [[ "${target_ca_server}" == "${current_ca_server}" ]]; then
        exec_ssl '--set-ca' "--ca=${target_ca_server}" || _error "failed to set acme default ca"
        handler_update_ocsp_config "${target_ca_server}" 'y'
        return 0
    fi

    domain="$(cfg 'nginx.domain')"
    cdn_domain="$(cfg 'nginx.cdn')"

    [[ -n "${domain}" && "${domain}" != 'null' ]] && reissue_targets+=("${domain}")
    if [[ -n "${cdn_domain}" && "${cdn_domain}" != 'null' && "${cdn_domain}" != "${domain}" ]]; then
        reissue_targets+=("${cdn_domain}")
    fi
    while IFS= read -r reissue_domain; do
        [[ -n "${reissue_domain}" ]] && reissue_targets+=("${reissue_domain}")
    done < <(printf '%s' "${SCRIPT_CONFIG}" | jq -r '.nginx.custom_sites // [] | .[] | .domain // empty')

    for reissue_domain in "${reissue_targets[@]}"; do
        if exec_ssl '--issue' "--domain=${reissue_domain}" "--ca=${target_ca_server}"; then
            switched_domains+=("${reissue_domain}")
            continue
        fi

        local rollback_domain=''
        for rollback_domain in "${switched_domains[@]}"; do
            exec_ssl '--issue' "--domain=${rollback_domain}" "--ca=${current_ca_server}" || true
        done
        exec_ssl '--set-ca' "--ca=${current_ca_server}" || true
        handler_update_ocsp_config "${current_ca_server}" 'y' || true
        _error "ca switch failed, rolled back to ${current_ca_server}"
    done

    # 全部重签成功后才写入配置与 acme 默认 CA
    cfg_set '.nginx.ca_server = $caServer' --arg caServer "${target_ca_server}"
    persist_script_config || _error "failed to persist script config"
    exec_ssl '--set-ca' "--ca=${target_ca_server}" || {
        cfg_set '.nginx.ca_server = $caServer' --arg caServer "${current_ca_server}"
        persist_script_config || true
        _error "failed to set acme default ca"
    }
    handler_update_ocsp_config "${target_ca_server}" 'y'
}

# =============================================================================
# 函数名称: handler_script_config
# 功能描述: 根据 CONFIG_DATA 生成并更新脚本配置。
#           原实现约 20 次 jq 调用，这里合并为一次。
# =============================================================================
function handler_script_config() {
    local CONFIG_TAG="${1:-${CONFIG_DATA['tag']}}"
    local XRAY_RULES_STATUS="${CONFIG_DATA['rules'],,}"
    local XRAY_RULES_BT="${CONFIG_DATA['block-bt'],,}"
    local XRAY_RULES_CN="${CONFIG_DATA['block-cn'],,}"
    local XRAY_RULES_AD="${CONFIG_DATA['block-ad'],,}"
    local XRAY_PORT="${CONFIG_DATA['port']:-443}"
    local XRAY_UUID=''
    local FALLBACK_UUID=''
    local TROJAN_PASSWORD=''
    local XHTTP_PATH=''
    local TARGET_DOMAIN=''
    local SERVER_NAMES='[]'
    local CDN_DOMAIN="${CONFIG_DATA['cdn']}"
    local SHORT_IDS='[]'
    local CA_EMAIL="${CONFIG_DATA['email']}"
    local title=''

    i18n_fill title "${CUR_FILE}.script.config_update"
    _info "${title}"

    handler_reset_script_config

    XRAY_UUID="$(exec_generate '--uuid' "${CONFIG_DATA['uuid']}")"
    FALLBACK_UUID="${CONFIG_DATA['fallback']:-$(exec_generate '--uuid')}"
    TROJAN_PASSWORD="${CONFIG_DATA['password']:-$(exec_generate '--password')}"
    XHTTP_PATH="${CONFIG_DATA['path']:-$(exec_generate '--path')}"
    TARGET_DOMAIN="${CONFIG_DATA['target']:-$(exec_generate '--target')}"
    SERVER_NAMES="$(exec_generate '--server-names' "${TARGET_DOMAIN}")"
    # 注意: ${var:-8 8} 的默认值不能带引号——'8 8' 会被当成单个词，
    # 导致 generate_short_ids 收到 "8 8" 而非两个参数 8 和 8
    local -a short_id_args=()
    if [[ -n "${CONFIG_DATA['short_ids']}" ]]; then
        read -r -a short_id_args <<<"${CONFIG_DATA['short_ids']}"
    else
        short_id_args=('8' '8')
    fi
    SHORT_IDS="$(exec_generate '--short-ids' "${short_id_args[@]}")"
    [[ -n "${SERVER_NAMES}" ]] || SERVER_NAMES="[\"${TARGET_DOMAIN}\"]"
    [[ -n "${SHORT_IDS}" ]] || SHORT_IDS='[""]'

    SCRIPT_CONFIG="$(printf '%s' "${SCRIPT_CONFIG}" | jq \
        --arg tag "${CONFIG_TAG}" \
        --argjson port "${XRAY_PORT}" \
        --arg rules "${XRAY_RULES_STATUS}" \
        --arg bt "${XRAY_RULES_BT}" \
        --arg cn "${XRAY_RULES_CN}" \
        --arg ad "${XRAY_RULES_AD}" \
        --arg uuid "${XRAY_UUID}" \
        --arg fallback "${FALLBACK_UUID}" \
        --arg trojan "${TROJAN_PASSWORD}" \
        --arg path "${XHTTP_PATH}" \
        --arg target "${TARGET_DOMAIN}" \
        --argjson serverNames "${SERVER_NAMES}" \
        --argjson shortIds "${SHORT_IDS}" \
        --arg cdn "${CDN_DOMAIN}" \
        --arg ca "${CA_EMAIL}" \
        '
        def flag($v): if $v != "n" and $v != "" then 1 else 0 end;
        .xray.rules = ((.xray.rules // {}) + {
            reset: flag($rules), bt: flag($bt), cn: flag($cn), ad: flag($ad)
        })
        | .xray.tag = $tag
        | .xray.port = $port
        | (if ($tag | ascii_downcase) == "trojan" then
              .xray.trojan = $trojan
           else
              .xray.uuid = $uuid
           end)
        | (if ($tag | ascii_downcase) == "fallback" or ($tag | ascii_downcase) == "sni"
           then .xray.fallback = $fallback else . end)
        | (if ["xhttp", "trojan", "fallback", "sni"] | index($tag | ascii_downcase) then
              .xray.path = $path else . end)
        | (if ["vision", "xhttp", "trojan", "fallback", "sni"] | index($tag | ascii_downcase) then
              .xray.target = $target
              | .xray.serverNames = $serverNames
              | .xray.shortIds = $shortIds
           else . end)
        | (if ($tag | ascii_downcase) == "sni" then
              .nginx.domain = $target
              | .nginx.cdn = $cdn
              | (if $ca != "" then .nginx.ca = $ca else . end)
           else . end)
        ')"

    persist_script_config || _error "failed to persist script config"
    load_config
}

# =============================================================================
# 函数名称: handler_x25519_config
# =============================================================================
function handler_x25519_config() {
    local X25519=''
    local PRIVATE_KEY=''
    local PUBLIC_KEY=''
    local HASH32=''
    local title=''

    i18n_fill title "${CUR_FILE}.script.config_update"
    _info "${title}"

    X25519="$(exec_generate '--x25519')"
    PRIVATE_KEY="$(echo "${X25519}" | awk -F, '{print $1}')"
    PUBLIC_KEY="$(echo "${X25519}" | awk -F, '{print $2}')"
    HASH32="$(echo "${X25519}" | awk -F, '{print $3}')"

    _info "Private Key: ${PRIVATE_KEY}"
    _info "Public Key: ${PUBLIC_KEY}"
    _info "Hash32: ${HASH32}"

    cfg_set '.xray.privateKey = $privateKey | .xray.publicKey = $publicKey | .xray.hash32 = $hash32' \
        --arg privateKey "${PRIVATE_KEY}" --arg publicKey "${PUBLIC_KEY}" --arg hash32 "${HASH32}"
    persist_script_config || _error "failed to persist script config"
}

# =============================================================================
# 函数名称: xray_socket_inbounds
# 功能描述: 读取现有 Xray 配置中所有以 unix socket 监听的入站，
#           输出 jq 数组 (tag / listen / port / rawSettings)。
#           这类监听方式通常是手工调整的 (如 SNI 分流)，模板无法体现。
# =============================================================================
function xray_socket_inbounds() {
    [[ -f "${XRAY_CONFIG_PATH}" ]] || {
        printf '[]'
        return 0
    }

    jq -c '
        [ (.inbounds // [])[]
          | select((.listen // "") | startswith("/"))
          | {tag: (.tag // ""),
             listen: .listen,
             port: (.port // null),
             rawSettings: (.streamSettings.rawSettings // null)}
        ]
    ' "${XRAY_CONFIG_PATH}" 2>/dev/null || printf '[]'
}

# =============================================================================
# 函数名称: handler_xray_config
# 功能描述: 生成 Xray 最终配置。
#           修正: 单个 jq 完成模板替换；.rules 为 null 时不再报错；
#                 fallback 缺端口时自动补齐；规则重置按 bt/cn/ad 开关生成。
# =============================================================================
function handler_xray_config() {
    local CONFIG_TAG=''
    local XRAY_PORT=''
    local XRAY_RULES_STATUS='0'
    local XRAY_RULES_BT='0'
    local XRAY_RULES_CN='0'
    local XRAY_RULES_AD='0'
    local XRAY_RULES='[]'
    local WARP_STATUS='0'
    local STATS_STATUS='1'
    local SOCKET_INBOUNDS='[]'
    local template=''
    local container_ip=''
    local title=''

    i18n_fill title "${CUR_FILE}.xray.config_update"
    _info "${title}"

    CONFIG_TAG="$(cfg 'xray.tag')"
    XRAY_PORT="$(cfg 'xray.port' '443')"
    XRAY_RULES_STATUS="$(cfg 'xray.rules.reset' '0')"
    XRAY_RULES_BT="$(cfg 'xray.rules.bt' '0')"
    XRAY_RULES_CN="$(cfg 'xray.rules.cn' '0')"
    XRAY_RULES_AD="$(cfg 'xray.rules.ad' '0')"
    XRAY_RULES="$(printf '%s' "${SCRIPT_CONFIG}" | jq -c '.rules // []')"
    WARP_STATUS="$(cfg 'xray.warp' '0')"
    # 空值视为默认开启 (模板自带统计)，只有显式 "0" 才关闭
    STATS_STATUS="$(cfg 'system.stats' '1')"
    [[ "${STATS_STATUS}" == '0' ]] || STATS_STATUS='1'

    # 先记录当前配置里的 socket 监听，稍后渲染完再还原
    SOCKET_INBOUNDS="$(xray_socket_inbounds)"

    template="${SCRIPT_XRAY_DIR}/${CONFIG_TAG}.json"
    [[ -f "${template}" ]] || _error "xray template not found: ${template}"

    XRAY_CONFIG="$(jq --arg tag "${CONFIG_TAG,,}" \
        --argjson port "${XRAY_PORT}" \
        --arg uuid "$(cfg 'xray.uuid')" \
        --arg fallback "$(cfg 'xray.fallback')" \
        --arg trojan "$(cfg 'xray.trojan')" \
        --arg target "$(cfg 'xray.target')" \
        --argjson serverNames "$(printf '%s' "${SCRIPT_CONFIG}" | jq -c '.xray.serverNames // []')" \
        --arg privateKey "$(cfg 'xray.privateKey')" \
        --argjson shortIds "$(printf '%s' "${SCRIPT_CONFIG}" | jq -c '.xray.shortIds // []')" \
        --arg path "$(cfg 'xray.path')" \
        --argjson rulesReset "${XRAY_RULES_STATUS}" \
        --argjson rulesBt "${XRAY_RULES_BT}" \
        --argjson rulesCn "${XRAY_RULES_CN}" \
        --argjson rulesAd "${XRAY_RULES_AD}" \
        --argjson rules "${XRAY_RULES}" \
        --argjson stats "${STATS_STATUS}" \
        "${STATS_JQ_DEF}"'
        # ---------- 入站参数替换 ----------
        (if $tag != "sni" then .inbounds[1].port = $port else . end)
        | (if ($tag | IN("vision", "xhttp", "fallback", "sni")) then
              .inbounds[1].settings.clients[0].id = $uuid else . end)
        | (if $tag == "trojan" then .inbounds[1].settings.clients[0].password = $trojan else . end)
        | (if ($tag | IN("vision", "xhttp", "trojan", "fallback", "sni")) then
              (if $tag != "sni" then
                  .inbounds[1].streamSettings.realitySettings.target = "\($target):443"
               else . end)
              | .inbounds[1].streamSettings.realitySettings.serverNames = $serverNames
              | .inbounds[1].streamSettings.realitySettings.privateKey = $privateKey
              | .inbounds[1].streamSettings.realitySettings.shortIds = $shortIds
           else . end)
        | (if ($tag | IN("xhttp", "trojan")) then
              .inbounds[1].streamSettings.xhttpSettings.path = $path else . end)
        | (if ($tag | IN("fallback", "sni")) then
              .inbounds[2].settings.clients[0].id = $fallback
              | .inbounds[2].streamSettings.xhttpSettings.path = $path
           else . end)
        # ---------- fallback 分支补齐监听端口 ----------
        | (if ($tag | IN("vision", "xhttp", "trojan")) then
              .inbounds[1].listen = "0.0.0.0"
              | .inbounds[1].port = $port
           else . end)
        | (if ($tag | IN("fallback", "sni")) then
              (if (.inbounds[1] | has("port") | not) and (.inbounds[1].listen // "" | startswith("/dev/shm") | not)
               then .inbounds[1].listen = "0.0.0.0" | .inbounds[1].port = $port
               else . end)
           else . end)
        # ---------- 流量统计开关 ----------
        | _stats($stats)
        # ---------- 路由规则 ----------
        | .routing.rules = (.routing.rules // [])
        | (if $rulesReset == 0 then
              .routing.rules = $rules
           else
              .routing.rules |= map(select(.ruleTag | IN("bt", "cn-ip", "ad-domain") | not))
           end)
        | (if $rulesReset == 1 then
              (if $rulesBt == 1 then
                  .routing.rules = (
                      ([{ruleTag: "bt", protocol: ["bittorrent"], outboundTag: "block"}] + .routing.rules)
                  ) else . end)
              | (if $rulesCn == 1 then
                    (.routing.rules | map(.ruleTag == "private-ip") | index(true)) as $pi
                    | .routing.rules = (
                        if $pi == null then .routing.rules + [{ruleTag: "cn-ip", ip: ["geoip:cn"], outboundTag: "block"}]
                        else .routing.rules[:$pi + 1] + [{ruleTag: "cn-ip", ip: ["geoip:cn"], outboundTag: "block"}] + .routing.rules[$pi + 1:]
                        end
                    )
                 else . end)
              | (if $rulesAd == 1 then
                    .routing.rules += [{ruleTag: "ad-domain", domain: ["geosite:category-ads-all"], outboundTag: "block"}]
                 else . end)
           else . end)
        ' "${template}")" || _error "failed to render xray config"

    # 保留手工设置的 unix socket 监听 (模板无法体现):
    # SNI 分流等场景下 Xray 监听 socket 而不是端口，重渲染若改回 0.0.0.0:443
    # 会与 nginx 抢端口导致 Xray 起不来。
    if [[ "${SOCKET_INBOUNDS}" != '[]' ]]; then
        XRAY_CONFIG="$(printf '%s' "${XRAY_CONFIG}" | jq --argjson keep "${SOCKET_INBOUNDS}" '
            reduce ($keep[]) as $k (.;
                .inbounds = ((.inbounds // []) | map(
                    if ($k.tag != "") and ((.tag // "") == $k.tag) then
                        .listen = $k.listen
                        | (if $k.port == null then del(.port) else .port = $k.port end)
                        | (if $k.rawSettings == null then .
                           else .streamSettings.rawSettings = $k.rawSettings end)
                    else . end)))
        ')" || _error "failed to preserve unix socket listener"

        i18n_fill title "${CUR_FILE}.xray.socket_kept"
        _info "${title}: $(printf '%s' "${SOCKET_INBOUNDS}" | jq -r 'map(.tag) | join(", ")')"
    fi

    # WARP 出站 (仅在已开启时追加)
    if [[ "${WARP_STATUS}" == '1' ]]; then
        container_ip="$(exec_docker '--obtain-container-ip')"
        if [[ -n "${container_ip}" ]]; then
            XRAY_CONFIG="$(printf '%s' "${XRAY_CONFIG}" | jq --arg ip "${container_ip}" \
                '.outbounds = ((.outbounds // []) | map(select(.tag != "warp")) + [{tag: "warp", protocol: "socks", settings: {servers: [{address: $ip, port: 40001}]}}])')"
        fi
    fi

    mkdir -p "$(dirname "${XRAY_CONFIG_PATH}")" || _error "failed to create xray config dir"
    printf '%s\n' "${XRAY_CONFIG}" >"${XRAY_CONFIG_PATH}" || _error "failed to write xray config"

    # 同步规则回脚本配置
    SCRIPT_CONFIG="$(printf '%s' "${SCRIPT_CONFIG}" | jq --argjson rules "$(printf '%s' "${XRAY_CONFIG}" | jq -c '.routing.rules')" '.rules = $rules')"
    persist_script_config || _error "failed to persist script config"
    load_config
}

# =============================================================================
# 函数名称: handler_read_xray_config
# =============================================================================
function handler_read_xray_config() {
    local CONFIG_TAG="${1}"

    if ! exec_check '--tag' "${CONFIG_TAG}"; then
        exit 1
    fi

    CONFIG_DATA['tag']="${CONFIG_TAG}"

    if printf '%s' "${SCRIPT_CONFIG}" | jq -r '.xray.rules.reset' | grep -Eq '^(0|1)$'; then
        exec_read 'rules'
    fi

    if [[ "${CONFIG_DATA['rules'],,}" != 'n' ]]; then
        exec_read 'block-bt'
        exec_read 'block-cn'
        exec_read 'block-ad'
    fi

    exec_read 'port'

    case "${CONFIG_TAG,,}" in
    trojan) exec_read 'password' ;;
    vision | xhttp | fallback | sni) exec_read 'uuid' ;;
    esac

    case "${CONFIG_TAG,,}" in
    fallback | sni) exec_read 'fallback' ;;
    esac

    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback) exec_read 'target' ;;
    sni)
        local CA_EMAIL=''
        CA_EMAIL="$(cfg 'nginx.ca')"
        [[ -z "${CA_EMAIL}" ]] && exec_read 'email'
        exec_read 'domain'
        exec_read 'cdn'
        ;;
    esac

    case "${CONFIG_TAG,,}" in
    vision | xhttp | trojan | fallback | sni) exec_read 'short' ;;
    esac

    case "${CONFIG_TAG,,}" in
    xhttp | trojan | fallback | sni) exec_read 'path' ;;
    esac
}

# =============================================================================
# 函数名称: handler_sni_config
# 功能描述: 切换配置类型时的前置处理 (停服务 / 配置 Nginx)。
#           修正: 只有确实曾以非 SNI 方式运行过时才去停 nginx，避免无谓中断。
# =============================================================================
function handler_sni_config() {
    local CONFIG_TAG=''
    local web="${1:-normal}"
    local msg=''
    local site_count='0'

    CONFIG_TAG="$(cfg 'xray.tag')"

    case "${CONFIG_TAG,,}" in
    sni)
        handler_change_domain 'domain' 'n'
        handler_change_domain 'cdn' 'n'
        site_count="$(get_custom_sites_count)"
        if ((site_count > 0)); then
            i18n_fill msg "${CUR_FILE}.custom_sites.syncing"
            _info "${msg}"
            sync_custom_sites_config "${SCRIPT_CONFIG}" || _error "failed to sync custom sites"
            rebuild_stream_config "${SCRIPT_CONFIG}"
        fi
        handler_web "${web}"
        ;;
    esac
}

function handler_check_sni_ports() {
    local msg=''
    if ! exec_check '--sni-ports'; then
        i18n_fill msg "${CUR_FILE}.sni.port_guard_fail"
        _error "${msg}"
    fi
}

# =============================================================================
# 自定义站点: 列表 / 新增 / 更新 / 删除
# =============================================================================

function handler_custom_site_list() {
    show_custom_sites_list
}

function handler_custom_site_add() {
    local domain=''
    local proxy_target=''
    local scheme=''
    local host=''
    local port=''
    local updated_script_config=''
    local conf_path=''
    local link_path=''
    local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"
    local msg=''

    exec_read 'custom-domain'
    exec_read 'proxy-target'

    domain="${CONFIG_DATA['custom-domain']}"
    proxy_target="${CONFIG_DATA['proxy-target']}"
    IFS=$'\t' read -r scheme host port <<<"$(parse_proxy_target "${proxy_target}")" || _error "failed to parse proxy target"

    updated_script_config="$(printf '%s' "${SCRIPT_CONFIG}" | jq \
        --arg domain "${domain}" --arg scheme "${scheme}" --arg host "${host}" --argjson port "${port}" \
        '.nginx.custom_sites = ((.nginx.custom_sites // []) + [{"domain": $domain, "scheme": $scheme, "host": $host, "port": $port}])')"

    conf_path="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
    link_path="${NGINX_CONFIG_DIR}/sites-enabled/${domain}.conf"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"

    exec_ssl '--issue' "--domain=${domain}" || _error "failed to issue certificate for ${domain}"
    if ! render_custom_site_config "${domain}" "${scheme}" "${host}" "${port}" "${conf_path}"; then
        rollback_stream_config_backup "${stream_backup}"
        exec_ssl '--stop-renew' "--domain=${domain}" || true
        _error "failed to render custom site config"
    fi
    if ! ln -sf "${conf_path}" "${link_path}"; then
        rm -f "${conf_path}"
        rollback_stream_config_backup "${stream_backup}"
        exec_ssl '--stop-renew' "--domain=${domain}" || true
        _error "failed to enable custom site config"
    fi
    rebuild_stream_config "${updated_script_config}"

    if ! test_and_reload_nginx; then
        rm -f "${conf_path}" "${link_path}"
        rollback_stream_config_backup "${stream_backup}"
        reload_nginx_silent || true
        exec_ssl '--stop-renew' "--domain=${domain}" || true
        _error "failed to apply custom site ${domain}"
    fi

    rm -f "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config || _error "failed to persist script config"
    load_config
    i18n_fill msg "${CUR_FILE}.custom_sites.added"
    _info "${msg}${domain}"
}

function handler_custom_site_update() {
    local custom_site_count=''
    local site_index=''
    local current_site=''
    local old_domain=''
    local old_scheme=''
    local old_host=''
    local old_port=''
    local old_proxy_target=''
    local new_domain=''
    local new_proxy_target=''
    local new_scheme=''
    local new_host=''
    local new_port=''
    local updated_script_config=''
    local old_conf_path=''
    local new_conf_path=''
    local old_link_path=''
    local new_link_path=''
    local old_conf_backup=''
    local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"
    local msg=''

    custom_site_count="$(get_custom_sites_count)"
    show_custom_sites_list
    ((custom_site_count > 0)) || return 0
    CONFIG_DATA['site-count']="${custom_site_count}"
    exec_read 'site-index'
    site_index="${CONFIG_DATA['site-index']}"
    current_site="$(get_custom_site_json_by_index "${site_index}")"

    old_domain="$(echo "${current_site}" | jq -r '.domain')"
    old_scheme="$(echo "${current_site}" | jq -r '.scheme')"
    old_host="$(echo "${current_site}" | jq -r '.host')"
    old_port="$(echo "${current_site}" | jq -r '.port')"
    old_proxy_target="${old_scheme}://${old_host}:${old_port}"

    new_domain="$(read_custom_site_domain_update "${old_domain}")"
    new_proxy_target="$(read_custom_site_proxy_target_update "${old_proxy_target}")"
    IFS=$'\t' read -r new_scheme new_host new_port <<<"$(parse_proxy_target "${new_proxy_target}")" || _error "failed to parse proxy target"

    updated_script_config="$(printf '%s' "${SCRIPT_CONFIG}" | jq \
        --argjson idx "$((site_index - 1))" \
        --arg domain "${new_domain}" --arg scheme "${new_scheme}" --arg host "${new_host}" --argjson port "${new_port}" \
        '.nginx.custom_sites[$idx] = {"domain": $domain, "scheme": $scheme, "host": $host, "port": $port}')"

    old_conf_path="${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf"
    new_conf_path="${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"
    old_link_path="${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
    new_link_path="${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf"
    old_conf_backup="${SCRIPT_CONFIG_DIR}/${old_domain}.custom-site.bak.conf"
    [[ -f "${old_conf_path}" ]] && cp -f "${old_conf_path}" "${old_conf_backup}"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"

    if [[ "${new_domain}" == "${old_domain}" ]]; then
        if [[ "${new_proxy_target}" != "${old_proxy_target}" ]]; then
            i18n_fill msg "${CUR_FILE}.custom_sites.upstream_only"
            _info "${msg}"
        fi
        if ! render_custom_site_config "${new_domain}" "${new_scheme}" "${new_host}" "${new_port}" "${new_conf_path}"; then
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            rollback_stream_config_backup "${stream_backup}"
            reload_nginx_silent || true
            _error "failed to render custom site config"
        fi
        if ! ln -sf "${new_conf_path}" "${new_link_path}"; then
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            rollback_stream_config_backup "${stream_backup}"
            reload_nginx_silent || true
            _error "failed to enable custom site config"
        fi
        rebuild_stream_config "${updated_script_config}"

        if ! test_and_reload_nginx; then
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            ln -sf "${old_conf_path}" "${old_link_path}"
            rollback_stream_config_backup "${stream_backup}"
            reload_nginx_silent || true
            _error "failed to update custom site ${old_domain}"
        fi
    else
        exec_ssl '--issue' "--domain=${new_domain}" || _error "failed to issue certificate for ${new_domain}"
        if ! render_custom_site_config "${new_domain}" "${new_scheme}" "${new_host}" "${new_port}" "${new_conf_path}"; then
            rollback_stream_config_backup "${stream_backup}"
            exec_ssl '--stop-renew' "--domain=${new_domain}" || true
            reload_nginx_silent || true
            _error "failed to render custom site config"
        fi
        if ! ln -sf "${new_conf_path}" "${new_link_path}"; then
            rm -f "${new_conf_path}"
            rollback_stream_config_backup "${stream_backup}"
            exec_ssl '--stop-renew' "--domain=${new_domain}" || true
            reload_nginx_silent || true
            _error "failed to enable custom site config"
        fi
        rm -f "${old_conf_path}" "${old_link_path}"
        rebuild_stream_config "${updated_script_config}"

        if ! test_and_reload_nginx; then
            rm -f "${new_conf_path}" "${new_link_path}"
            [[ -f "${old_conf_backup}" ]] && mv -f "${old_conf_backup}" "${old_conf_path}"
            ln -sf "${old_conf_path}" "${old_link_path}"
            rollback_stream_config_backup "${stream_backup}"
            reload_nginx_silent || true
            exec_ssl '--stop-renew' "--domain=${new_domain}" || true
            _error "failed to switch custom site domain ${old_domain} -> ${new_domain}"
        fi
        exec_ssl '--stop-renew' "--domain=${old_domain}" || true
    fi

    rm -f "${old_conf_backup}" "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config || _error "failed to persist script config"
    load_config
    i18n_fill msg "${CUR_FILE}.custom_sites.updated"
    _info "${msg}${new_domain}"
}

function handler_custom_site_delete() {
    local custom_site_count=''
    local site_index=''
    local current_site=''
    local domain=''
    local conf_path=''
    local link_path=''
    local conf_backup=''
    local stream_backup="${SCRIPT_CONFIG_DIR}/stream.conf.custom-sites.bak"
    local updated_script_config=''
    local msg=''

    custom_site_count="$(get_custom_sites_count)"
    show_custom_sites_list
    ((custom_site_count > 0)) || return 0
    CONFIG_DATA['site-count']="${custom_site_count}"
    exec_read 'site-index'
    site_index="${CONFIG_DATA['site-index']}"
    current_site="$(get_custom_site_json_by_index "${site_index}")"
    domain="$(echo "${current_site}" | jq -r '.domain')"
    conf_path="${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
    link_path="${NGINX_CONFIG_DIR}/sites-enabled/${domain}.conf"
    conf_backup="${SCRIPT_CONFIG_DIR}/${domain}.custom-site.bak.conf"

    updated_script_config="$(printf '%s' "${SCRIPT_CONFIG}" | jq --argjson idx "$((site_index - 1))" 'del(.nginx.custom_sites[$idx])')"
    [[ -f "${conf_path}" ]] && cp -f "${conf_path}" "${conf_backup}"
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${stream_backup}"

    rm -f "${conf_path}" "${link_path}"
    rebuild_stream_config "${updated_script_config}"

    if ! test_and_reload_nginx; then
        [[ -f "${conf_backup}" ]] && mv -f "${conf_backup}" "${conf_path}"
        ln -sf "${conf_path}" "${link_path}"
        rollback_stream_config_backup "${stream_backup}"
        reload_nginx_silent || true
        _error "failed to delete custom site ${domain}"
    fi

    rm -f "${conf_backup}" "${stream_backup}"
    SCRIPT_CONFIG="${updated_script_config}"
    persist_script_config || _error "failed to persist script config"
    load_config
    exec_ssl '--stop-renew' "--domain=${domain}" || true
    i18n_fill msg "${CUR_FILE}.custom_sites.deleted"
    _info "${msg}${domain}"
}

function handler_custom_sites() {
    case "${1}" in
    list) handler_custom_site_list ;;
    add) handler_custom_site_add ;;
    update) handler_custom_site_update ;;
    delete) handler_custom_site_delete ;;
    *) _error "unsupported custom site action: ${1}" ;;
    esac
}

# =============================================================================
# 函数名称: handler_xray_version
# 功能描述: 解析并写入要安装的 Xray 版本。
#           latest: 按 published_at 显式倒序取第一个 (GitHub 默认按 created_at
#                   排序，遇连续预发布时可能拿到较旧的版本)；
#           release: 取最新的非预发布版本，同样按 published_at 判定；
#           custom: 读取并校验用户输入。
# 参数:
#   $1: latest / custom / 其他 (默认视作 release)
# =============================================================================
function handler_xray_version() {
    local xray_version="$1"
    local version=''
    local api_url='https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30'

    case "${xray_version,,}" in
    latest)
        # 含预发布：按发布时间倒序取最新一个
        version="$(curl -fsSL --max-time 20 "${api_url}" |
            jq -r 'sort_by(.published_at) | reverse | .[0].tag_name // empty')"
        ;;
    custom)
        exec_read 'version' || _error "failed to read xray version"
        version="${CONFIG_DATA['version']}"
        ;;
    *)
        # 稳定版：先按发布时间倒序，再排除预发布
        version="$(curl -fsSL --max-time 20 "${api_url}" |
            jq -r 'sort_by(.published_at) | reverse | map(select(.prerelease == false)) | .[0].tag_name // empty')"
        # 首发接口异常时回退到官方 latest 接口
        if [[ -z "${version}" ]]; then
            version="$(curl -fsSL --max-time 20 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" |
                jq -r '.tag_name // empty')"
        fi
        ;;
    esac

    if [[ ! "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        cmd_exists 'curl' || _error "curl not found, cannot query Xray releases"
        _error "failed to resolve xray version (GitHub API unreachable or rate limited)"
    fi

    CONFIG_DATA['version']="${version}"
    cfg_set '.xray.version = $xray' --arg xray "${version}"
    persist_script_config || _error "failed to persist script config"
}

# =============================================================================
# 函数名称: handler_change_share_address
# 功能描述: 设置分享链接使用的地址。留空表示自动检测公网 IPv4；
#           填写 IPv6 (可带方括号) 或域名时，分享链接直接指向该地址。
#           同时处理 IPv6 部署的一种情况：自动检测到本机有 IPv6 但监听仍是
#           IPv4 通配时，把 inbound 改成同时接听 IPv6 的双栈地址。
# =============================================================================
function handler_change_share_address() {
    local address=''

    exec_read 'address'
    address="${CONFIG_DATA['address']}"
    address="${address//[[:space:]]/}"

    cfg_set '.xray.address = $address' --arg address "${address}" ||
        _error "failed to persist script config"
}

# =============================================================================
# 函数名称: handler_change_xray_port
# =============================================================================
function handler_change_xray_port() {
    local XRAY_PORT='443'
    local CONFIG_TAG=''

    CONFIG_TAG="$(cfg 'xray.tag')"
    exec_read 'port'

    XRAY_PORT="${CONFIG_DATA['port']:-${XRAY_PORT}}"

    cfg_set '.xray.port = $port' --argjson port "${XRAY_PORT}"
    persist_script_config || _error "failed to persist script config"
}

# =============================================================================
# 函数名称: handler_install / handler_purge
# =============================================================================
# =============================================================================
# 函数名称: fetch_xray_installer
# 功能描述: 下载 Xray 官方安装脚本，支持多个镜像源与 curl/wget 回退。
#           GitHub 直连在部分网络下不稳定，因此依次尝试不同地址。
# 返回值: 脚本内容输出到标准输出；全部失败返回 1
# =============================================================================
function fetch_xray_installer() {
    local -a urls=(
        'https://github.com/XTLS/Xray-install/raw/main/install-release.sh'
        'https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
        'https://ghproxy.net/https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
        'https://gh-proxy.com/https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh'
    )
    local url=''
    local content=''

    for url in "${urls[@]}"; do
        if cmd_exists 'curl'; then
            content="$(curl -fsSL --max-time 60 "${url}" 2>/dev/null)"
        elif cmd_exists 'wget'; then
            content="$(wget -qO- --timeout=60 --no-check-certificate "${url}" 2>/dev/null)"
        else
            _error "curl/wget not found, cannot download Xray installer"
        fi

        # 简单校验：官方安装脚本必含 install 相关关键字
        if [[ -n "${content}" && "${content}" == *"Xray"* && "${content}" == *"INSTALL"* ]]; then
            printf '%s' "${content}"
            return 0
        fi
        _warn "download failed from ${url}, trying next mirror..."
    done

    return 1
}

function handler_install() {
    local xray_version="$1"
    local force_install="${2:-n}"
    local version=''
    local installer=''
    local install_rc=0

    if [[ -n "${xray_version}" ]]; then
        handler_xray_version "${xray_version}"
        version="${CONFIG_DATA['version']}"
    else
        version="$(cfg 'xray.version')"
    fi

    if [[ -z "${version}" ]]; then
        _error "xray version is empty, please choose a version first"
    fi

    if ! cmd_exists 'xray' || [[ "${force_install}" != 'n' ]]; then
        _info "installing Xray ${version} ..."

        installer="$(fetch_xray_installer)" ||
            _error "failed to download Xray installer from all mirrors (check network / DNS)"

        # 写入临时文件后执行——bash -c 传大段脚本会被 $0 占位符干扰参数解析
        # 官方脚本参数格式: install-release.sh ACTION [OPTION]...
        # 即 ACTION 在前: install --version v1.0.0 (不是 --version v1.0.0 install)
        local installer_file='/tmp/xray-install-release.sh'
        printf '%s\n' "${installer}" >"${installer_file}" ||
            _error "failed to write installer to ${installer_file}"

        bash "${installer_file}" install --version "${version}"
        install_rc=$?
        rm -f "${installer_file}"
        if [[ ${install_rc} -ne 0 ]]; then
            _error "Xray installation failed (exit ${install_rc}), see output above"
        fi
        cmd_exists 'xray' || _error "Xray installation finished but binary is missing"
        _info "Xray ${version} installed: $(xray version 2>/dev/null | head -1)"
    else
        _info "Xray already installed: $(xray version 2>/dev/null | head -1)"
    fi
}

function handler_purge() {
    local installer=''
    installer="$(fetch_xray_installer)" ||
        _error "failed to download Xray installer from all mirrors (check network / DNS)"
    local installer_file='/tmp/xray-install-release.sh'
    printf '%s\n' "${installer}" >"${installer_file}"
    bash "${installer_file}" remove --purge
    local purge_rc=$?
    rm -f "${installer_file}"
    [[ ${purge_rc} -eq 0 ]] || _error "Xray uninstall failed (exit ${purge_rc})"
    SCRIPT_CONFIG="$(reset_json_fields "${SCRIPT_CONFIG}" 'xray')"
    persist_script_config || _error "failed to persist script config"
    load_config
}

# =============================================================================
# 函数名称: handler_start / handler_stop / handler_restart
# =============================================================================
function handler_start() {
    systemctl -q is-active xray || systemctl -q start xray
    systemctl -q is-enabled xray || systemctl -q enable xray
}

function handler_stop() {
    systemctl -q is-active xray && systemctl -q stop xray
    systemctl -q is-enabled xray && systemctl -q disable xray
}

function handler_restart() {
    if systemctl -q is-active xray; then
        systemctl -q restart xray || _error "xray restart failed"
    else
        systemctl -q start xray || _error "xray start failed"
    fi
    systemctl -q is-enabled xray || systemctl -q enable xray
}

function handler_share() {
    bash "${SHARE_PATH}"
}

# =============================================================================
# 函数名称: ipv6_listener_tag
# 功能描述: 找出承载代理流量的入站 tag。
#           以脚本配置里记录的 outbound tag 为准，取值失败时回退到
#           模板里第一个带 reality/tls 的入站。
# =============================================================================
function ipv6_listener_tag() {
    local tag=''
    local fallback=''

    tag="$(json_get "${XRAY_CONFIG_PATH}" ".inbounds[] | select(.tag == \"$(cfg 'xray.tag')\") | .tag" 2>/dev/null)"
    if [[ -n "${tag}" ]]; then
        printf '%s' "${tag}"
        return 0
    fi

    fallback="$(jq -r '
        [ (.inbounds // [])[]
          | select((.listen // "") | startswith("/") | not)
          | select(.port != null)
          | select((.streamSettings.security // "") != "")
        ] | (.[0].tag // "")' "${XRAY_CONFIG_PATH}" 2>/dev/null)"
    printf '%s' "${fallback}"
}

# =============================================================================
# 函数名称: handler_ipv6_listen_summary
# 功能描述: 输出当前入站监听方式，供菜单显示 (空表示未检测到)。
# =============================================================================
function handler_ipv6_listen_summary() {
    local tag=''

    [[ -f "${XRAY_CONFIG_PATH}" ]] || return 0
    tag="$(ipv6_listener_tag)"
    [[ -n "${tag}" ]] || return 0

    jq -r --arg tag "${tag}" '
        [ .inbounds[] | select(.tag == $tag) ][0]
        | if . == null then ""
          else "\(.listen // "-"):\(.port // "-")" end' "${XRAY_CONFIG_PATH}" 2>/dev/null
}

# =============================================================================
# 函数名称: handler_ipv6_deploy
# 功能描述: IPv6 一键部署。只调整入站监听方式，不重新生成密钥，不重渲染整份配置。
#           配置先校验后替换，xray 启动失败时自动回滚。
# 参数:
#   $1: dual-双栈 (::) / v6-仅 IPv6 (::) / default-恢复模板监听
# =============================================================================
function handler_ipv6_deploy() {
    local mode="${1:-dual}"
    local tag=''
    local listen=''
    local port=''
    local backup=''
    local tmp=''
    local title=''
    local ok=0

    [[ -f "${XRAY_CONFIG_PATH}" ]] || _error "xray config not found: ${XRAY_CONFIG_PATH}"

    tag="$(ipv6_listener_tag)"
    [[ -n "${tag}" ]] || _error "no proxy inbound found in xray config"

    backup="$(mktemp "${TMPDIR:-/tmp}/xray-ipv6.XXXXXX")" || _error "failed to create temp file"
    cp -f "${XRAY_CONFIG_PATH}" "${backup}" || _error "failed to backup xray config"

    case "${mode}" in
    default)
        # 恢复模板监听: 只把 listen 还原为协议模板里的值
        listen="$(jq -r --arg tag "$(cfg 'xray.tag')" \
            '.inbounds[] | select((.tag | ascii_downcase) == ($tag | ascii_downcase)) | .listen // empty' \
            "${SCRIPT_XRAY_DIR}/$(cfg 'xray.tag').json" 2>/dev/null | head -n 1)"
        [[ -n "${listen}" ]] || listen='0.0.0.0'
        tmp="$(mktemp "${TMPDIR:-/tmp}/xray-ipv6-new.XXXXXX")" || _error "failed to create temp file"
        jq --arg tag "${tag}" --arg listen "${listen}" \
            '.inbounds |= map(if .tag == $tag then .listen = $listen else . end)' \
            "${backup}" >"${tmp}" || _error "failed to render xray config"
        ;;
    dual | v6)
        listen='::'
        tmp="$(mktemp "${TMPDIR:-/tmp}/xray-ipv6-new.XXXXXX")" || _error "failed to create temp file"
        jq --arg tag "${tag}" --arg listen "${listen}" \
            '.inbounds |= map(if .tag == $tag then .listen = $listen else . end)' \
            "${backup}" >"${tmp}" || _error "failed to render xray config"
        ;;
    *)
        rm -f "${backup}"
        _error "unknown ipv6 deploy mode: ${mode}"
        ;;
    esac

    port="$(jq -r --arg tag "${tag}" '(.inbounds[] | select(.tag == $tag) | .port) // empty' "${tmp}" 2>/dev/null)"
    [[ -n "${port}" ]] || port="$(cfg 'xray.port' '443')"

    if ! xray -test -c "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}" "${backup}"
        _error "xray config test failed after ipv6 change"
    fi

    cat "${tmp}" >"${XRAY_CONFIG_PATH}" && ok=1
    rm -f "${tmp}"
    [[ "${ok}" == '1' ]] || {
        mv -f "${backup}" "${XRAY_CONFIG_PATH}"
        _error "failed to write xray config"
    }

    if ! systemctl -q restart xray 2>/dev/null; then
        mv -f "${backup}" "${XRAY_CONFIG_PATH}"
        systemctl -q restart xray >/dev/null 2>&1 || true
        rm -f "${backup}"
        _error "xray failed to start with the new listener, rolled back"
    fi
    systemctl -q is-enabled xray || systemctl -q enable xray
    rm -f "${backup}"

    # 仅 IPv6 时让分享链接直接指向 IPv6；双栈时清空地址回到自动检测
    case "${mode}" in
    v6)
        local v6=''

        v6="$(curl -6 -fsSL --max-time 8 ipv6.icanhazip.com 2>/dev/null | tr -d '[:space:]')"
        if [[ -n "${v6}" ]]; then
            cfg_set '.xray.address = $address' --arg address "${v6}" || true
        fi
        ;;
    dual | default)
        cfg_set '.xray.address = $address' --arg address '' || true
        ;;
    esac
    persist_script_config || _warn "failed to persist script config (share address unchanged)"

    i18n_fill title "${CUR_FILE}.ipv6.deployed"
    _info "${title}: ${tag} -> ${listen}:${port}"
    handler_share
}

# =============================================================================
# 函数名称: stats_is_enabled
# 功能描述: 判断 Xray 当前配置是否启用了流量统计。
#           以最终配置文件为准 (存在 stats 段且 api.services 含 StatsService)。
# 返回值: 0-已开启 1-已关闭
# =============================================================================
function stats_is_enabled() {
    [[ -f "${XRAY_CONFIG_PATH}" ]] || return 1
    jq -e 'has("stats") and ((.api.services // []) | index("StatsService") != null)' \
        "${XRAY_CONFIG_PATH}" >/dev/null 2>&1
}

# =============================================================================
# 函数名称: stats_write_config
# 功能描述: 就地修改当前 Xray 配置里的统计开关，不重新渲染整个配置。
#           这样不会覆盖手工调整过的监听方式 (例如 SNI 分流的 unix socket)。
# 参数:
#   $1: 1-开启 0-关闭
# 返回值: 0-成功 1-失败
# =============================================================================
function stats_write_config() {
    local value="$1"
    local tmp=''

    [[ -f "${XRAY_CONFIG_PATH}" ]] || return 1
    tmp="$(mktemp "${TMPDIR:-/tmp}/xray-config.XXXXXX")" || return 1

    if ! jq --argjson stats "${value}" "${STATS_JQ_DEF}"' _stats($stats)' \
        "${XRAY_CONFIG_PATH}" >"${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi

    # 覆盖写回原文件，保留 inode 与权限
    cat "${tmp}" >"${XRAY_CONFIG_PATH}" || {
        rm -f "${tmp}"
        return 1
    }
    rm -f "${tmp}"
    return 0
}

# =============================================================================
# 函数名称: handler_stats
# 功能描述: 查看/开启/关闭/清空 Xray 流量统计。
#           开关状态记入 .system.stats (空=默认开启, 1=开启, 0=关闭)，
#           由 handler_xray_config 生成配置时应用，重装或改端口后依然保持。
# 参数:
#   $1: show / enable / disable / reset / status / toggle (默认 show)
# =============================================================================
function handler_stats() {
    local action="${1:-show}"
    local msg=''

    if [[ "${action}" == 'toggle' ]]; then
        if stats_is_enabled; then
            action='disable'
        else
            action='enable'
        fi
    fi

    case "${action}" in
    show)
        if ! stats_is_enabled; then
            i18n_fill msg "${CUR_FILE}.stats.disabled_hint"
            _warn "${msg}"
            return 0
        fi
        bash "${TRAFFIC_PATH}" --show
        ;;
    reset)
        if ! stats_is_enabled; then
            i18n_fill msg "${CUR_FILE}.stats.disabled_hint"
            _warn "${msg}"
            return 0
        fi
        bash "${TRAFFIC_PATH}" --reset || return 1
        i18n_fill msg "${CUR_FILE}.stats.reset"
        _pass "${msg}"
        ;;
    enable)
        if stats_is_enabled; then
            i18n_fill msg "${CUR_FILE}.stats.already_enabled"
            _info "${msg}"
            return 0
        fi
        cfg_set '.system.stats = "1"' || _error "failed to update script config"
        stats_write_config 1 || _error "failed to update xray config"
        persist_script_config || _error "failed to persist script config"
        handler_restart
        i18n_fill msg "${CUR_FILE}.stats.enabled"
        _pass "${msg}"
        ;;
    disable)
        if ! stats_is_enabled; then
            i18n_fill msg "${CUR_FILE}.stats.already_disabled"
            _info "${msg}"
            return 0
        fi
        cfg_set '.system.stats = "0"' || _error "failed to update script config"
        stats_write_config 0 || _error "failed to update xray config"
        persist_script_config || _error "failed to persist script config"
        handler_restart
        i18n_fill msg "${CUR_FILE}.stats.disabled"
        _tip "${msg}"
        ;;
    status)
        if stats_is_enabled; then
            i18n_fill msg "${CUR_FILE}.stats.status_on"
        else
            i18n_fill msg "${CUR_FILE}.stats.status_off"
        fi
        echo "${msg}"
        ;;
    *)
        i18n_fill msg "${CUR_FILE}.stats.usage"
        _error "${msg}"
        return 1
        ;;
    esac
}

function handler_traffic() {
    handler_stats "${1:-show}"
}

# =============================================================================
# 函数名称: handler_bbr
# 功能描述: 开启/关闭/查看 TCP BBR 加速。
#           toggle 按当前内核状态自动切换，并把结果记入配置 .system.bbr
#           (空=未设置, 1=已开启, 0=已关闭)，供快速安装判断是否需要默认开启。
# 参数:
#   $1: status / enable / disable / toggle (默认 status)
# =============================================================================
function handler_bbr() {
    local action="${1:-status}"
    local msg=''

    if [[ "${action}" == 'toggle' ]]; then
        if bash "${BBR_PATH}" --is-enabled; then
            action='disable'
        else
            action='enable'
        fi
    fi

    case "${action}" in
    enable)
        if bash "${BBR_PATH}" --enable; then
            cfg_set '.system.bbr = "1"' && persist_script_config
            i18n_fill msg "${CUR_FILE}.bbr.enabled"
            _pass "${msg}"
        else
            i18n_fill msg "${CUR_FILE}.bbr.unsupported"
            _warn "${msg}"
            return 1
        fi
        ;;
    disable)
        if bash "${BBR_PATH}" --disable; then
            cfg_set '.system.bbr = "0"' && persist_script_config
            i18n_fill msg "${CUR_FILE}.bbr.disabled"
            _tip "${msg}"
        else
            i18n_fill msg "${CUR_FILE}.bbr.failed"
            _warn "${msg}"
            return 1
        fi
        ;;
    *)
        bash "${BBR_PATH}" --status
        ;;
    esac
}

# =============================================================================
# 函数名称: cron_replace
# 功能描述: 在 root crontab 中增删指定任务，兼容 crontab 为空的情况。
# 参数:
#   $1: remove / add
#   $2: 用于匹配任务的路径关键字
#   $3 (add 时必需): 完整的 cron 行
# =============================================================================
function cron_replace() {
    local action="$1"
    local keyword="$2"
    local line="${3:-}"
    local current=''

    current="$(crontab -l 2>/dev/null || true)"

    if [[ "${action}" == 'remove' ]]; then
        printf '%s\n' "${current}" | grep -v -F "${keyword}" | awk 'NF' | crontab - 2>/dev/null || true
        return 0
    fi

    {
        printf '%s\n' "${current}"
        printf '%s\n' "${line}"
    } | awk '!x[$0]++ && NF' | crontab - 2>/dev/null || return 1
}

function handler_geodata_cron() {
    local IS_QUICK="${1:-0}"
    local XRAY_STATUS=''
    local msg=''

    XRAY_STATUS="$(cfg 'xray.version')"
    [[ -n "${XRAY_STATUS}" ]] || return 0

    if [[ "${IS_QUICK}" == '0' ]] && crontab -l 2>/dev/null | grep -qF "${GEODATA_PATH}"; then
        cron_replace 'remove' "${GEODATA_PATH}"
        i18n_fill msg "${CUR_FILE}.geodata.close_cron"
        _tip "${msg}"
        return 0
    fi

    chmod a+x "${GEODATA_PATH}"
    cron_replace 'add' "${GEODATA_PATH}" "30 6 * * * ${GEODATA_PATH} >/dev/null 2>&1" || _warn "failed to update crontab"
    i18n_fill msg "${CUR_FILE}.geodata.update"
    _tip "${msg}"
    bash "${GEODATA_PATH}" || _warn "geodata update failed"
    i18n_fill msg "${CUR_FILE}.geodata.open_cron"
    _tip "${msg}"
}

function handler_docker() {
    if ! cmd_exists 'docker'; then
        exec_docker '--install'
    fi
}

# =============================================================================
# 函数名称: handler_warp / handler_reset_warp
# 功能描述: 开启/关闭 WARP 分流。
#           修正: 关闭时同时清理 warp-ip / warp-domain 路由规则。
# =============================================================================
function handler_warp() {
    local WARP_STATUS=''
    local container_ip=''

    handler_docker

    WARP_STATUS="$(cfg 'xray.warp' '0')"
    XRAY_CONFIG="$(cat "${XRAY_CONFIG_PATH}" 2>/dev/null)"
    [[ -n "${XRAY_CONFIG}" ]] || XRAY_CONFIG='{"outbounds":[],"routing":{"rules":[]}}'

    if [[ "${WARP_STATUS}" == '1' ]]; then
        WARP_STATUS=0
        exec_docker '--disable-warp'
        XRAY_CONFIG="$(printf '%s' "${XRAY_CONFIG}" | jq '
            .outbounds = ((.outbounds // []) | map(select(.tag != "warp")))
            | .routing.rules = ((.routing.rules // []) | map(select(
                (.outboundTag // "") != "warp" and (.ruleTag // "") != "warp-ip" and (.ruleTag // "") != "warp-domain")))
        ')"
    else
        WARP_STATUS=1
        exec_docker '--build-warp'
        container_ip="$(exec_docker '--enable-warp')"
        [[ -n "${container_ip}" ]] || _error "failed to obtain warp container ip"
        XRAY_CONFIG="$(printf '%s' "${XRAY_CONFIG}" | jq --arg ip "${container_ip}" '
            .outbounds = ((.outbounds // []) | map(select(.tag != "warp"))
                + [{tag: "warp", protocol: "socks", settings: {servers: [{address: $ip, port: 40001}]}}])
        ')"
    fi

    cfg_set '.xray.warp = $warp' --argjson warp "${WARP_STATUS}"
    persist_script_config || _error "failed to persist script config"
    printf '%s\n' "${XRAY_CONFIG}" >"${XRAY_CONFIG_PATH}" || _error "failed to write xray config"
}

function handler_reset_warp() {
    local WARP_STATUS=''
    WARP_STATUS="$(cfg 'xray.warp' '0')"
    handler_docker

    if [[ "${WARP_STATUS}" == '1' ]]; then
        exec_docker '--clean-container-logs'
        exec_docker '--disable-warp'
        exec_docker '--build-warp'
        exec_docker '--enable-warp'
    fi
}

# =============================================================================
# 函数名称: handler_nginx_install / update / purge / cron
# =============================================================================
function handler_nginx_install() {
    local NGINX_VERSION=''

    if ! cmd_exists 'nginx'; then
        bash "${NGINX_PATH}" --install --brotli || _error "nginx install failed"
        handler_ssl_install || _error "ssl install failed during nginx setup"
        handler_nginx_config || _error "nginx config apply failed"
        NGINX_VERSION="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2)"
        [[ -n "${NGINX_VERSION}" ]] || _error "failed to detect nginx version"
        cfg_set '.nginx.version = $version' --arg version "${NGINX_VERSION}"
        persist_script_config || _error "failed to persist nginx version"
    fi
}

function handler_nginx_update() {
    bash "${NGINX_PATH}" --update --brotli
}

function handler_nginx_purge() {
    bash "${NGINX_PATH}" --purge
    SCRIPT_CONFIG="$(reset_json_fields "${SCRIPT_CONFIG}" 'nginx')"
    persist_script_config || _error "failed to persist script config"
    load_config
}

function handler_nginx_cron() {
    local NGINX_STATUS=''
    local msg=''

    NGINX_STATUS="$(cfg 'nginx.version')"
    [[ -n "${NGINX_STATUS}" ]] || return 0

    if crontab -l 2>/dev/null | grep -qF "${NGINX_PATH}"; then
        cron_replace 'remove' "${NGINX_PATH}"
        i18n_fill msg "${CUR_FILE}.nginx.close_cron"
        _tip "${msg}"
        return 0
    fi

    chmod a+x "${NGINX_PATH}"
    cron_replace 'add' "${NGINX_PATH}" "0 3 * * * ${NGINX_PATH} --update --brotli >/dev/null 2>&1" || _warn "failed to update crontab"
    i18n_fill msg "${CUR_FILE}.nginx.open_cron"
    _tip "${msg}"
}

function handler_nginx_start() {
    ensure_nginx_support_files || return 1
    systemctl -q is-active nginx || systemctl -q start nginx
    systemctl -q is-enabled nginx || systemctl -q enable nginx
}

function handler_nginx_stop() {
    systemctl -q is-active nginx && systemctl -q stop nginx
    systemctl -q is-enabled nginx && systemctl -q disable nginx
}

function handler_nginx_restart() {
    ensure_nginx_support_files || return 1
    if systemctl -q is-active nginx; then
        systemctl -q restart nginx
    else
        systemctl -q start nginx
    fi
    systemctl -q is-enabled nginx || systemctl -q enable nginx
}

# =============================================================================
# 函数名称: handler_ssl_install
# =============================================================================
function handler_ssl_install() {
    local CA_EMAIL=''
    local CA_SERVER=''

    if [[ ! -e "${ACME_PATH}" ]]; then
        CA_EMAIL="$(cfg 'nginx.ca')"
        CA_SERVER="$(cfg 'nginx.ca_server' 'zerossl')"
        exec_ssl '--install' "--email=${CA_EMAIL}" "--ca=${CA_SERVER}" || exit 1
    fi
}

# =============================================================================
# 函数名称: handler_change_domain
# 功能描述: 更改域名 (domain / cdn)，包括证书签发、站点配置与 stream 映射。
#           修正: 非交互路径不再用旧域名覆盖用户输入。
# =============================================================================
function handler_change_domain() {
    local XHTTP_PATH=''
    local target_domain="$1"
    local stop_cert_service="${2:-y}"
    local old_domain=''
    local new_domain=''
    local site_conf=''
    local link_conf=''

    XHTTP_PATH="$(cfg 'xray.path')"
    old_domain="$(cfg "nginx.${target_domain}")"
    ensure_nginx_support_files || _error "failed to sync nginx support files"

    if [[ -n "${CONFIG_DATA[${target_domain}]}" ]]; then
        new_domain="${CONFIG_DATA[${target_domain}]}"
    elif [[ "${stop_cert_service}" == 'y' ]]; then
        [[ -n "${old_domain}" ]] && exec_read 'only-change-domain'
        exec_read "${target_domain}"
        new_domain="${CONFIG_DATA[${target_domain}]}"
    else
        new_domain="${old_domain}"
    fi
    CONFIG_DATA["${target_domain}"]="${new_domain}"

    if [[ -z "${new_domain}" ]]; then
        return 0
    fi

    site_conf="${NGINX_CONFIG_DIR}/sites-available/${new_domain}.conf"
    link_conf="${NGINX_CONFIG_DIR}/sites-enabled/${new_domain}.conf"

    # 备份旧配置
    [[ -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" ]] && cp -f "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf" "${SCRIPT_CONFIG_DIR}/stream.conf"
    if [[ -f "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" ]]; then
        cp -f "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${SCRIPT_CONFIG_DIR}/${old_domain}.conf"
        rm -f "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
    fi

    cp -f "${CONFIG_DIR}/nginx/conf/sites-available/${target_domain}.example.com.conf" "${site_conf}" || _error "site template missing"
    sed -i "s|example.com|${new_domain}|g" "${site_conf}"
    sed -i "s|/yourpath|${XHTTP_PATH}|g" "${site_conf}"
    # 保留自定义站点 URL 中的端口时必须限定，避免误伤真实数据
    ln -sf "${site_conf}" "${link_conf}"

    if ! exec_ssl '--issue' "--domain=${new_domain}"; then
        rm -f "${site_conf}" "${link_conf}"
        [[ -f "${SCRIPT_CONFIG_DIR}/stream.conf" ]] && mv -f "${SCRIPT_CONFIG_DIR}/stream.conf" "${NGINX_CONFIG_DIR}/modules-enabled/stream.conf"
        if [[ -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" ]]; then
            mv -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf"
            ln -sf "${NGINX_CONFIG_DIR}/sites-available/${old_domain}.conf" "${NGINX_CONFIG_DIR}/sites-enabled/${old_domain}.conf"
        fi
        handler_nginx_restart || true
        return 1
    fi

    if [[ -n "${old_domain}" && "${stop_cert_service}" == 'y' && "${old_domain}" != "${new_domain}" ]]; then
        exec_ssl '--stop-renew' "--domain=${old_domain}" || true
    fi

    if [[ "${target_domain}" == 'domain' ]]; then
        cfg_set '.xray.target = $domain | .xray.serverNames = [$domain] | del(.target.domain?) | .nginx.domain = $domain' --arg domain "${new_domain}"
    else
        cfg_set '.nginx[$key] = $domain' --arg key "${target_domain}" --arg domain "${new_domain}"
    fi

    # `仅更新域名` 模式: 在已有配置上替换域名，保持其它设置不变
    if [[ "${CONFIG_DATA['only-change-domain'],,}" == 'y' && -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" ]]; then
        sed "s|${old_domain}|${new_domain}|g" "${SCRIPT_CONFIG_DIR}/${old_domain}.conf" >"${site_conf}"
        rm -f "${SCRIPT_CONFIG_DIR}/${old_domain}.conf"
        ln -sf "${site_conf}" "${link_conf}"
    fi

    rebuild_stream_config "${SCRIPT_CONFIG}"
    persist_script_config || _error "failed to persist script config"
    load_config
    handler_nginx_restart || _error "nginx restart failed"
}

# =============================================================================
# 函数名称: handler_renew_ssl
# =============================================================================
function handler_renew_ssl() {
    exec_ssl '--renew' || _error "ssl renew failed"
    handler_nginx_restart || _error "nginx restart failed after renew"
    handler_restart || _error "xray restart failed after renew"
}

# =============================================================================
# 函数名称: handler_nginx_config
# 功能描述: 部署 Nginx 主配置与站点模板。
#           修正: 只拷贝 conf 下的文件，不再把 sites-available 整个目录搬过去。
# =============================================================================
function handler_nginx_config() {
    local CA_SERVER=''
    local item=''

    ensure_nginx_support_files || return 1
    mkdir -pv "${NGINX_CONFIG_DIR}/sites-enabled" || return 1

    if [[ -f "${NGINX_CONFIG_DIR}/nginx.conf" ]]; then
        mv "${NGINX_CONFIG_DIR}/nginx.conf" "${NGINX_CONFIG_DIR}/default.conf.bak" || return 1
    fi

    for item in "${CONFIG_DIR}/nginx/conf/"*; do
        [[ -f "${item}" ]] || continue
        cp -af "${item}" "${NGINX_CONFIG_DIR}/" || return 1
    done

    CA_SERVER="$(cfg 'nginx.ca_server' 'zerossl')"
    handler_update_ocsp_config "${CA_SERVER}" || return 1
}

# =============================================================================
# 函数名称: handler_cloudreve_v3 / handler_cloudreve_v4
# =============================================================================
function handler_cloudreve_v3() {
    handler_docker
    case "${1}" in
    install) exec_docker '--install-cloudreve-v3' ;;
    get) exec_docker '--get-cloudreve-v3-admin' ;;
    token) exec_docker '--get-aria2-token' ;;
    reset) exec_docker '--reset-cloudreve-v3-admin' ;;
    purge) exec_docker '--purge-cloudreve-v3' ;;
    start) exec_docker '--start-cloudreve-v3' ;;
    stop) exec_docker '--stop-cloudreve-v3' ;;
    esac
}

function handler_cloudreve_v4() {
    handler_docker
    case "${1}" in
    install) exec_docker '--install-cloudreve-v4' ;;
    update) exec_docker '--update-cloudreve-v4' ;;
    purge) exec_docker '--purge-cloudreve-v4' ;;
    start) exec_docker '--start-cloudreve-v4' ;;
    stop) exec_docker '--stop-cloudreve-v4' ;;
    esac
}

# =============================================================================
# 函数名称: handler_web
# 功能描述: 配置 Web 服务 (Cloudreve) 与 Nginx 集成。
# =============================================================================
function handler_web() {
    local web="${1:-normal}"
    local domain=''
    local cdn=''

    domain="$(cfg 'nginx.domain')"
    cdn="$(cfg 'nginx.cdn')"

    case "${web}" in
    v3)
        handler_cloudreve_v4 'stop'
        handler_cloudreve_v3 'start'
        ;;
    v4)
        handler_cloudreve_v3 'stop'
        handler_cloudreve_v4 'start'
        ;;
    *)
        handler_cloudreve_v3 'stop'
        handler_cloudreve_v4 'stop'
        ;;
    esac

    if [[ -f "${NGINX_CONFIG_DIR}/sites-available/${domain}.conf" && -f "${NGINX_CONFIG_DIR}/sites-available/${cdn}.conf" ]]; then
        case "${web}" in
        v3 | v4)
            sed -i "s|# include web/cloudreve.conf;|include web/cloudreve.conf;|" "${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
            sed -i "s|# include web/cloudreve.conf;|include web/cloudreve.conf;|" "${NGINX_CONFIG_DIR}/sites-available/${cdn}.conf"
            sed -i "s|include web/normal.conf;|# include web/normal.conf;|" "${NGINX_CONFIG_DIR}/sites-available/${cdn}.conf"
            ;;
        *)
            sed -i "s|^\([[:space:]]*\)include web/cloudreve.conf;|\1# include web/cloudreve.conf;|" "${NGINX_CONFIG_DIR}/sites-available/${domain}.conf"
            sed -i "s|^\([[:space:]]*\)include web/cloudreve.conf;|\1# include web/cloudreve.conf;|" "${NGINX_CONFIG_DIR}/sites-available/${cdn}.conf"
            sed -i "s|# include web/normal.conf;|include web/normal.conf;|" "${NGINX_CONFIG_DIR}/sites-available/${cdn}.conf"
            ;;
        esac
    fi

    handler_nginx_restart
    handler_restart

    cfg_set '.nginx.web = $web' --arg web "${web}"
    persist_script_config || _error "failed to persist script config"
}

# =============================================================================
# 函数名称: handler_quick_install
# =============================================================================
function handler_quick_install() {
    local quick_install_type="${1:-Vision}"

    handler_script_config "${quick_install_type}"
    handler_install 'release'
    # 首次快速安装默认开启 BBR；用户主动关闭过 (.system.bbr=0) 则不再覆盖
    [[ -n "$(cfg 'system.bbr')" ]] || handler_bbr 'enable' || true
    handler_x25519_config
    handler_xray_config
    handler_geodata_cron 1
    handler_restart
    handler_share
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    load_i18n
    load_config

    local option="$1"
    shift

    case "${option}" in
    --quick) handler_quick_install "$1" ;;
    --install) handler_install "$@" ;;
    --version) handler_xray_version "$1" ;;
    --purge) handler_purge ;;
    --nginx-install) handler_nginx_install ;;
    --nginx-update) handler_nginx_update ;;
    --nginx-purge) handler_nginx_purge ;;
    --script-config)
        handler_read_xray_config "$1"
        handler_script_config
        ;;
    --xray-config)
        handler_sni_config "${1:-normal}"
        handler_x25519_config
        handler_xray_config
        ;;
    --sni-ports) handler_check_sni_ports ;;
    --routing) handler_routing "$@" ;;
    --change-domain)
        handler_change_domain "$1"
        handler_xray_config
        handler_restart
        if [[ "${CONFIG_DATA['only-change-domain'],,}" != 'y' ]]; then
            handler_web "$(cfg 'nginx.web')"
        fi
        ;;
    --renew-certificate) handler_renew_ssl ;;
    --web) handler_web "${1:-normal}" ;;
    --v3-reset) handler_cloudreve_v3 'reset' ;;
    --ca-server) handler_ca_server "$1" ;;
    --custom-sites) handler_custom_sites "$1" ;;
    --share) handler_share ;;
    --nginx-cron) handler_nginx_cron ;;
    --geodata-cron) handler_geodata_cron "${1:-0}" ;;
    --warp) handler_warp ;;
    --reset-warp) handler_reset_warp ;;
    --traffic) handler_traffic "${1:-show}" ;;
    --bbr) handler_bbr "${1:-status}" ;;
    --change-port)
        handler_change_xray_port
        handler_xray_config
        handler_restart
        handler_share
        ;;
    --change-address)
        handler_change_share_address
        handler_share
        ;;
    --ipv6-deploy) handler_ipv6_deploy "${1:-dual}" ;;
    --start) handler_start ;;
    --stop) handler_stop ;;
    --restart) handler_restart ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
