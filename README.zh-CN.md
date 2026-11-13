# Debian Swap and BBR Setup

[English](README.md) | [简体中文](README.zh-CN.md)

一个用于 Debian 新服务器的 Swap 和标准 BBR 自动配置脚本。

脚本会检查现有配置，并以幂等方式完成设置。重复运行不会重复创建 Swap，也不会向 `/etc/fstab` 重复添加相同记录；如果已有的 `/swapfile` 已经启用但缺少 fstab 条目，脚本会自动补齐。

## 功能

- 检查 root 权限
- 检查当前系统是否为 Debian
- 检查必要的系统命令
- 保留服务器已有的 Swap
- 没有 Swap 时自动创建 `/swapfile`
- 根据物理内存自动选择 Swap 大小
- 支持手动指定 1 至 32 GiB Swap
- 检查根分区文件系统类型，识别 btrfs / ZFS / overlay 等特殊场景
- 检查磁盘空间
- 创建 `/etc/fstab` 备份，并处理末尾缺少换行的情况
- 设置 `vm.swappiness=10`
- 设置 `vm.vfs_cache_pressure=50`
- 检查当前内核是否支持 BBR
- 启用 `tcp_bbr`
- 设置 `fq` 默认队列算法
- 支持 LXC、OpenVZ 等容器环境检测
- 配置完成后校验实际生效值，而不是只相信命令返回值
- 支持 `--dry-run` 预检
- 支持 `--restore` 精确撤销本脚本创建的配置
- 支持 `--lang` 切换输出语言
- 支持重复运行

## 不会执行的操作

本脚本不会：

- 修改 SSH 配置
- 开启 root 密码登录
- 修改防火墙
- 开放任何端口
- 安装 XanMod 内核
- 安装其他第三方内核
- 删除现有 Swap
- 删除现有系统配置
- 下载或执行其他远程脚本

## 支持环境

推荐环境：

- Debian 11
- Debian 12
- Debian 13
- systemd 或常规 Debian VPS 环境
- Debian 官方内核

架构方面，只要当前 Debian 内核提供 `tcp_bbr`，脚本即可配置 BBR。

### 文件系统说明

| 根分区文件系统         | Swap 文件支持情况                                   |
| ---------------------- | --------------------------------------------------- |
| ext4 / xfs             | 直接支持，使用 `fallocate` 创建                     |
| btrfs                  | 支持，脚本会先 `chattr +C` 关闭 CoW，再用 `dd` 创建 |
| ZFS                    | 不支持 Swap 文件，脚本会直接报错退出                 |
| overlayfs / aufs       | 不支持（常见于 Docker），脚本会直接报错退出          |
| NFS / CIFS / 9p / FUSE | 不支持，脚本会直接报错退出                          |

btrfs 场景需要系统存在 `chattr` 命令，否则脚本会拒绝创建 Swap 文件。

### 容器限制

如果服务器实际是以下容器之一：

- OpenVZ
- LXC
- Docker
- systemd-nspawn

容器通常不能自行加载或更换宿主机内核模块，也通常不允许 `swapon`。

这种情况下，只有宿主机已经启用并向容器提供 BBR、且容器允许 Swap 时，脚本才能成功配置。脚本在 `swapon` 或 `sysctl` 失败时会明确报错并返回非 0 退出码，不会把未生效的配置报告为成功。

## 默认 Swap 规则

脚本默认按照物理内存决定 Swap 大小：

| 物理内存     | Swap 大小 |
| ------------ | --------: |
| 不超过 4 GiB |     2 GiB |
| 超过 4 GiB   |     4 GiB |

如果系统已经启用了任何 Swap，脚本会保留现有 Swap，不再创建 `/swapfile`。

创建 Swap 前，脚本会检查根分区空间，并确保创建完成后至少保留 1 GiB 可用空间。只有在确实需要新建文件时才会执行这项检查。

## 使用方法

### 方法一：克隆仓库

```bash
git clone https://github.com/Bosco1262/debian-swap-bbr.git
cd debian-swap-bbr
sudo ./setup-swap-bbr.sh
```

### 方法二：下载脚本后执行

建议先下载并检查脚本内容：

```bash
curl -fsSLO \
  https://raw.githubusercontent.com/Bosco1262/debian-swap-bbr/main/setup-swap-bbr.sh

less setup-swap-bbr.sh
```

确认无误后执行：

```bash
chmod +x setup-swap-bbr.sh
sudo ./setup-swap-bbr.sh
```

不建议使用下面这种未经检查就直接执行远程脚本的方式：

