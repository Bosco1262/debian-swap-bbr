# 《debian-swap-bbr》整份脚本完整讲解（给只有一点 Python 基础的同学）

[English](walkthrough.md) | [简体中文](walkthrough.zh-CN.md)

> 顺序是：先总览 → 再补基础概念 → 再按代码顺序逐段拆开 → 最后看运行效果和速查表。
> 读完你应该能说清楚：仓库里有什么、脚本每一步做什么、谁调用谁、跑完系统变成什么样。

> **版本说明**：本文档基于 **1.4.1** 版本编写。查代码时请以函数名为准（见第 5.2 节速查表）。

---

## 第 0.5 部分：版本演进与关键边界加固

本脚本的核心功能是“配置 Swap 与启用 BBR”，但在历次迭代（特别是 1.4.0 与 1.4.1）中加入了大量的工业级防御性加固：

| 加固项 | 解决的实际问题 / 带来的影响 |
| --- | --- |
| `--restore` 恢复校验只要求“本脚本启用过的 Swap”消失 | 安装前就已存在并启用着 `/swapfile` 的机器，恢复时不再永远失败报错 |
| 托管文件归属判定改为**首行精确匹配** | 用户配置里即使包含仓库名注释，也不会被误当成“脚本自己的文件”覆盖或删除 |
| `handle_error` 与 `on_interrupt` 退出前补写安装记录 | 运行中途发生未预期错误或用户按下 Ctrl+C 时，`--restore` 依然能完整撤销改动 |
| 新增 `acquire_lock`（`flock` 排他锁） | 两个实例并发运行时自动串行化，绝不会交错写入 fstab 或互相覆盖安装记录 |
| fstab 删除条目支持**原子替换与软链接保护** | 原子重命名避免断电截断 fstab；检测到 fstab 为软链接时自动回退为重写，不破坏软链接结构 |
| 失败时**立即打扫战场** | 创建 Swap 失败（如磁盘空间写满 100%）时立刻删除半成品并释放空间，避免后续连锁崩溃 |
| 探测到内核已内建 BBR 时跳过 modprobe | 自编译或云厂商静态内建 BBR 的内核，不再误报“模块加载失败”黄色警告 |
| 冲突扫描支持 `#` 与 `;` 双注释符与末行补全 | 遵循 sysctl 规范过滤分号注释，避免假冲突警告；文件末行无换行符也能完整读取 |
| 冲突优先级按参数类别精准比对 | 内存参数比对 `swap.conf`，网络参数比对 `bbr.conf`，彻底消除字典序导致的误报 |
| 期望值提取为 `EXPECTED_*` 统一常量 | 写入配置文件、冲突扫描、结果校验三处共用同一数据源，永不漂移 |
| 颜色按 stdout / stderr 独立判断 | 重定向普通输出到文件时，错误输出在终端里依然具备完整高亮颜色 |
| 全局变量更名为 `OUTPUT_LANG` | 与 gettext 的标准环境变量 `LANGUAGE` 彻底隔离，解析系统语言时更精确 |
| 安装记录采用“写入临时文件 + 原子改名” | 写入过程中断绝不会在系统留下残缺被截断的状态清单 |
| 自动化回归测试（CLI 与消息表）接入 CI | 每次代码变动均自动检验消息表对齐与参数解析边界 |

---

## 第 0 部分：一个前提 —— 这不是 Python 脚本

真正干活的是 `setup-swap-bbr.sh`。后缀 `.sh` 表示它是 **shell 脚本**（用 Bash 写成），在 Linux（Debian）命令行里运行，不是用 `python xxx.py` 跑的。

别担心：它用的思想和 Python 几乎一样。变量、函数、循环、条件判断、字典、参数、错误处理全都有，只是写法不同。先给对照表，后面可随时查阅：

