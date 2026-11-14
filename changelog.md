# 更新日志

## 未发布

代码评审（2026-11-14）修复中，下列条目已落地但尚未发版。

### 修复：端口与 bind 不一致（评审 C3）

- WebUI 保存 `Main_PORT` 时，顺手把 `smartdns.conf` 里的 `bind` / `bind-tcp` /
  `bind-tls` 端口一起改掉。原来只写 `script_conf.sh`：iptables 把 53 全量重定向到
  新端口，内核却还在旧端口监听 —— 解析全挂；看门狗又会因为「进程在、端口没听」
  每 90 秒杀一次内核再拉起，界面一直显示"运行中"，日志里只有一串 start 成功。
- 只改端口那一截：`[::]` / `0.0.0.0` 地址、`@wlan0` 设备名、其它参数、注释行都不动；
  改完返回 `port_note=`，前端提示「重启服务后生效」。
- 配置里没有 `bind` 行时不乱写，只提示「内核会按默认 53 端口监听，请自行确认」。

### 修复：规则下载不再关闭 TLS 校验（评审 C4）

- `scripts/lib.sh` 的 `download_links` 原来是 `curl -k` / `wget --no-check-certificate`，
  TLS 只加密不验身份；下载到的 hosts 会被转成 `address /域名/IP` 写进内核配置
  （root 权限、无人工确认），中间人可决定任意域名解析到哪。改成
  `curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-filesize 64M` 与
  `wget --https-only`（busybox wget 默认校验证书）。

### 修复：规则存在性判定（评审外，自行发现）

- `iptrules_check` / `webui.sh` 的 `ipt_active` 把 `($Main_PORT|$Second_PORT)` 直接
  拼进正则：`Second_PORT` 在 start 之前是空串，空分支让**任意一条** REDIRECT 都命中
  （真机 `script_conf.sh` 里 `Second_PORT` 确实是空的）。判据还锚不到
  `--to-ports`，`--to-ports 16053` 也会被当成自己的规则。两处都改成
  「跳过空端口 + 锚定 `--to-ports`」。

### 修复：本机模式对系统解析不生效（评审 C6）

链首原来放行 `uid 0`，用来避免内核自己的上游查询被自己再劫持一遍；但 Android 的
netd 也是 uid 0，普通应用的解析全走它 —— 真机实测 `dns_redirect` 里
`--uid-owner 0 -j RETURN` 计数 40、`REDIRECT --to-ports 6053` 恒为 0，也就是说
「本机模式」对普通应用完全没生效。

评审建议的是「让内核跑在专用 UID 上」。这条路在本模块走不通：内核要读的规则
（`rules/index.conf` 里是 `/data/adb/...` 的绝对路径）、要写的日志都在 `/data/adb`
下，而该目录是 0700，非 root 连路径都进不去 —— 真机验证时 `setuidgid 9999` 连
日志目录都写不了，配置也读不全。所以改成**按目的地放行**：

- 先把配置里所有明文 `:53` 的上游 IP 挑出来（IP 字面量 + `address /名字/IP` 钉死
  的主机名；DoT 853 / DoH 443 不经过 `--dport 53`，不用管），在 `dns_redirect` 里
  为这些 IP 各加一条 `-j RETURN`；
- 链里不再放行 uid 0，netd 的查询就会被正常重定向到本模块；
- 只要有**任何一个**明文上游钉不到 IP，就自动退回「放行 uid 0」的老做法：宁可本机
  模式不生效，也不能让内核的上游查询自环。

真机验收：`REDIRECT` 计数 0 → 10；连续解析 8 个域名 8/8 成功（无自环）；
`stop` 后规则与链全部清空，`start` 后恢复；`diag` 显示
「本机模式拦截: 已生效（按目的地放行内核上游）」，并列出放行了哪些 IP。

配套做了三件事，堵住「配置会改」带来的漏洞：

- **`conf-file` 包含也解析**：原来只看主配置，用户把 `server` 写进
  `conf-file ./xxx.conf` 就会被漏掉 —— 漏掉的明文上游会被自己的重定向劫持，
  直接自环。现在按「被包含文件所在目录」解析相对路径，最多 3 层 / 20 个文件。
- **上游清单快照**：内核启动成功时把「这次实际读到的上游」存到
  `.upstream.ips`，规则一律按快照生成。这样「改了 smartdns.conf 但还没重启内核」
  的窗口里重装规则，也不会出现「规则按新配置、内核还在用旧配置」的错位。
  单测里专门覆盖了「address 写在 server 后面」和「明文上游藏在包含文件里」。
- **看门狗定期对账**：进程活着时每约 5 分钟比对一次链里的 `-d` 放行列表与快照，
  不一致就只重装规则、不动内核进程。兜的是「iptables 被别的工具改过」这类情况。

### 配置：默认不再有明文上游（配合 C6）

随包默认配置改成「零明文上游」形态：

- 国内 DoT 也改成 **IP 直连 + SNI**：`server-tls 223.5.5.5:853 -host-name
  dns.alidns.com -tls-host-verify dns.alidns.com`（dot.pub 同理）。`-host-name`
  决定 SNI，`-tls-host-verify` 校验证书域名，两个必须成对写。
- **bootstrap 默认不再启用**：所有上游都是 IP 直连，不需要解析上游主机名，
  内核因此一条明文 `:53` 查询都不发 —— 重定向不会自环，链里连 `-d` 放行规则
  都不需要（真机验收：`-d` 规则 0 条，`REDIRECT` 计数照常增长）。
- **运营商本地解析默认注释掉**：它是这套配置里唯一的明文上游，各地 IP 不同，
  模块不替你猜。配置里写明了从哪查（路由器 WAN 页 / 搜「运营商+省份 DNS」）
  并给了电信/联通/移动的例子，需要时去掉注释即可；启用后模块会自动按目的地
  放行（真机验收：打开电信那两行 → 链里自动出现 `-d 202.96.209.5 -j RETURN`，
  解析正常；关掉 → 回到 0 条）。

### 修复：防火墙规则清理（评审 C1 / C2 / C5）

- **C1** `iptrules_off` 原来拿 `MODE` 当开关，改成「仅服务」模式后再停止/卸载就
  一条规则都不删，nat 表里仍把 53 重定向到没人监听的端口。现在清理与模式完全
  解耦：v4/v6、封锁与重定向两个方向都清一遍，`stop` / `clean` / 卸载走同一条路，
  清完还会再断言一次（有残留就整条扫出来再删并写 `boot.log`）。
- **C2** 原来是 `while iptrules_check` 收敛 + 超 3 轮 `exit 1`，而 proxy 模式装的
  `PREROUTING` 跳转从来没被删过，`local,proxy` 下必然死循环；那个 `exit 1` 正好
  落在 `server_stop` 与 `server_start` 之间，内核停了规则删一半 → 永久断网且看门狗
  救不回来。现在改成「删跳转 → 清链 → 删链」的固定序列，`PREROUTING` 按目标端口
  从 `-S` 反查后删除（IP 变了也能删），任何一步失败都继续，绝不 `exit`。
