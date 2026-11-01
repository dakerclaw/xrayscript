#!/usr/bin/env bash
# =============================================================================
# 脚本名称: nginx.sh
# 功能描述: 从源码编译、安装、更新与卸载 Nginx，集成最新 OpenSSL，
#           可选 Brotli 压缩模块，并管理 systemd 服务。
# 依赖: bash, curl, wget, git, gcc, make, awk, grep, sed, sort, tr, systemctl, jq,
#       dnf/yum/apt
# 配置:
#   - ${TMPFILE_DIR}/: 编译临时目录
#   - ${NGINX_PATH}/: /usr/local/nginx
#   - ${NGINX_LOG_PATH}/: /var/log/nginx
#   - /etc/systemd/system/nginx.service
# 相关链接:
#   - https://nginx.org/en/linux_packages.html
#   - https://github.com/google/ngx_brotli
#
# =============================================================================

# --- 环境与常量设置 ---
# 统一取脚本自身目录 (兼容被 source、以及 Windows 盘符路径)
readonly CUR_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
readonly CUR_FILE="$(basename -- "${BASH_SOURCE[0]:-$0}" | sed 's/\..*//')"
readonly PROJECT_ROOT="$(cd -P -- "${CUR_DIR}/.." && pwd -P)"

# shellcheck source=core/common.sh
source "${PROJECT_ROOT}/core/common.sh"

readonly NGINX_PATH="/usr/local/nginx"
readonly NGINX_LOG_PATH="/var/log/nginx"

# 编译工作目录 (退出时清理)
readonly TMPFILE_DIR="$(mktemp -d -p "${PROJECT_ROOT}" -t nginxtemp.XXXXXXXX)" || exit 1

# --- 全局变量声明 ---
# 修正: 原脚本定义 IS_ENABLE_BROTLI 却使用 is_enable_brotli，导致 --brotli 永远不生效
declare IS_ENABLE_BROTLI=''
declare -a cflags=()
declare GCC_HELP_CACHE=''

# 操作系统要求 (由 common.sh 的 check_os 使用)
MIN_UBUNTU=20
MIN_DEBIAN=10
MIN_CENTOS=7

# =============================================================================
# 函数名称: egress
# 功能描述: 退出时清理临时目录 (含临时 swap)。
# =============================================================================
function egress() {
    if [[ -e "${TMPFILE_DIR}/swap" ]] && swapon --show 2>/dev/null | grep -q "${TMPFILE_DIR}/swap"; then
        swapoff "${TMPFILE_DIR}/swap" 2>/dev/null || true
    fi
    rm -rf "${TMPFILE_DIR}"
}

if [[ -z "${EGRESS_REGISTERED:-}" ]]; then
    trap egress EXIT
    EGRESS_REGISTERED=1
fi

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
# 函数名称: _error_detect
# 功能描述: 执行命令并检查返回码，失败时打印错误并退出。
# =============================================================================
function _error_detect() {
    local cmd="$1"
    _info "$(t compile.executing "cmd" "${cmd}")"
    eval "${cmd}"
    [[ $? -eq 0 ]] || _error "$(t compile.fail_exec_cmd "cmd" "${cmd}")"
}

# =============================================================================
# 函数名称: _version_ge
# 功能描述: 判断 $1 是否 >= $2。
# =============================================================================
function _version_ge() {
    local higher=''
    higher="$(printf '%s\n%s\n' "$1" "$2" | sort -rV | head -n 1)"
    [[ "${higher}" == "$1" && "$1" != "$2" ]] || [[ "$1" == "$2" ]]
}

