#!/usr/bin/env bash

# Debian Swap and BBR Setup
# Debian Swap 与 BBR 配置脚本
#
# Repository: https://github.com/Bosco1262/debian-swap-bbr
#
# What this script does:
#   1. Check the Debian system and root privileges.
#   2. Keep the existing swap and add a missing fstab entry.
#   3. Create /swapfile when no swap is enabled.
#   4. Pick the swap size from physical memory.
#   5. Enable the standard BBR shipped with the Debian kernel.
#   6. Stay idempotent, running it twice changes nothing twice.
#   7. Support --dry-run and --lang.
#
# What this script does not do:
#   1. Touch the SSH configuration.
#   2. Touch the firewall.
#   3. Install XanMod or any other third-party kernel.
#   4. Remove the existing swap.
#
#
# 本脚本会做的事情：
#   1. 检查 Debian 系统与 root 权限。
#   2. 保留现有 Swap，并补写缺失的 fstab 条目。
#   3. 没有 Swap 时创建 /swapfile。
#   4. 根据物理内存决定 Swap 大小。
#   5. 启用 Debian 内核自带的标准 BBR。
#   6. 保持幂等，重复执行不会重复改动。
#   7. 支持 --dry-run 与 --lang。
#
# 本脚本不会做的事情：
#   1. 修改 SSH 配置。
#   2. 修改防火墙。
#   3. 安装 XanMod 或其他第三方内核。
#   4. 删除现有 Swap。
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 022

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.3.0"
readonly SWAPFILE="/swapfile"
readonly FSTAB="/etc/fstab"
readonly SYSCTL_DIR="/etc/sysctl.d"
readonly MODULES_LOAD_DIR="/etc/modules-load.d"
readonly STATE_DIR="/var/lib/debian-swap-bbr"
readonly STATE_FILE="${STATE_DIR}/state"

# The file names must sort after 99-sysctl.conf, which is a symlink to
# /etc/sysctl.conf on Debian, otherwise the same keys are overridden at boot.
#
# 文件名必须排在 99-sysctl.conf 之后，
# 在 Debian 上它是指向 /etc/sysctl.conf 的软链，
# 否则同名键会在开机时被覆盖。
readonly SWAP_CONFIG="${SYSCTL_DIR}/99-zz-local-swap.conf"
readonly BBR_CONFIG="${SYSCTL_DIR}/99-zz-local-bbr.conf"
readonly BBR_MODULE_CONFIG="${MODULES_LOAD_DIR}/bbr.conf"
readonly LEGACY_SWAP_CONFIG="${SYSCTL_DIR}/90-local-swap.conf"
readonly LEGACY_BBR_CONFIG="${SYSCTL_DIR}/90-local-bbr.conf"

SWAP_SIZE_GB=0
SWAP_CREATED=0
SWAP_CONFIGURED=0
BBR_CONFIGURED=0
DRY_RUN=0
RESTORE=0
SWAPFILE_OWNED=0
SWAP_ACTIVATED=0
USE_DD=0
CLEANING_UP=0
ROOT_FSTYPE=""
LANGUAGE=""

# The install record answers "did this script create it" during a restore.
#
# 安装记录用于在恢复时回答"这个是不是脚本创建的"。
MANIFEST_EXISTS=0
MF_INSTALLED_AT=""
MF_SWAPFILE_CREATED=0
MF_SWAPFILE_ENABLED=0
MF_FSTAB_ADDED=0
MF_SWAP_CONFIG=0
MF_BBR_CONFIG=0
MF_MODULE_CONFIG=0
MF_LEGACY_BACKUP=""
MF_PREV_VALUES_OK=0
MF_PREV_SWAPPINESS=""
MF_PREV_VFS_CACHE_PRESSURE=""
MF_PREV_CC=""
MF_PREV_QDISC=""

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