- **C5** 循环末尾 `|| let count++` 在 `count=0` 时返回 1（后自增返回旧值），清理成功
  反而让函数返回 1；`log=yes` 时 `command.sh` 带 `set -ex`，start/stop 被直接打断
  （真机：`stop` 返回 3、内核还在跑、规则已删空）。循环去掉后问题消失，另外清理里
  每条命令都吞掉退出码（真机上 `iptables -F` 因链已不存在返回 1 也会打断 stop）。

### 修复：端口体检的两次误判（评审 W1 / W12）

- **W1** `port_busy` 只看 `/proc/net/tcp{,6}` 的本地端口，不看状态列：上一轮连接
  留在 `TIME_WAIT`（`06`）时也算「被占用」。后果是 `wait_port_free` 每次白等满
  15 轮、`free_port_for_start` 去 kill 一个并不存在的占用者，最后报「端口仍被占用」
  并 `exit 1`；`diag` 也会显示「被占用 -> （空）」。现在 TCP 只把 `06` 当作可复用
  状态跳过（依赖 `SO_REUSEADDR`，smartdns 默认开启），`LISTEN` / `ESTABLISHED` /
  `CLOSE_WAIT` 等仍算占用；UDP 没有 `TIME_WAIT`，逻辑不变。
- **W12** `port_owner` 原来对每个 `/proc/<pid>/fd/*` 单独 `readlink`，真机上进程数
  × fd 数就是上万次 fork，实测 >90 秒不返回，而 `diag`、启动体检、`start_fail_hint`
  都在同步调用它。现在两条路径：先 `ss -a -n -p` 一次列全表，从 `ino:` 找到
  `pid=`（toybox 没编 `-p` 时自动跳过）；退回 `/proc` 时改成「一次 `ls -l` 取回
  所有 fd 链接 + 一次 awk 匹配 inode」，fork 次数从「fd 总数」降到 2 次，并套
  `timeout 8` 兜底。
- 本地配套测试 `webui-tests/port-owner-test.sh`（14 项）：`TIME_WAIT`/`LISTEN`/
  `CLOSE_WAIT`/UDP 的判定、`ss` 快路径、无 `pid=` 时回退、inode 不匹配、
  6300+ 行 fd 输出的耗时。这几个函数新增可覆盖的 `PROC_ROOT`（默认 `/proc`），
  测试全部跑在临时目录里。

### 修复：停止被看门狗覆盖 / 规则更新卡住看门狗（评审 W2 / W6）

- **W2** `start` 一进来就 `rm -f $STOP_FLAG`，而看门狗拉起内核也走这个 `start`：
  用户点「停止」的同一瞬间看门狗发起拉起，停止标记被抹掉 → 界面显示已停止、
  DNS 却在跑。现在拆出 `start-auto` 给看门狗专用：启动前先看标记（有就返回），
  启动后再复检一次，期间用户点了停止就按停止流程把刚拉起的核收掉；手动 `start`
  仍清标记，语义不变。判断用 `if` 而不是 `[ ... ] &&`，否则 `log=yes` 的 `set -e`
  会在标记不存在时把启动打断（与 C5 同一个坑）。
- **W6** `watch_rules` 原来同步执行 `rulesrc update all`：`curl --max-time 180` ×
  3 次重试 × N 个源，最坏半小时。这段时间看门狗整段不判活，DNS 掉了也不会自愈。
  现在改成 `setsid` 后台执行（无 `setsid` 时退回普通后台），先写
  `$RULES_STATE/.running` 防止重复触发，结束时记录 rc 并清理标记；看门狗主循环
  立即返回，照常每 30 秒判活。
- 本地配套测试 `webui-tests/watch-test.sh`（15 项）：`start-auto` 的调用关系、
  手动 `start` 语义、`set -e` 断言、`watch_rules` 立即返回、`.running` 生命周期、
  已有任务/未到期/无源文件时不重复启动。

### 修复：clean 还原脏备份 / 看门狗单实例竞态（评审 W3 / W13）

- **W3** 备份（`/dev/smartdns/tmp/iptables_rules.bak`）是 `iptables-save` 的直出：
  `initTask` 每次开机/模块更新都会重抓，`ensure_env` 在工作目录丢失时也会重抓。
  如果抓的时候服务正在跑，快照里就带着 `dns_redirect` 和 `--to-ports 6053`；
  之后 `clean` 拿它 `iptables-restore`，等于把「重定向到死端口」原样恢复回去，
  比不还原更糟。现在 `ipt_snapshot` 只落「干净」快照（含模块链或 `--to-ports`
  就丢掉，旧备份保持不动），`clean` 只在双栈备份都干净时才 restore，否则记
  `boot.log` 并只清自建链——自建链本来就已经被 `iptrules_off` 清掉了。
- **W13** 看门狗单实例原来只扫 `/proc` 的 cmdline：两个进程同时启动、都还没扫到
  对方时都会通过，之后每 30 秒互杀一次内核；`/proc` 读不到时也会当成「没有别的
  实例」。现在先 `mkdir` 抢目录锁（原子），抢不到等对方写 pid 再判断；pid 已死的
  残留锁自动接管；`/proc` 扫描降为兜底（处理 pid 复用）。退出时释放锁，`TERM`/`INT`
  改成先退出再由 `EXIT` trap 清锁，避免「锁没了但看门狗还在跑」。
- 本地配套测试 `webui-tests/backup-lock-test.sh`（18 项）：干净/脏快照、save 失败、
  备份可用性判定、锁的抢占/接管/空 pid/并发启动只活一个。

### 修复：proxy 取址只跑一次 / 规则装了没装没人知道（评审 W8 / W15）

- **W8** `for IP in "$(ifconfig …)"` 的引号把多行输出合成**一个**词，循环只迭代
  1 次；随后 `iptables -d ${IP}` 收到整串地址必然失败，proxy 模式按目的地放行的
  规则基本没装上。新增 `local_v4_addrs()`：优先 `ip -o -4 addr show`（一行一个、
  字段稳定），没有 `-o` 时退回 `ifconfig`，新老两种输出格式（`inet addr:` 与
  `inet x.x.x.x/len`）都认，并去掉掩码；调用处不加引号分词，私网过滤从
  grep 正则改成 `case`（原正则 `(^192\.168\.*)` 的 `\.*` 其实是「零或多个点」）。
- **W15** `iptrules_on` 里每条 iptables 都没检查返回值：ROM 不支持 nat 表、或规则
  被别的工具锁住时，会「静默装了个寂寞」，服务照样报启动成功。新增
  `iptrules_verify()`，装完分别验 v4 的 `OUTPUT → dns_redirect` 和 v6 的
  `dns_block`（封锁模式）/ `dns_redirect`；失败写 `boot.log` 并打印警告。
  **故意不返回 1**：返回 1 会让 `server_restart` 判定整个启动失败，看门狗转头去
  重启一个其实在正常解析的服务；规则缺失会被看门狗自己的 `iptrules_check`
  发现并按 30s → 5min 的间隔重装。
- 本地配套测试 `webui-tests/proxy-verify-test.sh`（13 项）：`ip -o` 解析、两种
  ifconfig 格式回退、循环次数、双栈校验的各失败分支、失败不返回 1。

## 4.2.1