| 概念 | Python | 这个脚本 | 大白话 |
| --- | --- | --- | --- |
| 变量 | `x = 1` | `X=1`，用时写 `$X` | 贴了标签的盒子 |
| 常量 | 约定全大写 | `readonly X=...` | 贴了封条的盒子，不许改 |
| 函数 | `def f(a): ...` | `f() { ... }`，参数用 `$1`、`$2` | 起好名字、可反复调用的一段步骤 |
| 返回值 | `return 值` | `return 0` 表示成功，`return 1` 表示失败 | 这里只回答「成 / 不成」 |
| 条件判断 | `if x == 1: ... else:` | `if [ "$X" -eq 1 ]; then ... fi` 或 `case ... esac` | 如果……就……否则…… |
| 循环 | `for x in list:` | `for x in "${arr[@]}"; do ... done` | 把同一件事重复做几遍 |
| 列表 | `list = [a, b]` | `arr=(a b)` | 一排盒子 |
| 字典 | `d = {"k": "v"}` | `declare -A D=( [k]='v' )`，取值 `${D[k]}` | 用名字查内容的表格 |
| 字符串格式化 | `"hi %s" % name` | `printf 'hi %s\n' "$name"` | 把值填进句子的空格 |
| 命令行参数 | `sys.argv` | `"$@"`（全部）、`$1`（第一个） | 用户敲在命令后的选项 |
| 取别人的结果 | `s = f()` | `s=$(某命令)` | 把别人的输出存进变量 |
| 错误处理 | `try / except` | `trap '...' ERR` | 出事自动跳去收尾 |

### 「模块导入」这里不一样，要特别说明

Python 用 `import` 加载别人写好的代码；**Bash 没有 import**。脚本用的是另外两种办法：

1. **直接调用系统里现成的小命令**，如 `awk`、`grep`、`df`、`sysctl`、`swapon`、`chmod`、`cp`。它们相当于系统自带的「函数库」，每个都是别人写好装在系统里的小程序，`sysctl -n vm.swappiness` 就像调用一个函数并取返回值。脚本开头还专门检查这些工具在不在。
2. **用 `. 文件名` 把配置文件读进来当变量用**。脚本里 `. /etc/os-release` 最接近「导入」：读完后能用 `$ID`、`$PRETTY_NAME`。但它只是读数据，不是加载代码。

脚本把「文案字典」直接写在自己文件里，没有拆成第二个文件，所以**整个项目只有一个程序文件**，不存在多个 `.py` 互相 import 的情况。所有函数都在同一文件里，互相喊名字即可 —— 这就是后面调用关系清晰简单的原因。

---

## 第 1 部分：总览

### 1.1 这个脚本解决什么问题

新买的 Debian 服务器（VPS）通常有两个默认状态不太理想：

- **没有 Swap（交换空间）**：内存不够时系统可能直接杀掉程序。Swap 是在硬盘上划一块专用地方，内存紧张时把暂时不用的数据挪过去。好比书桌（内存）放不下了，把暂时不看的书先放进抽屉（硬盘）；抽屉慢一些，但总比把书扔掉强。
- **没启用 BBR**：BBR 是 Linux 内核自带的一种「网络发送节奏算法」，线路拥挤、网速波动时通常更稳。好比同样踩油门，有人一堵车就猛踩猛松，BBR 像更聪明的油门，能更准地判断该发多快。

脚本就是一条命令把这两件事配好，而且**只做这两件事**。开头注释（3~38 行）写清了边界：

- **会做**：检查系统与权限、保留已有 Swap、必要时创建 `/swapfile`、按内存决定大小、启用内核自带的标准 BBR、保证重复运行不出乱子（幂等）、支持 `--dry-run` / `--restore` / `--lang`。
- **不会做**：不动 SSH、不动防火墙、不装第三方内核、不删除已有 Swap。

这个「边界声明」很重要：它是一个谨慎的配置脚本，不是到处乱改系统的大杂烩。

### 1.2 三种主要用法

```bash
sudo ./setup-swap-bbr.sh              # 正式配置
sudo ./setup-swap-bbr.sh --dry-run     # 预演：只打印「打算做什么」，什么也不改
sudo ./setup-swap-bbr.sh --restore     # 撤销：把它做过的改动还原
```