# Every user-facing string lives in these two tables.
# 所有面向用户的文案都放在这两张表里。
declare -A MSG_EN=(
    [usage_body]='Usage:
  sudo ./%s [options]

Options:
  --swap-size N     Swap size in GiB, 1 to 32 (also --swap-size=N)
  -l, --lang LANG   Output language: en or zh-CN
                    Defaults to the system locale, English as fallback
  -n, --dry-run     Check the environment and print the plan, change nothing
  --restore         Remove what this script created and return to the previous state
                    Combine with --dry-run to only print the plan
  -h, --help        Show this help
  -V, --version     Show the script version

Automatic swap size:
  Memory up to 4 GiB : 2 GiB swap
  Memory above 4 GiB : 4 GiB swap

Note:
  If any swap is already enabled, the existing swap is kept and no new
  /swapfile is created.'
    [err_not_root]='Please run this script as root.'
    [err_not_root_hint]='Example: sudo ./%s'
    [err_os_release_missing]='Cannot read /etc/os-release, unable to identify the operating system.'
    [err_os_unsupported]='This script only supports Debian.'
    [err_os_current]='Current system: %s'
    [ok_os_detected]='Detected system: %s'
    [err_missing_commands]='Missing required commands: %s'
    [err_install_hint]='Try installing them with:'
    [err_install_cmd]='apt-get update && apt-get install -y util-linux procps kmod coreutils'
    [warn_blkid_missing]='blkid is missing, an existing /swapfile cannot be verified safely.'
    [info_no_fallocate]='fallocate is not available, dd will be used to create the swap file.'
    [ok_commands]='Required commands are available.'
    [err_swap_size_not_int]='Swap size must be an integer in GiB.'
    [err_swap_size_range]='Swap size must be between 1 and 32 GiB.'
    [err_swap_size_missing]='--swap-size requires an integer value.'
    [err_lang_missing]='--lang requires a value: en or zh-CN.'
    [err_unknown_argument]='Unknown argument: %s'
    [info_user_swap_size]='Using the requested swap size: %s GiB'
    [warn_memory_unreadable]='Cannot read the physical memory size, defaulting to 2 GiB swap.'
    [info_memory_detected]='Detected physical memory: about %s MiB.'
    [info_auto_swap_size]='Selected %s GiB swap automatically.'
    [err_mkdir_failed]='Cannot create directory %s.'
    [dryrun_write_file]='[DRY-RUN] Would write %s.'
    [err_write_file]='Cannot write %s.'
    [err_chmod_file]='Cannot set permissions on %s.'
    [err_apply_sysctl_file]='Cannot apply %s.'
    [ok_swap_sysctl_written]='Swap kernel parameters written to %s.'
    [info_root_fstype]='Root filesystem type: %s'
    [err_fstype_unsupported]='%s does not support swap files.'
    [err_fstype_detail]='Containers, union filesystems and network filesystems cannot use %s.'
    [err_fstype_hint]='Use a block device or a swap provided by the host instead.'
    [info_btrfs_cow]='btrfs requires CoW to be disabled, chattr +C and dd will be used.'
    [err_chattr_missing]='chattr is missing, cannot create a safe swap file on btrfs.'
    [err_chattr_hint]='Try: apt-get install -y e2fsprogs'
    [err_df_failed]='Cannot read the free space of the root filesystem.'
    [err_disk_not_enough]='Not enough disk space to create %s GiB swap safely.'
    [err_disk_available]='Free space on the root filesystem: about %s MiB.'
    [err_disk_reserve]='The script requires at least 1024 MiB free space after creation.'
    [ok_disk]='Disk space check passed.'
    [err_blkid_missing_verify]='blkid (util-linux) is missing, cannot verify the existing %s safely.'
    [dryrun_create]='[DRY-RUN] Would create the swap file %s with size %s GiB.'
    [info_creating]='Creating a %s GiB swap file.'
    [err_create_file]='Cannot create %s.'
    [err_chattr_failed]='chattr +C failed, a swap file on btrfs must have CoW disabled.'
    [warn_fallocate_failed]='fallocate failed, falling back to dd.'
    [warn_no_fallocate]='fallocate is not available, falling back to dd.'
    [err_dd_failed]='Failed to create the swap file with dd.'
    [err_mkswap]='mkswap failed, %s is not a valid swap file.'
    [ok_swapfile_created]='Swap file created.'
    [info_fstab_present]='%s already contains %s, skipping.'
    [dryrun_fstab]='[DRY-RUN] Would append %s to %s.'
    [err_fstab_not_writable]='%s is not writable.'
    [err_fstab_backup]='Cannot back up %s.'
    [ok_fstab_written]='Added %s to %s.'
    [info_fstab_backup]='fstab backup: %s'
    [info_swap_active]='Swap is already enabled: %s'
    [info_swap_preserved]='Keeping the existing swap, no new %s will be created.'
    [info_swap_not_ours]='The existing swap is not %s, %s will not be modified.'
    [ok_swap_checked]='Swap configuration checked.'
    [warn_swapfile_idle]='%s exists but is not enabled.'
    [info_swapfile_signature]='%s has a valid swap signature and will be enabled.'
    [err_swapfile_unknown]='%s exists but cannot be confirmed as a swap file.'
    [err_swapfile_keep]='To avoid overwriting data, the script will not modify or delete it.'
    [dryrun_enable]='[DRY-RUN] Would enable %s and add its mount entry to %s.'
    [err_swapon]='Cannot enable %s.'
    [err_swapon_reason]='Common causes: containers disallow swapon, the filesystem does not support swap files, or disk space is insufficient.'
    [err_swapon_not_listed]='swapon returned success but %s is not listed as active swap.'
    [warn_fstab_after_swap]='Swap is enabled but %s could not be updated, it may be lost after reboot.'
    [warn_sysctl_after_swap]='Swap is enabled but kernel parameters could not be written.'
    [ok_swap_configured]='Swap configuration completed.'
    [warn_legacy_foreign]='%s was not created by this script, it will not be deleted. Please review it manually.'
    [dryrun_delete_legacy]='[DRY-RUN] Would delete the legacy config %s.'
    [dryrun_restore_legacy]='[DRY-RUN] Would restore %s from the backup.'
    [ok_deleted_legacy]='Deleted the legacy config %s.'
    [warn_delete_legacy_failed]='Cannot delete the legacy config %s, please review it manually.'
    [warn_container]='Container environment detected: %s'
    [warn_container_detail]='LXC, OpenVZ and other containers may not be able to load the BBR module themselves.'
    [warn_container_continue]='The script will continue and check whether the host already provides BBR.'
    [info_virt]='Virtualization: %s'
    [warn_modprobe_failed]='Cannot load the tcp_bbr module, checking whether the kernel already provides BBR.'
    [warn_modprobe_missing]='modprobe is missing, skipping module loading and checking the kernel directly.'
    [dryrun_module_present]='[DRY-RUN] tcp_bbr is not loaded yet but the module exists, the real run would load it.'
    [err_bbr_unsupported]='This kernel does not provide BBR.'
    [err_bbr_available]='Available congestion control algorithms: %s'
    [err_bbr_no_third_party]='The script will not install a third-party kernel.'
    [info_bbr_builtin]='tcp_bbr appears to be built into the kernel, skipping %s.'
    [ok_bbr_written]='Standard BBR configuration written.'
    [warn_sysctl_conflict]='%s also defines %s, please make sure the values match this script.'
    [warn_sysctl_order]='This script writes files that sort after 99-sysctl.conf, so its settings win at boot.'
    [err_verify_no_swap]='Verification failed: no swap is currently enabled.'
    [err_verify_value]='Verification failed: %s should be %s but is %s.'
    [err_verify_hint]='Check whether /etc/sysctl.conf or other files override %s.'
    [warn_verify_qdisc]='Verification hint: %s should be %s but is %s.'
    [warn_verify_qdisc_hint]='BBR still works, but the queue discipline may not be fq.'
    [err_verify_failed]='Some settings failed verification.'
    [info_start]='Configuring Debian swap and standard BBR.'
    [info_dryrun_start]='Running in DRY-RUN mode: checking the environment only, nothing will be modified.'
    [err_swap_incomplete]='Swap configuration was not completed.'
    [err_bbr_incomplete]='BBR configuration was not completed.'
    [warn_partial]='Some settings were not applied, please check the messages above.'
    [ok_dryrun_done]='DRY-RUN finished, nothing was modified.'
    [ok_all_done]='Swap and BBR are fully configured.'
    [info_takes_effect]='Changes take effect immediately, a reboot is normally not required.'
    [warn_cleanup_removed]='Removed %s because it was created by this run but could not be enabled.'
    [warn_cleanup_failed]='Cannot remove %s, please check it manually.'
    [err_line]='Script failed at line %s with exit code %s.'
    [err_check_output]='Please check the messages above.'
    [warn_interrupt]='Interrupted, cleaning up unfinished work.'
    [result_title]='================ Result ================'
    [label_swap]='[Swap]'
    [label_bbr]='[BBR]'
    [label_files]='[Files]'
    [result_available_cc]='Available: %s'
    [result_current_cc]='Current: %s'
    [result_qdisc]='Qdisc: %s'
    [result_module_loaded]='BBR module: loaded'
    [result_module_unknown]='BBR module: not shown by lsmod, may be built into the kernel or restricted by the container'
    [result_root_fstype]='Root filesystem: %s'
    [result_swap_conf]='Swap config: %s'
    [result_bbr_conf]='BBR config: %s'
    [result_bbr_module_conf]='BBR module config: %s'
    [result_fstab_has]='%s: contains %s'
    [result_fstab_has_not]='%s: does not contain %s'
    [result_swapfile_new]='Swap file: %s (created this run)'
    [result_swapfile_existing]='Swap file: %s (reused)'
    [result_swapfile_none]='Swap file: none (existing swap is used)'
    [result_swap_ok]='Swap: success'
    [result_swap_fail]='Swap: incomplete'
    [result_bbr_ok]='BBR: success'
    [result_bbr_fail]='BBR: incomplete'
    [result_state_file]='Install record: %s'
    [err_restore_conflict]='--restore cannot be combined with %s.'
    [restore_start]='Restoring: undoing the configuration created by this script.'
    [restore_no_state]='No install record found, only files carrying the script marker will be removed.'
    [ok_swapoff]='Disabled %s.'
    [err_swapoff]='Cannot disable %s, restore aborted. Free memory and try again.'
    [dryrun_swapoff]='[DRY-RUN] Would disable %s.'
    [warn_swap_active_kept]='%s is active but was not enabled by this script, it is left running.'
    [ok_swapfile_removed]='Removed %s.'
    [dryrun_remove_file]='[DRY-RUN] Would remove %s.'
    [err_remove_file]='Cannot remove %s.'
    [info_file_absent]='%s is not present, nothing to do.'
    [warn_file_not_ours]='%s was not created by this script, it is left untouched.'
    [ok_fstab_line_removed]='Updated %s: removed the %s entry.'
    [warn_fstab_line_missing]='%s does not contain the exact %s entry, nothing changed.'
    [info_fstab_kept]='%s was not modified by this script, it is left untouched.'
    [dryrun_fstab_remove]='[DRY-RUN] Would update %s: remove the %s entry.'
    [ok_daemon_reload]='systemd units reloaded.'
    [warn_daemon_reload]='systemctl daemon-reload failed, run it manually.'
    [ok_legacy_restored]='Restored %s from the backup.'
    [warn_legacy_exists]='%s already exists, the backup is kept for manual restore.'
    [warn_legacy_backup_missing]='The legacy backup %s is missing, nothing to restore.'
    [info_prev_restored]='Restored %s to %s.'
    [warn_prev_unknown]='Previous values were not recorded, kernel parameters stay as they are and return to system defaults after a reboot.'
    [warn_sysctl_restore_failed]='Cannot restore %s, set it manually.'
    [dryrun_sysctl]='[DRY-RUN] Would set %s to %s.'
    [warn_module_loaded]='The tcp_bbr module stays loaded until the next reboot.'
    [ok_restore_done]='Restore completed.'
    [err_restore_failed]='Restore did not complete, the install record is kept for a retry.'
    [info_state_written]='Install record written to %s.'
    [err_state_write]='Cannot write %s.'
)