只删代码，不改功能。**从这一版起不再兼容 4.0.0 之前的模块**，那批遗留迁移逻辑
全部删掉（约 130 行），4.0 及以后的升级路径完全不变。

### 删除

- `customize.sh`：`migrate_legacy_layout`（2024 年的 `list_block` / `list_ip` /
  `list_location` → `block` / `ip` / `domain_diverg` 目录搬家 + 改写配置里的
  相对路径）、`sync_scripts` 里把旧 `bootTask/*.sh` 与 `cronTask/root` 改名成
  `.legacy` 的两段、以及「包里没带 `rulesrc/` 时从 `config/` 兜底取 seed」的分支
- `common/rules.sh`：`rules_import_legacy`（把 3.x 的静态表复制进 `seed/`）、
  `rules_cleanup_legacy`（删 `config/` 下那四张约 5 MB 的重复表）、
  `rules_cache_gc`（清 3.5 及以前本地源复制到 `cache/*.raw` 的残留）
- `common/command.sh`：`conf_rules_fix` 里把旧 `conf-file` 引用改写成
  `./rules/index.conf` 的那段 awk 迁移。这个函数现在只负责「规则元数据、合并
  文件、索引确实存在」，不再动用户的配置

### 影响

- 从 4.0 之前升上来**不会**再自动迁移：目录不搬、配置不改、旧表不删。结果是旧
  静态表照旧生效、规则源里更新走不到内核（不报错，但会以为更新没生效）。
  升上来之前先 reset 一次，或按 README「从 4.0 之前升级」手改 `conf-file`
- 那四张约 5 MB 的旧表不再被自动清理，留在 `config/` 里；确认主配置不再引用后
  可以自己删
- 4.0 / 4.1 / 4.2.0 升到 4.2.1 无感：配置、规则源、本地 hosts 全部保留

## 4.2.0

4.1 之前每个源各生成一份 `auto-<id>.conf`，`index.conf` 把六七个文件全部丢给
内核。同一个域名被多个源收录时会重复定义，语义冲突时最终哪条生效取决于内核
内部顺序。这一版把所有启用源**合并成一份去重后的 `merged.conf`**。

### 新增：跨源合并去重

- 生成 `config/rules/merged.conf`：按「指令族 + 域名/CIDR」去重，同一域名只留
  一条，同一网段只归一边。`index.conf` 从「逐源引用」变成只引用这一个文件
  （用户手写的 `user-*.conf` 仍在它之后加载，优先级不变）。
- 冲突按类型定优先级，不再听天由命：`local-hosts`(60) > `hosts`(40) >
  `domain-block`/`ip-blacklist`(30) > `domain-foreign`(20) >
  `domain-cn`/`ip-whitelist`(10)，同级按 `sources.conf` 顺序先到先得。
- 生成 `merged.stats`（原始 / 保留 / 重复 / 冲突条数），更新日志里打一行摘要。
- 新增 `command.sh rulesrc merge`：只重建合并文件，不下载任何东西。
- 合并失败或文件缺失时 `index.conf` 自动退回逐源引用，不会出现「一条规则都
  没加载」；升级后首次启动自动补生成一次。
- 批量更新时只合并一次（`RULES_MERGE_DEFER`），不是每个源更新完都重算一遍。

### 新增：更细的更新时间粒度

- 定时更新从「每天 HH:MM」扩展到三种：`HH:MM`（每天）、`w1-HH:MM`（每周一，
  `w1`..`w7` 对应周一到周日）、`m15-HH:MM`（每月 15 日）。遇到小月没有这一天
  （如 2 月 31 日）就跳过该月。
- WebUI 的「更新时间」从三选一变成五选一：仅手动 / 每隔几小时 / 每天 / 每周 /
  每月，后两者多一个下拉选择器。
- 到期判断抽成 `rules_at_match`（at、当前时间、星期、日）纯函数，不再依赖系统
  时间也能测。
- 下次更新时间超过一天时直接报日期（如「预计 11月16日 06:00」），不再用
  「2 天后」这种会失真的取整。

### 新增：合并结果面板

- 规则页顶部显示合并后条数、合并前条数、被去掉的重复条数，以及参与合并的源
  数量和上次合并时间。
- `rules list` 新增 `merged_kept/total/removed/conflict/sources/time` 字段，
  条数以 `merged.conf` 实际行数为准（统计文件可能落后一步）。

### 修复

- 看门狗在别人正在重启内核时不再插一脚：除了「规则更新进行中」，现在也认
  `server_restart` 的 `.restart.lock`（持锁进程已死视为残留锁）。
- 界面上的模块版本不再带括号里的内核版本：`module.prop` 的 `version` 为了在
  管理器里一并显示内核版本，写的是 `4.2.0 (1.2026.08.05-0921)`，WebUI 直接照
  搬会把同一串内核版本显示两遍（顶部副标题一行放不下就折行），「关于」页还会
  叠成 `4.2.0 (…) (23)`。现在界面统一只显示 `4.2.0`，版本代号单列一行。
- 顶部副标题与右上角状态不再折行：标题区改成可收缩（`min-width:0` + 省略号），
  状态胶囊定宽不换行。真机窄屏（360~393px）下「运行中」不会再断成两行。
- 「自动刷新」开关的圆钮错位：轨道被内联改成 40×23 后，圆钮还是按 46×27 的
  21px + 19px 位移画，右边会顶出轨道。改成由 `--sh` / `--sp` 驱动尺寸与位移，
  任意轨道尺寸都保持 3px 均等留白；顺带去掉日志行里嵌套的 `<label>`（点一下会
  被触发两次）。
- 境外域名的测速从 `ping` 改成 `none`（`conv_domain_foreign`）。被墙的 IP 基本
  不回 ICMP，`ping` 只会把上游刚返回的有效答案整批丢掉：真机实测 `www.google.com`
  拿到 8 个 `142.251.x` 的答案，ping 全部 200ms 超时，最终返回 SERVFAIL（日志里
  的 `rtt: -0.1 ms, 0.0.0.0` 就是这个）。改成 `none` 后 IP 选择交给客户端或代理，
  有代理时境外解析从「2 秒后失败」变成「400ms 正常返回」。
- 停用 fork 自带的 `ip/blacklist-ip.conf`（186 条）。它只有在上游带
  `-blacklist-ip` 时才生效，而默认配置里没有任何上游带这个参数，等于纯占位；
  表里还混着 `172.217.24.0/24`、`172.217.161.0/24`（谷歌真实网段）、`1.1.1.1`、
  `108.160.0.0/16`（Dropbox）这类会误杀正常结果的条目。主配置不再引用它，
  文件保留为空占位——升级不会覆盖用户的 `smartdns.conf`，那些还留着这行引用的
  配置一旦找不到文件，内核会直接拒绝启动。
- 随包配置的境外段改成「走本地代理」模板：`proxy-server` + 两个 IP 直连的
  DoH（`8.8.8.8` / `1.1.1.1`，带 `-host-name` / `-http-host` / `-tls-host-verify`）。
  原来的三个境外 DoH 在受限网络里一个都通（443 被 RST、明文 53 拿到污染答案），
  实测境外查询 2 秒后统一 SERVFAIL。模板里写清了要改的两处（代理端口、代理
  名字）和没有代理时的做法（注释掉两行 `server-https`，内核会因 foreign 组无
  上游而立即失败，不再卡 2 秒）。

