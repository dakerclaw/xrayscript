#!/usr/bin/env bash
# =============================================================================
# CI 校验: i18n 中英键一致性 + shell 语法检查
# 用法: bash .github/scripts/check.sh
# 退出码: 0 通过, 1 发现问题
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
ROOT="$(pwd)"
rc=0

echo "== 1. i18n 键一致性 =="
if command -v jq >/dev/null 2>&1; then
    zh_keys="$(jq -r 'paths(scalars) | join(".")' i18n/zh.json | sort)"
    en_keys="$(jq -r 'paths(scalars) | join(".")' i18n/en.json | sort)"

    only_zh="$(comm -23 <(printf '%s\n' "${zh_keys}") <(printf '%s\n' "${en_keys}"))"
    only_en="$(comm -13 <(printf '%s\n' "${zh_keys}") <(printf '%s\n' "${en_keys}"))"

    if [[ -n "${only_zh}" ]]; then
        echo "以下键仅存在于 zh.json:"
        printf '  - %s\n' ${only_zh}
        rc=1
    fi
    if [[ -n "${only_en}" ]]; then
        echo "以下键仅存在于 en.json:"
        printf '  - %s\n' ${only_en}
        rc=1
    fi
    [[ ${rc} -eq 0 ]] && echo "  keys: $(printf '%s\n' "${zh_keys}" | wc -l) 个, 中英一致"
else
    echo "  [跳过] 未找到 jq"
fi

echo
echo "== 2. shell 语法检查 (bash -n) =="
while IFS= read -r f; do
    # 语法错误日志放本地临时文件 (不写 /tmp 之外的固定路径)
    if bash -n "${f}" 2>"${f}.synerr"; then
        echo "  OK   ${f#${ROOT}/}"
        rm -f "${f}.synerr"
    else
        echo "  FAIL ${f#${ROOT}/}"
        sed 's/^/       /' "${f}.synerr"
        rm -f "${f}.synerr"
        rc=1
    fi
done < <(find . -name '*.sh' -not -path './.git/*' | sort)

echo
echo "== 3. JSON 合法性 =="
if command -v jq >/dev/null 2>&1; then
    while IFS= read -r f; do
        if jq empty "${f}" 2>/dev/null; then
            echo "  OK   ${f#${ROOT}/}"
        else
            echo "  FAIL ${f#${ROOT}/}"
            rc=1
        fi
    done < <(find . -name '*.json' -not -path './.git/*' | sort)
fi

echo
if [[ ${rc} -eq 0 ]]; then
    echo "ALL CHECKS PASSED"
else
    echo "CHECKS FAILED"
fi
exit ${rc}