# The Chinese table must provide the same keys as MSG_EN.
# 中文表必须与 MSG_EN 提供相同的键。
declare -A MSG_ZH=(
    [usage_body]='用法：
  sudo ./%s [选项]

选项：
  --swap-size N     Swap 大小，单位 GiB，范围 1 到 32（也支持 --swap-size=N）
  -l, --lang LANG   输出语言：en 或 zh-CN
                    默认跟随系统 locale，无法识别时回退英文
  -n, --dry-run     只检查环境并输出计划，不修改任何内容
  --restore         撤销本脚本创建的配置，恢复到安装前的状态
                    与 --dry-run 同时使用只输出计划
  -h, --help        显示帮助信息
  -V, --version     显示脚本版本

自动 Swap 规则：
  内存不超过 4 GiB：创建 2 GiB Swap
  内存超过 4 GiB：创建 4 GiB Swap

注意：
  如果系统已经启用了任何 Swap，脚本会保留现有 Swap，
  不会再创建新的 /swapfile。'
    [err_not_root]='请以 root 身份运行此脚本。'
    [err_not_root_hint]='示例：sudo ./%s'
    [err_os_release_missing]='无法读取 /etc/os-release，不能识别操作系统。'
    [err_os_unsupported]='此脚本仅支持 Debian。'
    [err_os_current]='当前系统：%s'
    [ok_os_detected]='检测到系统：%s'
    [err_missing_commands]='缺少必要命令：%s'
    [err_install_hint]='可尝试执行以下命令安装依赖：'
    [err_install_cmd]='apt-get update && apt-get install -y util-linux procps kmod coreutils'
    [warn_blkid_missing]='缺少 blkid，已存在的 /swapfile 将无法被安全校验。'
    [info_no_fallocate]='系统没有 fallocate，创建 Swap 文件时会使用 dd。'
    [ok_commands]='必要命令检查通过。'
    [err_swap_size_not_int]='Swap 大小必须是整数，单位为 GiB。'
    [err_swap_size_range]='Swap 大小必须在 1 到 32 GiB 之间。'
    [err_swap_size_missing]='--swap-size 后面必须提供一个整数。'
    [err_lang_missing]='--lang 后面必须提供一个值：en 或 zh-CN。'
    [err_unknown_argument]='未知参数：%s'
    [info_user_swap_size]='使用用户指定的 Swap 大小：%s GiB'
    [warn_memory_unreadable]='无法读取物理内存大小，默认创建 2 GiB Swap。'
    [info_memory_detected]='检测到物理内存约为 %s MiB。'
    [info_auto_swap_size]='自动选择 %s GiB Swap。'
    [err_mkdir_failed]='无法创建目录 %s。'
    [dryrun_write_file]='[DRY-RUN] 将写入 %s。'
    [err_write_file]='无法写入 %s。'
    [err_chmod_file]='无法设置 %s 的权限。'
    [err_apply_sysctl_file]='无法应用 %s。'
    [ok_swap_sysctl_written]='Swap 内核参数已经写入 %s。'
    [info_root_fstype]='根分区文件系统：%s'
    [err_fstype_unsupported]='%s 文件系统不支持创建 Swap 文件。'
    [err_fstype_detail]='容器、联合文件系统和网络文件系统无法使用 %s。'
    [err_fstype_hint]='如需 Swap，请改用块设备或宿主机上的 Swap。'
    [info_btrfs_cow]='btrfs 需要关闭 CoW，创建时将使用 chattr +C 与 dd。'
    [err_chattr_missing]='缺少 chattr 命令，无法在 btrfs 上安全创建 Swap 文件。'
    [err_chattr_hint]='可尝试执行：apt-get install -y e2fsprogs'
    [err_df_failed]='无法读取根分区可用空间。'
    [err_disk_not_enough]='磁盘空间不足，无法安全创建 %s GiB Swap。'
    [err_disk_available]='当前根分区可用空间约为 %s MiB。'
    [err_disk_reserve]='脚本要求创建完成后至少保留 1024 MiB 可用空间。'
    [ok_disk]='磁盘空间检查通过。'
    [err_blkid_missing_verify]='缺少 blkid（util-linux），无法安全验证现有 %s。'
    [dryrun_create]='[DRY-RUN] 将在 %s 创建 %s GiB 的 Swap 文件。'
    [info_creating]='正在创建 %s GiB Swap 文件。'
    [err_create_file]='无法创建 %s。'
    [err_chattr_failed]='chattr +C 执行失败，btrfs 上的 Swap 文件必须关闭 CoW。'
    [warn_fallocate_failed]='fallocate 创建失败，将改用 dd。'
    [warn_no_fallocate]='系统没有 fallocate，将使用 dd 创建 Swap 文件。'
    [err_dd_failed]='使用 dd 创建 Swap 文件失败。'
    [err_mkswap]='mkswap 执行失败，%s 不是有效的 Swap 文件。'
    [ok_swapfile_created]='Swap 文件创建完成。'
    [info_fstab_present]='%s 已经包含 %s，无需重复写入。'
    [dryrun_fstab]='[DRY-RUN] 将把 %s 追加到 %s。'
    [err_fstab_not_writable]='%s 不可写。'
    [err_fstab_backup]='无法备份 %s。'
    [ok_fstab_written]='已经将 %s 写入 %s。'
    [info_fstab_backup]='fstab 备份位置：%s'
    [info_swap_active]='系统已经启用 Swap：%s'
    [info_swap_preserved]='脚本将保留现有 Swap，不创建新的 %s。'
    [info_swap_not_ours]='现有 Swap 不是 %s，脚本不会修改 %s。'
    [ok_swap_checked]='Swap 配置检查完成。'
    [warn_swapfile_idle]='%s 已存在，但当前没有启用。'
    [info_swapfile_signature]='%s 具有有效的 Swap 签名，将直接启用。'
    [err_swapfile_unknown]='%s 已存在，但不能确认它是 Swap 文件。'
    [err_swapfile_keep]='为避免覆盖重要数据，脚本不会修改或删除该文件。'
    [dryrun_enable]='[DRY-RUN] 将启用 %s，并向 %s 写入挂载条目。'
    [err_swapon]='无法启用 %s。'
    [err_swapon_reason]='常见原因：容器不允许 swapon、文件系统不支持 Swap 文件、磁盘空间不足。'
    [err_swapon_not_listed]='swapon 返回成功，但 %s 并未真正出现在 Swap 列表中。'
    [warn_fstab_after_swap]='Swap 已经启用，但 %s 写入失败，重启后可能失效。'
    [warn_sysctl_after_swap]='Swap 已经启用，但内核参数写入失败。'
    [ok_swap_configured]='Swap 配置完成。'
    [warn_legacy_foreign]='%s 不是本脚本创建的文件，脚本不会删除，请自行确认。'
    [dryrun_delete_legacy]='[DRY-RUN] 将删除旧版本配置 %s。'
    [dryrun_restore_legacy]='[DRY-RUN] 将从备份恢复 %s。'
    [ok_deleted_legacy]='已经删除旧版本配置 %s。'
    [warn_delete_legacy_failed]='无法删除旧版本配置 %s，请手动处理。'
    [warn_container]='检测到容器环境：%s'
    [warn_container_detail]='LXC、OpenVZ 或其他容器可能不能自行加载 BBR 模块。'
    [warn_container_continue]='脚本将继续检查宿主机是否已经提供 BBR。'
    [info_virt]='虚拟化环境：%s'
    [warn_modprobe_failed]='无法加载 tcp_bbr 模块，将继续检查内核是否已经提供 BBR。'
    [warn_modprobe_missing]='缺少 modprobe，跳过模块加载，直接检查内核 BBR 支持。'
    [dryrun_module_present]='[DRY-RUN] 当前未加载 tcp_bbr，但模块存在，正式运行时会自动加载。'
    [err_bbr_unsupported]='当前内核没有提供 BBR。'
    [err_bbr_available]='可用拥塞控制算法：%s'
    [err_bbr_no_third_party]='脚本不会安装第三方内核。'
    [info_bbr_builtin]='tcp_bbr 似乎已经内置在内核中，跳过 %s。'
    [ok_bbr_written]='标准 BBR 配置已经写入。'
    [warn_sysctl_conflict]='%s 中也设置了 %s，请确认取值与本脚本一致。'
    [warn_sysctl_order]='本脚本的配置文件排序在 99-sysctl.conf 之后，开机时会以脚本设置为准。'
    [err_verify_no_swap]='校验失败：当前没有任何已启用的 Swap。'
    [err_verify_value]='校验失败：%s 期望 %s，实际 %s。'
    [err_verify_hint]='请检查 /etc/sysctl.conf 等文件是否覆盖了 %s。'
    [warn_verify_qdisc]='校验提示：%s 期望 %s，实际 %s。'
    [warn_verify_qdisc_hint]='BBR 仍可工作，但队列算法可能不是 fq。'
    [err_verify_failed]='部分配置未通过校验。'
    [info_start]='开始配置 Debian Swap 和标准 BBR。'
    [info_dryrun_start]='以 DRY-RUN 模式运行：只检查环境并输出计划，不修改系统。'
    [err_swap_incomplete]='Swap 配置未能完成。'
    [err_bbr_incomplete]='BBR 配置未能完成。'
    [warn_partial]='部分配置未能完成，请检查上方错误信息。'
    [ok_dryrun_done]='DRY-RUN 检查完成，未做任何修改。'
    [ok_all_done]='Swap 和 BBR 已全部配置完成。'
    [info_takes_effect]='配置立即生效，通常不需要重启。'
    [warn_cleanup_removed]='已删除本次创建但未能启用的 %s。'
    [warn_cleanup_failed]='无法删除 %s，请手动检查。'
    [err_line]='脚本在第 %s 行执行失败，退出码：%s。'
    [err_check_output]='请检查上方输出信息。'
    [warn_interrupt]='收到中断信号，正在清理未完成的操作。'
    [result_title]='================ 配置结果 ================'
    [label_swap]='[Swap]'
    [label_bbr]='[BBR]'
    [label_files]='[配置文件]'
    [result_available_cc]='可用算法：%s'
    [result_current_cc]='当前算法：%s'
    [result_qdisc]='默认队列：%s'
    [result_module_loaded]='BBR 模块：已加载'
    [result_module_unknown]='BBR 模块：未在 lsmod 中显示，可能已编译进内核或受到容器限制'
    [result_root_fstype]='根分区文件系统：%s'
    [result_swap_conf]='Swap 参数：%s'
    [result_bbr_conf]='BBR 参数：%s'
    [result_bbr_module_conf]='BBR 模块：%s'
    [result_fstab_has]='%s：已包含 %s'
    [result_fstab_has_not]='%s：未包含 %s'
    [result_swapfile_new]='Swap 文件：%s，本次新建'
    [result_swapfile_existing]='Swap 文件：%s，使用已有文件'
    [result_swapfile_none]='Swap 文件：未使用（沿用现有 Swap）'
    [result_swap_ok]='Swap 配置：成功'
    [result_swap_fail]='Swap 配置：未完成'
    [result_bbr_ok]='BBR 配置：成功'
    [result_bbr_fail]='BBR 配置：未完成'
    [result_state_file]='安装记录：%s'
    [err_restore_conflict]='--restore 不能与 %s 同时使用。'
    [restore_start]='开始恢复：撤销由本脚本创建的配置。'
    [restore_no_state]='未找到安装记录，只会删除带本脚本标记的文件。'
    [ok_swapoff]='已停用 %s。'
    [err_swapoff]='无法停用 %s，恢复已中止。请释放内存后重试。'
    [dryrun_swapoff]='[DRY-RUN] 将停用 %s。'
    [warn_swap_active_kept]='%s 处于启用状态，但不是本脚本启用的，保持现状。'
    [ok_swapfile_removed]='已删除 %s。'
    [dryrun_remove_file]='[DRY-RUN] 将删除 %s。'
    [err_remove_file]='无法删除 %s。'
    [info_file_absent]='%s 不存在，无需处理。'
    [warn_file_not_ours]='%s 不是本脚本创建的文件，保持原样。'
    [ok_fstab_line_removed]='已更新 %s：移除了 %s 条目。'
    [warn_fstab_line_missing]='%s 中没有精确匹配的 %s 条目，未做修改。'
    [info_fstab_kept]='%s 不是本脚本修改的，保持原样。'
    [dryrun_fstab_remove]='[DRY-RUN] 将更新 %s：移除 %s 条目。'
    [ok_daemon_reload]='已重新加载 systemd 单元。'
    [warn_daemon_reload]='systemctl daemon-reload 执行失败，请手动执行。'
    [ok_legacy_restored]='已从备份恢复 %s。'
    [warn_legacy_exists]='%s 已存在，备份保留，请手动处理。'
    [warn_legacy_backup_missing]='旧版本备份 %s 不存在，无需恢复。'
    [info_prev_restored]='已将 %s 恢复为 %s。'
    [warn_prev_unknown]='未记录原始取值，内核参数保持当前值，重启后会回到系统默认。'
    [warn_sysctl_restore_failed]='无法恢复 %s，请手动设置。'
    [dryrun_sysctl]='[DRY-RUN] 将把 %s 设置为 %s。'
    [warn_module_loaded]='tcp_bbr 模块会保持加载，直到下次重启。'
    [ok_restore_done]='恢复完成。'
    [err_restore_failed]='恢复未完成，安装记录已保留，可稍后重试。'
    [info_state_written]='安装记录已写入 %s。'
    [err_state_write]='无法写入 %s。'
)