### 升级

直接覆盖刷入再重启，无数据迁移。首次启动会用现有 `auto-*.conf` 生成一份
`merged.conf`（实测 16.7 万行耗时 2~3 秒），之后走增量。
`config/rules/` 会从约 5 MB 变成约 10 MB（各源文件 + 合并文件各一份）。

## 4.1.0

4.0 把规则做成了「源」，但源清单只能手改 `rulesrc/sources.conf`，WebUI 里只
能看列表和点「更新」。这一版把增删改写进了界面，并修掉了 4.0 真机跑起来才
暴露的几处问题。

### 新增：规则源的可视化管理

- 「规则」页从「列表 + 更新」改成卡片式管理：每个源显示类型、地址、状态点、
  刷新计划、上次更新、预计下次，行内有启停开关，行尾是「更新 / 设置 / 删除」。
- 「＋ 添加规则源」与「设置」共用同一个底部抽屉：名称、类型（6 种，带一句话
  说明）、地址、**更新时间三选一**（仅手动 / 每 N 小时 / 每天 HH:MM）、启用开关。
- **内置源保护**：四张 seed 表与 `local-hosts` 可以停用但**不允许删除**，
  界面上不画删除按钮，shell 侧再挡一次。
- 改地址或类型时，已生成的规则文件**保留**（新源挂了旧规则还能用），只把状态
  标成「待更新」。
- 校验集中在 shell 侧一处：id 字符集、类型白名单、地址不含空格、
  `interval` / `enabled` / `at=HH:MM` 的格式；非法参数不会落盘。
- 命令行同步：`command.sh rulesrc set <id> <interval> <enabled> [HH:MM|-] [url] [type]`。

### 修复

- **规则更新后重载内核会卡几分钟（严重）**：`rulesrc update` 更新完直接调
  `server_start`，可旧内核还在跑、端口没释放，于是走进 `port_owner` 全机扫
  `/proc/*/fd` 找 socket 属主的兜底路径。真机上要跑几分钟，`state/.running`
  一直清不掉——界面上就是「更新中」永不结束，之后每次更新都会被
  「已有更新任务在进行」挡掉。现在统一走 `server_restart`（先停再起），
  并给 `free_port_for_start` 加了「先按进程名清旧核」的廉价路径。
- **重启串行化**：WebUI 操作、规则更新、看门狗可能同时要求重启，两个 `start`
  撞在一起会互相把对方刚拉起的核当成「旧核占用端口」杀掉。现在用
  `/data/adb/smartdns/.restart.lock` 串行（带持有者 pid，持有者没了即视为
  陈旧锁直接接管），看门狗在更新期间也让路。
- **陈旧 `.running` 自愈**：进程被强杀（刷机、改配置、系统回收）后标记会留下，
  后续更新被永久拒绝。现在以「有没有对应的活进程」为准，是孤儿就清掉。
- **前端把错误当成功**：`webui.sh` 通过 `err()` 输出的中文提示以前被当成正常
  返回（重名添加也会弹「已添加」），现在按退出码判失败。
- 打包脚本对 `.sh/.conf/.html` 做 CRLF→LF 归一化：Windows 上编辑过的脚本
  刷进手机后 `sh` 会把 `\r` 当成行尾，第一行就语法错。

### 验证

真机 RMX1901 / Android 13 / Magisk 31.1，3.4.4 → 4.1.0 直升后：
`rules-sandbox-test.sh` 113 项、`webui-rules-args-test.sh` 25 项、
无头浏览器交互 31 项、真机端到端 52 项（含增删改、非法参数、内置保护、
更新后重载耗时 10 秒、`.running` 清理、hosts 保存即解析生效）全部通过。

## 4.0.0

版本号从 3.4.4 直接跳到 4.0，因为规则的组织方式换了：以前规则是随包下发的
静态文件，现在规则是「源」——有自己的地址、类型和刷新节奏。3.5.0 是这中间
的内部开发版本，没有单独发过 Release。

### 新增：规则源管理器

把「规则」从随包下发的静态快照，改成可配置、可定时刷新的规则源。

- **规则不再跟发版绑定**：新增「规则源」管理器。每个源有独立的地址、类型和刷新
  节奏（每 N 小时，或每天几点），六种类型覆盖域名屏蔽 / 国内域名 / 国外域名 /
  IP 黑白名单 / hosts 映射。生成到 `config/rules/`，主配置只引用一个
  `./rules/index.conf`。
- **hosts 支持三种来源**：远程 hosts 列表（GitHub520、Steam520 等）、模块内
  本地 hosts（`rulesrc/local.hosts`，WebUI 可编辑）、以及直接读系统
  `/system/etc/hosts`。`0.0.0.0` 与 `::` 自动转成屏蔽，其余 IP 照实映射。
- **更新安全**：远程源返回网页、或转换结果为空，一律判为失败并保留上一次的
  规则；写入走 `.tmp` 原子替换；只有内容真的变了才重启内核。
- **不依赖 crond**：到期检查挂在看门狗循环里。crond 在 Magisk 环境里的两个坑
  （相对路径 chdir 失败、`-b` fork 出去被回收）上一版才踩过，能少一个进程就少一个。
- **WebUI 新增「规则」页**：源列表（类型 / 节奏 / 条数 / 上次更新 / 失败原因）、
  单个或全部立即更新、更新日志、自定义 hosts 与黑白名单编辑器。
- 原有的规则引用自动迁移：`block/defaults.conf`、`ip/chnroute.txt`、
  `domain_diverg/{chnlist,gfwlist}.txt`、`hosts/github.txt` 这几条会被
  `./rules/index.conf` 取代；手写的固定规则（`bogus-nxdomain`、内网后缀、
  localhost、`blacklist-ip`）保持直接引用，不受影响。

### 变更：config/ 下不再放订阅大表

以前 `config/block/defaults.conf`、`config/ip/chnroute.txt`、
`config/domain_diverg/{chnlist,gfwlist}.txt` 这四张表（约 5 MB）既随包下发、
又要在 `rulesrc/seed/` 存一份初始副本，同样的数据在磁盘上存在两遍。

4.0 起它们只作为 `rulesrc/seed/` 里的初始副本存在，`config/` 下不再保留。
升级后首次启动会清掉旧副本（实测释放 4204 KB），`config/` 从 4.2 MB 降到 37 KB。

清理是有条件的，两个都满足才删：`rulesrc/seed/` 里有同名副本且非空、
主配置已经不再 `conf-file` 引用它。顺序上先改配置引用、再删文件，
所以不会出现「内核找不到 conf-file 而拒绝启动」。只删这几个固定文件，
`ip/`、`hosts/` 里的手写规则一律不动。

### 修复

- **`index.conf` 用了相对路径**：内核解析 `conf-file` 的相对路径时，基准是
  「被包含文件所在目录」而不是主配置目录，于是 `./rules/auto-x.conf` 被拼成
  `config/rules/./rules/auto-x.conf`，内核直接报 no such file 并拒绝启动。
  4.0 首次刷入就踩到这个，改成绝对路径。
