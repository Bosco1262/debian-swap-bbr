# Debian Swap and BBR Setup

一个用于 Debian 新服务器的 Swap 和标准 BBR 自动配置脚本。

脚本会检查现有配置，并以幂等方式完成设置。重复运行不会重复创建 Swap，也不会向 `/etc/fstab` 重复添加相同记录。

## 功能

- 检查 root 权限
- 检查当前系统是否为 Debian
- 检查必要的系统命令
- 保留服务器已有的 Swap
- 没有 Swap 时自动创建 `/swapfile`
- 根据物理内存自动选择 Swap 大小
- 支持手动指定 1 至 32 GiB Swap
- 检查磁盘空间
- 创建 `/etc/fstab` 备份
- 设置 `vm.swappiness=10`
- 设置 `vm.vfs_cache_pressure=50`
- 检查当前内核是否支持 BBR
- 启用 `tcp_bbr`
- 设置 `fq` 默认队列算法
- 支持 LXC、OpenVZ 等容器环境检测
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

### 容器限制

如果服务器实际是以下容器之一：

- OpenVZ
- LXC
- Docker
- systemd-nspawn

容器通常不能自行加载或更换宿主机内核模块。

这种情况下，只有宿主机已经启用并向容器提供 BBR 时，脚本才能成功配置 BBR。

## 默认 Swap 规则

脚本默认按照物理内存决定 Swap 大小：

| 物理内存     | Swap 大小 |
| ------------ | --------: |
| 不超过 4 GiB |     2 GiB |
| 超过 4 GiB   |     4 GiB |

如果系统已经启用了任何 Swap，脚本会保留现有 Swap，不再创建 `/swapfile`。

创建 Swap 前，脚本会检查根分区空间，并确保创建完成后至少保留 1 GiB 可用空间。

## 使用方法

### 方法一：克隆仓库

```bash
git clone https://github.com/YOUR_USERNAME/debian-swap-bbr.git
cd debian-swap-bbr

chmod +x setup-swap-bbr.sh
sudo ./setup-swap-bbr.sh
```

### 方法二：下载脚本后执行

建议先下载并检查脚本内容：

```bash
curl -fsSLO \
  https://raw.githubusercontent.com/YOUR_USERNAME/debian-swap-bbr/main/setup-swap-bbr.sh

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

## 指定 Swap 大小

例如创建 2 GiB Swap：

```bash
sudo ./setup-swap-bbr.sh --swap-size 2
```

创建 4 GiB Swap：

```bash
sudo ./setup-swap-bbr.sh --swap-size 4
```

允许范围为 1 至 32 GiB：

```bash
sudo ./setup-swap-bbr.sh --swap-size 8
```

如果服务器已经启用了 Swap，`--swap-size` 不会覆盖现有 Swap。

## 查看帮助

```bash
./setup-swap-bbr.sh --help
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

部分内核可能将 BBR直接编译进内核，因此即使 `lsmod` 不显示模块，只要当前拥塞控制算法为 `bbr`，BBR 仍可能已经正常启用。

## 配置文件

脚本会管理以下文件：

```text
/swapfile
/etc/sysctl.d/90-local-swap.conf
/etc/sysctl.d/90-local-bbr.conf
/etc/modules-load.d/bbr.conf
```

如果脚本需要修改 `/etc/fstab`，会先创建带时间戳的备份：

```text
/etc/fstab.bak.YYYYMMDD-HHMMSS
```

## 手动卸载

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
sudo rm -f /etc/sysctl.d/90-local-swap.conf
```

重新加载 sysctl：

```bash
sudo sysctl --system
```

不要使用 `swapoff -a`，因为它会关闭服务器上的所有 Swap。

### 删除 BBR 配置

```bash
sudo rm -f /etc/sysctl.d/90-local-bbr.conf
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

### 检查 Bash 语法

```bash
bash -n setup-swap-bbr.sh
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

## License

本项目使用 MIT License。