# Translate a message key, extra arguments fill the printf placeholders.
# 翻译一个消息键，额外参数用于填充 printf 占位符。
msg() {
    local key="$1"
    shift

    local format=""

    if [ "$LANGUAGE" = "zh-CN" ]; then
        format="${MSG_ZH[$key]:-}"
    fi

    if [ -z "$format" ]; then
        format="${MSG_EN[$key]:-}"
    fi

    if [ -z "$format" ]; then
        format="$key"
    fi

    # The format strings come from the tables above, not from user input.
    # The leading -- keeps printf from reading messages such as
    # "--swap-size requires ..." as options.
    #
    # 格式串来自上面的消息表，不是用户输入。
    # 开头的 -- 防止 printf 把 "--swap-size ..." 这类消息当成选项。
    # shellcheck disable=SC2059
    printf -- "$format" "$@"
}

log_ok() {
    local key="$1"
    shift

    printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$(msg "$key" "$@")"
}

log_info() {
    local key="$1"
    shift

    printf '%b[INFO]%b %s\n' "$CYAN" "$NC" "$(msg "$key" "$@")"
}

log_warn() {
    local key="$1"
    shift

    printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$(msg "$key" "$@")" >&2
}

log_error() {
    local key="$1"
    shift

    printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$(msg "$key" "$@")" >&2
}

have() {
    command -v "$1" >/dev/null 2>&1
}

# The install record is a plain KEY=VALUE file. It is parsed line by line
# instead of being sourced, so its content can never execute code.
#
# 安装记录是纯 KEY=VALUE 文件，这里逐行解析而不是 source，
# 保证其中的内容永远不会被执行。
load_state() {
    local key
    local value

    MANIFEST_EXISTS=0

    if [ ! -r "$STATE_FILE" ]; then
        return 0
    fi

    MANIFEST_EXISTS=1

    while IFS='=' read -r key value; do
        case "$key" in
            ''|'#'*)
                continue
                ;;
            INSTALLED_AT)
                MF_INSTALLED_AT="$value"
                ;;
            SWAPFILE_CREATED)
                if [ "$value" = "1" ]; then
                    MF_SWAPFILE_CREATED=1
                fi
                ;;
            SWAPFILE_ENABLED)
                if [ "$value" = "1" ]; then
                    MF_SWAPFILE_ENABLED=1
                fi
                ;;
            FSTAB_ADDED)
                if [ "$value" = "1" ]; then
                    MF_FSTAB_ADDED=1
                fi
                ;;
            SWAP_CONFIG_CREATED)
                if [ "$value" = "1" ]; then
                    MF_SWAP_CONFIG=1
                fi
                ;;
            BBR_CONFIG_CREATED)
                if [ "$value" = "1" ]; then
                    MF_BBR_CONFIG=1
                fi
                ;;
            MODULE_CONFIG_CREATED)
                if [ "$value" = "1" ]; then
                    MF_MODULE_CONFIG=1
                fi
                ;;
            LEGACY_BACKUP)
                MF_LEGACY_BACKUP="$value"
                ;;
            PREV_VALUES_OK)
                if [ "$value" = "1" ]; then
                    MF_PREV_VALUES_OK=1
                fi
                ;;
            PREV_SWAPPINESS)
                MF_PREV_SWAPPINESS="$value"
                ;;
            PREV_VFS_CACHE_PRESSURE)
                MF_PREV_VFS_CACHE_PRESSURE="$value"
                ;;
            PREV_CC)
                MF_PREV_CC="$value"
                ;;
            PREV_QDISC)
                MF_PREV_QDISC="$value"
                ;;
        esac
    done < "$STATE_FILE"
}

write_state() {
    local installed_at

    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi

    if [ -n "$MF_INSTALLED_AT" ]; then
        installed_at="$MF_INSTALLED_AT"
    else
        installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    fi

    if ! mkdir -p "$STATE_DIR"; then
        log_error err_mkdir_failed "$STATE_DIR"
        return 1
    fi

    if ! {
        printf 'VERSION=%s\n' "$SCRIPT_VERSION"
        printf 'INSTALLED_AT=%s\n' "$installed_at"
        printf 'SWAPFILE_CREATED=%s\n' "$MF_SWAPFILE_CREATED"
        printf 'SWAPFILE_ENABLED=%s\n' "$MF_SWAPFILE_ENABLED"
        printf 'FSTAB_ADDED=%s\n' "$MF_FSTAB_ADDED"
        printf 'SWAP_CONFIG_CREATED=%s\n' "$MF_SWAP_CONFIG"
        printf 'BBR_CONFIG_CREATED=%s\n' "$MF_BBR_CONFIG"
        printf 'MODULE_CONFIG_CREATED=%s\n' "$MF_MODULE_CONFIG"
        printf 'LEGACY_BACKUP=%s\n' "$MF_LEGACY_BACKUP"
        printf 'PREV_VALUES_OK=%s\n' "$MF_PREV_VALUES_OK"
        printf 'PREV_SWAPPINESS=%s\n' "$MF_PREV_SWAPPINESS"
        printf 'PREV_VFS_CACHE_PRESSURE=%s\n' "$MF_PREV_VFS_CACHE_PRESSURE"
        printf 'PREV_CC=%s\n' "$MF_PREV_CC"
        printf 'PREV_QDISC=%s\n' "$MF_PREV_QDISC"
    } > "$STATE_FILE"
    then
        log_error err_state_write "$STATE_FILE"
        return 1
    fi

    chmod 644 "$STATE_FILE" 2>/dev/null || true
    return 0
}

state_changed() {
    if [ "$MF_SWAPFILE_CREATED" -eq 1 ] ||
       [ "$MF_SWAPFILE_ENABLED" -eq 1 ] ||
       [ "$MF_FSTAB_ADDED" -eq 1 ] ||
       [ "$MF_SWAP_CONFIG" -eq 1 ] ||
       [ "$MF_BBR_CONFIG" -eq 1 ] ||
       [ "$MF_MODULE_CONFIG" -eq 1 ] ||
       [ -n "$MF_LEGACY_BACKUP" ]; then
        return 0
    fi

    return 1
}

clear_state() {
    if [ -f "$STATE_FILE" ]; then
        if ! rm -f "$STATE_FILE"; then
            log_error err_remove_file "$STATE_FILE"
            return 1
        fi
    fi

    rmdir "$STATE_DIR" 2>/dev/null || true
    return 0
}