| 选项 | 作用 |
| --- | --- |
| `--swap-size N` 或 `--swap-size=N` | 手动指定 Swap 大小，1~32 GiB（不指定就按内存自动选） |
| `-l` / `--lang en` 或 `zh-CN` | 指定屏幕提示用英文还是中文 |
| `-n` / `--dry-run` | 预演模式，零改动 |
| `--restore` / `--uninstall` | 恢复模式；可和 `--dry-run` 组合成「只看恢复计划」 |
| `-h` / `--help` | 显示帮助 |
| `-V` / `--version` | 显示版本号（当前 1.4.1） |

`--dry-run` 就像「先看菜单再点菜」：先确认脚本打算干什么，再决定要不要真执行。

### 1.3 仓库里有什么（文件结构）

```text
debian-swap-bbr/
├── docs/
│   ├── walkthrough.zh-CN.md            # 中文深度代码讲解（本文档）
│   └── walkthrough.md                  # 英文深度代码讲解
├── tests/
│   ├── cli.sh                          # 命令行参数与无特权回归测试
│   └── check-messages.sh               # 消息字典完全对齐检查
├── .github/workflows/shellcheck.yml    # CI 自动化静态检查
├── setup-swap-bbr.sh                   # 主执行脚本（约 2640 行 Bash）
├── README.md                           # 英文主说明书
├── README.zh-CN.md                     # 中文主说明书
├── LICENSE                             # MIT 许可证
├── .gitattributes                      # 保证换行符强制为 LF
├── .gitignore                          # Git 忽略配置
└── .shellcheckrc                       # ShellCheck 规则微调
```

全部业务逻辑都在 `setup-swap-bbr.sh` 一个文件内。接下来将详细剖析它的每一处设计。

### 1.4 一句话看懂整个脚本

> 最后一行 `main "$@"` 是唯一入口；`main` 像总指挥，先定语言、读参数、查环境，然后按「记录原值 → 配置 Swap → 配置 BBR → 检查冲突 → 复查 → 写安装记录 → 打印结果」走一遍；如果带 `--restore`，中途改走「恢复流程」。所有失败都会被 `trap` 和局部的清理逻辑接住并清理半成品。

### 1.5 运行后最直观的效果

- **屏幕上**：一行行带 `[OK]` / `[INFO]` / `[WARN]` / `[ERROR]` 标签的提示（终端带彩色高亮），最后是一块「配置结果」面板，列出 Swap、BBR、相关文件的状态。
- **系统里**：可能新建 `/swapfile`、在 `/etc/fstab` 追加一行、写入两个 `99-zz-local-*.conf`、视情况写入 `bbr.conf`、生成一份 `/var/lib/debian-swap-bbr/state` 安装记录小票；4 个内核参数立即生效，通常不用重启。
- **退出码**：`0` 成功、`1` 失败或部分失败、`2` 参数写错、`130` 用户 Ctrl+C 中断。

---

## 第 2 部分：结合源码看 5 个基础概念

### 2.1 函数：给一段步骤起名字

```bash
have() {
    command -v "$1" >/dev/null 2>&1
}
```

这就是一个基础函数：名字叫 `have`，作用是「检查某个命令存不存在」。Python 里写 `def have(cmd): ...`，这里写 `名字() { ... }`；`$1` 是传进来的第一个参数；`local x=...` 声明只在函数内部用的局部变量。调用时直接写 `have blkid`。

**Bash 函数约定：`return 0` 表示成功，`return 1` 表示失败**（0 才是「真/无错误」）。所以源码中随处可见 `if ! 某函数; then 报错; fi`，读作「如果这个函数没成功，就报错」。

### 2.2 条件判断：if 和 case

```bash
if [ "${EUID}" -ne 0 ]; then
    log_error err_root_required
    log_error err_rerun_sudo "$SCRIPT_NAME"
    exit 1
fi
```

读作：「如果当前用户编号不是 0（不是管理员），就打印提示并退出」。`-ne` 是数字不等于，`-eq` 是数字等于，`-z` 是字符串为空，`-e` 是文件存在，`-L` 是软链接。