# =============================================================================
# 函数名称: _install
# 功能描述: 按系统类型安装软件包 (一次性安装，减少包管理器开销)。
# =============================================================================
function _install() {
    local -a packages=("$@")
    local installed_packages=''
    local -a missing=()
    local package_name=''

    case "$(_os)" in
    centos)
        if cmd_exists "dnf"; then
            packages=("dnf-plugins-core" "epel-release" "${packages[@]}")
            installed_packages="$(dnf list installed 2>/dev/null)"
            if [[ -n "$(_os_ver)" && "$(_os_ver)" -eq 8 ]]; then
                if ! dnf module list 2>/dev/null | grep container-tools | grep -qw "\[x\]"; then
                    _error_detect "dnf module disable -y container-tools"
                fi
            fi
            for package_name in "${packages[@]}"; do
                echo "${installed_packages}" | grep -iwq "${package_name}" || missing+=("${package_name}")
            done
            [[ ${#missing[@]} -eq 0 ]] && return 0
            _error_detect "dnf install -y ${missing[*]}"
        else
            packages=("epel-release" "yum-utils" "${packages[@]}")
            installed_packages="$(yum list installed 2>/dev/null)"
            for package_name in "${packages[@]}"; do
                echo "${installed_packages}" | grep -iwq "${package_name}" || missing+=("${package_name}")
            done
            [[ ${#missing[@]} -eq 0 ]] && return 0
            _error_detect "yum install -y ${missing[*]}"
        fi
        ;;
    ubuntu | debian)
        installed_packages="$(apt list --installed 2>/dev/null)"
        for package_name in "${packages[@]}"; do
            echo "${installed_packages}" | grep -iwq "${package_name}" || missing+=("${package_name}")
        done
        [[ ${#missing[@]} -eq 0 ]] && return 0
        apt-get update -y >/dev/null 2>&1 || true
        _error_detect "apt-get install -y ${missing[*]}"
        ;;
    esac
}

# =============================================================================
# 函数名称: swap_on
# 功能描述: 创建并启用临时 swap。
# =============================================================================
function swap_on() {
    local mem="${1:-0}"

    [[ "${mem}" -ne 0 ]] || return 0
    dd if=/dev/zero of="${TMPFILE_DIR}/swap" bs=1M count="${mem}" >/dev/null 2>&1 || return 1
    chmod 0600 "${TMPFILE_DIR}/swap"
    mkswap "${TMPFILE_DIR}/swap" >/dev/null 2>&1
    swapon "${TMPFILE_DIR}/swap" 2>/dev/null || true
}

# =============================================================================
# 函数名称: backup_files
# =============================================================================
function backup_files() {
    local backup_dir="$1"
    local current_date=''
    local file=''
    local backup_file=''

    current_date="$(date +%F)"
    for file in "${backup_dir}/"*; do
        [[ -f "$file" ]] || continue
        backup_file="${backup_dir}/$(basename "$file")_${current_date}"
        mv "$file" "$backup_file"
        echo "$(t backup_files.backup): ${file} -> ${backup_file}"
    done
}

# =============================================================================
# 函数名称: compile_dependencies
# =============================================================================
function compile_dependencies() {
    _info "$(t compile.install_deps)"

    _install ca-certificates curl wget gcc make git openssl tzdata socat

    case "$(_os)" in
    centos)
        _install bind-utils gcc-c++ perl-IPC-Cmd perl-Getopt-Long perl-Data-Dumper perl-Time-Piece
        _install pcre2-devel zlib-devel libxml2-devel libxslt-devel gd-devel geoip-devel perl-ExtUtils-Embed gperftools-devel perl-devel brotli-devel
        perl -e "use FindBin" &>/dev/null || _install perl-FindBin
        ;;
    debian | ubuntu)
        _install dnsutils g++ perl-base perl
        _install libpcre2-dev zlib1g-dev libxml2-dev libxslt1-dev libgd-dev libgeoip-dev libgoogle-perftools-dev libperl-dev libbrotli-dev
        ;;
    esac
}

# =============================================================================
# 函数名称: gen_cflags
# 功能描述: 生成编译优化参数。
#           修正: gcc 帮助文本只取一次 (原实现循环调用 10+ 次)。
# =============================================================================
function gen_cflags() {
    cflags=('-g0' '-O3')

    # 缓存 gcc -v --help 输出，避免重复启动编译器
    if [[ -z "${GCC_HELP_CACHE}" ]]; then
        GCC_HELP_CACHE="$(gcc -v --help 2>&1)"
    fi

    has_flag() { echo "${GCC_HELP_CACHE}" | grep -qw "$1"; }

    has_flag '\-fstack\-reuse' && cflags+=('-fstack-reuse=all')
    has_flag '\-fdwarf2\-cfi\-asm' && cflags+=('-fdwarf2-cfi-asm')
    has_flag '\-fplt' && cflags+=('-fplt')
    has_flag '\-ftrapv' && cflags+=('-fno-trapv')

    if has_flag '\-fexceptions'; then
        cflags+=('-fno-exceptions')
    elif has_flag '\-fhandle\-exceptions'; then
        cflags+=('-fno-handle-exceptions')
    fi

    has_flag '\-funwind\-tables' && cflags+=('-fno-unwind-tables')
    has_flag '\-fasynchronous\-unwind\-tables' && cflags+=('-fno-asynchronous-unwind-tables')
    has_flag '\-fstack\-check' && cflags+=('-fno-stack-check')
    has_flag '\-fstack\-clash\-protection' && cflags+=('-fno-stack-clash-protection')
    has_flag '\-fstack\-protector' && cflags+=('-fno-stack-protector')
    has_flag '\-fcf\-protection=' && cflags+=('-fcf-protection=none')
    has_flag '\-fsplit\-stack' && cflags+=('-fno-split-stack')

    if has_flag '\-fsanitize'; then
        # 临时文件放在编译目录，失败也不会污染当前目录
        if printf '' >"${TMPFILE_DIR}/temp.c" && gcc -E -fno-sanitize=all "${TMPFILE_DIR}/temp.c" >/dev/null 2>&1; then
            cflags+=('-fno-sanitize=all')
        fi
    fi

    has_flag '\-finstrument\-functions' && cflags+=('-fno-instrument-functions')

    unset -f has_flag
}

# =============================================================================
# 函数名称: fetch_versions
# 功能描述: 获取最新 Nginx / OpenSSL 版本号。
# =============================================================================
function fetch_latest_versions() {
    local tags=''

    tags="$(wget -qO- --no-check-certificate --timeout=20 https://api.github.com/repos/nginx/nginx/tags 2>/dev/null)"
    LATEST_NGINX_VERSION="$(printf '%s' "${tags}" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4 | grep 'release' | head -1 | sed 's/release/nginx/')"

    tags="$(wget -qO- --no-check-certificate --timeout=20 https://api.github.com/repos/openssl/openssl/tags 2>/dev/null)"
    LATEST_OPENSSL_VERSION="openssl-$(printf '%s' "${tags}" | grep -o '"name": *"[^"]*"' | cut -d'"' -f4 | grep -Eoi '^openssl-([0-9]\.?){3}$' | head -1)"

    [[ -n "${LATEST_NGINX_VERSION}" ]] || _error "failed to fetch latest nginx version"
    [[ -n "${LATEST_OPENSSL_VERSION}" && "${LATEST_OPENSSL_VERSION}" != 'openssl-' ]] || _error "failed to fetch latest openssl version"
}

# =============================================================================
# 函数名称: configure_args
# 功能描述: 输出 ./configure 参数 (Brotli 按需追加)。
# =============================================================================
function configure_args() {
    local -a args=(
        "--prefix=${NGINX_PATH}"
        --user=root --group=root
        --with-threads --with-file-aio
        --with-http_ssl_module --with-http_v2_module --with-http_v3_module
        --with-http_realip_module --with-http_addition_module
        --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic
        --with-http_geoip_module=dynamic --with-http_sub_module
        --with-http_dav_module --with-http_flv_module --with-http_mp4_module
        --with-http_gunzip_module --with-http_gzip_static_module
        --with-http_auth_request_module --with-http_random_index_module
        --with-http_secure_link_module --with-http_degradation_module
        --with-http_slice_module --with-http_stub_status_module
        --with-http_perl_module=dynamic
        --with-mail=dynamic --with-mail_ssl_module
        --with-stream --with-stream_ssl_module --with-stream_realip_module
        --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module
        --with-google_perftools_module
        --with-compat
        "--with-cc-opt=${cflags[*]}"
        "--with-openssl=../${LATEST_OPENSSL_VERSION}"
        "--with-openssl-opt=${cflags[*]}"
    )

    if [[ "${IS_ENABLE_BROTLI}" =~ ^[Yy]$ ]]; then
        args+=("--add-module=../ngx_brotli")
    fi

    printf '%s\n' "${args[@]}"
}

# =============================================================================
# 函数名称: source_compile
# 功能描述: 下载源码并编译 Nginx。
# =============================================================================
function source_compile() {
    local -a args=()

    cd "${TMPFILE_DIR}" || _error "failed to enter tmp dir"

    _info "$(t compile.fetch_versions)"
    fetch_latest_versions
    gen_cflags

    _info "$(t compile.download_nginx)"
    _error_detect "curl -fsSL -o ${LATEST_NGINX_VERSION}.tar.gz https://nginx.org/download/${LATEST_NGINX_VERSION}.tar.gz"
    tar -zxf "${LATEST_NGINX_VERSION}.tar.gz" || _error "extract nginx failed"

    _info "$(t compile.download_openssl)"
    _error_detect "curl -fsSL -o ${LATEST_OPENSSL_VERSION}.tar.gz https://github.com/openssl/openssl/archive/${LATEST_OPENSSL_VERSION#*-}.tar.gz"
    tar -zxf "${LATEST_OPENSSL_VERSION}.tar.gz" || _error "extract openssl failed"

    if [[ "${IS_ENABLE_BROTLI}" =~ ^[Yy]$ ]]; then
        _info "$(t compile.fetch_brotli)"
        _error_detect "git clone --depth 1 https://github.com/google/ngx_brotli && cd ngx_brotli && git submodule update --init --depth 1"
        cd "${TMPFILE_DIR}" || _error "failed to enter tmp dir"
    fi

    cd "${LATEST_NGINX_VERSION}" || _error "failed to enter nginx source dir"

    # Perl 模块的优化参数调整
    sed -i "s/OPTIMIZE[ \\t]*=>[ \\t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    sed -i 's/NGX_PERL_CFLAGS="$CFLAGS `$NGX_PERL -MExtUtils::Embed -e ccopts`"/NGX_PERL_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf
    sed -i 's/NGX_PM_CFLAGS=`$NGX_PERL -MExtUtils::Embed -e ccopts`/NGX_PM_CFLAGS="`$NGX_PERL -MExtUtils::Embed -e ccopts` $CFLAGS"/g' auto/lib/perl/conf

    _info "$(t compile.configure)"
    mapfile -t args < <(configure_args)
    ./configure "${args[@]}" || _error "$(t compile.fail_exec_cmd "cmd" "./configure")"

    _info "$(t compile.swap)"
    swap_on 512

    _info "$(t compile.start_compile)"
    _error_detect "make -j$(cpu_count)"
}

# =============================================================================
# 函数名称: source_install
# =============================================================================
function source_install() {
    source_compile

    _info "$(t install.start_install)"
    make install || _error "make install failed"
    mkdir -p "${NGINX_LOG_PATH}"
    ln -sf "${NGINX_PATH}/sbin/nginx" /usr/sbin/nginx
}

# =============================================================================
# 函数名称: source_update
# 功能描述: 检查并平滑升级 Nginx。
# =============================================================================
function source_update() {
    local current_version_nginx=''
    local current_version_openssl=''

    _info "$(t update.fetch_versions)"
    fetch_latest_versions

    _info "$(t update.read_current_versions)"
    current_version_nginx="$(nginx -V 2>&1 | grep "^nginx version:.*" | cut -d / -f 2)"
    current_version_openssl="$(nginx -V 2>&1 | grep "^built with OpenSSL" | awk '{print $4}')"

    _info "$(t update.check_update)"
    if ! _version_ge "${LATEST_NGINX_VERSION#*-}" "${current_version_nginx}" ||
        ! _version_ge "${LATEST_OPENSSL_VERSION#*-}" "${current_version_openssl}"; then
        return 1
    fi

    source_compile

    _info "$(t update.start_update)"
    mv "${NGINX_PATH}/sbin/nginx" "${NGINX_PATH}/sbin/nginx_$(date +%F)"
    backup_files "${NGINX_PATH}/modules"
    cp objs/nginx "${NGINX_PATH}/sbin/"
    cp objs/*.so "${NGINX_PATH}/modules/" 2>/dev/null || true
    ln -sf "${NGINX_PATH}/sbin/nginx" /usr/sbin/nginx

    if systemctl is-active --quiet nginx; then
        _info "$(t update.smooth_upgrade)"
        kill -USR2 "$(cat /run/nginx.pid)"
        sleep 1
        if [[ -e "/run/nginx.pid.oldbin" ]]; then
            kill -WINCH "$(cat /run/nginx.pid.oldbin)"
            kill -HUP "$(cat /run/nginx.pid.oldbin)"
            kill -QUIT "$(cat /run/nginx.pid.oldbin)"
        else
            _info "$(t update.no_old_process)"
        fi
    fi
    return 0
}

# =============================================================================
# 函数名称: purge_nginx
# =============================================================================
function purge_nginx() {
    _info "$(t purge.start_purge)"
    systemctl stop nginx 2>/dev/null || true
    rm -rf "${NGINX_PATH}"
    rm -f /usr/sbin/nginx
    rm -f /etc/systemd/system/nginx.service
    rm -rf "${NGINX_LOG_PATH}"
    systemctl daemon-reload 2>/dev/null || true
    _info "$(t purge.purged)"
}

# =============================================================================
# 函数名称: systemctl_config_nginx
# =============================================================================
function systemctl_config_nginx() {
    _info "$(t service.configure)"

    cat >/etc/systemd/system/nginx.service <<EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
# 清理并创建共享内存目录用于 tcmalloc
ExecStartPre=/bin/rm -rf /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx
ExecStartPre=/bin/chmod 711 /dev/shm/nginx
ExecStartPre=/bin/mkdir /dev/shm/nginx/tcmalloc
ExecStartPre=/bin/chmod 0777 /dev/shm/nginx/tcmalloc
# 测试配置文件
ExecStartPre=/usr/sbin/nginx -t -q -g 'daemon on; master_process on;'
# 启动 Nginx
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
# 重载 Nginx
ExecReload=/usr/sbin/nginx -g 'daemon on; master_process on;' -s reload
# 停止 Nginx
ExecStop=/bin/kill -s QUIT \$MAINPID
# 停止后清理共享内存
ExecStopPost=/bin/rm -rf /dev/shm/nginx
TimeoutStopSec=5
KillMode=mixed
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    _info "$(t service.complete)"
}

# =============================================================================
# 函数名称: show_help
# =============================================================================
function show_help() {
    printf '%s\n' "$(t help.usage "script_name" "$0")"
    printf '%s:\n' "$(t help.options_title)"
    printf '  %-12s %s\n' "--install" "$(t help.opt_install)"
    printf '  %-12s %s\n' "--update" "$(t help.opt_update)"
    printf '  %-12s %s\n' "--brotli" "$(t help.opt_brotli)"
    printf '  %-12s %s\n' "--purge" "$(t help.opt_purge)"
    printf '  %-12s %s\n' "--help" "$(t help.opt_help)"
    exit 0
}

# =============================================================================
# 函数名称: main
# =============================================================================
function main() {
    load_i18n
    check_os

    local action=''

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --install | --update | --purge) action="${1#--}" ;;
        --brotli) IS_ENABLE_BROTLI='Y' ;;
        --help) show_help ;;
        *) _error "$(t main.invalid_option "option" "$1")" ;;
        esac
        shift
    done

    case "${action}" in
    install)
        compile_dependencies
        source_install
        systemctl_config_nginx
        ;;
    update)
        compile_dependencies
        source_update || true
        ;;
    purge)
        purge_nginx
        ;;
    esac
}

# --- 脚本执行入口 ---
main "$@"