# Capture the values before this script changes anything, a re-run keeps the
# values recorded by the first run instead of recording its own settings.
#
# 在脚本改动之前记录原始值，重复执行时保留首次运行记录的值，
# 而不是把脚本自己的设置当成原始值。
capture_previous_state() {
    local value

    if [ "$DRY_RUN" -eq 1 ] || [ "$MF_PREV_VALUES_OK" -eq 1 ]; then
        return 0
    fi

    value=$(sysctl -n vm.swappiness 2>/dev/null) || value=""
    MF_PREV_SWAPPINESS="$value"

    value=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null) || value=""
    MF_PREV_VFS_CACHE_PRESSURE="$value"

    value=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || value=""
    MF_PREV_CC="$value"

    value=$(sysctl -n net.core.default_qdisc 2>/dev/null) || value=""
    MF_PREV_QDISC="$value"

    if [ -n "$MF_PREV_SWAPPINESS" ] &&
       [ -n "$MF_PREV_VFS_CACHE_PRESSURE" ] &&
       [ -n "$MF_PREV_CC" ] &&
       [ -n "$MF_PREV_QDISC" ]; then
        MF_PREV_VALUES_OK=1
    fi
}

# Language resolution follows a fixed priority:
#   1. an explicit -l / --lang / --language value,
#   2. LC_ALL, LC_MESSAGES or LANG,
#   3. English.
#
# 语言解析遵循固定优先级：
#   1. 显式的 -l / --lang / --language 参数，
#   2. LC_ALL、LC_MESSAGES 或 LANG，
#   3. 英文兜底。
set_language() {
    local value="$1"

    case "$value" in
        en)
            LANGUAGE="en"
            ;;
        zh-CN|zh|zh_CN|zh_cn|zh-Hans|zh-hans)
            LANGUAGE="zh-CN"
            ;;
        *)
            # The language is unknown at this point, so answer in both.
            # 此处还不知道应该用哪种语言，所以中英文同时提示。
            printf '\n[ERROR] Unsupported language: %s (use en or zh-CN)\n' "$value" >&2
            printf '[ERROR] 不支持的语言：%s（可选 en 或 zh-CN）\n' "$value" >&2
            exit 2
            ;;
    esac
}

detect_language() {
    local candidate

    candidate="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    candidate="${candidate%%@*}"
    candidate="${candidate%%.*}"

    case "$candidate" in
        zh*|*_CN*|*_cn*)
            printf '%s\n' "zh-CN"
            ;;
        *)
            printf '%s\n' "en"
            ;;
    esac
}

prescan_language() {
    local previous=""
    local argument

    for argument in "$@"; do
        case "$previous" in
            -l|--lang|--language)
                set_language "$argument"
                previous=""
                continue
                ;;
        esac

        case "$argument" in
            --lang=*|--language=*)
                set_language "${argument#*=}"
                ;;
            -l|--lang|--language)
                previous="$argument"
                ;;
        esac
    done
}

cleanup_partial() {
    if [ "$CLEANING_UP" -eq 1 ]; then
        return 0
    fi

    CLEANING_UP=1

    if [ "$SWAPFILE_OWNED" -ne 1 ] || [ "$SWAP_ACTIVATED" -ne 0 ]; then
        return 0
    fi

    if [ ! -e "$SWAPFILE" ]; then
        return 0
    fi

    if have swapon &&
       swapon --show=NAME --noheadings 2>/dev/null |
           awk -v target="$SWAPFILE" '$1 == target {found = 1} END {exit !found}'
    then
        return 0
    fi

    if rm -f "$SWAPFILE"; then
        log_warn warn_cleanup_removed "$SWAPFILE"
    else
        log_warn warn_cleanup_failed "$SWAPFILE"
    fi
}

handle_error() {
    local exit_code=$?
    local line_number=${1:-unknown}

    log_error err_line "$line_number" "$exit_code"
    log_error err_check_output

    cleanup_partial || true

    exit "$exit_code"
}

on_interrupt() {
    log_warn warn_interrupt
    cleanup_partial || true
    exit 130
}

trap 'handle_error "$LINENO"' ERR
trap 'on_interrupt' INT TERM

show_usage() {
    msg usage_body "$SCRIPT_NAME"
    printf '\n'
}

set_swap_size() {
    local value="$1"

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log_error err_swap_size_not_int
        exit 2
    fi

    # More than two digits is always out of range, reject early to avoid
    # arithmetic overflow in the parsing step below.
    #
    # 超过两位必然越界，提前拦截，避免后面的算术溢出。
    if [ "${#value}" -gt 2 ]; then
        log_error err_swap_size_range
        exit 2
    fi

    # The 10# prefix forces base 10 so that 08 is not treated as bad octal.
    # 10# 前缀强制十进制，避免 08 被当成非法八进制。
    value=$((10#$value))

    if ((value < 1 || value > 32)); then
        log_error err_swap_size_range
        exit 2
    fi

    SWAP_SIZE_GB="$value"
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --swap-size)
                if [ "$#" -lt 2 ]; then
                    log_error err_swap_size_missing
                    exit 2
                fi

                set_swap_size "$2"
                shift 2
                ;;
            --swap-size=*)
                set_swap_size "${1#*=}"
                shift
                ;;
            -l|--lang|--language)
                if [ "$#" -lt 2 ]; then
                    log_error err_lang_missing
                    exit 2
                fi

                set_language "$2"
                shift 2
                ;;
            --lang=*|--language=*)
                set_language "${1#*=}"
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            --restore|--uninstall)
                RESTORE=1
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                log_error err_unknown_argument "$1"
                show_usage
                exit 2
                ;;
        esac
    done

    if [ "$RESTORE" -eq 1 ] && [ "$SWAP_SIZE_GB" -gt 0 ]; then
        log_error err_restore_conflict "--swap-size"
        exit 2
    fi
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log_error err_not_root
        log_error err_not_root_hint "$SCRIPT_NAME"
        exit 1
    fi
}

check_operating_system() {
    if [ ! -r /etc/os-release ]; then
        log_error err_os_release_missing
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    if [ "${ID:-}" != "debian" ]; then
        log_error err_os_unsupported
        log_error err_os_current "${PRETTY_NAME:-unknown}"
        exit 1
    fi

    log_ok ok_os_detected "${PRETTY_NAME}"
}

check_required_commands() {
    local missing_commands=()
    local command_name

    for command_name in \
        awk \
        cat \
        chmod \
        cp \
        date \
        dd \
        df \
        free \
        grep \
        head \
        mkdir \
        mkswap \
        swapoff \
        swapon \
        sysctl \
        tail \
        tr
    do
        if ! have "$command_name"; then
            missing_commands+=("$command_name")
        fi
    done

    if [ "${#missing_commands[@]}" -gt 0 ]; then
        log_error err_missing_commands "${missing_commands[*]}"
        log_error err_install_hint
        log_error err_install_cmd
        exit 1
    fi

    # Missing tools below only degrade optional features, they never abort.
    # 下面这些命令缺失只会让可选功能降级，不影响主流程。
    if ! have blkid; then
        log_warn warn_blkid_missing
    fi

    if ! have fallocate; then
        log_info info_no_fallocate
    fi

    log_ok ok_commands
}

get_memory_mb() {
    local memory_mb

    memory_mb=$(awk '/MemTotal:/ {printf "%d\n", $2 / 1024}' /proc/meminfo 2>/dev/null) || memory_mb=""

    printf '%s\n' "${memory_mb:-0}"
}

calculate_swap_size() {
    local memory_mb

    if [ "$SWAP_SIZE_GB" -gt 0 ]; then
        log_info info_user_swap_size "$SWAP_SIZE_GB"
        return 0
    fi

    memory_mb=$(get_memory_mb)

    if ! [[ "$memory_mb" =~ ^[0-9]+$ ]] || [ "$memory_mb" -le 0 ]; then
        log_warn warn_memory_unreadable
        SWAP_SIZE_GB=2
        return 0
    fi

    if [ "$memory_mb" -le 4096 ]; then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=4
    fi

    log_info info_memory_detected "$memory_mb"
    log_info info_auto_swap_size "$SWAP_SIZE_GB"
}

ensure_config_dir() {
    local dir="$1"

    if [ -d "$dir" ]; then
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi

    if ! mkdir -p "$dir"; then
        log_error err_mkdir_failed "$dir"
        return 1
    fi
}

write_swap_sysctl() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_write_file "$SWAP_CONFIG"
        return 0
    fi

    if ! ensure_config_dir "$SYSCTL_DIR"; then
        return 1
    fi

    if ! cat > "$SWAP_CONFIG" <<'EOF'
# Managed by debian-swap-bbr
# 由 debian-swap-bbr 管理
# Lower values reduce the preference for swapping application memory.
# 较低的值会降低换出应用内存的倾向。
vm.swappiness=10

# Keep filesystem metadata cache available for longer.
# 让文件系统元数据缓存保留更久。
vm.vfs_cache_pressure=50
EOF
    then
        log_error err_write_file "$SWAP_CONFIG"
        return 1
    fi

    if ! chmod 644 "$SWAP_CONFIG"; then
        log_error err_chmod_file "$SWAP_CONFIG"
        return 1
    fi

    MF_SWAP_CONFIG=1

    if ! sysctl -q -p "$SWAP_CONFIG"; then
        log_error err_apply_sysctl_file "$SWAP_CONFIG"
        return 1
    fi

    log_ok ok_swap_sysctl_written "$SWAP_CONFIG"
}

