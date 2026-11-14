#!/system/bin/sh
### Program ###
readonly CORE_NAME="smartdns"

# PATH
#存储位置
readonly DATA_BASE="/data/adb/$CORE_NAME"
readonly CORE_INTERNAL_DIR="$MODDIR/binary"
readonly DATA_INTERNAL_DIR="$DATA_BASE/config"
readonly SCRIPT_INTERNAL_DIR="$DATA_BASE/scripts"

#自启动日志
BOOT_LOG="$MODDIR/boot.log"
#脚本运行日志
RUN_LOG="$MODDIR/script.log"

#脚本配置
readonly SCRIPT_CONF="$DATA_INTERNAL_DIR/script_conf.sh"

# 手动停止标记
# 看门狗（command.sh watch）会每隔一段时间确认内核还在跑，掉了就拉起来。
# 用户从 WebUI / 命令行主动"停止"时写这个标记，看门狗看到就让开，不跟用户抢；
# 下次 start 时删除。
readonly STOP_FLAG="$DATA_INTERNAL_DIR/.stopped"


#工作目录
# /dev/$CORE_NAME
# ├─ /binary 程序
# ├─ /config 配置
# └─ /tmp 暂存
readonly WORK_DIR="/dev/$CORE_NAME"
readonly CORE_DIR="$WORK_DIR/binary"
readonly DATA_DIR="$WORK_DIR/config"
TEMP_DIR="$WORK_DIR/tmp"

# 日志目录：放在 /data 下，不放 /dev。
# 原来用 $WORK_DIR/log（/dev 是 tmpfs），有两个实机问题：
#   1. 重启即清空，出问题后想回看「上次开机发生了什么」永远没有；
#   2. 部分机型上 magisk 域对 /dev 下的普通目录没有写权限（SELinux），
#      表现是配置里明明有 log-file，日志文件却永远不生成 —— 而 core.log
#      也写不进去，于是内核的错误输出也一起丢了，只剩「服务起没起来」。
# /data/adb 是模块自己的数据目录，root 一定写得进去，日志还能跨重启保留。
LOG_DIR="$DATA_BASE/log"

# 规则源管理器路径
# 以前规则表（block / ip / domain_diverg）是随包下发的静态快照，写死在
# smartdns.conf 里，想更新只能等模块发版。现在拆成两层：
#   rulesrc/ —— 规则从哪来（源清单、本地 hosts、下载缓存、每个源的状态）
#   config/rules/ —— 最终给内核看的 .conf（生成物，别手改）
# 这样"更新规则"和"发版"解耦，源可以按各自间隔自动刷新。
readonly RULESRC_DIR="$DATA_BASE/rulesrc"
readonly RULES_CACHE="$RULESRC_DIR/cache"
readonly RULES_STATE="$RULESRC_DIR/state"
readonly RULES_SEED="$RULESRC_DIR/seed"
readonly RULES_SOURCES="$RULESRC_DIR/sources.conf"
readonly RULES_LOCAL_HOSTS="$RULESRC_DIR/local.hosts"
readonly RULES_OUT="$DATA_INTERNAL_DIR/rules"

# 建立工作目录的 bind 挂载
# 单独抽出来是为了能在不触发"联网等待"的前提下重复执行——挂载可能丢失
# （模块更新后未重启、上电顺序、SELinux 拒绝），丢了就会找不到内核。
mount_workdir() {
	mkdir -p "$CORE_DIR" "$DATA_DIR" "$LOG_DIR" "$TEMP_DIR" 2>/dev/null
	mount -o bind "$CORE_INTERNAL_DIR" "$CORE_DIR" 2>/dev/null
	mount -o bind "$DATA_INTERNAL_DIR" "$DATA_DIR" 2>/dev/null
	return 0
}

