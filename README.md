# Debian Swap and BBR Setup

[English](README.md) | [简体中文](README.zh-CN.md)

A script that configures swap and the standard BBR congestion control on a fresh Debian server.

The script inspects the current state and applies the configuration idempotently. Running it twice does not create a second swap file, and it never appends the same `/etc/fstab` entry twice. If an existing `/swapfile` is already enabled but the fstab entry is missing, the script adds it back.

## Features

- Check root privileges
- Check that the system is Debian
- Check the required system commands
- Keep the swap that already exists on the server
- Create `/swapfile` when no swap is enabled
- Pick the swap size from the physical memory
- Allow a manual swap size from 1 to 32 GiB
- Detect the root filesystem type, including btrfs, ZFS and overlay
- Check the free disk space
- Back up `/etc/fstab` and handle a missing trailing newline
- Set `vm.swappiness=10`
- Set `vm.vfs_cache_pressure=50`
- Check whether the running kernel provides BBR
- Enable `tcp_bbr`
- Set `fq` as the default queue discipline
- Detect container environments such as LXC and OpenVZ
- Verify the values that actually took effect instead of trusting exit codes
- Support `--dry-run` for a read-only check
- Support `--restore` to undo only the changes this script made
- Support `--lang` for the output language
- Stay idempotent

## What the script does not do

The script never:

- Modifies the SSH configuration
- Enables root password login
- Modifies the firewall
- Opens any port
- Installs the XanMod kernel
- Installs any other third-party kernel
- Deletes the existing swap
- Deletes existing system configuration
- Downloads or executes remote scripts

## Supported environment

Recommended environment:

- Debian 11
- Debian 12
- Debian 13
- systemd or a regular Debian VPS
- The official Debian kernel

Any architecture works, as long as the running Debian kernel provides `tcp_bbr`.

### Filesystem notes

| Root filesystem         | Swap file support                                                      |
| ----------------------- | ---------------------------------------------------------------------- |
| ext4 / xfs              | Supported, created with `fallocate`                                    |
| btrfs                   | Supported, the script runs `chattr +C` first and then uses `dd`        |
| ZFS                     | Not supported, the script exits with an error                          |
| overlayfs / aufs        | Not supported (common in Docker), the script exits with an error       |
| NFS / CIFS / 9p / FUSE  | Not supported, the script exits with an error                          |

On btrfs the `chattr` command must be installed, otherwise the script refuses to create the swap file.

### Container limits

If the server is actually one of these containers:

- OpenVZ
- LXC
- Docker
- systemd-nspawn

then it usually cannot load kernel modules or change the host kernel, and `swapon` is usually denied as well.

In that case the script can only succeed when the host already provides BBR to the container and the container allows swap. When `swapon` or `sysctl` fails the script reports the error and exits with a non-zero status instead of reporting an unapplied configuration as successful.

## Default swap size

The default size follows the physical memory:

| Physical memory | Swap size |
| --------------- | --------: |
| Up to 4 GiB     |    2 GiB  |
| Above 4 GiB     |    4 GiB  |

If any swap is already enabled, the existing swap is kept and no new `/swapfile` is created.

Before creating the file the script checks the root filesystem and keeps at least 1 GiB free after creation. The check only runs when a new file really has to be created.

## Usage

### Option 1: clone the repository

```bash
git clone https://github.com/Bosco1262/debian-swap-bbr.git
cd debian-swap-bbr
sudo ./setup-swap-bbr.sh
```

### Option 2: download the script first

Downloading and reading the script before running it is recommended:

```bash
curl -fsSLO \
  https://raw.githubusercontent.com/Bosco1262/debian-swap-bbr/main/setup-swap-bbr.sh

less setup-swap-bbr.sh
```

Run it after reviewing:

```bash
chmod +x setup-swap-bbr.sh
sudo ./setup-swap-bbr.sh
```

Piping a remote script straight into a shell is not recommended:

```bash
curl URL | bash
```

## Options