get_active_swap() {
    swapon --show=NAME --noheadings 2>/dev/null | awk 'NF {print $1}' || true
}

swap_is_active() {
    get_active_swap | grep -Fqx -- "$1"
}

get_root_fstype() {
    local fstype=""

    if have findmnt; then
        fstype=$(findmnt -no FSTYPE / 2>/dev/null) || fstype=""
    fi

    if [ -z "$fstype" ] && have stat; then
        fstype=$(stat -f -c %T / 2>/dev/null) || fstype=""
    fi

    printf '%s\n' "${fstype:-unknown}" | tr '[:upper:]' '[:lower:]'
}

check_swapfile_support() {
    ROOT_FSTYPE=$(get_root_fstype)
    log_info info_root_fstype "$ROOT_FSTYPE"

    case "$ROOT_FSTYPE" in
        overlay|overlayfs|aufs|tmpfs|ramfs|zfs|nfs|nfs4|cifs|smb3|9p|fuse*)
            log_error err_fstype_unsupported "$ROOT_FSTYPE"
            log_error err_fstype_detail "$SWAPFILE"
            log_error err_fstype_hint
            return 1
            ;;
        btrfs)
            log_info info_btrfs_cow
            if ! have chattr; then
                log_error err_chattr_missing
                log_error err_chattr_hint
                return 1
            fi
            USE_DD=1
            ;;
        *)
            USE_DD=0
            ;;
    esac

    return 0
}

check_disk_space() {
    local available_kb
    local required_kb
    local reserve_kb

    available_kb=$(df --output=avail -k / 2>/dev/null | awk 'NR == 2 {print $1}') || available_kb=""

    if ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        available_kb=$(df -k / 2>/dev/null | awk 'NR == 2 {print $4}') || available_kb=""
    fi

    required_kb=$((SWAP_SIZE_GB * 1024 * 1024))

    # Keep at least 1 GiB free on the root filesystem after creating the file.
    # 创建文件后至少为根分区保留 1 GiB 可用空间。
    reserve_kb=$((1024 * 1024))

    if ! [[ "$available_kb" =~ ^[0-9]+$ ]]; then
        log_error err_df_failed
        return 1
    fi

    if [ "$available_kb" -lt $((required_kb + reserve_kb)) ]; then
        log_error err_disk_not_enough "$SWAP_SIZE_GB"
        log_error err_disk_available "$((available_kb / 1024))"
        log_error err_disk_reserve
        return 1
    fi

    log_ok ok_disk
}

is_swap_signature() {
    local signature=""

    if ! have blkid; then
        log_error err_blkid_missing_verify "$SWAPFILE"
        return 1
    fi

    signature=$(blkid -p -o value -s TYPE "$SWAPFILE" 2>/dev/null) || signature=""

    if [ -z "$signature" ]; then
        signature=$(blkid -o value -s TYPE "$SWAPFILE" 2>/dev/null) || signature=""
    fi

    [ "$signature" = "swap" ]
}

create_swapfile() {
    local allocated=0

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_create "$SWAPFILE" "$SWAP_SIZE_GB"
        return 0
    fi

    log_info info_creating "$SWAP_SIZE_GB"

    # From now on the file belongs to this run, a failure removes it again.
    # 从这一刻起文件归本次运行所有，失败时会被清理掉。
    SWAPFILE_OWNED=1

    if [ "$USE_DD" -eq 1 ]; then
        if ! : > "$SWAPFILE"; then
            log_error err_create_file "$SWAPFILE"
            return 1
        fi

        if ! chattr +C "$SWAPFILE"; then
            log_error err_chattr_failed
            return 1
        fi
    fi

    if [ "$USE_DD" -eq 0 ] && have fallocate; then
        if fallocate -l "${SWAP_SIZE_GB}G" "$SWAPFILE"; then
            allocated=1
        else
            log_warn warn_fallocate_failed
            rm -f "$SWAPFILE"
        fi
    elif [ "$USE_DD" -eq 0 ]; then
        log_warn warn_no_fallocate
    fi

    if [ "$allocated" -eq 0 ]; then
        if ! dd \
            if=/dev/zero \
            of="$SWAPFILE" \
            bs=1M \
            count=$((SWAP_SIZE_GB * 1024)) \
            status=progress
        then
            log_error err_dd_failed
            return 1
        fi
    fi

    if ! chmod 600 "$SWAPFILE"; then
        log_error err_chmod_file "$SWAPFILE"
        return 1
    fi

    if ! mkswap "$SWAPFILE"; then
        log_error err_mkswap "$SWAPFILE"
        return 1
    fi

    SWAP_CREATED=1
    MF_SWAPFILE_CREATED=1
    log_ok ok_swapfile_created
}

# The pattern accepts both "none swap" and "swap swap" plus tab separators,
# and it ignores commented lines.
#
# 该正则同时接受 "none swap" 与 "swap swap" 两种挂载点写法，
# 兼容 Tab 分隔，并忽略被注释掉的行。
fstab_has_swapfile() {
    grep -qE "^[[:space:]]*${SWAPFILE}[[:space:]]+[^#]*[[:space:]]swap([[:space:]]|\$)" "$FSTAB"
}

ensure_fstab_entry() {
    local backup_file

    if fstab_has_swapfile; then
        log_info info_fstab_present "$FSTAB" "$SWAPFILE"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_fstab "$SWAPFILE" "$FSTAB"
        return 0
    fi

    if [ ! -w "$FSTAB" ]; then
        log_error err_fstab_not_writable "$FSTAB"
        return 1
    fi

    backup_file="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"

    if ! cp -a "$FSTAB" "$backup_file"; then
        log_error err_fstab_backup "$FSTAB"
        return 1
    fi

    # Add the missing newline first so the new entry never joins the last line.
    # 最后一行缺少换行符时先补一个，避免新旧条目粘连成一行。
    if [ -s "$FSTAB" ] && [ -n "$(tail -c 1 "$FSTAB")" ]; then
        if ! printf '\n' >> "$FSTAB"; then
            log_error err_write_file "$FSTAB"
            return 1
        fi
    fi

    if ! printf '%s\n' "${SWAPFILE} none swap sw 0 0" >> "$FSTAB"; then
        log_error err_write_file "$FSTAB"
        return 1
    fi

    MF_FSTAB_ADDED=1

    log_ok ok_fstab_written "$SWAPFILE" "$FSTAB"
    log_info info_fstab_backup "$backup_file"
}

configure_swap() {
    local active_swap
    local existing_valid=0

    active_swap=$(get_active_swap)

    if [ -n "$active_swap" ]; then
        log_info info_swap_active "$(printf '%s' "$active_swap" | tr '\n' ' ')"
        log_info info_swap_preserved "$SWAPFILE"

        if swap_is_active "$SWAPFILE"; then
            if ! ensure_fstab_entry; then
                return 1
            fi
        else
            log_info info_swap_not_ours "$SWAPFILE" "$FSTAB"
        fi

        if ! write_swap_sysctl; then
            return 1
        fi

        SWAP_CONFIGURED=1
        log_ok ok_swap_checked
        return 0
    fi

    calculate_swap_size

    if [ -e "$SWAPFILE" ]; then
        log_warn warn_swapfile_idle "$SWAPFILE"

        if is_swap_signature; then
            log_info info_swapfile_signature "$SWAPFILE"
            existing_valid=1
        else
            log_error err_swapfile_unknown "$SWAPFILE"
            log_error err_swapfile_keep
            return 1
        fi
    else
        # Only a real creation needs the filesystem and disk space checks.
        # 只有真正需要创建文件时才检查文件系统与磁盘空间。
        if ! check_swapfile_support; then
            return 1
        fi

        if ! check_disk_space; then
            return 1
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_enable "$SWAPFILE" "$FSTAB"
        return 0
    fi

    if [ "$existing_valid" -eq 0 ]; then
        if ! create_swapfile; then
            return 1
        fi
    fi

    if ! chmod 600 "$SWAPFILE"; then
        log_error err_chmod_file "$SWAPFILE"
        return 1
    fi

    if ! swapon "$SWAPFILE"; then
        log_error err_swapon "$SWAPFILE"
        log_error err_swapon_reason
        return 1
    fi

    # The file may now take part in swapping, never delete it from here on.
    # 从此刻起文件可能已经参与交换，之后的失败都不应删除它。
    SWAP_ACTIVATED=1
    MF_SWAPFILE_ENABLED=1

    if ! swap_is_active "$SWAPFILE"; then
        log_error err_swapon_not_listed "$SWAPFILE"
        swapoff "$SWAPFILE" 2>/dev/null || true
        SWAP_ACTIVATED=0
        return 1
    fi

    if ! ensure_fstab_entry; then
        log_warn warn_fstab_after_swap "$FSTAB"
        return 1
    fi

    if ! write_swap_sysctl; then
        log_warn warn_sysctl_after_swap
        return 1
    fi

    SWAP_CONFIGURED=1
    log_ok ok_swap_configured
}