# 初始化
# 只做必须立刻完成的事：建工作目录、挂载、备份防火墙规则。
# 原本这里还带着"等待联网 + 执行开机任务"，会 ping dns.google 最多 60 次 × 10 秒
# = 10 分钟。开机那一刻网络往往还没就绪，于是 service.sh 里的 start 被卡住，
# 表现就是"开机后服务一直没起来、防火墙规则也没加载"（status 返回 3）。
# 联网相关的活全部挪到 boot 子命令里，由 service.sh 在服务启动之后放后台跑。
initTask() {
	# 创建工作环境
	mount_workdir
	# 保存防火墙初始设置。只落干净快照：initTask 可能被重复执行（模块更新、
	# 手动调用），那时模块规则已经在表里，直接 save 会把"重定向到死端口"
	# 存成"初始状态"，之后 clean 会把它原样恢复。
	ipt_snapshot "$IPT_BAK" iptables-save
	ipt_snapshot "$IP6T_BAK" ip6tables-save
	chmod 0640 $TEMP_DIR/*.bak 2>/dev/null
	return 0
}

# 等待网络就绪（最长 10 分钟）。只在后台的开机任务里用，不阻塞服务启动。
wait_network() {
	local count='0'
	while true; do
		ping -c 1 dns.google >/dev/null 2>&1
		if [ "$?" == '0' ]; then
			return 0
		elif [ ${count} -ge 60 ] ; then
			return 1
		fi
		sleep 10
		count=$((${count} + 1))
	done
}

# 开机任务
bootTask() {
	local lists file
	# crond 链路删除后 bootTask 目录可能不存在（git 不跟踪空目录）
	[ -d "$SCRIPT_INTERNAL_DIR/bootTask" ] || return 0
	lists=`find $SCRIPT_INTERNAL_DIR/bootTask -mindepth 2 -name 'boot.sh'`
	if [ -n "$lists" ]; then
		for file in $lists; do
			sh $file
			sleep 5
		done
	fi
}

#防火墙备份
readonly IPT_BAK="$TEMP_DIR/iptables_rules.bak"
readonly IP6T_BAK="$TEMP_DIR/ip6tables_rules.bak"

# 看门狗单实例锁。mkdir 是原子的：两个同时启动只有一个能建成。
# 必须放 tmpfs（$WORK_DIR）而不是 $DATA_BASE —— 锁里只有 pid，断电或
# kill -9 留下的陈旧锁会跨开机存活；pid 是顺序分配的，很可能被别的进程
# 复用，新看门狗就会误判「已有实例」而静默退出（复审 R1，真机可用 pid=1
# 稳定复现）。/dev 重启即空，从根上消除跨开机残留。
readonly WATCH_LOCK="$WORK_DIR/.watch.lock"

# 只有「干净」的快照才落盘：里面出现模块自建链或 --to-ports，说明抓快照时
# 服务正在跑；这种备份在 clean 时会把「重定向到死端口」原样恢复回去，比不还原
# 更糟。遇到脏快照就丢掉临时文件、保留旧备份（旧备份也可能本来就不存在 ——
# 那就宁可不备份，clean 只清自建链）。
ipt_snapshot() {
	local f="$1" cmd="$2" tmp="$1.tmp"
	$cmd > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	if [ -s "$tmp" ] && ! grep -qE 'dns_(redirect|block|proxy)|--to-ports' "$tmp" 2>/dev/null; then
		mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
	else
		rm -f "$tmp"
	fi
	return 0
}

# 备份能不能用来还原：缺失 / 空 / 含模块规则 都不行
ipt_bak_usable() {
	[ -s "$IPT_BAK" ] && [ -s "$IP6T_BAK" ] || return 1
	! grep -qE 'dns_(redirect|block|proxy)|--to-ports' "$IPT_BAK" "$IP6T_BAK" 2>/dev/null
}

#程序PID
readonly PID_FILE="$TEMP_DIR/server.pid"

### 启动参数 ###
# 注意：CORE_BOOT 不再在这里写死。
# 旧写法用裸命令名 `smartdns`，依赖 PATH 找到真正的内核；一旦工作目录的
# bind 挂载丢失，就会命中 /system/bin/smartdns（安装时生成的 command.sh
# 转发脚本），把 `smartdns -c xxx -p yyy` 变成 `command.sh -c xxx`。
# 现在由 command.sh 的 ensure_workdir 解析出绝对路径后再拼装。

### 时区 ###
# 内核是静态链接的 musl 程序，镜像里没有 tzdata：
#   - TZ=Asia/Shanghai 认不出来（回落 UTC）
#   - TZ=CST-8 这种 POSIX 写法才认
# 不处理的话日志时间是 UTC，比手机上的时间差 8 小时，排查时完全对不上。
# 这里按设备当前时区换算出 POSIX 串，供内核启动前 export。
core_tz() {
	local z sign hh mm
	z=$(date +%z 2>/dev/null)
	case "$z" in
		[+-][0-9][0-9][0-9][0-9]) ;;
		*) return 1 ;;
	esac
	sign=$(printf '%s' "$z" | cut -c1)
	hh=$(printf '%s' "$z" | cut -c2-3)
	mm=$(printf '%s' "$z" | cut -c4-5)
	# POSIX 的符号是反的：UTC+8 写作 XXX-8
	[ "$sign" = '+' ] && sign='-' || sign='+'
	if [ "$mm" = '00' ]; then
		printf 'LOC%s%d\n' "$sign" "$(expr "$hh" + 0)"
	else
		printf 'LOC%s%d:%s\n' "$sign" "$(expr "$hh" + 0)" "$mm"
	fi
	return 0
}
