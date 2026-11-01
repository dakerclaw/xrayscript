#!/usr/bin/env bash
# =============================================================================
# 脚本名称: docker.sh
# 功能描述: Docker 环境管理：安装 Docker、管理 Cloudflare WARP 容器、
#           管理 Cloudreve (v3 / v4) 容器服务。
# 依赖: bash, jq, wget, sed, awk, grep, curl, openssl, docker, docker compose
# 配置:
#   - ${CONFIG_DIR}/cloudflare-warp/Dockerfile
#   - ${CLOUDREVE_V*_YAML_DIR}/docker-compose.yaml
#
# 参考:
#   - https://github.com/docker/docker-install
#   - https://github.com/haoel/haoel.github.io
#   - https://cloudreve.org
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')"
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)"

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

readonly DOCKER_DIR="${SCRIPT_CONFIG_DIR}/docker"
readonly WARP_DIR="${DOCKER_DIR}/cloudflare-warp"
readonly CLOUDREVE_V3_DIR="${DOCKER_DIR}/cloudreve/v3"
readonly CLOUDREVE_V3_YAML_DIR="${CONFIG_DIR}/cloudreve/v3"
readonly CLOUDREVE_V4_DIR="${DOCKER_DIR}/cloudreve/v4"
readonly CLOUDREVE_V4_YAML_DIR="${CONFIG_DIR}/cloudreve/v4"

# =============================================================================
# 函数名称: t
# 功能描述: 取本脚本的 i18n 文本，支持 ${name} 占位符替换。
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
# 函数名称: docker_compose
# 功能描述: 兼容 docker compose (v2) 与 docker-compose (v1)。
# 参数:
#   $1: 工作目录
#   $@: compose 子命令
# =============================================================================
function docker_compose() {
    local work_dir="$1"
    shift

    if docker compose version >/dev/null 2>&1; then
        (cd "${work_dir}" && docker compose "$@")
    else
        (cd "${work_dir}" && docker-compose "$@")
    fi
}

# =============================================================================
# 函数名称: container_running
# =============================================================================
function container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# =============================================================================
# 函数名称: install_docker
# 功能描述: 从官方脚本安装 Docker (CentOS 8 自动加 --allowerasing)。
# =============================================================================
function install_docker() {
    local script_path="${TOOL_DIR}/install-docker.sh"
    local url='https://get.docker.com'

    _info "$(t install.start)"

    mkdir -p "${TOOL_DIR}" || _error "failed to create tool dir"

    # 修正: 国内网络下 get.docker.com 可达性差，优先使用官方仓库镜像脚本
    if ! wget -q -O "${script_path}" "${url}"; then
        wget -q -O "${script_path}" "https://mirrors.aliyun.com/docker-ce/linux/static/install.sh" 2>/dev/null ||
            _error "failed to download docker install script"
    fi

    if [[ "$(_os)" == "centos" && "$(_os_ver)" == "8" ]]; then
        _info "$(t install.centos8_fix)"
        sed -i 's|$sh_c "$pkg_manager install -y -q $pkgs"| $sh_c "$pkg_manager install -y -q $pkgs --allowerasing"|' "${script_path}"
    fi

    _info "$(t install.dry_run)"
    sh "${script_path}" --dry-run || _error "docker dry-run failed"

    _info "$(t install.running)"
    sh "${script_path}" || _error "docker install failed"

    systemctl enable --now docker >/dev/null 2>&1 || true
}

# =============================================================================
# 函数名称: get_container_ip
# =============================================================================
function get_container_ip() {
    local container_name="$1"
    docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}" 2>/dev/null
}

# =============================================================================
# 函数名称: build_warp / enable_warp / disable_warp
# =============================================================================
function build_warp() {
    if ! docker images --format '{{.Repository}}' | grep -qx 'xrayscript-warp'; then
        _info "$(t warp.build.start)"
        docker build -t xrayscript-warp "${CONFIG_DIR}/cloudflare-warp" || _error "$(t warp.build.fail)"
    fi
}

function enable_warp() {
    local container_ip=''
    local msg=''

    if ! container_running 'xrayscript-warp'; then
        _info "$(t warp.enable.start)"
        mkdir -vp "${WARP_DIR}" >&2
        docker run -d --restart=always --name=xrayscript-warp \
            --log-driver json-file --log-opt max-size=100m --log-opt max-file=3 \
            -v "${WARP_DIR}":/var/lib/cloudflare-warp:rw xrayscript-warp >&2 ||
            _error "$(t warp.build.fail)"
        # 容器首次启动需要注册 WARP 账号，等待其就绪
        sleep 3
    fi

    container_ip="$(get_container_ip 'xrayscript-warp')"
    if [[ -n "${container_ip}" ]]; then
        msg="$(t warp.enable.success "container_ip" "${container_ip}")"
        _info "${msg}"
        echo "${container_ip}"
    fi
}

