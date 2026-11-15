#!/usr/bin/env bash
#
# Static checks on the message tables:
#   1. MSG_EN and MSG_ZH must expose exactly the same keys.
#   2. Every key must be referenced by a log_*/msg call, and every referenced
#      key must exist in the tables.
#
# 消息表静态检查：
#   1. MSG_EN 与 MSG_ZH 的键必须完全一致。
#   2. 每个键都必须被 log_*/msg 引用，被引用的键也必须存在。
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

# Declared separately: "readonly x=$(cmd)" would mask a failing command.
# 分开声明：readonly 与命令替换写在一行会掩盖命令的失败。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TARGET="${SCRIPT_DIR}/../setup-swap-bbr.sh"

failures=0

fail() {
    printf 'FAIL %s\n' "$1"
    failures=$((failures + 1))
}

pass() {
    printf 'ok   %s\n' "$1"
}

if [ ! -r "$TARGET" ]; then
    printf 'FAIL cannot read %s\n' "$TARGET" >&2
    exit 1
fi

# Print the [key]= entries that belong to one table.
extract_keys() {
    awk -v table="$1" '
        $0 ~ "^declare -A " table "=" { inside = 1; next }
        inside && /^\)/ { inside = 0; next }
        inside && /^[[:space:]]+\[[A-Za-z0-9_]+\]=/ {
            line = $0
            sub(/^[[:space:]]+\[/, "", line)
            sub(/\]=.*/, "", line)
            print line
        }
    ' "$TARGET"
}

en_keys=$(extract_keys MSG_EN | sort)
zh_keys=$(extract_keys MSG_ZH | sort)

if [ -z "$en_keys" ]; then
    printf 'FAIL no MSG_EN keys found, the parser or the table layout changed\n' >&2
    exit 1
fi

if [ "$en_keys" = "$zh_keys" ]; then
    pass "MSG_EN and MSG_ZH expose the same $(printf '%s\n' "$en_keys" | wc -l) keys"
else
    fail 'MSG_EN and MSG_ZH differ'
    diff <(printf '%s\n' "$en_keys") <(printf '%s\n' "$zh_keys") || true
fi

# Tokens used right after a logging call, e.g. "log_warn warn_no_flock".
used_keys=$(
    grep -oE '(log_ok|log_info|log_warn|log_error|msg)[[:space:]]+[a-z][a-z0-9_]+' "$TARGET" |
        awk '{ print $2 }' |
        sort -u
)

unused=$(comm -23 <(printf '%s\n' "$en_keys") <(printf '%s\n' "$used_keys"))
missing=$(comm -13 <(printf '%s\n' "$en_keys") <(printf '%s\n' "$used_keys"))

if [ -z "$unused" ]; then
    pass 'every message key is referenced'
else
    fail 'defined but never used:'
    printf '%s\n' "$unused" | sed 's/^/       /'
fi

if [ -z "$missing" ]; then
    pass 'every referenced key is defined'
else
    fail 'referenced but not defined:'
    printf '%s\n' "$missing" | sed 's/^/       /'
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%d check(s) failed\n' "$failures" >&2
    exit 1
fi

printf '\nall message checks passed\n'