detect_virtualization() {
    if have systemd-detect-virt; then
        systemd-detect-virt 2>/dev/null || true
    else
        printf '%s\n' "unknown"
    fi
}

migrate_legacy_configs() {
    local legacy_file
    local base
    local backup_dir

    for legacy_file in "$LEGACY_SWAP_CONFIG" "$LEGACY_BBR_CONFIG"; do
        if [ ! -e "$legacy_file" ]; then
            continue
        fi

        if ! head -n 1 "$legacy_file" 2>/dev/null | grep -q 'Managed by debian-swap-bbr'; then
            log_warn warn_legacy_foreign "$legacy_file"
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log_info dryrun_delete_legacy "$legacy_file"
            continue
        fi

        # Legacy files are moved into the backup directory instead of being
        # deleted, so a restore can put them back.
        #
        # 旧版文件改为移动进备份目录而不是直接删除，
        # 这样恢复时还能放回去。
        if [ -z "$MF_LEGACY_BACKUP" ]; then
            backup_dir="${STATE_DIR}/backup.$(date +%Y%m%d-%H%M%S)"

            if ! mkdir -p "$backup_dir"; then
                log_error err_mkdir_failed "$backup_dir"
                continue
            fi

            MF_LEGACY_BACKUP="$backup_dir"
        fi

        base="${legacy_file##*/}"

        if mv "$legacy_file" "${MF_LEGACY_BACKUP}/${base}"; then
            log_ok ok_deleted_legacy "$legacy_file"
        else
            log_warn warn_delete_legacy_failed "$legacy_file"
        fi
    done
}

reload_units() {
    if [ "$DRY_RUN" -eq 1 ] || ! have systemctl; then
        return 0
    fi

    if systemctl daemon-reload; then
        log_ok ok_daemon_reload
    else
        log_warn warn_daemon_reload
    fi
}

# Only the exact line written by this script is removed, anything else in
# fstab is preserved byte for byte.
#
# 只删除由本脚本写入的那一行精确内容，fstab 的其余部分保持原样。
remove_fstab_entry() {
    local entry="${SWAPFILE} none swap sw 0 0"
    local backup_file
    local tmp_file

    if ! grep -qxF -- "$entry" "$FSTAB"; then
        log_warn warn_fstab_line_missing "$FSTAB" "$SWAPFILE"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_fstab_remove "$FSTAB" "$SWAPFILE"
        return 0
    fi

    backup_file="${FSTAB}.bak.$(date +%Y%m%d-%H%M%S)"

    if ! cp -a "$FSTAB" "$backup_file"; then
        log_error err_fstab_backup "$FSTAB"
        return 1
    fi

    tmp_file="${FSTAB}.swapbbr.tmp"
    grep -vxF -- "$entry" "$FSTAB" > "$tmp_file" || true

    if ! cat "$tmp_file" > "$FSTAB"; then
        rm -f "$tmp_file"
        log_error err_write_file "$FSTAB"
        return 1
    fi

    rm -f "$tmp_file"

    log_ok ok_fstab_line_removed "$FSTAB" "$SWAPFILE"
    log_info info_fstab_backup "$backup_file"

    reload_units
}

# A file is removed when the install record says this script created it, or
# when its first line carries the script marker. Everything else is kept.
#
# 安装记录证明是本脚本创建的，或首行带有脚本标记的文件才会被删除，
# 其他文件一律保留。
remove_owned_file() {
    local file="$1"
    local recorded="$2"

    if [ ! -e "$file" ]; then
        log_info info_file_absent "$file"
        return 0
    fi

    if [ "$recorded" -ne 1 ] && ! head -n 1 "$file" 2>/dev/null | grep -q 'Managed by debian-swap-bbr'; then
        log_warn warn_file_not_ours "$file"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_remove_file "$file"
        return 0
    fi

    if rm -f "$file"; then
        log_ok ok_swapfile_removed "$file"
    else
        log_error err_remove_file "$file"
        return 1
    fi
}

restore_legacy_backups() {
    local legacy_file
    local source_file
    local base

    if [ -z "$MF_LEGACY_BACKUP" ]; then
        return 0
    fi

    if [ ! -d "$MF_LEGACY_BACKUP" ]; then
        log_warn warn_legacy_backup_missing "$MF_LEGACY_BACKUP"
        return 0
    fi

    for legacy_file in "$LEGACY_SWAP_CONFIG" "$LEGACY_BBR_CONFIG"; do
        base="${legacy_file##*/}"
        source_file="${MF_LEGACY_BACKUP}/${base}"

        if [ ! -e "$source_file" ]; then
            continue
        fi

        if [ -e "$legacy_file" ]; then
            log_warn warn_legacy_exists "$legacy_file"
            continue
        fi

        if [ "$DRY_RUN" -eq 1 ]; then
            log_info dryrun_restore_legacy "$legacy_file"
            continue
        fi

        if mv "$source_file" "$legacy_file"; then
            log_ok ok_legacy_restored "$legacy_file"
        else
            log_error err_write_file "$legacy_file"
        fi
    done

    rmdir "$MF_LEGACY_BACKUP" 2>/dev/null || true
    return 0
}

restore_one_sysctl() {
    local key="$1"
    local value="$2"

    if [ -z "$value" ]; then
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_sysctl "$key" "$value"
        return 0
    fi

    if sysctl -q -w "${key}=${value}"; then
        log_ok info_prev_restored "$key" "$value"
    else
        log_warn warn_sysctl_restore_failed "$key"
    fi
}

restore_sysctl_values() {
    if [ "$MF_PREV_VALUES_OK" -ne 1 ]; then
        log_warn warn_prev_unknown
        return 0
    fi

    restore_one_sysctl "vm.swappiness" "$MF_PREV_SWAPPINESS"
    restore_one_sysctl "vm.vfs_cache_pressure" "$MF_PREV_VFS_CACHE_PRESSURE"
    restore_one_sysctl "net.core.default_qdisc" "$MF_PREV_QDISC"
    restore_one_sysctl "net.ipv4.tcp_congestion_control" "$MF_PREV_CC"
}

