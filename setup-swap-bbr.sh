#!/usr/bin/env bash

# Debian Swap and BBR Setup
# Repository: https://github.com/YOUR_USERNAME/debian-swap-bbr
#
# 功能：
#   1. 检查 Debian 系统和 root 权限
#   2. 已有 Swap 时保留现有配置
#   3. 没有 Swap 时自动创建 /swapfile
#   4. 根据内存自动决定 Swap 大小
#   5. 启用 Debian 内核自带的标准 BBR
#   6. 支持重复执行，不重复写入配置
#
# 本脚本不会：
#   1. 修改 SSH 配置
#   2. 修改防火墙
#   3. 安装 XanMod 或其他第三方内核
#   4. 删除现有 Swap
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 022

readonly SCRIPT_NAME="${0##*/}"
readonly SWAPFILE="/swapfile"
readonly FSTAB="/etc/fstab"
readonly SWAP_CONFIG="/etc/sysctl.d/90-local-swap.conf"
readonly BBR_CONFIG="/etc/sysctl.d/90-local-bbr.conf"
readonly BBR_MODULE_CONFIG="/etc/modules-load.d/bbr.conf"

SWAP_SIZE_GB=0
SWAP_CREATED=0
BBR_CONFIGURED=0

if [ -t 1 ]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[0;33m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly CYAN=''
    readonly NC=''
fi

log_ok() {
    printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"
}

log_info() {
    printf '%b[INFO]%b %s\n' "$CYAN" "$NC" "$*"
}

log_warn() {
    printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2
}

log_error() {
    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2
}

handle_error() {
    local exit_code=$?
    local line_number=${1:-unknown}

    log_error "脚本在第 ${line_number} 行执行失败，退出码：${exit_code}"
    log_error "请检查上方输出信息。"

    exit "$exit_code"
}

trap 'handle_error "$LINENO"' ERR

show_usage() {
    cat <<EOF
用法：
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --swap-size 2
  sudo ./${SCRIPT_NAME} --swap-size 4
  ./${SCRIPT_NAME} --help

参数：
  --swap-size N    指定 Swap 大小，单位为 GiB，范围 1 到 32
                   未指定时根据物理内存自动选择
  -h, --help       显示帮助信息

自动 Swap 规则：
  内存不超过 4 GiB：创建 2 GiB Swap
  内存超过 4 GiB：创建 4 GiB Swap

注意：
  如果系统已经启用了任何 Swap，脚本会保留现有 Swap，
  不会再创建新的 /swapfile。
EOF
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --swap-size)
                if [ "$#" -lt 2 ]; then
                    log_error "--swap-size 后面必须提供一个整数。"
                    exit 2
                fi

                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "Swap 大小必须是整数，单位为 GiB。"
                    exit 2
                fi

                if (( "$2" < 1 || "$2" > 32 )); then
                    log_error "Swap 大小必须在 1 到 32 GiB 之间。"
                    exit 2
                fi

                SWAP_SIZE_GB="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数：$1"
                show_usage
                exit 2
                ;;
        esac
    done
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error "请以 root 身份运行此脚本。"
        log_error "示例：sudo ./${SCRIPT_NAME}"
        exit 1
    fi
}

check_operating_system() {
    if [ ! -r /etc/os-release ]; then
        log_error "无法读取 /etc/os-release，不能识别操作系统。"
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    if [ "${ID:-}" != "debian" ]; then
        log_error "此脚本仅支持 Debian。"
        log_error "当前系统：${PRETTY_NAME:-未知}"
        exit 1
    fi

    log_ok "检测到系统：${PRETTY_NAME}"
}

check_required_commands() {
    local missing_commands=()
    local command_name

    for command_name in \
        awk \
        cp \
        date \
        df \
        free \
        grep \
        lsmod \
        chmod \
        mkswap \
        modprobe \
        swapon \
        sysctl
    do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            missing_commands+=("$command_name")
        fi
    done

    if [ "${#missing_commands[@]}" -gt 0 ]; then
        log_error "缺少必要命令：${missing_commands[*]}"
        log_error "可尝试执行以下命令安装依赖："
        log_error "apt-get update && apt-get install -y util-linux procps kmod coreutils"
        exit 1
    fi

    log_ok "必要命令检查通过。"
}

get_memory_mb() {
    awk '/MemTotal:/ {printf "%d\n", $2 / 1024}' /proc/meminfo
}

