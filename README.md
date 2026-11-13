# SmartDNS - Android
已在Magisk31.1,安卓15中测试，运行正常。
> 本项目起源于 [x4455/smartdns-Android](https://github.com/x4455/smartdns-Android)，
> 但已经独立演进：内核跟进 SmartDNS 官方 Release（当前 **Release 48.4**），
> 模块侧新增了 KernelSU / MMRL WebUI、规则源管理、跨源合并去重、掉线自愈等，
> 与原仓库的代码结构、配置格式和发版节奏都已不同。原作署名见文末「感谢」。

## 关于本项目

- **内核跟进上游**：内核二进制取自 [pymumu/smartdns](https://github.com/pymumu/smartdns) 官方 Release，当前为 `1.2026.08.05-0921`（记录在 `kernel.tag` / `kernel.version`），由 GitHub Actions 每周检查上游更新。
- **新增 WebUI**：在模块管理器里点「打开 WebUI」即可完成启停、改端口、改模式、编辑 `smartdns.conf`、看日志，不必再手工编辑文件或敲命令。
- **规则源（4.0 起）**：规则不再随发版更新，而是可配置的「源」——每个源有自己的地址、类型和刷新节奏，到期由看门狗自动刷新。详见 [规则源](#规则源)。
- **掉线自愈**：开机后常驻看门狗每 30 秒检查内核进程与防火墙规则，异常自动拉起；从 WebUI 主动「停止」时不干预。
- **维护者**：[@ewgikeit](https://github.com/ewgikeit)
- **向后兼容**：shell 控制脚本、`script_conf.sh`、`smartdns.conf` 的格式与路径不变，升级不会覆盖你已有的配置。**唯一的例外是 4.0 会删除 `config/` 下的四张旧规则表**，见下节。


这是一个 [Magisk](https://github.com/topjohnwu/Magisk) / [KernelSU](https://github.com/tiann/KernelSU) 模块，使 [SmartDNS](https://github.com/pymumu/smartdns) 运行在安卓设备上。使用 shell 脚本控制其的启动与停止以及达到某些目的。

- 有关 SmartDNS 的信息详情请看 [官方文档](https://github.com/pymumu/smartdns/blob/master/ReadMe.md) 。
- **使用前请阅读 [声明](#声明)** 。

## 需求

- arm, arm64 指令集
- Magisk v20.0+ 或 KernelSU（WebUI 需要 KernelSU / KSU WebUI / MMRL）
- Busybox (建议安装模块 Busybox for Android NDK by osm0sis @ xda-developers)
- 在 Android 9+ 系统上使用，请关闭系统设置中的私人DNS，它会导致**模块失效**。

## 安装

[下载zip](https://github.com/ewgikeit/Smartdns-for-Android/releases/latest) 后，在 Magisk Manager / KernelSU 管理器中刷入。

- 更新模块时，可能会因为参数变化而导致错误，请在刷入之后自行调整。
- 为了避免更新导致错误或数据丢失，自动脚本**不会主动更新**。

### 升级到 4.0（务必先读）

4.0 改的是规则的**存放方式**，不是配置格式。你的 `smartdns.conf`、`script_conf.sh`、
`scripts/` 都不会被覆盖，但有两件事需要知道。

**风险 1：会删除 `config/` 下的四张旧规则表（约 5 MB）**

```
config/block/defaults.conf
config/ip/chnroute.txt
config/domain_diverg/chnlist.txt
config/domain_diverg/gfwlist.txt
```

它们现在只作为内置源的初始副本放在 `rulesrc/seed/`，`config/` 下那份是纯重复。
删除前提是「`seed/` 里已有同名副本且非空」+「主配置已不再引用它」，两个都满足
才动手，所以不会出现内核找不到 `conf-file` 而拒绝启动。

**风险 2：回滚到 3.4.x 需要重新铺表**

3.4.x 的主配置直接引用上面那四个文件，4.0 删掉后回滚就找不到。想回滚有两条路：

```shell
# 路线 A：让 3.4.x 的包重新铺表（推荐，先删数据目录）
su -c 'sh /data/adb/modules/smartdns/command.sh stop'
su -c 'rm -rf /data/adb/smartdns'
# 然后刷 3.4.x 的包并重启

# 路线 B：把内置副本复制回 3.x 的位置
su -c 'cd /data/adb/smartdns && mkdir -p config/block config/ip config/domain_diverg && \
  cp rulesrc/seed/block-defaults.conf   config/block/defaults.conf && \
  cp rulesrc/seed/ip-chnroute.txt       config/ip/chnroute.txt && \
  cp rulesrc/seed/domain-chnlist.txt    config/domain_diverg/chnlist.txt && \
  cp rulesrc/seed/domain-gfwlist.txt    config/domain_diverg/gfwlist.txt'
```

### 从 4.0 升级到 4.1

4.1 只改脚本和 WebUI，**没有数据迁移**，直接覆盖刷入再重启即可，配置、规则源、
本地 hosts 全部保留。仍然建议先按下面的「刷机步骤」备份一次。

如果你在 4.0 上遇到过这两种情况，4.1 已经修掉：

- 点了「更新」之后界面一直转圈、提示「已有更新任务在进行」——4.0 在更新完
  重载内核时没有先停旧内核，撞端口后走进了极慢的兜底路径，标记文件清不掉。
- 重启前后偶尔出现两个内核进程抢端口——4.1 给重启加了锁，同一时刻只有一个
  重启动作能动内核。

验证时看这两行就够：

```shell
su -c 'grep versionCode /data/adb/modules/smartdns/module.prop'   # 22
su -c 'sh /data/adb/modules/smartdns/command.sh status'
```

### 从 4.1 升级到 4.2

4.2 只改脚本，**没有数据迁移**，直接覆盖刷入再重启即可。

第一次启动时会用现有的 `auto-*.conf` 自动生成 `merged.conf`（16 万条约 2~3 秒，
只做一次），之后 `index.conf` 就从「逐个源引用」变成「只引用合并文件」。开机
日志里出现 `合并 N 个源：...` 就说明生效了。旧的 `auto-*.conf` 不会删，它们是
单源更新的判定依据。

回退到 4.1 也安全：4.1 的 `index.conf` 会重新生成成逐源引用，`merged.conf`
只是躺在那里不再被引用。

验证：

```shell
su -c 'grep versionCode /data/adb/modules/smartdns/module.prop'    # 23
su -c 'cat /data/adb/smartdns/config/rules/index.conf'             # 只有一行 merged.conf
su -c 'cat /data/adb/smartdns/config/rules/merged.stats'           # 去重统计
```

### 刷机步骤

**第一步：备份**（重要，回滚全靠它）

```shell
su -c 'tar czf /sdcard/sdns-backup.tgz -C /data/adb smartdns'
# 再拉一份到电脑
adb pull /sdcard/sdns-backup.tgz
```

也可以在模块管理器里用「备份」功能。

**第二步：刷入**

模块管理器 → 模块 → 从本地安装 → 选 `smartdns-android.zip`。
**不要**用「卸载 → 重启 → 再装」这种方式升级，那会丢失全部配置。

刷入日志里应该能看到这两行：

```
- 规则源: seed 4 个内置表
- Setting permissions
```

**第三步：重启手机**

4.0 的迁移在**服务启动时**做（先改配置引用、再删旧文件），所以要重启一次让它
生效。**不要**在刷完后手动去点「启动」，等开机自启即可。

**第四步：验证**

```shell
# 版本应为 4.0.0 (21)
su -c 'grep versionCode /data/adb/modules/smartdns/module.prop'

# 服务状态，rc=0 即正常
su -c 'sh /data/adb/modules/smartdns/command.sh status'

# 规则源状态，六条应该都是 ok，带条数
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc list'

# 迁移记录（首次开机才有）
su -c 'cat /data/adb/modules/smartdns/boot.log'
```

`boot.log` 里首次开机应该是这个样子：

```
[提示]: 原来的静态规则列表已接入「规则源」管理。
[boot] 规则引用切换到 rules/index.conf
[rules] 清理旧规则副本: block/defaults.conf (1402 KB)
[rules] 清理旧规则副本: ip/chnroute.txt (293 KB)
[rules] 清理旧规则副本: domain_diverg/chnlist.txt (2046 KB)
[rules] 清理旧规则副本: domain_diverg/gfwlist.txt (462 KB)
[boot] 清理 config/ 下旧规则副本 5 个，释放 4204 KB
[信息]: 服务器 成功启动
```

如果 `status` 返回 3（服务没起来），看 `/data/adb/smartdns/log/core.log`，
那是内核自己吐的启动错误。

**第五步：打开 WebUI 确认「规则」页**

六条源都应显示 `ok` 和条数，`github520` 约 40 条。点一次「全部更新」应当
全部成功、0 失败。

### 恢复默认配置

使用终端等工具，刷入前以Root权限执行以下命令

- *配置文件*: `touch /data/adb/smartdns/config/reset`
- *自动脚本*: `touch /data/adb/smartdns/scripts/reset`

## 图形化界面（WebUI）

模块内置了一个 WebUI 页面，入口在模块管理器里：

- **KernelSU / APatch**：模块详情页 →「打开 WebUI」
- **Magisk**：安装 [KsuWebUIStandalone](https://github.com/5ec1cff/KsuWebUIStandalone) 或 MMRL 后，在同一入口打开
- **MMRL**：模块详情页 →「WebUI」

打开后可以：

| 页面 | 能做什么 |
|--|--|
| 状态 | 查看运行状态、PID、工作模式、监听端口、iptables 规则是否生效、内核版本；一键启动 / 停止 / 重启 / 清理规则 |
| 运行参数 | 图形化修改主/次端口、工作模式、放行网卡（tun / wlan / data）、放行应用、IPv6 封锁、日志开关、语言；等价于编辑 `script_conf.sh` |
| DNS 配置 | 在线编辑 `smartdns.conf`，支持保存（自动备份上一版）、重新载入、配置测试、还原备份、恢复出厂 |
| 规则 | 增删改订阅规则源（自定义刷新时间、启停、删除），手动更新，多源合并去重，编辑自定义 hosts 与黑白名单 |
| 日志 | 查看服务日志 / 审计日志 / 脚本日志 / 开机日志，可切换行数与自动刷新 |
| 关于 | 版本信息、一键检查上游内核新版本、相关链接 |

实现方式：页面 `webroot/index.html` 通过 KernelSU 的 `ksu.exec` 以 root 调用模块自带的 `webui.sh`，所有读写都限制在 `/data/adb/smartdns` 下的白名单文件，参数在 shell 侧二次校验。

> 注意：改完运行参数或配置后需要**重启服务**才会生效；「测试配置」要求先停止服务，否则端口冲突会误报失败。

## 规则源

规则不再写死在主配置里，也不再随模块发版才更新。每个「源」有自己的地址、类型和刷新节奏：

```
/data/adb/smartdns/
├── config/
│   ├── smartdns.conf          只引用 ./rules/index.conf 这一个汇总文件
│   ├── rules/                 生成物：auto-<id>.conf、merged.conf（去重后）、user-*.conf、index.conf
│   ├── ip/  domain_diverg/  hosts/   手写的固定规则（不随订阅变化）
└── rulesrc/
    ├── sources.conf           源清单
    ├── local.hosts            本地 hosts（WebUI 可编辑）
    ├── seed/                  内置表的初始副本（订阅大表只存在这里）
    ├── state/<id>             每个源的最后更新时间、条数、状态
    └── cache/                 远程源的下载原文
```

> 4.0 之前，订阅大表（广告表 / 国内域名 / 国外域名 / 网段）直接铺在 `config/`
> 下，与 `seed/` 里的副本重复占 5 MB，升级时已自动清理。
>
> `config/rules/` 现在约 10 MB：各源的 `auto-<id>.conf`（约 5 MB）加上合并后的
> `merged.conf`（约 5 MB）。两份都留着是有意的——各源文件用于「这个源这次变了没
> 有」的判定和单源失败时的兜底，合并文件才是内核真正加载的那一份。

`sources.conf` 每行一个源：

```
id=anti-ad type=domain-block url=seed/block-defaults.conf interval=168 enabled=1
id=github520 type=hosts url=https://raw.hellogithub.com/hosts interval=6 enabled=1
id=local-hosts type=hosts url=/data/adb/smartdns/rulesrc/local.hosts interval=0 enabled=1
```

字段说明：

| 字段 | 含义 |
|--|--|
| `id` | 唯一标识，同时是生成的文件名（字母数字与连字符） |
| `type` | `domain-block` / `domain-cn` / `domain-foreign` / `ip-whitelist` / `ip-blacklist` / `hosts` |
| `url` | `https://…`、`/绝对路径`、`seed/<文件名>`，或 `system`（读 `/system/etc/hosts`） |
| `interval` | 刷新间隔（小时），`0` 表示只手动更新 |
| `at=` | 可选，改成定点更新，与 `interval` 二选一：`06:00` 每天 / `w1-06:00` 每周一（`w1`..`w7` 是周一到周日）/ `m15-06:00` 每月 15 日 |
| `enabled` | `1` 启用 / `0` 停用 |

### 在 WebUI 里管理源

「规则」页每个源是一张卡片：类型、地址、状态点、刷新计划、上次更新与预计下次，
右侧是启用开关，行尾是「更新 / 设置 / 删除」。

- **添加**：底部抽屉里填名称、类型、地址，再选更新时间——*仅手动* /
  *每 N 小时更新一次* / *每天 HH:MM 更新*。
- **设置**：同一个抽屉，名称创建后锁定（它就是生成的文件名），其余都能改。
- **删除**：二次确认，确认后连同 `auto-<id>.conf`、状态、缓存一起清掉。
- **内置源**（四张 seed 表 + `local-hosts`）**只能停用，不能删除**。
- 改地址或类型时，旧的规则文件会保留一份（新源拉不动时旧规则还能继续用），
  状态显示为「待更新」。

六种类型对应的输出：

| type | 输入格式 | 生成 |
|--|--|--|
| `domain-block` | hosts / 纯域名 / 已带 `address` 的行 | `address /域名/#` |
| `domain-cn` | 纯域名 | `nameserver /域名/China` |
| `domain-foreign` | 纯域名 | `domain-rules /域名/ -nameserver foreign -ipset gfwlist` |
| `ip-whitelist` | CIDR | `whitelist-ip` |
| `ip-blacklist` | CIDR | `blacklist-ip` |
| `hosts` | hosts（`IP 域名 [域名…]`） | `address /域名/IP` |

`hosts` 类型的两条特殊约定：`0.0.0.0` 与 `::` 视为屏蔽，转成 `address /域名/#`（返回空地址比返回 `0.0.0.0` 干净）；其余 IP 照实映射，包括 `127.0.0.1` 和局域网地址。

更新流程：下载 → 转换 → 校验（远程源拿到 HTML 或转换结果为空一律拒绝，保留旧规则）→ 写 `.tmp` → 原子替换 → 有变化才重启内核。调度挂在看门狗里，不额外起守护进程。

### 跨源合并与去重

多个源收录同一个域名很常见（两个广告表、chnlist 与 gfwlist 的重叠部分）。如果
把各源的 `auto-<id>.conf` 原样丢给内核，同一个域名会被定义多次：重复的规则白
占内存和解析时间，语义不同的规则（一个屏蔽、一个映射到 IP）最终哪条生效还取决
于内核内部匹配顺序——等于听天由命。

所以每次生成时会把所有启用源的规则**合并成一份** `config/rules/merged.conf`，
按「指令族 + 域名/CIDR」去重：同一个域名只保留一条，同一个网段只归一边。
`index.conf` 因此通常只有一行引用：

```
conf-file /data/adb/smartdns/config/rules/merged.conf
conf-file /data/adb/smartdns/config/rules/user-block.conf   # 有内容才会出现
```

冲突时按类型取用，优先级从高到低：

| 优先级 | 来源 | 理由 |
|--|--|--|
| 60 | `local-hosts` | 用户手写的映射，最明确 |
| 40 | `hosts` | 域名 → IP 的显式映射 |
| 30 | `domain-block` / `ip-blacklist` | 屏蔽 |
| 20 | `domain-foreign` | 走国外组 |
| 10 | `domain-cn` / `ip-whitelist` | 走国内组 |

同优先级按 `sources.conf` 里的先后，先出现的赢。举个例子：`chnlist` 和
`gfwlist` 都收录了 `airasia.com`，合并后保留 gfwlist 的「走国外」；`github520`
映射了 `collector.github.com`，即使 gfwlist 也收录了它，最终按 IP 映射走。

合并结果与统计写在 `config/rules/merged.stats`（原始条数、保留条数、重复数、
冲突数），每次更新完会在「更新日志」里打一行摘要：

```
[rules] 合并 5 个源：167697 条 -> 去重后 167681 条（删除重复 16，语义冲突 16）
```

`user-block.conf` / `user-allow.conf` / `user-hosts.conf` 不参与合并，始终排
在 `merged.conf` 之后加载，所以手写规则永远覆盖订阅规则。

合并文件缺失时（升级后首次启动、或合并本身失败）`index.conf` 会自动退回逐源
引用：内核多解析几份重复规则无所谓，但不能出现「一条规则都没加载」。

命令行操作：

```shell
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc list'          # 查看状态
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc update all'    # 全部更新
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc update github520'
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc add mylist domain-block https://example.com/list.txt 24 1'
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc set mylist 0 1 07:30'   # 改成每天 07:30
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc set mylist 12 1 -'      # 改成每 12 小时
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc del mylist'
su -c 'sh /data/adb/modules/smartdns/command.sh rulesrc merge'        # 只重建合并去重文件，不下载
```

## 配置文件

因网络环境的不可靠性，不对默认配置的可用性负责，**仅供参考**。请根据自身的网络情况 **自行配置**，具体参考 [配置文件](#配置文件) 进行配置。

### Smartdns 配置

配置文件位于 `/data/adb/smartdns/config/smartdns.conf`。如果你不知道你在干什么，请保持下列参数为默认值

|参数|功能|默认|
|--|--|--|
|cache-file|缓存持久化文件路径|cache-file /dev/smartdns/tmp/dns_cache
|log-file|日志文件路径|log-file /data/adb/smartdns/log/smartdns.log
|audit-file|审计文件路径|audit-file /data/adb/smartdns/log/smartdns-audit.log
|ca-file|证书文件|ca-file /dev/smartdns/binary/CA/ca-certificates.crt
|ca-path|证书文件路径|ca-path /dev/smartdns/binary/CA

> 日志放在 `/data/adb/smartdns/log/` 而不是 `/dev/smartdns/log/`：`/dev` 是内存文件系统，
> 重启就清空，而且部分机型上内核进程所在的安全域写不进 `/dev` 下的普通目录
> （表现是配置里有 `log-file`、日志文件却永远不生成）。服务每次启动时会自动把
> 老配置里的 `/dev` 路径改到 `/data` 下，原文件备份为 `smartdns.conf.bak`。

其他参数设置，请参考 [配置参数](https://github.com/pymumu/smartdns/blob/master/ReadMe.md#配置参数)

黑白名单

- 如果一个查询返回多个ip的结果，只要其中一个在blacklist中，该结果整个丢弃。
- 如果一个查询返回多个ip的结果，但没有任何结果符合whitelist，该结果整个丢弃。

### 控制脚本配置

配置文件位于 `/data/adb/smartdns/config/script_conf.sh`。脚本参数影响 iptables 规则和服务控制。修改之前，务必确保服务已经停止。

|参数|功能|
|--|--|
|log|生成脚本运行日志|
|language|脚本提示信息的语言|
|Main_PORT|主要监听端口，处理本地流量|
|Second_PORT|次要监听端口，处理代理流量 (为空时使用 Main_PORT 的值)|
|MODE|工作模式|
|TUN|不重定向走 VPN(tun) 的数据包|
|WLAN|不重定向走 WiFi(wlan) 的数据包|
|DATA|不重定向走 DATA(rmnet_data) 的数据包|
|PKG|不重定向特定应用的数据包 (填包名或UID，用空格分隔)|
|IP6T_BLOCK|封锁或重定向本机 IPv6 网络上的数据包|

工作模式介绍

```txt
local         : 本机发出到53端口的数据包重定向到 Main_PORT (默认)
proxy         : 发往本机53端口的数据包重定向到 Second_PORT
local,proxy   : 结合上面俩项
server        : 仅启动服务器 (任务脚本照常运行)
```

PKG 介绍

- iptables 不会重定向在 `PKG` 中包名所对应的 UID 所发出的查询。另外，以 `root` `radio` 身份发出的查询也会放行。

IP6T_BLOCK 介绍

- IPv6 重定向需要运行完全支持 ip6tables(CONFIG_IP6_NF_*) 的内核的 Android 设备，大多数情况下您必须自己编译内核。如果您的设备内核不支持，会自动转为封锁。

### 任务脚本

在设定时间执行 shell 脚本。文件结构遵循下面的示例。

```txt
/data/adb/smartdns/scripts
 │      *** 开机任务脚本 ***
 ├─── bootTask
 │   ├─── crond             <--- 任务目录
 │   │   └─── boot.sh       <--- 主脚本 (名称必须为 boot.sh)
 │   └─── ...
 │      *** 定时任务脚本 ***
 ├─── cronTask
 │   ├─── hosts_update      <--- 任务目录
 │   │   ├─── crond.reg     <--- 注册执行时间 (名称必须为 crond.reg)
 │   │   └─── GitHub.sh     <--- 脚本
 │   └─── ...
 └─── lib.sh                <--- 常用脚本函数
```

### 使用&配置 建议

- 服务启动时，请确保互联网连接通畅。长时间断网可能会导致解析异常。
- 上游服务器优先指定 IP，至少需要一个IP地址形式的上游服务器，用以解析域名形式的上游服务器。
- 同一个地址，一般没有必要配置多种协议。

## 异常解决

- 使用 `smartdns -clean` 命令清理可。这会尝试将 iptables 恢复至开机后首次启动时记录的状态，会对使用到 iptables 的程序造成一些影响。

### 代理类应用兼容性

当参数`TUN='yes'`时(默认), 对于启用 VPN (即屏幕顶部出现一个🗝️图标)后

#### 以下方案**仅供参考**，请自行调整相关应用中与 DNS相关 的处理。

- [Adguard](https://github.com/AdguardTeam/AdguardForAndroid):

1. 本地VPN模式兼容性不好，需换成HTTP代理，`网络 -> 过滤方式 -> 本地HTTP代理`
1. DNS指向 `127.0.0.1:(填监听端口)` ，`DNS -> 选择 DNS 服务器 -> 添加自定义DNS服务器`
1. 为 root 添加放行规则， `高级 -> 低级设置 -> pref.excluded.packages` 添加一行内容: `0` 。
1. 控制脚本配置中的参数 `MODE` 设置为 `server`。

- [Clash](https://github.com/Kr328/ClashForAndroid):

1. 默认设置下 SmartDNS 不参与，交由 Clash 完成处理。如需有需要，自行调整。

## 命令

使用终端等工具 以Root权限执行，以下是常用命令

```shell
smartdns [options]
~ start
# 启动服务

~ stop
# 停止服务

~ status
# 服务状态

~ clean
# 清理服务并恢复 iptables 到初始状态

~ -h, --help
# 帮助信息
```

## 更新内核（维护者）

内核二进制来自上游官方 Release，模块只取两个静态文件：`smartdns-arm` 与 `smartdns-aarch64`，分别对应 `binary/arm`、`binary/arm64`。

**自动**：`.github/workflows/update-kernel.yml` 每周一检查上游最新 Release，发现新版本会自动下载、校验 ELF 架构、替换二进制、递增 `versionCode` 并提交。

**手动**：

```shell
# 替换二进制
curl -fL -o binary/arm   https://github.com/pymumu/smartdns/releases/download/<tag>/smartdns-arm
curl -fL -o binary/arm64 https://github.com/pymumu/smartdns/releases/download/<tag>/smartdns-aarch64
chmod +x binary/arm binary/arm64

# 记录版本号（WebUI 与 updateinfo 使用）
echo <tag> > kernel.tag
```

**发版**：改好 `module.prop` 的 `version` 与 `versionCode` 后打 tag（`git tag v3.2.0 && git push --tags`），`build-release.yml` 会自动打包 `smartdns-android.zip` 并发布 Release，同时用 `module.prop` 重新生成 `updateinfo.json`。

## 更新根证书库（维护者）

`binary/ca-certificates.zip` 是 DoH / DoT 校验上游证书用的根证书库，内容取自 [Mozilla 信任库](https://curl.se/ca/cacert.pem)。它**不会**随内核更新一起刷新，需要单独处理。

**自动**：`.github/workflows/update-ca.yml` 每月 1 日重新下载官方 PEM、按 CN 拆成单证书文件、重建 `CA/ca-certificates.crt` 合并包并打包，有变化才提交（同时递增 `versionCode`），使用日期记录在 `binary/CA_VERSION`。

**手动**：

```shell
sh scripts/update-ca.sh
```

脚本会校验证书数量、拆分与合并结果，任一环节不符就放弃更新，不会产出坏包。证书名已做 ASCII 归一化（历史上有一个匈牙利语文件名，导致 Windows 解压报错）。

替换后建议实测一次校验链：

```shell
unzip -p binary/ca-certificates.zip CA/ca-certificates.crt > /tmp/ca.crt
echo | openssl s_client -connect dns.alidns.com:443 -servername dns.alidns.com -CAfile /tmp/ca.crt
```

## 感谢

- [SmartDNS](https://github.com/pymumu/smartdns) | pymumu（内核）
- [x4455/smartdns-Android](https://github.com/x4455/smartdns-Android) | x4455（本项目起源于此：模块骨架、`customize.sh`、防火墙与开机脚本的早期实现）
- [ClashForMagisk](https://github.com/Kr328/ClashForMagisk) | Kr328

### 规则来源

内置的四张表随包下发，作为「规则源」的初始副本：

| 内容 | 来源 |
|--|--|
| 广告屏蔽（`anti-ad`） | [anti-AD](https://github.com/privacy-protection-tools/anti-AD) |
| 国内域名（`chnlist`） | chnlist 汇总 |
| 国外域名（`gfwlist`） | gfwlist 转换 |
| 国内网段（`chnroute`） | chnroute |

在线 hosts 源：

- [GitHub520](https://github.com/521xueweihan/GitHub520) | 521xueweihan（经 `raw.hellogithub.com` 分发）
- [Steam520](https://github.com/pboymt/Steam520) | pboymt

> 早期版本的致谢里列过 [AD-hosts](https://github.com/E7KMbb/AD-hosts)，但这个分支从未使用过它的数据（`config/` 里的广告表来自 anti-AD），该列表也已停止维护，现已移除。

## 捐赠

如果你觉得 SmartDNS 对你有帮助，请捐助 **[原作者](https://github.com/pymumu/smartdns/blob/master/ReadMe.md#捐赠)** ，以使项目能持续发展，更加完善。

## 声明

### 如果您下载且安装 SmartDNS，则表示认同声明协议

- `SmartDNS` 著作权归属 Nick Peng (pymumu at gmail.com)。
- `SmartDNS` 为免费软件，用户可以非商业性地复制和使用 `SmartDNS`。
- 禁止将 `SmartDNS` 用于商业用途。
- 使用本软件的风险由用户自行承担，在适用法律允许的最大范围内，对因使用本产品所产生的损害及风险，包括但不限于直接或间接的个人损害、商业赢利的丧失、贸易中断、商业信息的丢失或任何其它经济损失，不承担任何责任。
- 本软件不会未经用户同意收集任何用户信息。