function disable_warp() {
    if container_running 'xrayscript-warp'; then
        _warn "$(t warp.disable.stop)"
        docker stop xrayscript-warp >/dev/null 2>&1
        docker rm xrayscript-warp >/dev/null 2>&1
        docker image rm xrayscript-warp >/dev/null 2>&1 || true
        rm -rf "${WARP_DIR}"
        _info "$(t warp.disable.success)"
    fi
}

# =============================================================================
# 函数名称: install_cloudreve_v3
# =============================================================================
function install_cloudreve_v3() {
    if container_running 'cloudreve_v3'; then
        return 0
    fi

    _info "$(t cloudreve_v3.create_dir)"
    mkdir -vp "${CLOUDREVE_V3_DIR}"/{uploads,avatar,aria2/config,data/aria2} || _error "failed to create cloudreve v3 dirs"
    touch "${CLOUDREVE_V3_DIR}/conf.ini" "${CLOUDREVE_V3_DIR}/cloudreve.db"
    chmod -R 777 "${CLOUDREVE_V3_DIR}/data/aria2"

    cp "${CLOUDREVE_V3_YAML_DIR}/docker-compose.yaml" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
    sed -i "s|cloudreve:$|cloudreve_v3:|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
    sed -i "s|container_name: cloudreve|container_name: cloudreve_v3|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
    sed -i "s|/usr/local/cloudreve|${CLOUDREVE_V3_DIR}|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"
    sed -i "s|your_aria_rpc_token|$(openssl rand -hex 32)|" "${CLOUDREVE_V3_DIR}/docker-compose.yaml"

    _info "$(t cloudreve_v3.start)"
    docker_compose "${CLOUDREVE_V3_DIR}" up -d || _error "cloudreve v3 start failed"
    sleep 5
    get_cloudreve_v3_admin
    get_aria2_token
}

# =============================================================================
# 函数名称: get_cloudreve_v3_admin / get_aria2_token
# =============================================================================
function get_cloudreve_v3_admin() {
    local cloudreve_info=''
    local cloudreve_username=''
    local cloudreve_password=''
    local msg=''

    container_running 'cloudreve_v3' || return 0

    cloudreve_info="$(docker logs cloudreve_v3 2>&1 | head -n 20)"
    cloudreve_username="$(echo "${cloudreve_info}" | grep Admin | awk '{print $NF}' | head -1)"
    cloudreve_password="$(echo "${cloudreve_info}" | grep Admin | awk '{print $NF}' | tail -1)"
    msg="$(t cloudreve_v3.admin_info "username" "${cloudreve_username}" "password" "${cloudreve_password}")"
    _info "${msg}"
}

function get_aria2_token() {
    local token=''
    local msg=''

    token="$(sed -n 's/.*RPC_SECRET=//p' "${CLOUDREVE_V3_DIR}/docker-compose.yaml")"
    msg="$(t cloudreve_v3.aria2_token "token" "${token}")"
    _info "${msg}"
}

# =============================================================================
# 函数名称: reset_cloudreve_v3_admin
# =============================================================================
function reset_cloudreve_v3_admin() {
    container_running 'cloudreve_v3' || return 0

    _info "$(t cloudreve_v3.reset)"
    docker_compose "${CLOUDREVE_V3_DIR}" down
    rm -rf "${CLOUDREVE_V3_DIR}/cloudreve.db"
    touch "${CLOUDREVE_V3_DIR}/cloudreve.db"
    docker_compose "${CLOUDREVE_V3_DIR}" up -d
    sleep 5
    get_cloudreve_v3_admin
}

# =============================================================================
# 函数名称: purge_cloudreve_v3
# =============================================================================
function purge_cloudreve_v3() {
    container_running 'cloudreve_v3' || return 0

    _warn "$(t cloudreve_v3.purge)"
    docker_compose "${CLOUDREVE_V3_DIR}" down -v 2>/dev/null || docker_compose "${CLOUDREVE_V3_DIR}" down
    rm -rf "${CLOUDREVE_V3_DIR}"
}

