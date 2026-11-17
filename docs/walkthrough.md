# Comprehensive Walkthrough of debian-swap-bbr (For Readers with Basic Python Familiarity)

[English](walkthrough.md) | [简体中文](walkthrough.zh-CN.md)

> Structure: High-level overview → Core Bash concepts mapped from Python → Section-by-section code breakdown → Topology, cheat sheet, runtime effects, and reading guide.
> After reading, you will understand: what lives in this repository, what every line in the script does, how functions invoke each other, and how the operating system changes after execution.

> **Version Note**: This guide is based on **v1.4.1**. When inspecting the code, rely on function names as anchors (see Section 5.2 for the cheat sheet).

---

## Section 0.5: Version Evolution & Key Boundary Hardening

The core purpose of this script is straightforward: "configure Swap and enable BBR". However, across iterations (especially v1.4.0 and v1.4.1), significant industrial-grade defensive hardening was integrated:

| Hardening Item | Problem Solved & Practical Impact |
| --- | --- |
| `--restore` verification only requires "Swap enabled by this script" to be inactive | Servers with a pre-existing `/swapfile` before running the script will no longer fail restore verification indefinitely. |
| Managed file ownership identification changed to **exact first-line header matching** | User config files containing comments that mention the repo name are no longer misidentified as script-managed files, preventing unintended overwrites or deletions. |
| `handle_error` and `on_interrupt` write the state record before exiting | If an unexpected error occurs midway or the user presses Ctrl+C, `--restore` can still cleanly undo every modification made up to that point. |
| Concurrency lock via `acquire_lock` (`flock` exclusive lock) | Multiple instances running concurrently are serialized; fstab and state files will never suffer from race conditions or interleaved writes. |
| `fstab` entry removal supports **atomic replacement and symlink protection** | Atomic rename prevents corrupted or truncated fstab files during sudden power loss. If `/etc/fstab` is a symbolic link, it automatically falls back to in-place rewrite, preserving symlink integrity. |
| **Immediate cleanup on creation failure** | If Swap creation fails midway (e.g. disk becomes 100% full during `dd`), the partial file is removed immediately to free disk space, preventing cascading system crashes. |
| Skip `modprobe` when BBR is already built-in | Kernels with statically built-in BBR (custom compiled or cloud provider kernels) no longer trigger spurious yellow "failed to load module" warnings. |
| Conflict scan supports `#` and `;` inline comments and files missing trailing newlines | Conforms to sysctl parsing standards by stripping semicolon comments (eliminating false positive conflicts) and reliably reads files even if the final line lacks a newline character. |
| Conflict precedence compared strictly by configuration category | Memory parameters are checked against `swap.conf`, while network parameters are checked against `bbr.conf`, eliminating false warnings caused by alphabetical sorting order. |
| Expected values unified under `EXPECTED_*` constants | File generation, conflict scanning, and verification share a single source of truth, preventing configuration drift. |
| ANSI color detection split independently between stdout and stderr | When stdout is redirected to a file or pipe, stderr error messages still retain full terminal color highlighting. |
| Internal language variable renamed to `OUTPUT_LANG` | Fully decoupled from gettext's standard `LANGUAGE` environment variable for clean, predictable localization. |
| State persistence uses "temporary file + atomic rename" | Interruptions during state writes will never leave a truncated, corrupted state file on disk. |
| Automated CI regression tests (CLI parsing and message tables) | Every change automatically verifies message dictionary parity and command-line boundary validation in GitHub Actions. |

---

## Section 0: Prerequisite — This is Not a Python Script

The executable file doing the actual work is `setup-swap-bbr.sh`. The `.sh` extension indicates that it is a **shell script** written in Bash, intended to run in a Linux (Debian) terminal rather than via `python xxx.py`.

The mental model is virtually identical to Python. Variables, functions, loops, branch logic, dictionaries, argument handling, and exception management are all present—only the syntax differs:

| Concept | Python | This Bash Script | Plain Explanation |
| --- | --- | --- | --- |
| Variable | `x = 1` | `X=1`, referenced as `$X` | A labeled box holding data |
| Constant | UPPERCASE convention | `readonly X=...` | A sealed box that cannot be reassigned |
| Function | `def f(a): ...` | `f() { ... }`, args via `$1`, `$2` | A named, reusable sequence of steps |
| Return value | `return val` | `return 0` (success), `return 1` (failure) | Answers only: "did it succeed or fail?" |
| Condition | `if x == 1: ... else:` | `if [ "$X" -eq 1 ]; then ... fi` or `case ... esac` | If condition holds, do A; otherwise do B |
| Loop | `for x in list:` | `for x in "${arr[@]}"; do ... done` | Repeat an action over a collection |
| List / Array | `list = [a, b]` | `arr=(a b)` | An ordered row of boxes |
| Dictionary / Map | `d = {"k": "v"}` | `declare -A D=( [k]='v' )`, read via `${D[k]}` | A key-value lookup table |
| String formatting | `"hi %s" % name` | `printf 'hi %s\n' "$name"` | Fill placeholders inside a template sentence |
| CLI arguments | `sys.argv` | `"$@"` (all args), `$1` (first arg) | Flags and arguments provided by the user |
| Capturing output | `s = f()` | `s=$(command)` | Save command standard output into a variable |
| Error handling | `try / except` | `trap '...' ERR` | Intercept errors and execute cleanup logic |

### How "Module Imports" Differ in Bash

In Python, code is split across files and loaded via `import`. **Bash does not have an `import` statement**. The script uses two mechanisms instead:

1. **Directly invoking system utility binaries**, such as `awk`, `grep`, `df`, `sysctl`, `swapon`, `chmod`, and `cp`. These act like pre-installed standard library functions. Running `sysctl -n vm.swappiness` is equivalent to calling a library function and capturing its return value. The script verifies the presence of these utilities during startup.
2. **Reading data files into the current environment using the dot command (`. filename`)**. For example, `. /etc/os-release` is the closest Bash equivalent to an import: it loads key-value pairs into variables like `$ID` and `$PRETTY_NAME`. It imports configuration data, not executable code modules.

Localization strings are embedded directly within the script as associative arrays rather than in external JSON or `.po` files. Consequently, **the entire core functionality resides in a single self-contained script**. There are no circular dependencies or complex package structures; functions call each other by name within the same file.

---

## Section 1: Overview

### 1.1 Problems Solved by this Script

Fresh Debian cloud servers or VPS instances often have two non-ideal default states:

- **No Swap Space**: When memory is exhausted, the Linux kernel Out-Of-Memory (OOM) killer abruptly terminates processes. Swap reserves space on disk to park idle memory pages when RAM is constrained. While disk I/O is slower than RAM, it prevents critical processes from crashing.
- **BBR Congestion Control Disabled**: BBR (Bottleneck Bandwidth and RTT) is a modern congestion control algorithm built into the Linux kernel. Under packet loss and network congestion, BBR maintains higher throughput and lower latency compared to legacy loss-based algorithms like Reno or CUBIC.

This script configures both features using a single command, and **strictly limits its scope to these two tasks**. The header comments (lines 3–38) outline its operational boundaries:

- **What it does**: Verifies system prerequisites and root privileges; preserves existing Swap partitions; creates `/swapfile` only when needed; sizes Swap proportionally to RAM; enables the kernel's built-in BBR; guarantees idempotency (safe to re-run); supports `--dry-run`, `--restore`, and `--lang`.
- **What it never does**: Does not alter SSH configurations; does not touch firewall rules (iptables/nftables); does not install third-party kernels; never deletes pre-existing Swap files or partitions.

This strict boundary ensures predictability and safety across diverse server environments.

### 1.2 Three Primary Modes of Use