calculate_swap_size() {
    local memory_mb

    if [ "$SWAP_SIZE_GB" -gt 0 ]; then
        log_info "使用用户指定的 Swap 大小：${SWAP_SIZE_GB} GiB"
        return
    fi

    memory_mb=$(get_memory_mb)

    if [ "$memory_mb" -le 4096 ]; then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=4
    fi

    log_info "检测到物理内存约为 ${memory_mb} MiB。"
    log_info "自动选择 ${SWAP_SIZE_GB} GiB Swap。"
}

write_swap_sysctl() {
    cat > "$SWAP_CONFIG" <<'EOF'
# Managed by debian-swap-bbr
# Lower values reduce preference for swapping application memory.
vm.swappiness=10

# Keep filesystem metadata cache available for longer.
vm.vfs_cache_pressure=50
EOF

    chmod 644 "$SWAP_CONFIG"
    sysctl -q -p "$SWAP_CONFIG"

    log_ok "Swap 内核参数已经写入 ${SWAP_CONFIG}。"
}

get_active_swap() {
    swapon --show=NAME --noheadings 2>/dev/null |
        awk 'NF {print $1; exit}'
}

check_disk_space() {
    local available_kb
    local required_kb
    local reserve_kb

    available_kb=$(df --output=avail -k / | awk 'NR == 2 {print $1}')
    required_kb=$((SWAP_SIZE_GB * 1024 * 1024))

    # 创建 Swap 后至少为根分区保留 1 GiB 可用空间。
    reserve_kb=$((1024 * 1024))

    if [ -z "$available_kb" ] || ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        log_error "无法读取根分区可用空间。"
        return 1
    fi

    if [ "$available_kb" -lt $((required_kb + reserve_kb)) ]; then
        log_error "磁盘空间不足，无法安全创建 ${SWAP_SIZE_GB} GiB Swap。"
        log_error "当前根分区可用空间约为 $((available_kb / 1024)) MiB。"
        log_error "脚本要求创建完成后至少保留 1024 MiB 可用空间。"
        return 1
    fi

    log_ok "磁盘空间检查通过。"
}

is_swap_signature() {
    local signature

    if ! command -v blkid >/dev/null 2>&1; then
        log_error "缺少 blkid 命令，无法安全验证现有 /swapfile。"
        return 1
    fi

    signature=$(blkid -o value -s TYPE "$SWAPFILE" 2>/dev/null || true)

    [ "$signature" = "swap" ]
}

create_swapfile() {
    log_info "正在创建 ${SWAP_SIZE_GB} GiB Swap 文件。"

    if command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"; then
            log_warn "fallocate 创建失败，将改用 dd。"
            rm -f "$SWAPFILE"

            dd \
                if=/dev/zero \
                of="$SWAPFILE" \
                bs=1M \
                count=$((SWAP_SIZE_GB * 1024)) \
                status=progress
        fi
    else
        log_warn "系统没有 fallocate，将使用 dd 创建 Swap 文件。"

        dd \
            if=/dev/zero \
            of="$SWAPFILE" \
            bs=1M \
            count=$((SWAP_SIZE_GB * 1024)) \
            status=progress
    fi

    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    SWAP_CREATED=1

    log_ok "Swap 文件创建完成。"
}

ensure_fstab_entry() {
    local backup_file

    if grep -qE '^/swapfile[[:space:]]+none[[:space:]]+swap([[:space:]]|$)' "$FSTAB"; then
        log_info "${FSTAB} 已经包含 /swapfile，无需重复写入。"
        return
    fi

    backup_file="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FSTAB" "$backup_file"

    printf '%s\n' '/swapfile none swap sw 0 0' >> "$FSTAB"

    log_ok "已经将 /swapfile 写入 ${FSTAB}。"
    log_info "fstab 备份位置：${backup_file}"
}

configure_swap() {
    local active_swap

    active_swap=$(get_active_swap)

    if [ -n "$active_swap" ]; then
        log_info "系统已经启用 Swap：${active_swap}"
        log_info "脚本将保留现有 Swap，不创建新的 /swapfile。"

        write_swap_sysctl
        return 0
    fi

    calculate_swap_size
    check_disk_space

    if [ -e "$SWAPFILE" ]; then
        log_warn "${SWAPFILE} 已存在，但当前没有启用。"

        if is_swap_signature; then
            log_info "${SWAPFILE} 具有有效的 Swap 签名，将直接启用。"
        else
            log_error "${SWAPFILE} 已存在，但不能确认它是 Swap 文件。"
            log_error "为避免覆盖重要数据，脚本不会修改或删除该文件。"
            return 1
        fi
    else
        create_swapfile
    fi

    chmod 600 "$SWAPFILE"
    swapon "$SWAPFILE"

    ensure_fstab_entry
    write_swap_sysctl

    log_ok "Swap 配置完成。"
}