# =============================================================================
# 函数名称: start_cloudreve_v3 / stop_cloudreve_v3
# =============================================================================
function start_cloudreve_v3() {
    container_running 'cloudreve_v3' && return 0

    if [[ -d "${CLOUDREVE_V3_DIR}" ]]; then
        _info "$(t cloudreve_v3.start_service)"
        docker_compose "${CLOUDREVE_V3_DIR}" up -d
    else
        _info "$(t cloudreve_v3.install_fallback)"
        install_cloudreve_v3
    fi
}

function stop_cloudreve_v3() {
    container_running 'cloudreve_v3' || return 0
    _warn "$(t cloudreve_v3.stop)"
    docker_compose "${CLOUDREVE_V3_DIR}" down
}

# =============================================================================
# 函数名称: Cloudreve v4
# =============================================================================
function install_cloudreve_v4() {
    container_running 'cloudreve_v4' && return 0

    _info "$(t cloudreve_v4.create_dir)"
    mkdir -vp "${CLOUDREVE_V4_DIR}"
    cp "${CLOUDREVE_V4_YAML_DIR}/docker-compose.yaml" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"
    sed -i "s|cloudreve:$|cloudreve_v4:|" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"
    sed -i "s|container_name: cloudreve-backend|container_name: cloudreve_v4|" "${CLOUDREVE_V4_DIR}/docker-compose.yaml"

    _info "$(t cloudreve_v4.start)"
    docker_compose "${CLOUDREVE_V4_DIR}" up -d || _error "cloudreve v4 start failed"
}

function update_cloudreve_v4() {
    container_running 'cloudreve_v4' || return 0
    _info "$(t cloudreve_v4.update)"
    docker_compose "${CLOUDREVE_V4_DIR}" pull
    docker_compose "${CLOUDREVE_V4_DIR}" up -d
}

function purge_cloudreve_v4() {
    container_running 'cloudreve_v4' || return 0
    _warn "$(t cloudreve_v4.purge)"
    docker_compose "${CLOUDREVE_V4_DIR}" down -v 2>/dev/null || docker_compose "${CLOUDREVE_V4_DIR}" down
    rm -rf "${CLOUDREVE_V4_DIR}"
}

function start_cloudreve_v4() {
    container_running 'cloudreve_v4' && return 0

    if [[ -d "${CLOUDREVE_V4_DIR}" ]]; then
        _info "$(t cloudreve_v4.start_service)"
        docker_compose "${CLOUDREVE_V4_DIR}" up -d
    else
        _info "$(t cloudreve_v4.install_fallback)"
        install_cloudreve_v4
    fi
}

function stop_cloudreve_v4() {
    container_running 'cloudreve_v4' || return 0
    _warn "$(t cloudreve_v4.stop)"
    docker_compose "${CLOUDREVE_V4_DIR}" down
}

# =============================================================================
# 函数名称: clean_container_logs / obtain_container_ip
# =============================================================================
function clean_container_logs() {
    local container_name_or_id="${1:-xrayscript-warp}"
    local log_path=''

    log_path="$(docker inspect --format='{{.LogPath}}' "${container_name_or_id}" 2>/dev/null)"
    [[ -n "${log_path}" && -f "${log_path}" ]] || return 0
    truncate -s 0 "${log_path}"
}

function obtain_container_ip() {
    local container_name="${1:-xrayscript-warp}"
    local container_ip=''

    container_ip="$(get_container_ip "${container_name}")"
    [[ -n "${container_ip}" ]] && echo "${container_ip}"
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    load_i18n

    case "${1,,}" in
    --install) install_docker ;;
    --build-warp) build_warp ;;
    --enable-warp) enable_warp ;;
    --disable-warp) disable_warp ;;
    --install-cloudreve-v3) install_cloudreve_v3 ;;
    --get-cloudreve-v3-admin) get_cloudreve_v3_admin ;;
    --get-aria2-token) get_aria2_token ;;
    --reset-cloudreve-v3-admin) reset_cloudreve_v3_admin ;;
    --purge-cloudreve-v3) purge_cloudreve_v3 ;;
    --start-cloudreve-v3) start_cloudreve_v3 ;;
    --stop-cloudreve-v3) stop_cloudreve_v3 ;;
    --install-cloudreve-v4) install_cloudreve_v4 ;;
    --update-cloudreve-v4) update_cloudreve_v4 ;;
    --purge-cloudreve-v4) purge_cloudreve_v4 ;;
    --start-cloudreve-v4) start_cloudreve_v4 ;;
    --stop-cloudreve-v4) stop_cloudreve_v4 ;;
    --clean-container-logs) clean_container_logs "${2:-}" ;;
    --obtain-container-ip) obtain_container_ip "${2:-}" ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