```bash
sudo ./setup-swap-bbr.sh              # Standard execution: apply configuration
sudo ./setup-swap-bbr.sh --dry-run     # Dry-run: preview planned actions without modifying the system
sudo ./setup-swap-bbr.sh --restore     # Restore: revert all changes made by this script
```

| Option | Description |
| --- | --- |
| `--swap-size N` or `--swap-size=N` | Manually specify Swap size in GiB (1–32). If omitted, automatically determined based on RAM. |
| `-l` / `--lang en` or `zh-CN` | Explicitly choose UI output language (`en` or `zh-CN`). |
| `-n` / `--dry-run` | Simulation mode. Verifies checks and prints planned changes with zero disk/kernel modifications. |
| `--restore` / `--uninstall` | Restore mode. Reverts sysctl parameters, removes managed configs and swapfile, and restores backups. |
| `-h` / `--help` | Display command usage and flag descriptions. |
| `-V` / `--version` | Display version information (current: 1.4.1). |

### 1.3 Repository File Layout

```text
debian-swap-bbr/
├── docs/
│   ├── walkthrough.zh-CN.md            # In-depth Chinese code walkthrough
│   └── walkthrough.md                  # In-depth English code walkthrough (this document)
├── tests/
│   ├── cli.sh                          # Regression tests for CLI argument parsing and unprivileged usage
│   └── check-messages.sh               # CI validation for complete localization dictionary parity
├── .github/workflows/shellcheck.yml    # CI pipeline for ShellCheck and test runners
├── setup-swap-bbr.sh                   # Main script (~2640 lines of Bash)
├── README.md                           # Primary English documentation
├── README.zh-CN.md                     # Primary Chinese documentation
├── LICENSE                             # MIT License
├── .gitattributes                      # Enforces LF line endings across platforms
├── .gitignore                          # Git ignore definitions
└── .shellcheckrc                       # Tailored ShellCheck rule configurations
```

All operational logic resides inside `setup-swap-bbr.sh`.

### 1.4 The Script in One Sentence

> The final line `main "$@"` is the sole entry point; `main` coordinates execution by detecting language, parsing flags, validating the environment, recording baseline state, configuring Swap, activating BBR, scanning for sysctl conflicts, verifying runtime values, writing the state manifest, and presenting a summary panel—or routing to `restore_all` if `--restore` is passed, with all failures trapped to clean up partial state.

### 1.5 Observable Runtime Effects

- **On Screen**: Structured log messages tagged with `[OK]`, `[INFO]`, `[WARN]`, and `[ERROR]` (with ANSI terminal colors), culminating in a formatted configuration summary panel.
- **On the System**: When needed, creates `/swapfile`, appends an entry to `/etc/fstab`, writes configuration files to `/etc/sysctl.d/99-zz-local-*.conf`, adds `/etc/modules-load.d/bbr.conf` (if modular), writes `/var/lib/debian-swap-bbr/state`, and applies 4 kernel parameters live without requiring a reboot.
- **Exit Codes**: `0` on success, `1` on general failure or unmet prerequisites, `2` on invalid CLI syntax, and `130` on user interrupt (SIGINT/Ctrl+C).

---

## Section 2: Five Core Concepts in Source Code

### 2.1 Functions: Naming Reusable Steps

```bash
have() {
    command -v "$1" >/dev/null 2>&1
}
```

This helper tests whether a given binary exists in `$PATH`. In Python, one would write `def have(cmd): ...`. In Bash, functions are declared as `name() { ... }`. Arguments are accessed positionally: `$1` is the first argument, `$2` is the second, and `local x=...` defines a local variable scoped to the function.

**Bash convention**: `return 0` represents success ("truthy" / no error), while non-zero values (such as `return 1`) represent failure. Thus, patterns like `if ! some_func; then ... fi` read as "if this function did not succeed, handle the error".

### 2.2 Branching: `if` and `case`

```bash
if [ "${EUID}" -ne 0 ]; then
    log_error err_root_required
    log_error err_rerun_sudo "$SCRIPT_NAME"
    exit 1
fi
```