- **本地源被复制进缓存**：seed 和 `local.hosts` 以前会 `cp` 一份到
  `rulesrc/cache/`，5 MB 又存了一遍。现在本地源直接读原文件，缓存只留给远程源
  （失败时还能回看上次下到的内容）。
- **「自定义 hosts」保存后不生效**：以前 `putfile` 只写文件，用户点了保存还得
  再点一次「更新」。现在写完立即转换并后台重载。
- **`rules reload` 会杀掉自己**：前台调 `command.sh start` 停旧内核时，把当前
  桥接会话一起杀了，`ok=1` 永远回不去，前端表现成「点了没反应」。改后台重启。
- **IPv6 的 DNS 封锁从未生效**（既有问题，这次一并修）：开机那一刻系统自己也在
  操作 xtables，模块的 `ip6tables -N dns_block` 抢不到锁直接失败，随后
  `-A OUTPUT -j dns_block` 报 `Couldn't find target dns_block`。`status` 仍显示
  「防火墙规则已加载」，所以一直没人发现。所有 `iptables` / `ip6tables` 调用
  现在都带 `-w 5`（等锁最多 5 秒），实机验证 `dns_block` 链能正常建立。
- **看门狗没有单实例保护**：连开两次 `command.sh watch` 就会有两个看门狗，
  各自判活、各自把内核「拉起来」，互相把对方启动的进程当成异常，结果是
  每 30 秒重启一次内核。现在启动时扫 `/proc` 比对 cmdline，已有在跑就直接退出
  （不用 pid 文件：`/dev` 是 tmpfs，重启即清、pid 还会被复用）。

### 升级须知（重要）

1. **会删除 `config/` 下的四张旧规则表**（约 5 MB）。这是设计如此：数据已在
   `rulesrc/seed/` 里，重复副本没有意义。
2. **回滚到 3.4.x 需要重新铺表**。3.4.x 的主配置直接引用
   `./block/defaults.conf` 这些文件，而 4.0 已经删掉了。回滚时要么用 3.4.x 的包
   重新刷入（`customize.sh` 不会重建已存在的 config），要么把
   `rulesrc/seed/*` 复制回 `config/` 对应位置。**升级前建议先用模块管理器
   「备份」，或在 TWRP / adb 里打包一份 `/data/adb/smartdns`**。
3. **第一次启动会自动迁移并重启一次内核**。开机瞬间 DNS 可能中断几秒，
   `boot.log` 里能看到「规则引用切换到 rules/index.conf」和清理记录。
4. 规则源默认全部指向 `seed/`，**离线可用**，不会因为没网就没有规则。
   `github520` 是唯一默认启用的在线源（6 小时刷新一次）。

## 3.4.4

这一版处理的是「从旧模块直接升级」留下的后遗症。模块目录本身不用管（Magisk
升级时整目录重建，实测五个程序文件 md5 与最新包一致），但数据目录
`/data/adb/smartdns` 是被完整继承的，2024 那版的目录名和脚本会一直跟着：

- **规则目录名对不上**：旧版用 `list_block / list_ip / list_location`，新版用
  `block / ip / domain_diverg`。升级后新目录从来不生成，用户的 `smartdns.conf`
  也还指着旧名字。现在安装时自动迁移（同名文件不覆盖，绝不删用户数据），
  并把配置里的 `./list_xxx/` 路径一起改写。
- **开机任务静默失效**：旧 `scripts/bootTask/crond.sh` 是"深度 1"，而
  `bootTask()` 用 `find -mindepth 2 -name boot.sh` 找任务 —— 旧脚本永远匹配不上，
  crond 从来没启动过，hosts 自动更新也就一直空转。现在安装时增量同步 scripts：
  旧结构的开机脚本改名为 `.legacy` 保留现场，新结构补进去；用户自己加的脚本不动。
- **卸载不彻底**：`uninstall.sh` 以前只删配置目录。现在会先停服务（否则内核
  进程一直占着 6053，重装第一次启动就 `bind failed, Address in use`）、解掉
  `/dev/smartdns` 下的 bind 挂载再删工作目录、清 `/data/local/tmp/smartdns`，
  并清理上游原版用架构命名的旧模块目录（`smartdns-aarch64` / `smartdns-arm`）。

## 3.4.3

实机（Android 13 / Magisk 31.1 / KsuWebUI）逐项验证后修的三个问题：

- **服务日志一直是空的**：只有 `log-file` 没有 `log-level` 时，内核按默认级别过滤，
  正常运行时一条日志都不产生，连日志文件都不会创建（文件是第一次要写日志时才打开的）。
  启动前自动补 `log-level info`，用户自己写过的级别不动；日志缺失提示里也补上了这条原因。
- **日志时间比手机慢 8 小时**：内核是静态链接的 musl 程序，镜像里没有 tzdata，
  只认 `CST-8` 这类 POSIX 时区串，`Asia/Shanghai` 会被当成无效值回落 UTC。
  启动前按设备当前时区换算成 POSIX 串传给内核，配置测试同样处理。
- **「关于」显示"配置备份 暂无"、还原备份报错**：只认 WebUI 保存生成的
  `.webui.bak`，不认模块自愈时留下的 `.bak`。现在两者都认。

## 3.4.2

3.4.1 开机日志里的一句话点破了问题：「修正配置落盘路径: cache-file」——只报了
`cache-file`，说明 `log-file` 的路径被判成了可写，可日志文件根本不存在。

1. **日志目录从 `/dev/smartdns/log` 搬到 `/data/adb/smartdns/log`**
   `/dev` 是内存文件系统，重启就清空；更要紧的是部分机型上内核进程所在的安全域
   写不进 `/dev` 下的普通目录，而 `[ -w ]` 在 shell 里测是测不出来的。
   结果就是配置里明明有 `log-file`，日志永远不生成 —— 而 `core.log` 也写不进去，
   内核的错误输出跟着一起丢，只剩一句「服务起没起来」。
   `/data/adb` 是模块自己的数据目录，一定写得进去，日志还能跨重启保留。
   启动时自动把老配置里的 `/dev` 路径改过来，原文件备份为 `smartdns.conf.bak`。

2. **新增「日志 → 内核输出」**
   `core.log`（内核的 stdout/stderr）以前没有任何入口可看，服务起不来时只能干瞪眼。
   现在日志页直接可读，包含端口冲突、配置解析失败这些原始报错。

3. **修「重启」假成功**：`restart` 原来取的是 `stop` 的退出码，而 `stop` 恒返回 0，
   于是 `start` 失败也会提示「重启完成」。现在按 `start` 的结果判定。

4. **回包长度收敛**：`ctl` 只带回尾部 20 行。某些管理器的 `exec` 对回包有长度限制，
   两层 base64 再放大 1.8 倍，长了就被截断——表现是按钮偶发「未知错误」。

5. 默认配置里的 `log-file` / `audit-file` 直接指向新目录，新装用户无需迁移。

## 3.4.1

修 3.4.0 实机日志里暴露的两类启动失败。它们的共同点是：界面上一切正常，
只有 `core.log` 里留一行，而且那一行还看不出是谁的问题。