```text
--swap-size N    Swap size in GiB, 1 to 32, --swap-size=N also works
-l, --lang LANG  Output language: en or zh-CN
                 Defaults to the system locale, English as the fallback
-n, --dry-run    Check the environment and print the plan, change nothing
--restore, --uninstall
                 Remove what this script created and return to the previous state
                 Combine with --dry-run to only print the plan
-h, --help       Show the help text
-V, --version    Show the script version
```

Create a 2 GiB swap:

```bash
sudo ./setup-swap-bbr.sh --swap-size 2
```

Create a 4 GiB swap:

```bash
sudo ./setup-swap-bbr.sh --swap-size=4
```

`--swap-size` never overrides an existing swap.

### Output language

The output language follows a fixed priority:

1. An explicit `-l`, `--lang` or `--language` value, either `en` or `zh-CN`.
2. The system locale (`LC_ALL`, `LC_MESSAGES`, `LANG`).
3. English as the guaranteed fallback.

```bash
sudo ./setup-swap-bbr.sh --lang en         # force English
sudo ./setup-swap-bbr.sh --lang zh-CN      # force Chinese
LANG=zh_CN.UTF-8 sudo ./setup-swap-bbr.sh  # follow the system
```

`--lang` only affects terminal output, including `--help` and error messages. The files written to `/etc/sysctl.d` always keep the English keys with bilingual comments, regardless of the output language.

### Dry run

Run a check first on a new server:

```bash
sudo ./setup-swap-bbr.sh --dry-run
```

`--dry-run` performs the system detection, command checks, filesystem check, disk space check and BBR support check, but it creates no file, writes no fstab entry and changes no sysctl value.

## Help and version

```bash
./setup-swap-bbr.sh --help
./setup-swap-bbr.sh --version
```

## Verifying swap

```bash
swapon --show
free -h
```

Inspect the swap tunables:

```bash
sysctl vm.swappiness
sysctl vm.vfs_cache_pressure
```

Expected result:

```text
vm.swappiness = 10
vm.vfs_cache_pressure = 50
```

The script runs the same verification before it exits and returns a non-zero status when a value did not take effect.

## Verifying BBR

Available congestion control algorithms:

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

Current congestion control algorithm:

```bash
sysctl net.ipv4.tcp_congestion_control
```

Default queue discipline:

```bash
sysctl net.core.default_qdisc
```

Expected result:

```text
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

BBR module:

```bash
lsmod | grep tcp_bbr
```

Some kernels compile BBR into the kernel itself, so `lsmod` may not list the module even though `bbr` is the active congestion control algorithm.

## Configuration files

The script manages these files:

```text
/swapfile
/etc/sysctl.d/99-zz-local-swap.conf
/etc/sysctl.d/99-zz-local-bbr.conf
/etc/modules-load.d/bbr.conf
/var/lib/debian-swap-bbr/state
```

`/var/lib/debian-swap-bbr/state` is the install record, `--restore` uses it to decide whether a change was made by this script. `/var/lib/debian-swap-bbr/backup.*` only appears when something had to be backed up: a migrated legacy config, or a user file that already existed at a managed path.

The file names deliberately sort after `99-sysctl.conf`, which on Debian is a symlink to `/etc/sysctl.conf`, so the values are not overridden at boot. The script also reports conflicting keys found in `/etc/sysctl.conf`.

When `tcp_bbr` is built into the kernel, the script skips `/etc/modules-load.d/bbr.conf` to avoid a "module not found" message at boot.

When `/etc/fstab` has to be modified, a timestamped backup is created first:

```text
/etc/fstab.bak.YYYYMMDD-HHMMSS
```

### Upgrading from an older version

Older versions used `90-local-*.conf`. The script only deletes those files when their first line contains the `Managed by debian-swap-bbr` marker; anything else is kept and reported.

## Idempotency and failure handling

- Swap already enabled: kept as is, no new file is created
- `/swapfile` exists but is not enabled: verified with `blkid` before it is enabled
- `/swapfile` enabled but the fstab entry is missing: the entry is added back
- fstab entry already present, whether it uses `none` or `swap` as the mount point: no duplicate is appended
- Failure during creation: the `/swapfile` created by this run but never enabled is removed
- Failure of a critical command: the script returns a non-zero status instead of printing "configuration completed"

## Restoring the original state

The script writes an install record to `/var/lib/debian-swap-bbr/state`. It stores which change was made by the script and the values of `vm.swappiness`, `vm.vfs_cache_pressure`, the congestion control algorithm and the queue discipline from before the change.

```bash
sudo ./setup-swap-bbr.sh --restore --dry-run   # preview only
sudo ./setup-swap-bbr.sh --restore             # apply
```

The restore runs in dependency order:

1. `swapoff /swapfile`, only when the record says this script enabled it
2. Remove `/swapfile`, only when the record says this script created it; an existing file is always kept
3. Remove the exact line this script wrote from `/etc/fstab` (backed up first)
4. `systemctl daemon-reload`
5. Remove `99-zz-local-*.conf` and `modules-load.d/bbr.conf` when they carry the script marker
6. Move the legacy `90-local-*.conf` files back from the backup directory
7. Restore the four kernel parameters from the values stored in the record

The restore never:

- Deletes a `/swapfile` it did not create
- Touches an fstab entry it did not write
- Deletes a configuration file without the script marker
- Unloads the `tcp_bbr` module, it disappears after the next reboot
- Touches SSH, the firewall or the kernel

Behaviour details:

- `--restore --dry-run` prints the plan and changes nothing
- A failing `swapoff` (out of memory) aborts the restore and keeps both `/swapfile` and the install record, so it can be retried later
- Before finishing, the restore re-checks the real state: swap is gone, fstab is clean and the four kernel parameters are back. Any mismatch keeps the install record and returns a non-zero status
- A file the user already had at a managed path is moved into `/var/lib/debian-swap-bbr/backup.*` during installation and moved back by the restore; if a newer file appeared at that path, the backup is kept and reported
- The restore is idempotent, a second run returns 0
- `--restore` and `--swap-size` are mutually exclusive, using both returns exit code 2
- Without an install record (for example an installation made by 1.0–1.2) only the marker files are removed, `/swapfile` and fstab are left untouched with a warning

## Troubleshooting

| Symptom                                                              | Cause and fix                                                                              |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `swapon: /swapfile: Operation not permitted`                          | The container disallows swapon, configure swap on the host instead                         |
| `swapon: /swapfile: Invalid argument`                                 | btrfs CoW not disabled, unsupported filesystem, or a sparse file                           |
| `The script requires at least 1024 MiB free space after creation`      | Not enough free space, clean up the disk or use a smaller `--swap-size`                    |
| `This kernel does not provide BBR`                                    | The kernel lacks BBR or the container does not expose it, the script installs no kernel    |
| `Verification failed: net.ipv4.tcp_congestion_control`                | A conflicting key in `/etc/sysctl.conf`, or a restricted container                         |
| `/swapfile exists but cannot be confirmed as a swap file`             | The script refuses to overwrite it, review the file yourself                               |
| `env: 'bash\r': No such file or directory`                            | The script carries Windows CRLF line endings, run `sed -i 's/\r$//' setup-swap-bbr.sh`     |

The failing line and exit code are taken from the `Script failed at line N with exit code M` message.

### Transferring the script from Windows

Copying the script from a Windows machine can turn the line endings into CRLF and break execution. Check it after the transfer:

```bash
head -n 1 setup-swap-bbr.sh | cat -A
```

The expected output is `#!/usr/bin/env bash$`. If the line ends with `^M$`, convert the file:

```bash
sed -i 's/\r$//' setup-swap-bbr.sh
```

The repository ships a `.gitattributes` that forces LF for `.sh`, `.md` and `.yml`, so a `git clone` is never affected.

## Manual removal (fallback)

Prefer `sudo ./setup-swap-bbr.sh --restore`. The steps below are for machines without an install record, or when a single file has to be handled manually.