restore_all() {
    local failed=0

    log_info restore_start

    if [ "$MANIFEST_EXISTS" -eq 0 ]; then
        log_warn restore_no_state
    fi

    if swap_is_active "$SWAPFILE"; then
        if [ "$MF_SWAPFILE_ENABLED" -eq 1 ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_info dryrun_swapoff "$SWAPFILE"
            elif swapoff "$SWAPFILE"; then
                log_ok ok_swapoff "$SWAPFILE"
            else
                log_error err_swapoff "$SWAPFILE"
                log_warn err_restore_failed
                return 1
            fi
        else
            log_warn warn_swap_active_kept "$SWAPFILE"
        fi
    fi

    # The file is deleted only when the install record proves this script
    # created it, an already existing swap file is always kept.
    #
    # 只有安装记录证明文件由本脚本创建时才删除，已有文件一律保留。
    if [ "$MF_SWAPFILE_CREATED" -eq 1 ] && [ -e "$SWAPFILE" ]; then
        if swap_is_active "$SWAPFILE"; then
            log_warn warn_swap_active_kept "$SWAPFILE"
        elif [ "$DRY_RUN" -eq 1 ]; then
            log_info dryrun_remove_file "$SWAPFILE"
        elif rm -f "$SWAPFILE"; then
            log_ok ok_swapfile_removed "$SWAPFILE"
        else
            log_error err_remove_file "$SWAPFILE"
            failed=1
        fi
    fi

    if [ "$MF_FSTAB_ADDED" -eq 1 ]; then
        if ! remove_fstab_entry; then
            failed=1
        fi
    elif fstab_has_swapfile; then
        log_info info_fstab_kept "$FSTAB"
    fi

    if ! remove_owned_file "$SWAP_CONFIG" "$MF_SWAP_CONFIG"; then
        failed=1
    fi

    if ! remove_owned_file "$BBR_CONFIG" "$MF_BBR_CONFIG"; then
        failed=1
    fi

    if ! remove_owned_file "$BBR_MODULE_CONFIG" "$MF_MODULE_CONFIG"; then
        failed=1
    fi

    restore_legacy_backups
    restore_sysctl_values

    if have lsmod && lsmod | awk '$1 == "tcp_bbr" {found = 1} END {exit !found}'; then
        log_warn warn_module_loaded
    fi

    if [ "$failed" -ne 0 ]; then
        log_warn err_restore_failed
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_ok ok_dryrun_done
        return 0
    fi

    if ! clear_state; then
        log_warn err_restore_failed
        return 1
    fi

    log_ok ok_restore_done
    return 0
}

configure_bbr() {
    local virtualization
    local available_cc
    local module_available=0

    virtualization=$(detect_virtualization)

    if have systemd-detect-virt && systemd-detect-virt --container >/dev/null 2>&1; then
        log_warn warn_container "$virtualization"
        log_warn warn_container_detail
        log_warn warn_container_continue
    else
        log_info info_virt "$virtualization"
    fi

    if have modprobe; then
        if modprobe -n tcp_bbr >/dev/null 2>&1; then
            module_available=1
        fi

        if [ "$DRY_RUN" -eq 0 ] && ! modprobe tcp_bbr 2>/dev/null; then
            log_warn warn_modprobe_failed
        fi
    else
        log_warn warn_modprobe_missing
    fi

    available_cc=$(
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null ||
            true
    )

    if ! grep -qw 'bbr' <<< "$available_cc"; then
        if [ "$DRY_RUN" -eq 1 ] && [ "$module_available" -eq 1 ]; then
            log_info dryrun_module_present
        else
            log_error err_bbr_unsupported
            log_error err_bbr_available "${available_cc:-unknown}"
            log_error err_bbr_no_third_party
            return 1
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info dryrun_write_file "$BBR_CONFIG"
        return 0
    fi

    if [ "$module_available" -eq 1 ]; then
        if ! ensure_config_dir "$MODULES_LOAD_DIR"; then
            return 1
        fi

        if ! {
            printf '%s\n' '# Managed by debian-swap-bbr'
            printf '%s\n' '# 由 debian-swap-bbr 管理'
            printf '%s\n' 'tcp_bbr'
        } > "$BBR_MODULE_CONFIG"
        then
            log_error err_write_file "$BBR_MODULE_CONFIG"
            return 1
        fi

        if ! chmod 644 "$BBR_MODULE_CONFIG"; then
            log_error err_chmod_file "$BBR_MODULE_CONFIG"
            return 1
        fi

        MF_MODULE_CONFIG=1
    else
        log_info info_bbr_builtin "$BBR_MODULE_CONFIG"
    fi

    if ! ensure_config_dir "$SYSCTL_DIR"; then
        return 1
    fi

    if ! cat > "$BBR_CONFIG" <<'EOF'
# Managed by debian-swap-bbr
# 由 debian-swap-bbr 管理
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    then
        log_error err_write_file "$BBR_CONFIG"
        return 1
    fi

    if ! chmod 644 "$BBR_CONFIG"; then
        log_error err_chmod_file "$BBR_CONFIG"
        return 1
    fi

    MF_BBR_CONFIG=1

    if ! sysctl -q -p "$BBR_CONFIG"; then
        log_error err_apply_sysctl_file "$BBR_CONFIG"
        return 1
    fi

    BBR_CONFIGURED=1
    log_ok ok_bbr_written
}

check_sysctl_conflicts() {
    local line
    local key
    local found=0

    if [ ! -r /etc/sysctl.conf ]; then
        return 0
    fi

    while IFS= read -r line; do
        key="${line%%=*}"
        key="${key//[[:space:]]/}"

        case "$key" in
            ''|'#'*)
                continue
                ;;
            vm.swappiness|vm.vfs_cache_pressure|net.ipv4.tcp_congestion_control|net.core.default_qdisc)
                log_warn warn_sysctl_conflict "/etc/sysctl.conf" "$key"
                found=1
                ;;
        esac
    done < /etc/sysctl.conf

    if [ "$found" -eq 1 ]; then
        log_warn warn_sysctl_order
    fi

    return 0
}

verify_result() {
    local failed=0
    local value

    if [ "$SWAP_CONFIGURED" -eq 1 ]; then
        if [ -z "$(get_active_swap)" ]; then
            log_error err_verify_no_swap
            failed=1
        fi

        value=$(sysctl -n vm.swappiness 2>/dev/null) || value=""
        if [ "$value" != "10" ]; then
            log_error err_verify_value "vm.swappiness" "10" "${value:-unknown}"
            log_error err_verify_hint "$SWAP_CONFIG"
            failed=1
        fi

        value=$(sysctl -n vm.vfs_cache_pressure 2>/dev/null) || value=""
        if [ "$value" != "50" ]; then
            log_error err_verify_value "vm.vfs_cache_pressure" "50" "${value:-unknown}"
            log_error err_verify_hint "$SWAP_CONFIG"
            failed=1
        fi
    fi

    if [ "$BBR_CONFIGURED" -eq 1 ]; then
        value=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || value=""
        if [ "$value" != "bbr" ]; then
            log_error err_verify_value "net.ipv4.tcp_congestion_control" "bbr" "${value:-unknown}"
            log_error err_verify_hint "$BBR_CONFIG"
            failed=1
        fi

        value=$(sysctl -n net.core.default_qdisc 2>/dev/null) || value=""
        if [ "$value" != "fq" ]; then
            log_warn warn_verify_qdisc "net.core.default_qdisc" "fq" "${value:-unknown}"
            log_warn warn_verify_qdisc_hint
        fi
    fi

    [ "$failed" -eq 0 ]
}

show_result() {
    local available_cc
    local current_cc
    local current_qdisc
    local fstype

    available_cc=$(
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null ||
            printf '%s' "unknown"
    )

    current_cc=$(
        sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null ||
            printf '%s' "unknown"
    )

    current_qdisc=$(
        sysctl -n net.core.default_qdisc 2>/dev/null ||
            printf '%s' "unknown"
    )

    fstype=$(get_root_fstype)

    echo
    printf '%s\n' "$(msg result_title)"

    echo
    printf '%s\n' "$(msg label_swap)"
    swapon --show || true
    free -h || true

    echo
    printf '%s\n' "$(msg label_bbr)"
    printf '%s\n' "$(msg result_available_cc "$available_cc")"
    printf '%s\n' "$(msg result_current_cc "$current_cc")"
    printf '%s\n' "$(msg result_qdisc "$current_qdisc")"

    if have lsmod && lsmod | awk '$1 == "tcp_bbr" {found = 1} END {exit !found}'; then
        printf '%s\n' "$(msg result_module_loaded)"
    else
        printf '%s\n' "$(msg result_module_unknown)"
    fi

    echo
    printf '%s\n' "$(msg label_files)"
    printf '%s\n' "$(msg result_root_fstype "$fstype")"
    printf '%s\n' "$(msg result_swap_conf "$SWAP_CONFIG")"
    printf '%s\n' "$(msg result_bbr_conf "$BBR_CONFIG")"
    printf '%s\n' "$(msg result_bbr_module_conf "$BBR_MODULE_CONFIG")"

    if [ "$DRY_RUN" -eq 0 ] || [ -e "$STATE_FILE" ]; then
        printf '%s\n' "$(msg result_state_file "$STATE_FILE")"
    fi

    if fstab_has_swapfile; then
        printf '%s\n' "$(msg result_fstab_has "$FSTAB" "$SWAPFILE")"
    else
        printf '%s\n' "$(msg result_fstab_has_not "$FSTAB" "$SWAPFILE")"
    fi

    if [ "$SWAP_CREATED" -eq 1 ]; then
        printf '%s\n' "$(msg result_swapfile_new "$SWAPFILE")"
    elif [ -e "$SWAPFILE" ]; then
        printf '%s\n' "$(msg result_swapfile_existing "$SWAPFILE")"
    else
        printf '%s\n' "$(msg result_swapfile_none)"
    fi

    if [ "$SWAP_CONFIGURED" -eq 1 ]; then
        printf '%s\n' "$(msg result_swap_ok)"
    else
        printf '%s\n' "$(msg result_swap_fail)"
    fi

    if [ "$BBR_CONFIGURED" -eq 1 ]; then
        printf '%s\n' "$(msg result_bbr_ok)"
    else
        printf '%s\n' "$(msg result_bbr_fail)"
    fi

    printf '%s\n' "=========================================="
}

main() {
    local failed=0

    # Resolve the language before parsing so that parse errors are localized.
    # 先确定语言再解析参数，这样参数错误也能用正确的语言提示。
    LANGUAGE=$(detect_language)
    prescan_language "$@"

    parse_arguments "$@"
    require_root
    check_operating_system
    check_required_commands
    load_state

    if [ "$RESTORE" -eq 1 ]; then
        if restore_all; then
            exit 0
        fi
        exit 1
    fi

    capture_previous_state

    echo
    if [ "$DRY_RUN" -eq 1 ]; then
        log_info info_dryrun_start
    else
        log_info info_start
    fi

    migrate_legacy_configs

    if ! configure_swap; then
        failed=1
        log_error err_swap_incomplete
    fi

    if ! configure_bbr; then
        failed=1
        log_error err_bbr_incomplete
    fi

    check_sysctl_conflicts

    if [ "$DRY_RUN" -eq 0 ]; then
        if ! verify_result; then
            failed=1
            log_error err_verify_failed
        fi
    fi

    if [ "$DRY_RUN" -eq 0 ] && state_changed; then
        if write_state; then
            log_info info_state_written "$STATE_FILE"
        else
            failed=1
        fi
    fi

    if [ "$failed" -ne 0 ]; then
        # Explicit "return 1" paths never reach the ERR trap, clean up here.
        # 显式 return 1 的路径不会触发 ERR trap，这里统一清理半成品。
        cleanup_partial || true
    fi

    show_result

    if [ "$failed" -ne 0 ]; then
        log_warn warn_partial
        exit 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_ok ok_dryrun_done
        exit 0
    fi

    log_ok ok_all_done
    log_info info_takes_effect
}

main "$@"