```bash
curl URL | bash
```

## 参数说明

```text
--swap-size N    指定 Swap 大小，单位为 GiB，范围 1 到 32
                 也支持 --swap-size=N
-l, --lang LANG  输出语言：en 或 zh-CN
                 默认跟随系统 locale，无法识别时回退英文
-n, --dry-run    只检查环境并输出计划，不修改任何文件
--restore, --uninstall
                 撤销本脚本创建的配置，恢复到安装前的状态
                 与 --dry-run 同时使用只输出计划
-h, --help       显示帮助信息
-V, --version    显示脚本版本
```

创建 2 GiB Swap：

```bash
sudo ./setup-swap-bbr.sh --swap-size 2
```

创建 4 GiB Swap：

```bash
sudo ./setup-swap-bbr.sh --swap-size=4
```

如果服务器已经启用了 Swap，`--swap-size` 不会覆盖现有 Swap。

### 输出语言

脚本输出的语言遵循固定优先级：

1. 显式参数 `-l`、`--lang` 或 `--language`，取值为 `en` 或 `zh-CN`。
2. 自动检测系统 locale（`LC_ALL`、`LC_MESSAGES`、`LANG`）。
3. 无法识别时回退英文。

```bash
sudo ./setup-swap-bbr.sh --lang en        # 强制英文
sudo ./setup-swap-bbr.sh --lang zh-CN     # 强制中文
LANG=zh_CN.UTF-8 sudo ./setup-swap-bbr.sh # 跟随系统
```

`--lang` 只影响终端输出，`--help` 与错误提示同样会跟随该语言。写入 `/etc/sysctl.d` 的配置文件始终是英文键名加双语注释，不受输出语言影响。

### 预检模式

首次在新服务器上运行时，建议先预检：

```bash
sudo ./setup-swap-bbr.sh --dry-run
```

`--dry-run` 会完成系统识别、命令检查、文件系统检查、磁盘空间检查和 BBR 支持检查，但不会创建文件、不会写入 fstab、不会修改 sysctl。它适合用来确认脚本的行为是否符合预期。

## 查看帮助与版本

```bash
./setup-swap-bbr.sh --help
./setup-swap-bbr.sh --version
```

## 验证 Swap

```bash
swapon --show
free -h
```

查看 Swap 参数：

```bash
sysctl vm.swappiness
sysctl vm.vfs_cache_pressure
```

预期结果：

```text
vm.swappiness = 10
vm.vfs_cache_pressure = 50
```

脚本在结束前会自动执行同样的校验，校验失败时会以非 0 退出码结束。

## 验证 BBR

检查可用拥塞控制算法：

```bash
sysctl net.ipv4.tcp_available_congestion_control
```

检查当前拥塞控制算法：

```bash
sysctl net.ipv4.tcp_congestion_control
```

检查默认队列算法：

```bash
sysctl net.core.default_qdisc
```

预期结果：

```text
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
```

检查 BBR 模块：

```bash
lsmod | grep tcp_bbr
```

部分内核可能将 BBR 直接编译进内核，因此即使 `lsmod` 不显示模块，只要当前拥塞控制算法为 `bbr`，BBR 仍可能已经正常启用。

## 配置文件

脚本会管理以下文件：

```text
/swapfile
/etc/sysctl.d/99-zz-local-swap.conf
/etc/sysctl.d/99-zz-local-bbr.conf
/etc/modules-load.d/bbr.conf
/var/lib/debian-swap-bbr/state
```

其中 `/var/lib/debian-swap-bbr/state` 是安装状态清单，`--restore` 依赖它判断每一项改动是否由脚本完成。`/var/lib/debian-swap-bbr/backup.*` 只在需要备份时出现：旧版本配置迁移、或目标路径上原本就有用户自己的同名文件。

文件名刻意排在 `99-sysctl.conf`（在 Debian 上是指向 `/etc/sysctl.conf` 的软链）之后，避免开机时被 `/etc/sysctl.conf` 中的同名键覆盖。脚本启动时也会提示 `/etc/sysctl.conf` 中是否存在冲突的同名键。

如果内核已内置 `tcp_bbr`，脚本会跳过 `/etc/modules-load.d/bbr.conf`，避免开机时出现模块找不到的报错。

如果脚本需要修改 `/etc/fstab`，会先创建带时间戳的备份：

```text
/etc/fstab.bak.YYYYMMDD-HHMMSS
```

### 从旧版本升级