分支较多时脚本采用 `case ... esac`，相当于 Python 里的 `match/case` 或长串 `if/elif/else`。例如根据语言参数做匹配：`case "$value" in en) ... ;; zh-CN|zh) ... ;; *) ... ;; esac`。

### 2.3 循环：while 和 for

- `while [ "$#" -gt 0 ]; do ... shift; done`：只要还有参数没处理就继续，`shift` 扔掉最前面一个参数，相当于自己向前移动参数指针。
- `for command_name in "${required_commands[@]}"; do ... done`：遍历「必需命令清单」数组，逐个检查。
- `while IFS= read -r line || [ -n "$line" ]; do ... done < "$file"`：一行一行读取文本文件。即使文件末行缺少换行符，尾部的 `|| [ -n "$line" ]` 也能确保最后一行不会被丢弃。

### 2.4 「模块导入」在脚本里的真实样子

前面提过 Bash 没有 `import`。检查系统是否为 Debian 时的做法是：

```bash
. /etc/os-release
if [ "${ID:-}" != "debian" ]; then ... fi
```

`. 文件名`（点命令，等价于 `source`）把文本里的键值对加载进当前环境。除此以外，复用能力全靠调用小命令：`df` 读磁盘、`sysctl` 调内核、`mkswap` 打格式标记、`swapon` 启用交换空间。`变量=$(命令)` 叫「命令替换」，把命令的输出捕获到变量中。

### 2.5 三个小而关键的习惯

- **0/1 当布尔开关用**：Python 用 `True/False`，Bash 中用整数 `0/1`。例如 `DRY_RUN=1` 代表预演模式开启。
- **`>&2` 导向错误输出流**：`log_warn` 和 `log_error` 输出到 `>&2`（stderr），普通信息走 stdout。将正常输出重定向到文件时，警告和报错依然会直接印在终端上。
- **「幂等性」**：同一个操作跑 1 次和跑 100 次，系统状态完全相同。fstab 里已有条目就不再追加、已有 Swap 就不新建、带自身标记的配置按原样处理。

---

## 第 3 部分：按代码顺序逐段拆解脚本

### 3.1 开头：自我介绍与安全开关（1~43 行）

- 第 1 行 `#!/usr/bin/env bash`：声明使用 Bash 解释器。
- 41 行 `set -Eeuo pipefail`：
  - `-e`：遇到任何未捕获的错误立即停止；
  - `-u`：使用未定义变量直接报错；
  - `-o pipefail`：管道中只要有一环失败，整条管道就算失败；
  - `-E`：让 ERR trap 能被子 shell 和函数继承。
- 42 行 `umask 022`：保证新建文件具备标准的权限掩码（默认 644/755）。

### 3.2 常量配置池：readonly（44~75 行）

| 常量 | 取值 | 作用 |
| --- | --- | --- |
| `SCRIPT_NAME` / `SCRIPT_VERSION` | 脚本名 / `1.4.1` | 帮助、版本号与清单标识 |
| `EXPECTED_*` | `10` / `50` / `bbr` / `fq` | 配置写入、冲突扫描、结果校验共用的期望值，单点定义 |
| `SWAPFILE` / `FSTAB` | `/swapfile` / `/etc/fstab` | 核心路径 |
| `SYSCTL_DIR` / `MODULES_LOAD_DIR` | `/etc/sysctl.d` / `/etc/modules-load.d` | 内核与模块自动加载目录 |
| `STATE_DIR` / `STATE_FILE` | `/var/lib/debian-swap-bbr` / `state` | 安装状态记录清单所在位置 |
| `SWAP_CONFIG` / `BBR_CONFIG` | `99-zz-local-swap.conf` / `99-zz-local-bbr.conf` | 配置文件名（`99-zz-` 确保排序最后） |
| `BBR_MODULE_CONFIG` | `/etc/modules-load.d/bbr.conf` | 开机自动加载模块条目 |

