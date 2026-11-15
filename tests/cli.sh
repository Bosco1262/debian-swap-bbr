#!/usr/bin/env bash
#
# Root-free command line checks. Every case below is handled before the root
# check, so the suite runs on any Linux box, on macOS and on Git Bash, without
# privileges and without a Debian host.
#
# 无 root 依赖的命令行检查。下列用例都在 root 检查之前处理，
# 因此可以在任意 Linux、macOS 或 Git Bash 上运行，无需特权，也不要求 Debian。
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

# Declared separately: "readonly x=$(cmd)" would mask a failing command.
# 分开声明：readonly 与命令替换写在一行会掩盖命令的失败。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TARGET="${SCRIPT_DIR}/../setup-swap-bbr.sh"

# Resolve bash once so the suite does not depend on the executable bit.
BASH_BIN="$(command -v bash)"
readonly BASH_BIN

passes=0
failures=0

pass() {
    printf 'ok   %s\n' "$1"
    passes=$((passes + 1))
}

fail() {
    printf 'FAIL %s\n' "$1"
    failures=$((failures + 1))
}

# expect_exit <expected status> <argument...>
expect_exit() {
    local expected="$1"
    shift

    local status=0
    local output

    output=$("$BASH_BIN" "$TARGET" "$@" 2>&1) || status=$?

    if [ "$status" -eq "$expected" ]; then
        pass "exit $status: $*"
    else
        fail "exit $status (want $expected): $*"
        printf '%s\n' "$output" | sed 's/^/       /'
    fi
}

# expect_output <expected status> <needle> <argument...>
expect_output() {
    local expected="$1"
    local needle="$2"
    shift 2

    local status=0
    local output

    output=$("$BASH_BIN" "$TARGET" "$@" 2>&1) || status=$?

    if [ "$status" -ne "$expected" ]; then
        fail "exit $status (want $expected): $*"
        return 0
    fi

    case "$output" in
        *"$needle"*)
            pass "output contains '$needle': $*"
            ;;
        *)
            fail "output does not contain '$needle': $*"
            ;;
    esac
}

# 1. Help and version are available without root.
expect_output 0 'Usage:' --help
expect_output 0 '用法：' --lang zh-CN --help
expect_output 0 'setup-swap-bbr.sh' --version
expect_output 0 'setup-swap-bbr.sh' --lang en --version

# 2. Argument errors exit with 2.
expect_exit 2 --swap-size 0
expect_exit 2 --swap-size 33
expect_exit 2 --swap-size=33
expect_exit 2 --swap-size abc
expect_exit 2 --swap-size 1.5
expect_exit 2 --swap-size
expect_exit 2 --swap-size=
expect_exit 2 --lang fr
expect_exit 2 --lang
expect_exit 2 --restore --swap-size 2
expect_exit 2 --no-such-option

# 3. A leading zero is decimal, not octal: 08 is a valid size, so parsing must
#    move past the argument check and stop at the root check instead of
#    reporting "must be an integer".
if [ "${EUID}" -ne 0 ]; then
    expect_exit 1 --swap-size 08 --dry-run
    expect_exit 1 --dry-run
fi

# 4. On an argument error the help text belongs to stderr, so a caller who
#    redirects stdout to a file does not capture the usage text.
status=0
stderr_only=$("$BASH_BIN" "$TARGET" --no-such-option 2>&1 >/dev/null) || status=$?

if [ "$status" -ne 2 ]; then
    fail "unknown option exits $status (want 2)"
else
    case "$stderr_only" in
        *'Usage:'* | *'用法：'*)
            pass 'usage text is written to stderr on an argument error'
            ;;
        *)
            fail 'usage text was not written to stderr on an argument error'
            ;;
    esac
fi

printf '\n%d passed, %d failed\n' "$passes" "$failures"

if [ "$failures" -ne 0 ]; then
    exit 1
fi