Reads as: "If the effective user ID is not 0 (not root), print an error and exit with code 1".
- `-ne` / `-eq`: Numeric inequality / equality.
- `-z` / `-n`: String is empty / non-empty.
- `-e` / `-f` / `-d` / `-L`: Path exists / is regular file / is directory / is symbolic link.

Multi-branch conditions use `case ... esac` (analogous to Python's `match/case` or chained `elif`):
```bash
case "$value" in
    en)                                    OUTPUT_LANG="en" ;;
    zh-CN|zh|zh_CN|zh_cn|zh-Hans|zh-hans)  OUTPUT_LANG="zh-CN" ;;
    *)                                     printf '[ERROR] Unsupported language: %s\n' "$value" >&2; exit 2 ;;
esac
```

### 2.3 Loops: `while` and `for`

- `while [ "$#" -gt 0 ]; do ... shift; done`: Iterates through CLI arguments. `shift` consumes the current `$1` and slides remaining arguments forward.
- `for command_name in "${required_commands[@]}"; do ... done`: Iterates over an array of required binary names.
- `while IFS= read -r line || [ -n "$line" ]; do ... done < "$file"`: Reads a file line-by-line. The trailing `|| [ -n "$line" ]` guarantees that if the last line lacks a trailing newline character (`\n`), it is still processed rather than silently discarded.

### 2.4 How "Imports" Work in Practice

To check whether the operating system is Debian, the script reads `/etc/os-release`:

```bash
. /etc/os-release
if [ "${ID:-}" != "debian" ]; then ... fi
```

The dot command (`.`) parses the file's variable assignments into the active shell environment. Beyond reading system metadata, modularity is achieved through Unix CLI tools: `df` inspects filesystem capacity, `sysctl` queries and modifies kernel parameters, `mkswap` writes swap metadata, and `swapon` activates space in the VM subsystem. The syntax `output=$(command)` (command substitution) captures standard output into a variable.

### 2.5 Three Key Engineering Habits

- **0/1 as Boolean Flags**: Bash lacks native boolean data types; integers `0` and `1` represent false and true flags (e.g., `DRY_RUN=1`).
- **`>&2` Redirects to Standard Error**: `log_warn` and `log_error` direct output to stderr via `>&2`. When standard output is piped to a file or tool (`./setup-swap-bbr.sh > install.log`), error messages remain immediately visible on the console.
- **Idempotency**: Running an operation once or one hundred times yields the exact same end state. Existing `/etc/fstab` lines are not duplicated, active Swap is preserved, and files bearing script ownership markers are safely managed.

---

## Section 3: Step-by-Step Code Walkthrough

### 3.1 Header and Safety Directives (Lines 1–43)

- Line 1: `#!/usr/bin/env bash` declares Bash as the interpreter.
- Line 41: `set -Eeuo pipefail`:
  - `-e`: Aborts immediately if an unhandled command returns a non-zero exit code.
  - `-u`: Treats references to unset variables as fatal errors.
  - `-o pipefail`: Propagates pipeline errors so that failure at any pipeline stage fails the entire pipe.
  - `-E`: Ensures `ERR` traps are inherited by shell functions and command substitutions.
- Line 42: `umask 022`: Enforces standard default file creation permissions (644 for files, 755 for directories).

### 3.2 Constants Pool: `readonly` (Lines 44–75)

| Constant | Value | Purpose |
| --- | --- | --- |
| `SCRIPT_NAME` / `SCRIPT_VERSION` | Script filename / `1.4.1` | Displayed in help text, version output, and state manifest |
| `EXPECTED_*` | `10` / `50` / `bbr` / `fq` | Single source of truth for target kernel values |
| `SWAPFILE` / `FSTAB` | `/swapfile` / `/etc/fstab` | Target system paths |
| `SYSCTL_DIR` / `MODULES_LOAD_DIR` | `/etc/sysctl.d` / `/etc/modules-load.d` | Drop-in directories for sysctl and module configuration |
| `STATE_DIR` / `STATE_FILE` | `/var/lib/debian-swap-bbr` / `state` | Persistent state tracking manifest location |
| `SWAP_CONFIG` / `BBR_CONFIG` | `99-zz-local-swap.conf` / `99-zz-local-bbr.conf` | Configuration filenames (`99-zz-` guarantees highest load precedence) |
| `BBR_MODULE_CONFIG` | `/etc/modules-load.d/bbr.conf` | Module persistence file for dynamic module kernels |

**Why `99-zz-`?**  
Debian loads sysctl files from `/etc/sysctl.d/` in natural lexicographical order; later files override earlier ones. Debian's default `/etc/sysctl.d/99-sysctl.conf` is a symlink pointing back to `/etc/sysctl.conf`. By prefixing filenames with `99-zz-`, the script guarantees its settings sort after Debian's defaults, ensuring settings persist cleanly across system reboots.

### 3.3 Runtime Variables Pool (Lines 76–108)

- **Execution Flags**: `DRY_RUN`, `RESTORE`, `USE_DD` (switches from `fallocate` to `dd` on Btrfs), and `CLEANING_UP` (re-entrancy guard).
- **Runtime Metadata**: `SWAP_SIZE_GB`, `SWAP_CREATED`, `SWAP_CONFIGURED`, `BBR_CONFIGURED`, `ROOT_FSTYPE`, `OUTPUT_LANG`.
- **Safety Line Dual Flags**: `SWAPFILE_OWNED=1` (created by the current process) and `SWAP_ACTIVATED=1` (active in the kernel). **Unactivated files are deleted immediately on failure; active files are never deleted abruptly**.
- **`MF_*` Manifest Family**: Variables serialized into the `state` file, tracking created files, fstab additions, and baseline kernel parameters (`MF_PREV_*`).

### 3.4 Terminal Color and Localization Dictionaries (Lines 109–534)

- `if [ -t 1 ]` and `if [ -t 2 ]`: Independently check whether stdout and stderr are attached to terminal devices before emitting ANSI escape color codes.
- `MSG_EN` and `MSG_ZH`: Associative arrays (`declare -A`) containing ~180 localized message keys. `tests/check-messages.sh` validates that both dictionaries share 100% identical keys.

### 3.5 Output Helpers (Lines 536–596)

- `msg key [args...]`: Looks up the translation string from `MSG_EN` or `MSG_ZH` based on `OUTPUT_LANG`, formatting arguments via `printf -- "$format" "$@"`.
- `log_ok / log_info / log_warn / log_error`: Formats log lines with green, cyan, yellow, or red level tags. Warnings and errors write directly to stderr.
- `have cmd`: Silently checks command existence via `command -v`.

### 3.6 State Manifest & Backup Management (Lines 603–871)

To ensure reliable reversal during `--restore`, the script records exactly what changes were made:
- `write_state`: Writes `MF_*` key-value pairs to a temporary file (`state.XXXXXX`), applies `chmod 644`, and atomically renames it over `state` via `mv -f`.
- `load_state`: Parses the manifest safely using `IFS='=' read -r key value`, avoiding arbitrary code execution hazards associated with sourcing external files.
- `backup_file_before_change`: Before overwriting any configuration file, if an existing file lacks the script's ownership header, it is backed up to a dedicated `backup.*` directory.
- `capture_previous_state`: Captures pre-existing kernel values **only during the initial installation when no prior state file exists**, preventing the script from recording its own modifications as historical baselines.

### 3.7 Language & Argument Parsing (Lines 873–1136)

- `prescan_language`: Performs a preliminary pass over CLI arguments specifically looking for `--lang`. If a subsequent argument fails validation (e.g., `--swap-size abc`), error messages are displayed in the user's preferred language immediately.
- `parse_arguments`: Processes all command-line flags and handles mutually exclusive options.
- `set_swap_size`: Validates integer input, restricts values to at most 2 digits, strips leading zeros using base-10 parsing (`10#$value`), and bounds input to 1–32 GiB.

### 3.8 Environment Validation Gates (Lines 1138–1222)

1. `require_root`: Verifies `EUID -eq 0`.
2. `check_operating_system`: Reads `/etc/os-release` and enforces `ID=debian`.
3. `check_required_commands`: Iterates through prerequisites (`awk`, `dd`, `free`, `swapon`, `sysctl`, etc.), outputting tailored `apt-get install` remediation commands if any are missing.

### 3.9 Concurrency Locking and Exception Trapping (Lines 1224–1251, 951–1040)

- `acquire_lock`: Obtains an exclusive non-blocking file lock in `/run` (`flock -n 9`). Concurrent instances exit immediately with code 1.
- `trap 'handle_error "$LINENO"' ERR`: Catches unhandled runtime errors. **Flushes the state manifest to disk, cleans up partial unactivated files, and terminates with the active exit code**.
- `trap 'on_interrupt INT' INT / TERM`: Handles SIGINT (Ctrl+C) and SIGTERM. **Flushes state**, removes partial files via `cleanup_partial`, and exits with standard signal exit codes (130/143).
- `cleanup_partial`: Surgical cleanup function. Only removes `/swapfile` if all four conditions are met: owned by the current run, not yet activated in the kernel, file exists on disk, and not listed in active system swap.

### 3.10 Swap Provisioning Logic (Lines 1253–1744)

1. **Size Decision**: `calculate_swap_size` checks physical RAM. Systems with ≤ 4096 MiB receive 2 GiB; systems with > 4096 MiB receive 4 GiB (explicit CLI arguments take precedence).
2. **Filesystem Compatibility**: `check_swapfile_support` inspects the root filesystem. Incompatible filesystems (`overlay`, `zfs`, `nfs`) trigger an immediate error; on `btrfs`, it switches to `USE_DD=1` and applies `chattr +C` (disabling Copy-on-Write).
3. **Capacity Check**: `check_disk_space` requires available storage to exceed "target swap size + 1 GiB safety margin".
4. **Allocation & Activation**:
   - Tries fast allocation via `fallocate`; falls back to zero-fill via `dd if=/dev/zero` if unsupported.
   - **Immediate cleanup on failure**: If allocation fails (e.g. disk full), `cleanup_partial` and `rm -f "$SWAPFILE"` run immediately to free space.
   - Sets file permissions to `chmod 600` and initializes swap metadata via `mkswap`.
   - Activates swap with `swapon "$SWAPFILE"`, verifying activation via `swap_is_active`.
5. **Persistence**: `ensure_fstab_entry` backs up `/etc/fstab`, appends the mount line idempotently, and calls `systemctl daemon-reload`.
6. **Sysctl Parameters**: `write_swap_sysctl` applies `vm.swappiness=10` and `vm.vfs_cache_pressure=50` via `sysctl -q -p`.

### 3.11 BBR Activation & Conflict Detection (Lines 2186–2417)

1. **Virtualization Check**: `detect_virtualization` identifies containerized environments (LXC, Docker) and logs appropriate notices.
2. **Built-in Kernel Detection & Module Loading**:
   - Inspects `available_cc` to see if `bbr` is already supported by the active kernel.
   - **If BBR is already built-in or available**, skips `modprobe` and avoids false warning messages.
   - If not yet loaded, attempts `modprobe tcp_bbr`.
   - For modular kernels, writes `/etc/modules-load.d/bbr.conf`; for statically compiled kernels, skips module persistence.
3. **Parameter Application**: Sets `net.core.default_qdisc=fq` and `net.ipv4.tcp_congestion_control=bbr`, applying them immediately.
4. **Comprehensive Conflict Scanning (`check_sysctl_conflicts`)**:
   - Scans `/etc/sysctl.conf` and `/etc/sysctl.d/*.conf`.
   - Strips both `#` and `;` inline comments according to sysctl specifications.
   - Uses `read -r line || [ -n "$line" ]` to handle files lacking trailing newlines.
   - Accurately checks precedence against respective target files: memory parameters against `swap.conf` and network parameters against `bbr.conf`.

### 3.12 Verification & Status Reporting (Lines 2419–2549)

- `verify_result`: Directly queries the kernel to verify swap space and sysctl parameters match expected values.
- `show_result`: Renders a structured status panel detailing swap memory allocation, active congestion algorithms, queue disciplines, and managed files.

### 3.13 Restoration Workflow (`--restore`) (Lines 1785–2184)

Executed in reverse dependency order with strict defense:
1. Deactivates Swap via `swapoff /swapfile` (only if the state manifest confirms it was activated by this script; aborts safely if deactivation fails).
2. `remove_fstab_entry`: Removes the fstab entry using a temporary file with atomic `mv -f` replacement. If `/etc/fstab` is a symlink, rewrites in-place to preserve link structure, followed by systemd reload.
3. Deletes `/swapfile` (only if created by this script; pre-existing swap is preserved).
4. Deletes script-owned `99-zz-local-*.conf` and `bbr.conf`.
5. Restores original user configuration files from `backup.*` directories.
6. Reverts the 4 sysctl parameters to their recorded pre-installation baselines.
7. Validates full system restoration and purges the state directory via `clear_state`.

### 3.14 Main Entry Flow (Lines 2551–2640)

```text
main "$@"
 ├── Determine language (detect_language / prescan_language)
 ├── Parse command-line flags (parse_arguments)
 ├── Environment validation (root check / Debian check / required commands)
 ├── Acquire exclusive lock (acquire_lock)
 ├── Load historical state manifest (load_state)
 ├── [Branch A: Restore Mode] restore_all → exit
 ├── [Branch B: Install Mode]
 │    ├── Capture baseline sysctl values (capture_previous_state)
 │    ├── Migrate legacy 90-local-*.conf files if present
 │    ├── Configure Swap (configure_swap) — immediate cleanup on error
 │    ├── Configure BBR (configure_bbr)
 │    ├── Scan for potential sysctl overrides (check_sysctl_conflicts)
 │    ├── Verify live kernel settings (verify_result)
 │    ├── Persist state manifest (write_state)
 │    └── Display status summary panel (show_result)
 └── Exit cleanly (exit 0 or exit 1)
```

---

## Section 4: Function Call Topology

```
[ Foundation Layer ]
  ├── Localization & Logging: msg → MSG_ZH / MSG_EN → log_ok / log_info / log_warn / log_error
  ├── Filesystem Helpers: have, file_has_marker, get_root_fstype, ensure_config_dir, reload_units
  ├── Backups & State: ensure_backup_dir → move_to_backup → backup_file_before_change
  └── Error & Signal Traps: trap (ERR / INT / TERM) → handle_error / on_interrupt → cleanup_partial

[ Core Orchestration (main) ]
  ├── Args & Environment: prescan_language, parse_arguments, require_root, check_operating_system, check_required_commands, acquire_lock
  ├── State Persistence: load_state, capture_previous_state, write_state, clear_state
  ├── Installation Pipeline:
  │     ├── configure_swap: calculate_swap_size, check_swapfile_support, check_disk_space, create_swapfile, ensure_fstab_entry, write_swap_sysctl
  │     └── configure_bbr: detect_virtualization, modprobe, backup_file_before_change, sysctl -p
  ├── Verification & Audit: check_sysctl_conflicts, verify_result
  └── Restoration Pipeline (restore_all):
        ├── swapoff / remove_fstab_entry / reload_units
        ├── remove_owned_file / restore_config_file
        ├── restore_sysctl_values → restore_one_sysctl
        └── verify_restore
```

---

## Section 5: Cheat Sheet

### 5.1 Key State Variables

| Variable | Type & Default | Description |
| :--- | :--- | :--- |
| `OUTPUT_LANG` | String (`en` / `zh-CN`) | Active output language driving `msg` formatting |
| `DRY_RUN` | Integer (`0` / `1`) | Simulation mode flag (log actions without modifying system) |
| `RESTORE` | Integer (`0` / `1`) | Uninstall / restoration mode flag |
| `SWAP_SIZE_GB` | Integer (default `0`) | Target Swap capacity in GiB |
| `SWAPFILE_OWNED` | Integer (`0` / `1`) | Indicates `/swapfile` was created by the active run |
| `SWAP_ACTIVATED` | Integer (`0` / `1`) | Indicates `/swapfile` is active in the kernel (safety boundary) |
| `MF_SWAPFILE_CREATED` | Integer (`0` / `1`) | Persisted flag: swapfile was created by the script |
| `MF_SWAPFILE_ENABLED` | Integer (`0` / `1`) | Persisted flag: swapfile was activated by the script |
| `MF_FSTAB_ADDED` | Integer (`0` / `1`) | Persisted flag: mount entry was appended to `/etc/fstab` |
| `MF_PREV_*` | String | Persisted baseline kernel values for restoration |

### 5.2 Core Functions

| Function | Module | Primary Responsibility |
| :--- | :--- | :--- |
| `prescan_language` | CLI Parsing | Pre-scans `--lang` so syntax errors can be localized |
| `acquire_lock` | Concurrency | Locks `/run/debian-swap-bbr.lock` to prevent race conditions |
| `cleanup_partial` | Fault Tolerance | Cleans up unactivated partial files on failure or interrupt |
| `create_swapfile` | Swap Core | Allocates file (fallocate/dd), sets permissions, runs mkswap |
| `ensure_fstab_entry`| Persistence | Appends swap mount entry to `/etc/fstab` idempotently |
| `configure_bbr` | BBR Core | Detects built-in kernel support, configures qdisc, enables BBR |
| `check_sysctl_conflicts` | Audit | Scans sysctl files, strips `#` and `;`, warns of overriding keys |
| `remove_fstab_entry` | Restore Core | Removes entry using atomic replacement with symlink preservation |
| `restore_all` | Restore Core | Reverts files, configurations, and sysctl values in reverse order |

---

## Section 6: Runtime Behavior & Safety Boundaries

### 6.1 Exit Codes

* `0`: Successful execution (including `--help`, `--version`, dry-run, and restore).
* `1`: General failure or unmet prerequisites (non-root, non-Debian, missing tool, insufficient disk space, kernel rejection, incomplete restore).
* `2`: Command-line syntax error (unrecognized flag, out-of-range value, mutually exclusive options).
* `130`: Interrupted by user via SIGINT (Ctrl+C); partial files cleaned up before exit.
* `143`: Terminated via SIGTERM signal; partial files cleaned up before exit.

### 6.2 Non-Negotiable Safety Guardrails

The script is strictly scoped and adheres to rigid guardrails:
* **Zero Network and Security Surface Modification**: Never modifies SSH configurations, never changes root credentials, and never alters firewall rules (iptables/nftables).
* **Zero Untrusted Third-Party Code**: Never installs unofficial third-party kernels (e.g. XanMod) and never fetches or runs remote code.
* **Preservation of Pre-Existing Assets**: Never deletes or shrinks pre-existing Swap partitions or swapfiles, never deletes unmanaged configuration files, and never replaces symlinked `/etc/fstab` files with regular files.

---

## Section 7: Recommended Reading Order for Beginners

1. **Header Comments (lines 3–38)**: Learn the explicit boundary of what the script does and does not do.
2. **Main Entry Function (`main`, lines 2551–2640)**: Trace the 18 sequential orchestration steps.
3. **Core Business Functions**: Study `configure_swap` and `configure_bbr` along with their error branches.
4. **Defensive Reversal Logic**: Read `restore_all` and `remove_fstab_entry` to understand idempotency and atomic file replacement.
5. **Safe Local Verification**: Run `sudo ./setup-swap-bbr.sh --dry-run` to trace code branches safely without making changes.