**为什么起名 `99-zz-`？**  
Debian 在开机或执行 `sysctl --system` 时，按文件名自然字母顺序读取 `/etc/sysctl.d/` 下的文件。后读的配置会覆盖先读的同名键。Debian 默认的 `/etc/sysctl.d/99-sysctl.conf` 是指向 `/etc/sysctl.conf` 的软链。脚本通过 `99-zz-...` 确保自身排序排在它后面，这样脚本配置的参数在开机时就不会被意外覆盖。

### 3.3 运行态变量池（76~108 行）

- **模式开关**：`DRY_RUN`（预演）、`RESTORE`（恢复）、`USE_DD`（Btrfs 改用 dd 写入）、`CLEANING_UP`（清理防重入）。
- **运行状态**：`SWAP_SIZE_GB`、`SWAP_CREATED`、`SWAP_CONFIGURED`、`BBR_CONFIGURED`、`ROOT_FSTYPE`、`OUTPUT_LANG`。
- **安全红线双标志**：`SWAPFILE_OWNED=1`（文件归本次运行创建）与 `SWAP_ACTIVATED=1`（文件已成功激活入内核）。**只要未激活，失败时立刻安全删除；一旦激活，绝不能随意删除底层文件**。
- **`MF_*` 记账家族**：记录在 `state` 清单里的一组变量，包括是否创建了 Swap 文件、是否添加了 fstab、改动前的 4 个原始内核参数值（`MF_PREV_*`）等。

### 3.4 终端颜色与中英双语文案字典（109~534 行）

- `if [ -t 1 ]` / `if [ -t 2 ]`：分别检测标准输出与标准错误是否连接到真实终端，只有终端环境才输出 ANSI 彩色字符。
- `MSG_EN` 与 `MSG_ZH`：两张关联数组字典（约 180 个键）。包含所有的用户提示文案。由 `tests/check-messages.sh` 保证两张表的键完全一致。

### 3.5 输出工具箱（536~596 行）

- `msg 键 参数...`：核心翻译器。根据 `OUTPUT_LANG` 从字典取出格式串，用 `printf -- "$format" "$@"` 填充参数。
- `log_ok / log_info / log_warn / log_error`：为文本加上绿、青、黄、红标签。后两者通过 `>&2` 导向标准错误输出。
- `have 命令名`：利用 `command -v` 静默探测命令是否存在。

### 3.6 安装状态清单（小笔记本）（603~871 行）

当需要 `--restore` 时，脚本必须精确区分“哪些是本次改的，哪些是系统本来就有的”：
- `write_state`：把当前的 `MF_*` 变量写入临时文件 `state.XXXXXX`，设置 644 权限后，通过 `mv -f` 原子重命名替换 `state` 文件。写入中途中断绝不会留下半截脏文件。
- `load_state`：逐行通过 `IFS='=' read -r key value` 解析清单，严格避免直接 `source` 以防代码注入。
- `backup_file_before_change`：在覆盖任何托管配置文件前，如果该路径已存在文件且**首行没有脚本标记**，判定为用户私有文件，先移入 `backup.*` 备份目录妥善保管。
- `capture_previous_state`：**仅在首次运行且无安装记录时**采集内核参数原始值，避免重复运行时把脚本自己的设定值当成“历史原值”。

### 3.7 语言与参数解析（873~1136 行）

- `prescan_language`：在解析所有业务参数之前，**提前预扫描一遍命令行**找出 `--lang`。这样即使后面的参数敲错了（如 `--swap-size abc`），报错信息也能立刻使用用户指定的语言输出。
- `parse_arguments`：逐项解析命令行参数。
- `set_swap_size`：严格校验纯整数、限制最多 2 位数（防止数值溢出）、使用 `10#$value` 消除前导 0 带来的八进制歧义，限制在 1~32 范围内。

### 3.8 三道入场检查（1138~1222 行）

1. `require_root`：检查 `EUID -eq 0`，非 root 立即退出。
2. `check_operating_system`：读取 `/etc/os-release`，确认 `ID=debian`。
3. `check_required_commands`：遍历必需命令数组（`awk`, `dd`, `free`, `swapon`, `sysctl` 等）。如果缺少工具，给出具体的 `apt-get install` 提示并退出。