### Removing the swap created by the script

First make sure `/swapfile` was created by this script and is no longer needed:

```bash
sudo swapoff /swapfile
```

Remove the entry from `/etc/fstab`:

```bash
sudo sed -i '\|^/swapfile[[:space:]]|d' /etc/fstab
```

Remove the swap file and its tunables:

```bash
sudo rm -f /swapfile
sudo rm -f /etc/sysctl.d/99-zz-local-swap.conf
```

Reload sysctl:

```bash
sudo sysctl --system
```

Do not use `swapoff -a`, it disables every swap device on the server.

### Removing the BBR configuration

```bash
sudo rm -f /etc/sysctl.d/99-zz-local-bbr.conf
sudo rm -f /etc/modules-load.d/bbr.conf
```

Removing the files does not select another congestion control algorithm.

To switch back to the Debian default `cubic` right away:

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo sysctl -w net.core.default_qdisc=fq_codel
```

Then reload the configuration:

```bash
sudo sysctl --system
```

## Development checks

### ShellCheck

Install ShellCheck on Debian:

```bash
sudo apt-get update
sudo apt-get install -y shellcheck
```

Run it:

```bash
shellcheck setup-swap-bbr.sh
```

The `.shellcheckrc` in the repository root disables `SC2310` and `SC2311`: every function handles its own failures explicitly and does not rely on `set -e` inside condition contexts.

### Bash syntax check

```bash
bash -n setup-swap-bbr.sh
```

### Code comment convention

Comments are bilingual, English first and Simplified Chinese second, and follow these spacing rules:

```bash
# No blank line is needed between two single-line comments.
# 单行注释的两种注释间不需要空行。

# A blank line must be left between
# single-block, multi-line comments.
#
# 在单段多行注释之间
# 必须留出一个空行。

# This is a multi-line comment spanning multiple sections.
#
# Two blank lines must be left between comments in the two languages.
#
#
# 这是一个多段多行注释。
#
# 在两种语言的注释之间，必须留出两个空行。
```

In short:

1. A single English line and its Chinese line sit next to each other, no blank comment line in between.
2. A single-block multi-line comment uses one blank comment line (`#`) between the two languages.
3. A comment with several sections uses one blank comment line between sections and two blank comment lines between the two languages.

Comments written into `/etc/sysctl.d` files are bilingual as well, while the keys and values never depend on the output language.

### Suggested local checks

```bash
# Argument parsing
sudo ./setup-swap-bbr.sh --swap-size 08     # must be treated as 8 GiB
sudo ./setup-swap-bbr.sh --swap-size 33     # must exit with 2
sudo ./setup-swap-bbr.sh --swap-size        # must exit with 2
sudo ./setup-swap-bbr.sh --lang fr          # must exit with 2

# Language resolution
sudo ./setup-swap-bbr.sh --lang en --help   # English help
sudo ./setup-swap-bbr.sh --lang zh-CN --help # Chinese help

# Idempotency: run twice, fstab must still contain a single /swapfile line
sudo ./setup-swap-bbr.sh && sudo ./setup-swap-bbr.sh
grep -c '^/swapfile' /etc/fstab

# Restore
sudo ./setup-swap-bbr.sh --restore --dry-run        # print the plan only
sudo ./setup-swap-bbr.sh --restore                  # undo what the script created
sudo ./setup-swap-bbr.sh --restore --swap-size 2    # must exit with 2
```

## Security notes

Before running any root script on a production server:

1. Read the whole script.
2. Check whether it downloads or executes remote code.
3. Check which system files it modifies.
4. Check the commit history and releases of the repository.
5. Run it on a test server or a snapshot first.
6. Create a snapshot in AWS EC2, Google Compute Engine, DigitalOcean, Vultr or the matching cloud platform when available.

The script only handles swap and the standard BBR configuration, it never touches SSH, the firewall or third-party kernels.

# License

This project is licensed under the [MIT License](LICENSE).