1. **`bind service [::]:6053 failed, Address in use`**
   根因在停止流程：`kill -TERM` 发出去就返回了，紧接着的 `start` 去 bind
   同一个端口，撞上还没退干净的旧进程。开机时进程多、回收慢，所以只在
   开机那条路径上偶发。现在 `server_stop` 会等进程真的消失（超时再 `kill -9`），
   并等端口释放后才返回。

   另加一道保险：启动前查 `/proc/net/{udp,tcp}{,6}`，端口还被占就先找出占用者——
   是本模块残留的内核就清掉，是别的程序就**直接报出 pid 和进程名**，
   而不是把 `Address in use` 丢给用户自己猜。诊断信息里也多了端口占用一节。

2. **`create file /tmp/smartdns.cache failed, Permission denied`**
   从上游继承下来的老配置里没有 `cache-file` 这一行，内核于是用自己编译进去
   的默认值 `/tmp/smartdns.cache`；Android 的 `/tmp` 不可写（SELinux 拦 rootfs），
   于是运行中每半分钟往 `core.log` 刷一条错误。`log-file` / `audit-file` 同理，
   路径不可写就等于没有日志，日志页永远是空的。

   现在每次启动前做一次落盘路径体检：缺失就补上、不可写就改到模块工作目录
   （`/dev/smartdns/tmp`、`/dev/smartdns/log`），改动前备份为 `smartdns.conf.bak`，
   并在输出里说明改了哪几项。改完是幂等的，不会每次启动都动配置。

3. **"进程在，但 DNS 没在听"**：内核 bind 失败后不一定退出，进程活着、端口空着，
   看门狗会一直当它正常。现在看门狗额外确认端口确实在监听，连续 3 次确认
   没在听才重启（能读 `/proc/net` 的设备才做这项判断，避免误杀）。
   `server_start` 也会识别 `start dns server failed` 并清掉这个没用上的进程，
   不再报"启动成功"。

## 3.4.0

修 3.3.0 实测暴露的四个问题：按钮首次点击失败、配置测试读不出结果、日志页报
atob 异常、服务偶尔自己停。

1. **按钮第一次点必报错、第二次才正常**：某些时机下 `exec` 回包会是空串、
   或干脆是**上一次调用的输出**。现在每次调用都带一个唯一流水号，回包头部必须
   原样带回，对不上就自动重试（最多 3 次），用户不再需要点两遍。
   诊断页新增「自动重试」计数与最近失败原因。
2. **配置测试「进程退出码 undefined、（无输出）」**：真实原因是服务正在运行，
   后端拒绝测试，而前端把拒绝当成了测试结果。现在会先问一句、自动停服
   → 测试 → 自动重新启动；编辑器里有未保存内容时，**直接测编辑器里那一份**
   （不必先保存）；后端返回原因时完整展示，不再吞成「（无输出）」。
3. **服务日志 / 审计日志「读取失败」**：日志不存在时后端返回的是中文提示，
   前端却一律当 base64 交给 `atob`，于是真正的信息被
   `The string to be decoded contains characters outside of the Latin1 range` 盖住。
   现在非 base64 文本原样显示，并直接给出处理办法（`log-file` 怎么加、
   `audit-enable yes` 怎么开、脚本日志怎么打开）。另外顺手补建日志目录。
4. **服务偶尔自己停止，需要手动启动**：新增常驻看门狗。`service.sh` 开机后以
   `setsid` 拉起 `command.sh watch`，每 30 秒检查内核进程与防火墙规则，
   异常即自动拉起（首次检查在 20 秒后）；日志写 `boot.log` 并自动截断，
   WebUI / 命令行主动「停止」会写标记文件，看门狗不干预。
5. 作者改为 `ewgikeit`。

## 3.3.1

根证书库从 2024 年 1 月的旧快照刷新到 Mozilla 2026-11-05，并加入自动更新。

原 `binary/ca-certificates.zip` 来自上游 3.1.0 提交（2024-01-22），实际内容停在 2023-05：
137 个根证书里有 4 个已过期，同时缺少 26 个此后新增的根（SSL.com TLS ECC/RSA 2022、
Sectigo Public Server Authentication E46/R46、TrustAsia G3/G4、SECOM 2024、D-TRUST 2023、
Telekom Security TLS 2023、e-Szigno 2023、Telia EC/RSA v3 等）；另有一批早已被 Mozilla
停止信任的老根仍在被信任（Entrust 系列、Baltimore CyberTrust、AAA Certificate Services、
DigiCert Global Root CA 等）。

- 新增 `scripts/update-ca.sh`：下载 https://curl.se/ca/cacert.pem，按 CN 拆成单证书文件、
  重建 `CA/ca-certificates.crt` 合并包，校验证书数量/拆分/合并三处一致后才打包
- 新增 `.github/workflows/update-ca.yml`：每月 1 日自动刷新，有变化才提交并递增 `versionCode`
- 证书文件名做 ASCII 归一化（旧包中一个匈牙利语文件名会让 Windows 解压直接报错）
- 记录证书快照日期到 `binary/CA_VERSION`
- 新包 118 个根证书，0 个过期；实测 dns.alidns.com / 1.1.1.1:853 / doh.pub 校验链均通过

## 3.3.0

修「WebUI 能打开但读取失败、按钮报未知错误」，根因是**桥接只回传最后一行**。

实测 Magisk 31.1 的 `exec(cmd)` 同步返回，且**只返回 stdout 的最后一行**：
`webui.sh info` 的最后一行是 `ok=1`、`status` 的最后一行是 `script_conf=...`，
于是整张状态表只剩一个字段，解析必然失败，控制器也读不到 `rc`。

- 新增单行传输层：后端输出先 `base64 | tr -d '\n'` 压成一行再回传，前端解码还原
  （前缀魔数 `SDNS1` 校验完整性，退出码随载荷回传）
- 所有 `webui.sh` 调用（status / info / conf / ctl / tail / cat …）统一走该通道
- 返回值被截断时明确报「返回内容被截断」，不再静默成空输出
- 桥接诊断改为：多行回传测试（直接暴露是否被截断）+ info/status 字段数

## 3.2.9

修「诊断里把 Magisk 显示成 KernelSU / APatch」，以及同步返回型 `exec` 的兼容。

Magisk 也暴露 `window.ksu` 这个兼容对象，但它的 `exec(cmd)` 是**同步返回 stdout 的**，
既不是 KernelSU 的回调式，也不是 MMRL 的 Promise。3.2.8 按"存在 window.ksu"推断管理器，
标签就写错了；同时探测顺序让这类环境每次都要先白等两次回调超时。

改动：

- 管理器身份不再靠全局对象猜，改由 `webui.sh info` 的 `manager=` 给出：
  依次尝试 `magisk -v` / `ksud -V` / `apd -V`，显示真实管理器与版本（如 `Magisk 31.1`）
- 桥接探测改为**先试同步返回**（能立刻判断成败、不空等），再退两种回调形态；
  同步环境下页面加载 0 延迟，回调环境约 20ms
- 诊断面板字段改为「桥接对象 / 调用形态 / 管理器 / 模块目录」，
  调用形态明确区分 `同步返回` / `Promise 返回` / 两种回调
- `webui.sh` 调用统一加 `2>&1`：同步型 exec 会丢掉 stderr，失败时就成了
  "成功但空输出"；现在错误文本会并进 stdout 显示出来