旧版本使用 `90-local-*.conf`。脚本只会删除首行包含 `Managed by debian-swap-bbr` 标记的旧文件，其他文件一律保留并给出提示。

## 幂等性与失败处理

- 已启用 Swap：保留现有 Swap，不新建文件
- 已有 `/swapfile` 但未启用：先用 `blkid` 校验签名，确认是 Swap 文件后才启用
- 已有 `/swapfile` 且已启用但 fstab 缺条目：自动补写条目
- fstab 已有 `/swapfile` 条目（无论挂载点写 `none` 还是 `swap`）：不会重复追加
- 创建过程中失败：脚本会删除本次创建但未能启用的 `/swapfile`，避免留下无效文件
- 关键命令失败：立即返回非 0 退出码，而不是继续打印"配置完成"

## 恢复（--restore）

脚本会在安装时写入状态清单 `/var/lib/debian-swap-bbr/state`，记录每一项改动是否由脚本完成，并保存改动前的 `vm.swappiness`、`vm.vfs_cache_pressure`、拥塞控制算法和队列算法。

```bash
sudo ./setup-swap-bbr.sh --restore --dry-run   # 只预览，不改动
sudo ./setup-swap-bbr.sh --restore             # 正式恢复
```

恢复按依赖顺序执行：

1. `swapoff /swapfile`（只有清单记录"由脚本启用"时才执行）
2. 删除 `/swapfile`（只有清单记录"由脚本创建"时才执行，已有文件一律保留）
3. 从 `/etc/fstab` 删除由脚本写入的那一行（精确匹配，删除前备份）
4. `systemctl daemon-reload`
5. 删除带脚本标记的 `99-zz-local-*.conf` 与 `modules-load.d/bbr.conf`
6. 把旧版本 `90-local-*.conf` 从备份目录放回原位
7. 用清单记录的旧值恢复 4 个内核参数

恢复**不会**做这些事：

- 不删除不是本脚本创建的 `/swapfile`
- 不修改不是本脚本写入的 fstab 条目
- 不删除没有本脚本标记的配置文件
- 不卸载 `tcp_bbr` 模块（重启后自然消失）
- 不动 SSH、防火墙、内核

行为细节：

- `--restore --dry-run` 只打印计划，不产生任何改动
- `swapoff` 失败（内存不足）时立即中止，`/swapfile` 与状态清单都保留，可稍后重试
- 恢复结束前会复查真实状态（Swap 是否已关闭、fstab 是否干净、4 个内核参数是否回到旧值），任一项不符都会保留状态清单并返回非 0
- 安装时如果目标路径上已有用户自己的同名配置文件，会先移入 `/var/lib/debian-swap-bbr/backup.*`，恢复时放回；若放回时该路径已有更新的文件，则保留备份并提示手动处理
- 恢复是幂等的，重复执行返回 0
- `--restore` 与 `--swap-size` 互斥，同时使用返回退出码 2
- 找不到状态清单时（例如由 1.0–1.2 安装），只删除带标记的配置文件，`/swapfile` 与 fstab 保持原样并给出提示

## 故障排查

| 现象                                                | 常见原因与处理方式                                                                    |
| --------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `swapon: /swapfile: Operation not permitted`        | 容器不允许 swapon，需要宿主机配置 Swap                                                |
| `swapon: /swapfile: Invalid argument`               | btrfs 未关闭 CoW、文件系统不支持 Swap 文件，或文件存在空洞                            |
| `脚本要求创建完成后至少保留 1024 MiB 可用空间`/对应英文提示 | 根分区空间不足，先清理磁盘或改用更小的 `--swap-size`                                  |
| `当前内核没有提供 BBR`/`This kernel does not provide BBR` | 内核不支持 BBR，或容器未向容器提供 BBR，脚本不会安装第三方内核                        |
| `校验失败：net.ipv4.tcp_congestion_control`         | `/etc/sysctl.conf` 中存在冲突配置，或运行在受限容器中                                 |
| `/swapfile 已存在，但不能确认它是 Swap 文件`        | 出于安全考虑脚本不会覆盖，请自行确认该文件用途                                        |
| `env: 'bash\r': No such file or directory`          | 脚本被 Windows 的 CRLF 换行污染，执行 `sed -i 's/\r$//' setup-swap-bbr.sh` 后重试     |

查看脚本执行失败的行号和退出码，可直接从输出中的 `脚本在第 N 行执行失败` 定位。

### 从 Windows 传输脚本

在 Windows 上 `scp` 或复制粘贴脚本后，换行符可能变成 CRLF，导致脚本无法执行。传输后先检查：