detect_virtualization() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt 2>/dev/null || true
    else
        printf '%s\n' "unknown"
    fi
}

configure_bbr() {
    local virtualization
    local available_cc
    local current_cc
    local current_qdisc

    virtualization=$(detect_virtualization)

    if command -v systemd-detect-virt >/dev/null 2>&1 &&
       systemd-detect-virt --container >/dev/null 2>&1; then
        log_warn "检测到容器环境：${virtualization}"
        log_warn "LXC、OpenVZ 或其他容器可能不能自行加载 BBR 模块。"
        log_warn "脚本将继续检查宿主机是否已经提供 BBR。"
    else
        log_info "虚拟化环境：${virtualization}"
    fi

    if ! modprobe tcp_bbr 2>/dev/null; then
        log_warn "无法加载 tcp_bbr 模块。"
        log_warn "可能是容器限制，或者当前内核不包含 BBR。"
    fi

    available_cc=$(
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null ||
            true
    )

    if ! grep -qw 'bbr' <<< "$available_cc"; then
        log_error "当前内核没有提供 BBR。"
        log_error "可用拥塞控制算法：${available_cc:-无法读取}"
        log_error "脚本不会安装第三方内核。"
        return 1
    fi

    printf '%s\n' 'tcp_bbr' > "$BBR_MODULE_CONFIG"
    chmod 644 "$BBR_MODULE_CONFIG"

    cat > "$BBR_CONFIG" <<'EOF'
# Managed by debian-swap-bbr
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    chmod 644 "$BBR_CONFIG"
    sysctl -q -p "$BBR_CONFIG"

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)

    if [ "$current_cc" != "bbr" ]; then
        log_error "BBR 配置已写入，但当前拥塞控制算法不是 bbr。"
        log_error "当前算法：${current_cc:-无法读取}"
        return 1
    fi

    if [ "$current_qdisc" != "fq" ]; then
        log_warn "BBR 已启用，但当前默认队列算法不是 fq。"
        log_warn "当前队列算法：${current_qdisc:-无法读取}"
    fi

    BBR_CONFIGURED=1
    log_ok "标准 BBR 已经启用。"
}

show_result() {
    local available_cc
    local current_cc
    local current_qdisc

    available_cc=$(
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null ||
            printf '%s' "未知"
    )

    current_cc=$(
        sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null ||
            printf '%s' "未知"
    )

    current_qdisc=$(
        sysctl -n net.core.default_qdisc 2>/dev/null ||
            printf '%s' "未知"
    )

    echo
    printf '%s\n' "================ 配置结果 ================"

    echo
    printf '%s\n' "[Swap]"
    swapon --show || true
    free -h

    echo
    printf '%s\n' "[BBR]"
    printf '可用算法：%s\n' "$available_cc"
    printf '当前算法：%s\n' "$current_cc"
    printf '默认队列：%s\n' "$current_qdisc"

    if lsmod | grep -q '^tcp_bbr'; then
        printf 'BBR 模块：已加载\n'
    else
        printf '%s\n' \
            "BBR 模块：未在 lsmod 中显示，可能已编译进内核或受到容器限制"
    fi

    echo
    printf '%s\n' "[配置文件]"
    printf 'Swap 参数：%s\n' "$SWAP_CONFIG"
    printf 'BBR 参数：%s\n' "$BBR_CONFIG"
    printf 'BBR 模块：%s\n' "$BBR_MODULE_CONFIG"

    if [ "$SWAP_CREATED" -eq 1 ]; then
        printf 'Swap 文件：%s，新创建\n' "$SWAPFILE"
    else
        printf '%s\n' "Swap 文件：未新建或已经存在"
    fi

    if [ "$BBR_CONFIGURED" -eq 1 ]; then
        printf '%s\n' "BBR 配置：成功"
    else
        printf '%s\n' "BBR 配置：未完成"
    fi

    printf '%s\n' "=========================================="
}

main() {
    local failed=0

    parse_arguments "$@"
    require_root
    check_operating_system
    check_required_commands

    echo
    log_info "开始配置 Debian Swap 和标准 BBR。"

    if ! configure_swap; then
        failed=1
        log_error "Swap 配置未能完成。"
    fi

    if ! configure_bbr; then
        failed=1
        log_error "BBR 配置未能完成。"
    fi

    show_result

    if [ "$failed" -ne 0 ]; then
        log_warn "部分配置未能完成，请检查上方错误信息。"
        exit 1
    fi

    log_ok "Swap 和 BBR 已全部配置完成。"
    log_info "配置立即生效，通常不需要重启。"
}

main "$@"