- 后端无输出时直接报错，状态解析失败会把原始返回带进提示
- 「关于」页新增「模块管理器」一行
- 控制按钮执行期间显示"启动中…"并禁用，避免同步阻塞时重复点击

## 3.2.8

修「WebUI 能打开，但读不到状态，启动/停止/重启/清理全部报未知错误」。

根因在 `webroot/index.html` 的桥接层：KernelSU / APatch 的 `ksu.exec` 是**回调式**
（`exec(cmd, options, callback)`，无返回值），而页面写的是

```js
return Promise.resolve(ksu.exec(cmd)).then(norm);
```

回调式实现在这里立刻 resolve 成 `undefined`，`norm()` 把它当成「成功且输出为空」。
于是每个动作都"执行成功"，但 stdout 恒为空：状态页解析不出任何字段，
控制按钮拿到空输出后落到 `未知错误` 这个兜底分支。

改动：

- `ksu.exec` / `$mmrl.exec` 统一按回调 + Promise 双兼容封装，都能正确取到 errno/stdout/stderr
- 首次使用前用 `echo webui-probe-ok` 探测一次参数形态（`exec(cmd,cb)` / `exec(cmd,opts,cb)` / `exec(cmd)`），
  只做一次，之后按探测结果调用
- 每次 exec 带超时（默认 20s，控制类动作 90s），不再无限等待
- 状态读取失败改为把原因显示在状态卡上，并做去重，避免 5 秒轮询反复弹提示
- 按钮失败时区分「后端无返回」与「后端返回 rc≠0」，不再一律叫未知错误
- 「关于」页新增**桥接诊断**：显示运行环境、调用形态、模块目录、`id` 与 `webui.sh status` 的原始 errno/stdout/stderr
- 模块目录探测要求 `webui.sh` 与 `constant.sh` 同时存在，优先精确路径再退回通配

## 3.2.7

修「开机时 `start` 报成功，一两分钟后进程却没了」。

证据来自 3.2.6 的 `boot.log`：

```
===== Sun Nov  8 22:46:10 2026 boot =====
[信息]: 服务器 已经停止
[信息]: 服务器 成功启动
[boot] command.sh start -> rc=0
```

启动那一刻内核确实活着（3.2.6 的双采样 + `kill -0` 已排除残影误判），但要不了多久就消失。
差别在于启动方式：手动 `su` 里启动时父 shell 一直在，开机时父 shell（`service.sh`）启动完就退出。
进程与会话没有脱钩时，父 shell 退出/进程组被回收就会把它一起带走。

改动：

- **内核启动改为 `setsid` 自成会话**（缺 `setsid` 时退回 `nohup`，再退回裸启动），
  父 shell 死活与内核无关。这是本次的主修复。
- **`service.sh` 增加启动后 20 秒复检**：`start` 成功不代表 20 秒后还活着。
  复检失败会把 `core.log` 末尾和 `ps` 结果直接写进 `boot.log`，
  下次出问题不用再让用户手动复现。
- **修 `scripts/lib.sh` 的 `reload_config()`**：原来用裸 `$CORE_NAME status|start`，
  PATH 里命中的是 `/system/bin/smartdns` 转发脚本（`exec command.sh "$@"`），
  cron 重载 hosts 时行为不可控。改为走 `$MODDIR/command.sh` 绝对路径。

## 3.2.6

修「刷完模块后启动报 `[Error]: 找不到可执行的内核文件`」——模块装上了，但里面**没有内核**。

根因在发布包的打包规则：`build-release.yml` 里的 `zip -x '*.zip'` 本意是排除仓库根目录的
杂包，但 zip 的通配符**会跨目录匹配**，把 `binary/ca-certificates.zip`（证书库）一起排掉了。
装上后 `customize.sh` 解证书库失败 → `$MODPATH/binary` 目录根本没被创建 → 紧接着的
`cp 内核` 静默失败（没有校验），模块「安装成功」却只剩脚本、没有内核，启动必然报
「找不到可执行的内核文件」。

改动：

- **打包不再误伤证书库**：去掉 `-x '*.zip'`；冒烟校验从 6 项扩到 9 项，新增
  `binary/ca-certificates.zip`、`common/command.sh`、`config/smartdns.conf`，缺一个就构建失败。
- **`customize.sh` 显式 `mkdir -p $MODPATH/binary`**，不再依赖 `unzip -d` 顺带建目录；
  证书库缺失/解压失败只提示不中断（DoH/DoT 无 CA 时仍可跑）。
- **内核复制后强制校验**：`cp` 完检查文件非空，失败直接 `abort`，不再"装成功但没内核"。
- **`command.sh` 增加权限自愈**：内核文件在、但执行位丢了（重装/解压常见）时自动 `chmod 0755`
  重试，不误报"文件不存在"；判断挂载是否丢失改用「文件是否存在」而非「是否可执行」。
- **重挂载前先 `umount`**：挂载可能残留在已被替换的旧目录上，此时直接 `mount` 挂不上去。
- **失败时直接打印现场**：`core_ready` 失败会列出模块 binary 目录、工作目录内容、bind 挂载，
  一条命令就能定位，不必再让用户来回跑 diag。

## 3.2.5

修「重启后服务压根没起来」——开机后 `status` 直接返回 3（服务器未启动 + 规则未加载）。

根因在初始化流程：`command.sh` 首次运行要执行 `initTask()`，而它里面带着**等待联网**
——`ping dns.google` 失败就 `sleep 10` 重试，最多 60 次 = **10 分钟**。开机那一刻网络
通常还没就绪，于是 `service.sh` 里的 `sh command.sh start` 就卡在这个循环里，服务根本
没被启动，iptables 规则自然也没加载。等十分钟后它倒是会继续跑完，但用户早就以为模块坏了。

改动：

- **`initTask()` 只做必须立刻完成的事**：建工作目录、bind 挂载、备份防火墙规则（毫秒级），
  联网等待拆成独立的 `wait_network()`
- **新增 `command.sh boot` 子命令**：等联网 → 执行 hosts 更新等开机任务
- **`service.sh` 先启动服务，再把开机任务丢后台**（`sh command.sh boot &`），
  联网再慢也挡不住服务
- **`boot.log` 无条件落盘**：原来只有 `log='yes'` 才重定向，导致开机失败时连日志都
  不存在，一点线索都没有。开机路径没有控制台，必须写文件

## 3.2.4

修实机「服务起不来」，以及一个更坑人的「说启动成功但其实早就死了」。

内核日志里真正的报错是：

```
[ERROR][ server_socket.c:142 ] bind service 0.0.0.0:6053 failed, Address in use
```

配置里同时写了 `bind [::]:6053` 和 `bind 0.0.0.0:6053`。Android 的 IPv6 默认双栈
（`bindv6only=0`），`[::]` 已经把 IPv4 一起占了，再 bind `0.0.0.0` 就是自己跟自己
抢端口。模块出厂配置只写 `bind [::]:6053`，就是为了避开这个坑。

跟着这个报错还牵出模块自身的一个 bug，这才是「启动成功却连不上」的元凶：