```bash
head -n 1 setup-swap-bbr.sh | cat -A
```

正常输出应为 `#!/usr/bin/env bash$`，若行尾出现 `^M$` 则需要转换：

```bash
sed -i 's/\r$//' setup-swap-bbr.sh
```

仓库已通过 `.gitattributes` 强制 `.sh` / `.md` / `.yml` 使用 LF，用 `git clone` 获取的文件不会出现该问题。

## 手动卸载（兜底）

优先使用 `sudo ./setup-swap-bbr.sh --restore`。下面的步骤适用于没有状态清单、或需要单独处理某个文件的场景。

### 删除脚本创建的 Swap

首先确认 `/swapfile` 是由本脚本创建并且不再需要：

```bash
sudo swapoff /swapfile
```

从 `/etc/fstab` 中删除 `/swapfile` 对应行：

```bash
sudo sed -i '\|^/swapfile[[:space:]]|d' /etc/fstab
```

删除 Swap 文件和参数配置：

```bash
sudo rm -f /swapfile
sudo rm -f /etc/sysctl.d/99-zz-local-swap.conf
```

重新加载 sysctl：

```bash
sudo sysctl --system
```

不要使用 `swapoff -a`，因为它会关闭服务器上的所有 Swap。

### 删除 BBR 配置

```bash
sudo rm -f /etc/sysctl.d/99-zz-local-bbr.conf
sudo rm -f /etc/modules-load.d/bbr.conf
```

删除配置文件不会自动选择其他拥塞控制算法。

如果需要立即恢复 Debian 常用的 `cubic`：

```bash
sudo sysctl -w net.ipv4.tcp_congestion_control=cubic
sudo sysctl -w net.core.default_qdisc=fq_codel
```

然后重新加载配置：

```bash
sudo sysctl --system
```

## 开发检查

### 使用 ShellCheck

在 Debian 上安装 ShellCheck：

```bash
sudo apt-get update
sudo apt-get install -y shellcheck
```

检查脚本：

```bash
shellcheck setup-swap-bbr.sh
```

仓库根目录的 `.shellcheckrc` 关闭了 `SC2310` / `SC2311`：本脚本的函数在内部显式处理每一步失败，不依赖 `set -e` 在条件语境中生效。

### 检查 Bash 语法

```bash
bash -n setup-swap-bbr.sh
```

### 代码注释规范

脚本内的注释使用英文与简体中文双语，并遵循以下排版规则：

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

规则归纳：

1. 单行双语注释直接相邻，中间不加空注释行。
2. 单段多行双语注释，在两种语言之间留一个空注释行（`#`）。
3. 多段多行注释，段与段之间留一个空注释行，两种语言之间留两个空注释行。

配置文件中由脚本写入的注释同样保持双语，但系统配置的键名与取值不会随输出语言变化。

### 建议的本地验证

```bash
# 参数解析
sudo ./setup-swap-bbr.sh --swap-size 08     # 应按 8 GiB 处理
sudo ./setup-swap-bbr.sh --swap-size 33     # 应退出码 2
sudo ./setup-swap-bbr.sh --swap-size        # 应退出码 2
sudo ./setup-swap-bbr.sh --lang fr          # 应退出码 2

# 语言解析
sudo ./setup-swap-bbr.sh --lang en --help   # 英文帮助
sudo ./setup-swap-bbr.sh --lang zh-CN --help # 中文帮助

# 幂等性：连续执行两次，fstab 只应出现一行 /swapfile
sudo ./setup-swap-bbr.sh && sudo ./setup-swap-bbr.sh
grep -c '^/swapfile' /etc/fstab

# 恢复
sudo ./setup-swap-bbr.sh --restore --dry-run        # 只打印计划
sudo ./setup-swap-bbr.sh --restore                  # 撤销脚本创建的配置
sudo ./setup-swap-bbr.sh --restore --swap-size 2    # 应退出码 2
```

## 安全说明

在生产服务器上运行任何 root 脚本之前，应先完成以下检查：

1. 阅读完整脚本内容。
2. 检查脚本是否下载或执行其他远程代码。
3. 检查脚本修改的系统文件。
4. 检查仓库的提交历史和 Release。
5. 先在测试服务器或快照环境中运行。
6. VPS 支持快照时，应先在 AWS EC2、Google Compute Engine、DigitalOcean、Vultr 或对应云平台创建快照。

本脚本只处理 Swap 和标准 BBR，不会配置 SSH、防火墙或第三方内核。

# License

本项目采用 [MIT License](LICENSE)。