### 3.9 安全锁与全局异常保护网（1224~1251 行、951~1040 行）

- `acquire_lock`：在 `/run` 下利用 `flock -n 9` 抢占排他文件锁。并发的第二个实例会直接退出，杜绝竞态写入。
- `trap 'handle_error "$LINENO"' ERR`：命令异常崩溃时捕获报错行号。**先补写一次安装记录，随后立即清理半成品**，带着真实错误码退出。
- `trap 'on_interrupt INT' INT` / `TERM`：用户按 Ctrl+C 中断时触发。**同样先补写安装记录**，调用 `cleanup_partial` 清理未启用的临时文件，再按约定退出码（130/143）退出。
- `cleanup_partial`：精准的清理守卫。必须同时满足“归本次所有”、“未激活入内核”、“文件确实存在”、“系统 swapon 列表中没有它”这四个条件才会删除。

### 3.10 Swap 业务逻辑核心（1253~1744 行）

1. **容量决策**：`calculate_swap_size` 读取物理内存，≤ 4096 MiB 配 2 GiB，> 4096 MiB 配 4 GiB（用户显式指定优先）。
2. **底层支持检查**：`check_swapfile_support` 检查根分区文件系统。如果是 `overlay`、`zfs`、`nfs` 等直接报错拦截；如果是 `btrfs`，自动切换为 `USE_DD=1` 并设置 `chattr +C`（禁用写时复制）。
3. **磁盘余量检查**：`check_disk_space` 要求可用空间必须大于“所需 Swap 大小 + 1 GiB 保护余量”。
4. **创建与激活**：
   - 优先尝试 `fallocate`（秒级分配）；若不支持则安全回退到 `dd if=/dev/zero` 逐块填充；
   - **失败立即清理**：若 `dd` 写满磁盘或 `mkswap` 格式化失败，**立刻 `rm -f "$SWAPFILE"` 释放磁盘空间**，避免引发后续级联错误；
   - 设置 `chmod 600`，执行 `swapon "$SWAPFILE"`；
   - 激活后调用 `swap_is_active` 重新从系统内核中读取并复核（不盲目轻信命令返回值）。
5. **fstab 自动补充**：`ensure_fstab_entry` 检查条目是否存在；不存在时先备份 fstab，补齐末行换行，追加开机挂载条目，并执行 `systemctl daemon-reload`。
6. **写入参数**：`write_swap_sysctl` 写入 `vm.swappiness=10` 和 `vm.vfs_cache_pressure=50`，并执行 `sysctl -q -p` 立即生效。

### 3.11 BBR 业务逻辑与冲突扫描（2186~2417 行）

1. **容器探测**：`detect_virtualization` 识别 LXC / Docker 等环境，打印提示。
2. **内核自带检测与按需加载**：
   - 先查询系统 `available_cc` 是否已经包含 `bbr`；
   - **如果内核已经内建或启用了 BBR**，直接跳过 `modprobe` 加载与失败报警；
   - 如果尚未启用，才尝试通过 `modprobe tcp_bbr` 加载模块；
   - 若系统为动态模块则写入 `/etc/modules-load.d/bbr.conf`；若为静态内建则智能跳过该文件。
3. **参数应用**：写入 `net.core.default_qdisc=fq` 与 `net.ipv4.tcp_congestion_control=bbr` 并立即生效。
4. **全方位冲突扫描（`check_sysctl_conflicts`）**：
   - 遍历 `/etc/sysctl.conf` 与 `/etc/sysctl.d/*.conf`；
   - 连续过滤 `#` 与 `;` 两种行内注释；
   - 通过 `read -r line || [ -n "$line" ]` 确保无换行末行不漏检；
   - 精准比对优先级：网络参数比对 `bbr.conf`，内存参数比对 `swap.conf`，准确预警可能在开机时被覆盖的配置。

### 3.12 结果校验与展示面板（2419~2549 行）

- `verify_result`：不依赖历史标记，重新调用系统原生接口读取实际值，确保 Swap 真的已启用、各项 sysctl 内核参数完全符合期望。
- `show_result`：打印规整的信息汇总面板，展示真实的 Swap/内存占用、BBR 算法与队列规则、以及管理的文件列表。