- **`server_start()` 误报成功**：内核 bind 失败后是「起来即退出」，而启动检测只
  轮询一次 `pidof`，正好抓到那个还没退干净的进程残影，于是打印「服务器 成功启动」。
  实际服务已经死了，用户看到的是"成功"却上不了网。
  现在改为**两次采样 + `kill -0` 存活确认**（间隔 1 秒），并且内核打印完日志就退出
  的极快失败场景会在 1 秒内直接报错，不再空等 15 秒。
- **启动失败给出针对性提示**：日志里出现 `Address in use` 时，除了 tail 内核输出，
  还会直接说明「同一端口同时 bind 了 `[::]` 与 `0.0.0.0`」这个最常见原因和改法，
  并提示用 `netstat -lntup | grep <端口>` 排查其它占用者。
- **WebUI 保存配置时拦掉同类错误**：`do_put` 在写入前检查同一端口（分 udp/tcp 两套
  命名空间）是否同时被 `[::]` 和 `0.0.0.0` bind，命中则拒绝写入并说明原因。
- **`diag` 不再被日志吞掉**：`log='yes'` 时脚本会把 stdout/stderr 全部重定向进
  `script.log`，`diag` 在终端上表现为「敲完什么都没发生」。现在 `diag` 在重定向之前
  处理，一定输出到终端；内容里补了 `log` 开关状态、模块目录列表、`script.log` 末尾。
- **不再静默退出**：模块目录无法进入、`constant.sh` / `defaults.sh` /
  `script_conf.sh` 缺失时，打印明确错误并指出缺哪个文件，而不是无声 `exit 1`。

如果你之前手改过配置，请检查 `/data/adb/smartdns/config/smartdns.conf` 里有没有
重复绑定的端口，删掉 `bind 0.0.0.0:<端口>` 那一行即可。

## 3.2.3

修实机报的这个问题：`smartdns start` 输出「无效的参数: -c」+ 打印帮助 + 启动失败。

根因是**找内核的方式不可靠**：`server_start()` 用 `PATH="$CORE_DIR:$PATH"` 再执行
裸命令 `smartdns`。工作目录 `/dev/smartdns/binary` 是 bind 挂载，一旦挂载丢失或
里面的 `smartdns` 缺失，PATH 查找就会命中 `/system/bin/smartdns`——那是安装时
生成的转发脚本（`exec command.sh "$@"`）。于是 `smartdns -c 配置 -p pid`
变成了 `command.sh -c 配置 -p pid`，自然报「无效的参数: -c」。

改动：

- **内核改用绝对路径调用**，不再依赖 PATH；按 工作目录 → 模块目录 → `binary/arm64`
  或 `binary/arm`（按 `uname -m` 判断）依次兜底，缺 `smartdns` 时自动复制补上，
  保证进程名仍是 `smartdns`（否则 `pidof` 找不到，状态会一直显示已停止）
- **挂载丢失自动补挂**：新增 `mount_workdir()`，与 `initTask()` 的联网等待解耦，
  可以随时快速补挂；自动初始化的判断也从"目录是否存在"改为"内核与配置是否可见"
- **启动失败时打印内核输出**：内核 stdout/stderr 写入 `log/core.log`，失败时
  直接 tail 出来，不用再猜是配置错了还是架构不对
- **新增 `smartdns diag`**：一次输出路径、挂载、文件权限、内核自检、pid、
  防火墙规则和当前设置，排查启动问题不用再手敲一堆命令
- 内核参数（`-c` / `-p` / `-v` 等）被误传给本脚本时给出针对性提示

## 3.2.2

继续修实机启动链路上的问题（均为容器脚本层面，与 3.2.1 同一个故障现象）：

- **`service.sh` / `uninstall.sh` 取模块目录的方式不可靠**：原来用 `${0%/*}`，
  当管理器以相对文件名（`sh service.sh`）调用时解析不出目录，`cd` 失败会让
  开机自启静默失效。改为 `case` 判断：带路径则 `cd` 到其目录，否则用当前工作目录。
- **`customize.sh` 的 `realpath /etc`** 在缺该命令时会得到空值，导致安装被误判为
  "文件结构未适配"而中止。改为 `realpath` → `readlink -f` → `/etc` 三级兜底。
- `service.sh` 的日志清理改用 `rm -f`，首次开机时不再往 boot.log 里写无谓报错。

## 3.2.1

修复实机上报的两个致命问题（继承自上游，会导致模块完全无法启动）：

- **端口校验用了 POSIX ERE 不支持的语法**：`port_valid()` 里 `grep -E '^(?:[1-9]\d{0,3}|...)$'`
  中的非捕获组 `(?:...)` 和 `\d` 在 Android 的 toybox / busybox grep 上直接报
  `repetition-operator operand invalid`，任何端口都判为非法，于是 `main()` 第一条
  就 `exit 1`，`status` / `start` / `stop` 全部失效。改为纯 shell 实现（字符类匹配 +
  去前导零后数值比较），不再依赖 grep 的扩展语法。
- **依赖 pgrep**：部分机型 toybox 未编译 pgrep，`pgrep smartdns` 报 command not found，
  导致状态永远显示"已停止"、停止操作无效。新增 `core_pids()`：优先 `pidof`，
  退回 `pgrep`，最后解析 `ps` 兜底。
- 端口非法时的报错改为输出当前值并指出 `script_conf.sh` 路径，便于定位

## 3.2.0

- **内核更新**：smartdns 升级至上游 Release 48.4（`1.2026.08.05-0921`），arm / arm64 静态二进制同步替换
- **新增 WebUI 图形化配置**（`webroot/index.html` + `webui.sh`）：
  - 状态面板：运行状态、PID、模式、端口、iptables 规则、内核版本，一键启动 / 停止 / 重启 / 清理
  - 运行参数：端口、工作模式、放行网卡、放行应用、IPv6 封锁、日志开关、语言
  - DNS 配置：在线编辑 `smartdns.conf`，自动备份、配置测试、还原、恢复出厂
  - 日志：服务 / 审计 / 脚本 / 开机日志查看，支持自动刷新
  - 关于：版本信息与一键检查上游内核新版本
- 安装脚本适配 KernelSU / MMRL：解压 `webroot` 与出厂配置模板并设置权限
- 新增 `webui.sh` 后端，带路径白名单与参数校验，避免前端直接拼接 root 命令
- 新增 GitHub Actions：每周检查上游内核更新；打 tag 时自动打包并发布 Release
- `updateinfo.json` 改用 `releases/latest/download` 固定地址，发版无需再改文件

## 22.10.25

- 改变了 MODE 的模式参数，避免让人疑惑。详见 README.md
- 改进任务脚本
- 更新默认配置
- 改用日期版本号

## 3.0.0

- 移除不必要的修改数值命令
- 添加任务脚本，定时更新[GitHub hosts](https://github.com/521xueweihan/GitHub520)
- 大幅改动，优化可读性，多语言支持
- 优化默认配置
- versionCode 重置为 1

## β 3.1.0

## 目前发布的模块均*未经测试*。没有精力去确保更新质量，介意误用

- 移除 x86、x64 架构包，精简体积。
- 尝试添加定时任务系统。
- 移除参数 `ServerUID` 。smartdns已支持设定自身用户权限
- 更新默认配置
- smartdns 版本更新至Release 43
