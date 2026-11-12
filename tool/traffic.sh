#!/usr/bin/env bash
# =============================================================================
# 脚本名称: traffic.sh
# 功能描述: 通过 Xray Stats API 查询/清空流量统计，并按入站/出站/用户汇总。
#           依赖: bash, xray, awk, sort, numfmt, column
# 用法:
#   bash traffic.sh [--show]   显示累计流量
#   bash traffic.sh --reset    显示并清零累计流量
# =============================================================================

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-}"
export PATH

_APISERVER=127.0.0.1:32768
_XRAY=/usr/local/bin/xray

apidata() {
    local ARGS=()
    local RAW=''

    if [[ "${1:-}" == "reset" ]]; then
        ARGS=("-reset=true")
    fi

    # 统计被关闭或 Xray 未运行时 statsquery 会失败，交由调用方提示
    RAW="$("$_XRAY" api statsquery --server="$_APISERVER" "${ARGS[@]}" 2>&1)" || return 1

    printf '%s\n' "${RAW}" |
        awk '{
        if (match($1, /"name":/)) {
            f=1; gsub(/^"|link"|,$/, "", $2);
            split($2, p,  ">>>");
            printf "%s:%s->%s\t", p[1],p[2],p[4];
        }
        else if (match($1, /"value":/) && f){
          f = 0;
          gsub(/"/, "", $2);
          printf "%.0f\n", $2;
        }
        else if (match($0, /}/) && f) { f = 0; print 0; }
    }'
}

print_sum() {
    local DATA="$1"
    local PREFIX="$2"
    local SORTED=""
    local SUM=""

    SORTED=$(printf '%s\n' "$DATA" | grep "^${PREFIX}" | sort -r)
    SUM=$(printf '%s\n' "$SORTED" | awk '
        /->up/{us+=$2}
        /->down/{ds+=$2}
        END{
            printf "SUM->up:\t%.0f\nSUM->down:\t%.0f\nSUM->TOTAL:\t%.0f\n", us, ds, us+ds;
        }')

    # numfmt / column 为可选依赖，缺失时退回原始输出
    if command -v numfmt >/dev/null 2>&1; then
        SORTED=$(printf '%s\n' "$SORTED" | numfmt --field=2 --suffix=B --to=iec 2>/dev/null || printf '%s\n' "$SORTED")
        SUM=$(printf '%s\n' "$SUM" | numfmt --field=2 --suffix=B --to=iec 2>/dev/null || printf '%s\n' "$SUM")
    fi

    if command -v column >/dev/null 2>&1; then
        printf '%s\n%s\n' "${SORTED}" "${SUM}" | column -t
    else
        printf '%s\n%s\n' "${SORTED}" "${SUM}"
    fi
}

case "${1:-}" in
--show | '') API_ARG='' ;;
--reset | reset) API_ARG='reset' ;;
*)
    echo "usage: $0 [--show|--reset]" >&2
    exit 1
    ;;
esac

if ! DATA="$(apidata "${API_ARG}")"; then
    echo 'traffic: failed to query stats (statistics disabled or xray not running)' >&2
    exit 1
fi

echo "------------Inbound----------"
print_sum "$DATA" "inbound"
echo "-----------------------------"
echo "------------Outbound----------"
print_sum "$DATA" "outbound"
echo "-----------------------------"
echo
echo "-------------User------------"
print_sum "$DATA" "user"
echo "-----------------------------"