### 3.13 完整恢复流程（--restore）（1785~2184 行）

按照严格的依赖倒序执行，步步防御：
1. `swapoff /swapfile`（仅当清单证实由本脚本启用时才停用；若停用失败如内存不足，立即中止恢复，保留现场）；
2. `remove_fstab_entry`：从 fstab 中剔除本脚本添加的行。**先写入临时文件，检查非空后采用 `mv -f` 原子替换；若 fstab 为软链接则回退到直接重写**，安全保留符号链接结构，随后重载 systemd；
3. 删除 `/swapfile`（仅当清单证实由本脚本创建时才删除；系统原有的 Swap 绝对保留）；
4. 删除带脚本标记的 `99-zz-local-*.conf` 与 `bbr.conf`；
5. 把备份目录中备份的用户原文件放回原处（若现场已有更新的用户文件，则保留备份并提示手动处理）；
6. 将 4 个内核参数还原为安装前记录的原值；
7. 复查系统状态完全干净后，调用 `clear_state` 擦除状态清单。

### 3.14 总入口与执行流（main）（2551~2640 行）

```text
main "$@"
 ├── 确定语言 (detect_language / prescan_language)
 ├── 解析命令行参数 (parse_arguments)
 ├── 基础环境检查 (root / Debian / 必需命令)
 ├── 抢占排他锁 (acquire_lock)
 ├── 读取历史安装记录 (load_state)
 ├── [分支一：恢复模式] restore_all → 退出
 ├── [分支二：安装模式]
 │    ├── 记录当前内核参数原值 (capture_previous_state)
 │    ├── 迁移旧版 90-local-*.conf 配置文件
 │    ├── 配置 Swap (configure_swap) —— 若失败立即打扫战场
 │    ├── 配置 BBR (configure_bbr)
 │    ├── 扫描系统潜在冲突 (check_sysctl_conflicts)
 │    ├── 最终生效值校验 (verify_result)
 │    ├── 写入安装状态清单 (write_state)
 │    └── 展示结果汇总面板 (show_result)
 └── 根据失败状态优雅退出 (exit 0 或 exit 1)
```

---

## 第 4 部分：函数调用关系拓扑

```
[ 底层支撑层 ]
  ├── 字典与日志: msg → MSG_ZH / MSG_EN → log_ok / log_info / log_warn / log_error
  ├── 文件系统工具: have, file_has_marker, get_root_fstype, ensure_config_dir, reload_units
  ├── 备份与记录: ensure_backup_dir → move_to_backup → backup_file_before_change
  └── 异常中断网: trap (ERR / INT / TERM) → handle_error / on_interrupt → cleanup_partial

[ 核心业务调度 (main) ]
  ├── 参数与环境: prescan_language, parse_arguments, require_root, check_operating_system, check_required_commands, acquire_lock
  ├── 状态机读写: load_state, capture_previous_state, write_state, clear_state
  ├── 安装分支:
  │     ├── configure_swap: calculate_swap_size, check_swapfile_support, check_disk_space, create_swapfile, ensure_fstab_entry, write_swap_sysctl
  │     └── configure_bbr: detect_virtualization, modprobe, backup_file_before_change, sysctl -p
  ├── 校验与扫描: check_sysctl_conflicts, verify_result
  └── 恢复分支 (restore_all):
        ├── swapoff / remove_fstab_entry / reload_units
        ├── remove_owned_file / restore_config_file
        ├── restore_sysctl_values → restore_one_sysctl
        └── verify_restore
```

---

## 第 5 部分：核心变量与函数速查表

### 5.1 关键状态变量速查

| 变量名 | 类型与默认值 | 业务含义 |
| :--- | :--- | :--- |
| `OUTPUT_LANG` | 字符串（`en` / `zh-CN`） | 当前使用的输出语言，驱动 `msg` 取词 |
| `DRY_RUN` | 整数（`0` / `1`） | 是否开启预演模式（只打印计划，不落盘） |
| `RESTORE` | 整数（`0` / `1`） | 是否开启卸载/恢复模式 |
| `SWAP_SIZE_GB` | 整数（默认 `0`） | 最终生效的 Swap 容量（单位 GiB） |
| `SWAPFILE_OWNED` | 整数（`0` / `1`） | 标识当前运行是否创建了 `/swapfile` |
| `SWAP_ACTIVATED` | 整数（`0` / `1`） | 标识 `/swapfile` 是否已被内核启用（安全线红线） |
| `MF_SWAPFILE_CREATED` | 整数（`0` / `1`） | 记录在清单中：该文件是否由本脚本创建 |
| `MF_SWAPFILE_ENABLED` | 整数（`0` / `1`） | 记录在清单中：该文件是否由本脚本启用 |
| `MF_FSTAB_ADDED` | 整数（`0` / `1`） | 记录在清单中：fstab 挂载条目是否由本脚本追加 |
| `MF_PREV_*` | 字符串 | 记录改动前系统的原始参数值，供 restore 还原 |

### 5.2 核心函数职责速查

| 函数名 | 所属模块 | 核心职责 |
| :--- | :--- | :--- |
| `prescan_language` | 参数解析 | 提前预扫 `--lang`，让语法报错也能本地化显示 |
| `acquire_lock` | 并发控制 | 申请 `/run` 下的文件锁，阻止重复并发实例 |
| `cleanup_partial` | 容错清理 | 严格只清理本次创建但未能成功激活的半成品文件 |
| `create_swapfile` | Swap 核心 | 空间分配（fallocate/dd）、权限设定与 mkswap 格式化 |
| `ensure_fstab_entry`| 持久化 | 向 `/etc/fstab` 幂等写入开机自动挂载记录 |
| `configure_bbr` | BBR 核心 | 智能探测内核内建状态，配置队列算法与启用 BBR |
| `check_sysctl_conflicts` | 冲突检测 | 过滤 `#` 与 `;` 注释，精准扫描外部覆盖配置 |
| `remove_fstab_entry` | 恢复核心 | 原子替换并兼容软链接地从 fstab 移除指定行 |
| `restore_all` | 恢复调度 | 按依赖倒序全面还原文件、配置条目与内核参数 |

---

## 第 6 部分：运行时效果与安全边界

### 6.1 退出码规范（Exit Codes）

* `0`：执行完全成功（含 `--help`、`--version`、预演成功、恢复成功）；
* `1`：执行失败或环境不满足（非 root、非 Debian、缺必要命令、磁盘不足、内核不支持、恢复未完全等）；
* `2`：命令行参数错误（未知参数、参数越界、互斥参数混用等）；
* `130`：用户按下 Ctrl+C（SIGINT）中断，清理半成品后安全退出；
* `143`：收到 SIGTERM 信号终止，清理后安全退出。

### 6.2 坚守的安全红线

本脚本秉持极简与高内聚设计：
* **绝不触碰网络与安全策略**：不修改 SSH 配置、不开放 root 密码、不改动 iptables / nftables 防火墙；
* **绝不引入第三方不可控代码**：不安装 XanMod 等第三方非官方内核，不下载或执行任何远端外部脚本；
* **绝不破坏用户既有资产**：不删除系统已有的 Swap 分区或文件，不删除无脚本标记的配置文件，遇到 fstab 软链接时绝对保留链接本体。

---

## 第 7 部分：初学者阅读路线建议

1. **先读开头注释**（了解“做什么”与“绝不做什么”的边界声明）；
2. **直奔尾部 `main` 函数**（把握整体调度的 18 个主干步骤）；
3. **深入两大业务分支**：精读 `configure_swap` 与 `configure_bbr` 的判断分支；
4. **精读逆向恢复设计**：阅读 `restore_all` 与 `remove_fstab_entry`，体会防御性编程中的幂等性与原子性；
5. **本地无害验证**：在终端执行 `sudo ./setup-swap-bbr.sh --dry-run`，对比源码中的分支逻辑印证理解。
