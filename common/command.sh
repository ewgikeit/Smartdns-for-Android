#!/system/bin/sh
# 获取真实路径
# realpath 在部分老设备上不存在，缺失时 MODDIR 会为空导致全盘失效，故加兜底
MODDIR=''
if command -v realpath >/dev/null 2>&1; then
	MODDIR=$(realpath "$0" 2>/dev/null)
	if [ -n "$MODDIR" ]; then
		MODDIR=${MODDIR%/*}
	else
		MODDIR=''
	fi
fi
if [ -z "$MODDIR" ]; then
	case "$0" in
		*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
		*) MODDIR=$(pwd) ;;
	esac
fi
# 不要静默退出：目录/文件缺失时必须把原因打出来。
# 静默 exit 1 的表现就是「敲完命令什么都没发生」，最难排查。
if [ -z "$MODDIR" ] || ! cd "$MODDIR" 2>/dev/null; then
	echo "[Error]: 无法定位模块目录（\$0=$0），请确认模块已正确安装。"
	exit 1
fi
# 加载参数
for _f in constant.sh defaults.sh rules.sh; do
	if [ ! -f "$MODDIR/$_f" ]; then
		echo "[Error]: 模块文件缺失: $MODDIR/$_f"
		echo "        模块可能安装不完整，请重新刷入。"
		exit 1
	fi
done
. $MODDIR/constant.sh
. $MODDIR/defaults.sh
# 规则源管理器（只定义函数，source 本身没有副作用）
. $MODDIR/rules.sh
# 用户设置
if [ -f "$SCRIPT_CONF" ]; then
	. $SCRIPT_CONF
else
	echo "[Error]: 配置文件缺失: $SCRIPT_CONF"
	echo "        可重新刷入模块，或执行: cp $MODDIR/defaults.sh $SCRIPT_CONF"
	exit 1
fi
# 加载语言
if [ -f $MODDIR/translations/$language.sh ]; then
	. $MODDIR/translations/$language.sh
else
	. $MODDIR/translations/en.sh
fi
# 自动初始化
# 不能只看目录是否存在：模块更新后未重启时 /dev/smartdns 还在，但里面已经
# 看不到内核与配置文件了，会导致后面找不到内核。
# 判断依据用「文件是否存在」而不是「是否可执行」——执行权限由 ensure_workdir
# 单独修复，两者混在一起会把"权限丢了"误判成"挂载丢了"。
if [ ! -d "$WORK_DIR" ]; then
	initTask       # 首次：建目录 + bind 挂载 + 备份防火墙规则
elif [ ! -f "$CORE_DIR/$CORE_NAME" ] || [ ! -f "$DATA_DIR/smartdns.conf" ]; then
	mount_workdir  # 仅挂载丢失：快速补挂，不等联网
fi


### 加载函数 ###

# 文件存在但没有执行权限时补回 0755
_perm_fix() {
	[ -f "$1" ] || return 1
	[ -x "$1" ] && return 0
	chmod 0755 "$1" 2>/dev/null
	[ -x "$1" ]
}

# 工作目录自检
# 工作目录 /dev/smartdns 靠 initTask 里的 bind 挂载把「模块目录」和「配置目录」
# 映射进来。挂载有可能丢失（更新模块后未重启、上电顺序、SELinux 拒绝等），
# 此时 $CORE_DIR 会是空目录。
# 旧实现靠 PATH="$CORE_DIR:$PATH" 去找 smartdns，一旦目录空了就会命中
# /system/bin/smartdns（customize.sh 安装时生成的转发脚本），
# 于是 `smartdns -c ... -p ...` 被当成 `command.sh -c ... -p ...`，
# 表现为「无效的参数: -c」+ 打印帮助 + 启动失败。
# 这里改成显式解析内核与配置的绝对路径，顺带自动补挂载。
ensure_workdir() {
	# 1) 先把「文件在、权限丢」的情况自愈掉：模块重装/解压/跨文件系统复制后
	#    执行位丢失很常见，不应该因此报「内核文件不存在」。
	_perm_fix "$CORE_DIR/$CORE_NAME"
	_perm_fix "$CORE_INTERNAL_DIR/$CORE_NAME"

	# 2) 文件真的看不到时才重挂。重挂前先摘掉——
	#    挂载有可能残留在「已经不存在/被替换」的旧目录上，此时直接 mount 会
	#    挂不上去，表现为工作目录一直是空的。
	if [ ! -f "$CORE_DIR/$CORE_NAME" ] || [ ! -f "$DATA_DIR/smartdns.conf" ]; then
		umount "$CORE_DIR" 2>/dev/null
		umount "$DATA_DIR" 2>/dev/null
		mount_workdir
		_perm_fix "$CORE_DIR/$CORE_NAME"
	fi

	# 内核可执行文件：工作目录 → 模块目录 → 按 CPU 架构取原始二进制
	CORE_EXE=''
	if [ -x "$CORE_DIR/$CORE_NAME" ]; then
		CORE_EXE="$CORE_DIR/$CORE_NAME"
	elif [ -x "$CORE_INTERNAL_DIR/$CORE_NAME" ]; then
		CORE_EXE="$CORE_INTERNAL_DIR/$CORE_NAME"
	else
		# 安装时没复制成 smartdns 的兜底：用 binary/arm64 或 binary/arm。
		# 必须以 smartdns 这个名字存在，否则 /proc 里的进程名会变成 arm64，
		# pidof/pgrep 找不到，状态会一直显示"已停止"。
		local arch_bin='' tgt
		case "$(uname -m 2>/dev/null)" in
			aarch64|arm64) arch_bin="$CORE_INTERNAL_DIR/arm64" ;;
			armv8l|armv7*|arm) arch_bin="$CORE_INTERNAL_DIR/arm" ;;
		esac
		if [ -n "$arch_bin" ] && [ -f "$arch_bin" ]; then
			for tgt in "$CORE_INTERNAL_DIR/$CORE_NAME" "$TEMP_DIR/$CORE_NAME"; do
				if cp -f "$arch_bin" "$tgt" 2>/dev/null && [ -s "$tgt" ]; then
					chmod 0755 "$tgt" 2>/dev/null
					CORE_EXE="$tgt"
					break
				fi
			done
		fi
	fi

	# 配置文件：工作目录优先，退化到配置目录本身
	CONF_FILE="$DATA_DIR/smartdns.conf"
	[ -f "$CONF_FILE" ] || CONF_FILE="$DATA_INTERNAL_DIR/smartdns.conf"
	return 0
}

# 需要内核的操作用它兜底，避免出现"什么都没找到还去执行"的情况
core_ready() {
	[ -n "$CORE_EXE" ] && return 0
	echo "[Error]: 找不到可执行的内核文件，模块可能安装不完整。"
	echo "  期望位置: $CORE_DIR/$CORE_NAME"
	echo "  备用位置: $CORE_INTERNAL_DIR/$CORE_NAME"
	echo '  ---- 现场 ----'
	echo "  [$CORE_INTERNAL_DIR]"; ls -l "$CORE_INTERNAL_DIR" 2>&1 | head -n 6
	echo "  [$CORE_DIR]"; ls -l "$CORE_DIR" 2>&1 | head -n 6
	echo '  ---- 挂载 ----'
	mount 2>/dev/null | grep -F "$WORK_DIR" || echo "  （$WORK_DIR 下没有 bind 挂载）"
	echo "  请重新刷入模块；或执行 sh $MODDIR/command.sh diag 查看详情。"
	exit 1
}

# 诊断信息：启动失败时一条命令把环境全打出来
diag_info() {
	echo '===== 路径 ====='
	echo "MODDIR           : $MODDIR"
	echo "WORK_DIR         : $WORK_DIR"
	echo "CORE_INTERNAL_DIR: $CORE_INTERNAL_DIR"
	echo "CORE_DIR         : $CORE_DIR"
	echo "CORE_EXE         : ${CORE_EXE:-（未找到）}"
	echo "CONF_FILE        : ${CONF_FILE:-（未解析）} $([ -f "$CONF_FILE" ] && echo '[存在]' || echo '[缺失]')"
	echo "PID_FILE         : $PID_FILE"
	echo "SCRIPT_CONF      : $SCRIPT_CONF $([ -f "$SCRIPT_CONF" ] && echo '[存在]' || echo '[缺失]')"
	echo "arch             : $(uname -m 2>/dev/null)"
	echo "log              : ${log:-未设置}（RUN_LOG=$RUN_LOG）"
	echo "module.prop      : $(grep '^version=' "$MODDIR/module.prop" 2>/dev/null)"

	echo '===== 工作目录挂载 ====='
	mount 2>/dev/null | grep -F "$WORK_DIR" || echo "（缺失：$WORK_DIR 下没有 bind 挂载）"

	echo '===== 模块内二进制 ====='
	ls -l "$CORE_INTERNAL_DIR" 2>&1 | head -n 10

	echo '===== 工作目录内容 ====='
	ls -l "$CORE_DIR" 2>&1 | head -n 10

	echo '===== 模块目录 ====='
	ls -l "$MODDIR" 2>&1 | head -n 12

	echo '===== 内核自检 ====='
	if [ -n "$CORE_EXE" ]; then
		"$CORE_EXE" -v 2>&1 | head -n 3
	else
		echo '内核文件缺失或不可执行'
	fi

	echo '===== 运行状态 ====='
	echo "PID: $(core_pids | tr '\n' ' ')"

	echo '===== 防火墙 ====='
	local rules
	rules=$(iptables -w 5 -t nat -S 2>/dev/null | grep -F dns_redirect | head -n 5)
	if [ -n "$rules" ]; then
		echo "$rules"
	else
		echo '（无 dns_redirect 链）'
	fi
	if [ "$IP6T_BLOCK" == 'yes' ]; then
		rules=$(ip6tables -w 5 -t filter -S 2>/dev/null | grep -F dns_block | head -n 5)
		if [ -n "$rules" ]; then
			echo "$rules"
		else
			echo '（无 dns_block 链）'
		fi
	fi
	# 审查 C6 的现场判据：链里放行了 uid 0，而 Android 的 netd 正是 uid 0。
	# 这意味着「本机模式」拦不到系统解析（普通应用都走 netd），REDIRECT 计数
	# 会一直是 0。真机实测结论，见 changelog 4.2.2「已知限制」。
	case "$MODE" in
		*local*)
			if iptables -w 5 -t nat -S dns_redirect 2>/dev/null | grep -q -- '--uid-owner 0 '; then
				echo '本机模式拦截: 未生效（链中放行 uid 0 = netd，系统解析不会被重定向）'
				echo '              要拦截请把系统 DNS / 私人DNS 指向 127.0.0.1:'"$Main_PORT"
			else
				echo '本机模式拦截: 已生效（按目的地放行内核上游，netd 的查询会被重定向）'
				echo "              放行的上游: $(core_upstream_ips 2>/dev/null | tr '\n' ' ')"
			fi
			;;
	esac

	echo '===== 当前设置 ====='
	echo "Main_PORT=$Main_PORT Second_PORT=$Second_PORT MODE=$MODE TUN=$TUN WLAN=$WLAN DATA=$DATA log=$log"

	# 这两个是 core.log 里最难对上号的错误来源，直接列出来
	echo '===== 端口与落盘路径 ====='
	local p k v
	if proc_net_ok; then
		for p in $Main_PORT $Second_PORT; do
			[ -n "$p" ] || continue
			if port_busy "$p"; then
				echo "端口 $p: 被占用 -> $(port_owner "$p" 2>/dev/null | head -n 1)"
			else
				echo "端口 $p: 空闲"
			fi
		done
	else
		echo '（/proc/net 不可读，无法判断端口占用）'
	fi
	for k in cache-file log-file audit-file; do
		v=$(conf_get "$k")
		if [ -z "$v" ]; then
			echo "$k: （配置里没有，内核会用内置默认值）"
		elif path_writable "$v"; then
			echo "$k: $v [可写]"
		else
			echo "$k: $v [不可写]"
		fi
	done

	echo '===== 脚本日志（末尾 15 行） ====='
	if [ -f "$RUN_LOG" ]; then
		tail -n 15 "$RUN_LOG" 2>&1
	else
		echo "（无 $RUN_LOG）"
	fi
}

# 查找内核进程 PID
# 不能直接依赖 pgrep：部分机型的 toybox 没有编译进 pgrep，
# 会 command not found，导致状态永远显示"已停止"、停止操作失效。
# 优先用 pidof（Android 各版本都有），退回 pgrep，最后兜底解析 ps。
core_pids() {
	if command -v pidof >/dev/null 2>&1; then
		pidof "$CORE_NAME" 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
	elif command -v pgrep >/dev/null 2>&1; then
		pgrep "$CORE_NAME" 2>/dev/null
	else
		ps -A -o PID,ARGS 2>/dev/null \
			| awk -v n="$CORE_NAME" 'NR > 1 && $2 ~ ("(^|/)" n "$") {print $1}'
	fi
}

## 启动前体检：端口与配置落盘路径
# 这两类故障在界面上完全看不出来，只在 core.log 里留一行：
#   1. bind service [::]:6053 failed, Address in use
#   2. create file /tmp/smartdns.cache failed, Permission denied

# 端口在 /proc/net/{udp,tcp}{,6} 里写成 4 位大写十六进制
port_hex() {
	printf '%04X' "$1" 2>/dev/null
}

# 本机能不能读端口表。读不到时端口类判断一律当作"未知"，
# 不能把"看不到"当成"没在监听"——那会让看门狗误杀正常进程。
proc_net_ok() {
	local P="${PROC_ROOT:-/proc}"
	[ -r "$P/net/udp" ] || [ -r "$P/net/udp6" ] || [ -r "$P/net/tcp" ]
}

# 端口上是否已经有 socket（返回 0 = 被占）
#
# TCP 的 TIME_WAIT（状态列 06）不算占用：smartdns 每次 stop 都主动断开，
# 重启时上一轮的连接几乎必然还停在 TIME_WAIT，而 bind 在 SO_REUSEADDR 下
# 可以直接复用。把它算成占用会让 wait_port_free 白等 15 轮，再进
# free_port_for_start 去 kill 一个根本不存在的占用者，最后报「端口仍被占用」。
# 其余状态（LISTEN/ESTABLISHED/CLOSE_WAIT…）都真实持有本地端口，仍然算占用。
# UDP 没有 TIME_WAIT，只要有同端口条目就算占用。
port_busy() {
	local hp f tw P
	P="${PROC_ROOT:-/proc}"
	hp=$(port_hex "$1") || return 1
	[ -n "$hp" ] || return 1
	for f in "$P/net/udp" "$P/net/udp6" "$P/net/tcp" "$P/net/tcp6"; do
		[ -r "$f" ] || continue
		tw=0
		case "$f" in */tcp*) tw=1 ;; esac
		awk -v p=":$hp" -v tw="$tw" '
			NR > 1 && substr($2, length($2) - length(p) + 1) == p {
				if (tw && $4 == "06") next
				hit = 1; exit
			}
			END { exit !hit }
		' "$f" && return 0
	done
	return 1
}

# 从 ss 的输出里找 socket inode 的属主（快路径）。
# ss 一次就能列出全机 socket 并直接给 pid，比遍历 /proc 快两个数量级。
# toybox 的 ss 不一定编译了 -p / ino，拿不到 pid= 就老实返回失败，
# 交给下面的 /proc 兜底——绝不因为快路径失败就报「无人占用」。
port_owner_ss() {
	local i dump out pid P
	P="${PROC_ROOT:-/proc}"
	command -v ss >/dev/null 2>&1 || return 1
	dump=$(ss -a -n -p 2>/dev/null) || return 1
	[ -n "$dump" ] || return 1
	for i in "$@"; do
		out=$(printf '%s\n' "$dump" | grep -F "ino:$i" | head -n 1)
		[ -n "$out" ] || continue
		pid=$(printf '%s\n' "$out" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)
		[ -n "$pid" ] || continue
		printf '%s %s %s\n' "$pid" \
			"$(cat "$P/$pid/comm" 2>/dev/null)" \
			"$(readlink "$P/$pid/exe" 2>/dev/null)"
		return 0
	done
	return 1
}

# /proc 兜底路径：一次 ls 取回全机 fd 的符号链接，再用一次 awk 匹配 inode。
# 原实现对每个 fd 单独 readlink（几千进程 × 几十 fd = 上万个 fork），
# 真机实测 >90s，而调用方（启动体检、diag、看门狗）没有任何超时保护。
# 这里把 fork 次数降到 2 次；ls 再套一层 timeout，防止个别 fd 目录卡住。
port_owner_proc() {
	local inodes="$1" lscmd P
	P="${PROC_ROOT:-/proc}"
	lscmd="ls -l $P/[0-9]*/fd"
	if command -v timeout >/dev/null 2>&1; then
		lscmd="timeout 8 $lscmd"
	fi
	# 不加引号：要让 $lscmd 拆成命令+参数，并让 [0-9]* 正常展开
	# shellcheck disable=SC2086
	$lscmd 2>/dev/null | awk -v want="$inodes" -v root="$P" '
		BEGIN {
			n = split(want, a, " ")
			for (i = 1; i <= n; i++) if (a[i] != "") W[a[i]] = 1
		}
		# ls 多目录时的分组头：<PROC_ROOT>/<pid>/fd:
		substr($0, 1, length(root) + 1) == root "/" && substr($0, length($0) - 3) == "/fd:" {
			pid = substr($0, length(root) + 2, length($0) - length(root) - 5)
			next
		}
		{
			k = index($0, "socket:[")
			if (k == 0 || pid == "") next
			ino = substr($0, k + 8)
			gsub(/[^0-9].*/, "", ino)
			if (ino == "" || !(ino in W)) next
			print pid, ino
			exit
		}'
}

# 找出谁占着端口，打印 "pid comm exe"（只取第一个）
port_owner() {
	local hp f inodes='' hit pid P
	P="${PROC_ROOT:-/proc}"
	hp=$(port_hex "$1") || return 1
	for f in "$P/net/udp" "$P/net/udp6" "$P/net/tcp" "$P/net/tcp6"; do
		[ -r "$f" ] || continue
		inodes="$inodes $(awk -v p=":$hp" '
			NR > 1 && substr($2, length($2) - length(p) + 1) == p { print $10 }
		' "$f" 2>/dev/null)"
	done
	inodes=$(printf '%s' "$inodes" | tr -s ' ' | sed 's/^ //; s/ $//')
	[ -n "$inodes" ] || return 1

	# $inodes 已清洗成空格分隔的数字，需要分词传给快路径
	# shellcheck disable=SC2086
	port_owner_ss $inodes && return 0

	hit=$(port_owner_proc "$inodes" 2>/dev/null) || return 1
	pid=${hit%% *}
	[ -n "$pid" ] || return 1
	printf '%s %s %s\n' "$pid" \
		"$(cat "$P/$pid/comm" 2>/dev/null)" \
		"$(readlink "$P/$pid/exe" 2>/dev/null)"
}

# 等进程真的消失（kill -0 还成功就说明没退）
wait_pid_gone() {
	local pid="$1" n="${2:-15}"
	while [ "$n" -gt 0 ]; do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.2 2>/dev/null || sleep 1
		n=$((n - 1))
	done
	kill -0 "$pid" 2>/dev/null || return 0
	return 1
}

# 等端口释放
wait_port_free() {
	local n="${2:-15}"
	while [ "$n" -gt 0 ]; do
		port_busy "$1" || return 0
		sleep 0.2 2>/dev/null || sleep 1
		n=$((n - 1))
	done
	port_busy "$1" && return 1
	return 0
}

# 往 boot.log 记一笔（只在文件已存在时写，命令行调用不凭空造文件）
boot_note() {
	[ -f "$BOOT_LOG" ] && printf '[boot] %s %s\n' "$(date +%c)" "$*" >> "$BOOT_LOG" 2>/dev/null
	return 0
}

# 启动前把端口让出来。
# start 分支虽然已经先 server_stop，但还有两种情况让不出来：
#   - 旧进程收到 TERM 后没有立刻退（现在 server_stop 会等，这里是双保险）
#   - 端口被别的程序占着（其它 DNS、代理，或遗留的 smartdns 实例）
# 内核 bind 失败后**不一定退出**：进程还在、DNS 却没在听，看门狗看到进程活着
# 就以为一切正常，服务于是永远起不来，日志里每 30 秒刷一条错误。
free_port_for_start() {
	local port info pid name exe pids
	for port in $Main_PORT $Second_PORT; do
		[ -n "$port" ] || continue
		wait_port_free "$port" 15 && continue

		# 先按进程名清一遍自己的核。定位 socket 属主虽然已经改成 ss/批量 ls，
		# 但仍然比直接按名字杀贵得多；最常见的情形（旧核没退干净）用 core_pids
		# 就够了，没必要为了一个 pid 去扫全机的 fd。
		pids=$(core_pids)
		if [ -n "$pids" ]; then
			for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
			if wait_port_free "$port" 10; then
				boot_note "端口 $port 原被旧内核占用 (pid $pids)，已释放"
				continue
			fi
		fi

		info=$(port_owner "$port" 2>/dev/null | head -n 1)
		pid=${info%% *}
		info=${info#* }
		name=${info%% *}
		exe=${info#* }

		# 占用者如果是本模块的内核（上一次没退干净），直接清掉
		case "$exe" in
			"$CORE_DIR"/*|"$CORE_INTERNAL_DIR"/*|"$TEMP_DIR"/*) kill -9 "$pid" 2>/dev/null ;;
			'') [ "$name" = "$CORE_NAME" ] && kill -9 "$pid" 2>/dev/null ;;
			*)  [ "$name" = "$CORE_NAME" ] && kill -9 "$pid" 2>/dev/null ;;
		esac

		if [ -n "$pid" ] && wait_port_free "$port" 25; then
			boot_note "端口 $port 原先被 ${name:-未知} (pid $pid) 占用，已释放"
			continue
		fi

		echo "[Error]: 端口 $port 仍被占用，内核无法 bind。"
		if [ -n "$pid" ]; then
			echo "  占用进程: ${name:-未知} (pid $pid)${exe:+  $exe}"
		else
			echo '  占用进程: 未能定位（可能是内核持有的 socket，或 /proc 读不到）'
		fi
		echo '  处理办法:'
		echo '    1) 结束上面这个程序后重试；'
		echo "    2) 或在 WebUI 的「端口」里换一个（例如 $((port + 1000))）。"
		echo "  涉及文件: $CONF_FILE"
		exit 1
	done
	return 0
}

### 配置里的落盘路径 ###
# 从上游继承下来的老配置通常没有 cache-file 这一行，内核于是用自己编译进去的
# 默认值 /tmp/smartdns.cache，而 Android 的 /tmp 写不了（SELinux 拦 rootfs），
# 表现就是 core.log 里每半分钟一条 create file ... Permission denied。
# log-file / audit-file 同理：路径不可写就等于没有日志，WebUI 日志页永远是空的。

conf_get() {
	awk -v k="$1" '!/^[[:space:]]*#/ && $1 == k { print $2; exit }' "$CONF_FILE" 2>/dev/null
}

# 原地替换某条指令的值，保留其余内容和顺序
conf_set() {
	local tmp="$TEMP_DIR/.conf-set.$$"
	awk -v k="$1" -v v="$2" '
		!done && $0 !~ /^[[:space:]]*#/ && $1 == k { print k " " v; done = 1; next }
		{ print }
	' "$CONF_FILE" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	[ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
	cat "$tmp" > "$CONF_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
	rm -f "$tmp"
	return 0
}

# 这个路径能不能真正写进去
# 注意：这里只能代表 shell 自己的写权限，内核进程的安全域可能不同，
# 所以「日志放哪」不靠这个判断（见 conf_path_fix 里的说明）。
path_writable() {
	local p="$1" d
	case "$p" in
		# Android 上这些位置看着存在、实际写不了（SELinux 拦 rootfs），不必试探
		/tmp/*|/var/*|/run/*|/usr/*|/etc/*|/system/*|/proc/*|/sys/*) return 1 ;;
	esac
	d=$(dirname "$p" 2>/dev/null)
	[ -n "$d" ] || return 1
	mkdir -p "$d" 2>/dev/null
	[ -d "$d" ] && [ -w "$d" ] || return 1
	[ -e "$p" ] && { [ -w "$p" ] || return 1; }
	return 0
}

conf_path_fix() {
	[ -f "$CONF_FILE" ] || return 0
	local key cur want changed='' orig="$TEMP_DIR/.conf-orig.$$"
	cp -f "$CONF_FILE" "$orig" 2>/dev/null

	for key in cache-file log-file audit-file; do
		case "$key" in
			cache-file)
				# 缓存放工作目录的 tmpfs；那里也写不了就退到 /data 下
				if path_writable "$TEMP_DIR/dns_cache"; then
					want="$TEMP_DIR/dns_cache"
				else
					want="$DATA_BASE/tmp/dns_cache"
				fi
				;;
			log-file)   want="$LOG_DIR/$CORE_NAME.log" ;;
			audit-file) want="$LOG_DIR/$CORE_NAME-audit.log" ;;
		esac

		cur=$(conf_get "$key")

		if [ -z "$cur" ]; then
			# cache-file 缺失会让内核退回 /tmp（就是那条 Permission denied）；
			# log-file 缺失只是没日志，但日志页会一直空着，一并补上更省事。
			# audit-file 缺省就是关闭状态，不替用户打开。
			[ "$key" = 'audit-file' ] && continue
			printf '\n# 路径由模块统一指定（Android 上默认值不可写）\n%s %s\n' "$key" "$want" >> "$CONF_FILE" 2>/dev/null \
				&& changed="$changed $key"
			continue
		fi

		# 已经是目标值就别再动（否则每次启动都改配置、都写 .bak）
		[ "$cur" = "$want" ] && continue

		# 日志类不看「当前能不能写」，只看「是不是在新的日志目录里」。
		# 老版本写在 /dev/smartdns/log（tmpfs）：重启就清空，而且部分机型上
		# magisk 域根本写不进 /dev 下的普通目录 —— 用 [ -w ] 测是测不出来的
		# （shell 能写不代表内核进程所在的安全域能写）。统一搬到 /data 下。
		case "$key" in
			log-file|audit-file)
				case "$cur" in
					"$LOG_DIR"/*) continue ;;
				esac
				conf_set "$key" "$want" && changed="$changed $key"
				continue
				;;
		esac

		path_writable "$cur" && continue
		conf_set "$key" "$want" && changed="$changed $key"
	done

	[ -n "$changed" ] || { rm -f "$orig"; return 0; }

	[ -s "$orig" ] && cp -f "$orig" "$CONF_FILE.bak" 2>/dev/null
	rm -f "$orig"
	echo "[提示]: 配置里的落盘路径已调整到模块数据目录：$changed"
	echo "  原因: Android 上内核默认的 /tmp、以及 /dev 下的临时目录都可能写不进去，"
	echo '        表现就是 core.log 里的 "create file ... Permission denied"，或日志一直是空的。'
	echo "  原配置已备份: $CONF_FILE.bak"
	boot_note "调整配置落盘路径:$changed"
	return 0
}

# 光有 log-file 还不够。
# 实测：只写 log-file、不写 log-level 时，内核按默认级别过滤，正常运行时一条日志
# 都不产生，连日志文件都不会创建（文件是第一次真正要写日志时才打开的）。
# 结果就是"配置看起来对、日志页永远空着"。这里补一个缺省级别，
# 用户自己写过的 log-level 一律不动。
conf_log_fix() {
	[ -f "$CONF_FILE" ] || return 0
	[ -n "$(conf_get log-file)" ] || return 0
	[ -n "$(conf_get log-level)" ] && return 0
	printf '\n# 只有 log-file 没有 log-level 时，内核默认不写日志（由模块补上）\nlog-level info\n' \
		>> "$CONF_FILE" 2>/dev/null || return 0
	echo '[提示]: 配置里只有 log-file、没有 log-level，内核默认不产生任何日志。'
	echo '        已补上 log-level info，重启服务后日志页才会有内容。'
	boot_note '补上 log-level info'
	return 0
}

# 保证主配置引用的规则文件确实存在。
#
# 主配置只引用一个 ./rules/index.conf，由规则源管理器生成；内核遇到不存在的
# conf-file 会直接拒绝启动，所以起进程之前必须把这三层补齐：
#   1. 规则源元数据（sources.conf / seed / local.hosts）就位；
#   2. 首次运行用包内快照铺一份规则，保证开机就有国内/国外分流和广告屏蔽；
#   3. 合并文件与索引重建（升级后第一次启动、手改 sources.conf 后都要重建）。
conf_rules_fix() {
	[ -f "$CONF_FILE" ] || return 0
	local _f

	rules_init >/dev/null 2>&1
	# 只做一次，之后即使 index 空了也不再自动重建 —— 那多半是用户自己清空的。
	if [ ! -s "$RULES_OUT/index.conf" ] && [ ! -f "$RULES_STATE/.seeded" ]; then
		rules_update_local_only >/dev/null 2>&1
		: > "$RULES_STATE/.seeded" 2>/dev/null
	fi
	# 4.1 及以前只有逐源的 auto-*.conf。升级后第一次启动补一份合并文件，
	# 否则 index 会退回逐源引用：能跑，但跨源去重没生效。
	# 另外手动改过 sources.conf（改了启停）时它比合并文件新，也得重建一次，
	# 否则内核加载的还是旧的那份合并结果。
	if [ ! -s "$RULES_OUT/merged.conf" ] || [ "$RULES_SOURCES" -nt "$RULES_OUT/merged.conf" ]; then
		for _f in "$RULES_OUT"/auto-*.conf; do
			[ -s "$_f" ] && { rules_gen_merged >/dev/null 2>&1; break; }
		done
	fi
	rules_gen_index >/dev/null 2>&1
	return 0
}

## 防火墙部分
iptrules_on() {
	if [[ "$MODE" != *'local'* && "$MODE" != *'proxy'* ]]; then
		return 0
	fi
	local IPP
	#  IPv4
	# 建链 dns_redirect
	iptables -w 5 -t nat -N dns_redirect
	# 加载重定向规则
	iptrules_load 'iptables' '-A'
	# 外链
	for IPP in $packet_type
	do
		iptables -w 5 -t nat -A OUTPUT -p ${IPP} --dport 53 -j dns_redirect
		iptables -w 5 -t nat -A POSTROUTING -p ${IPP} -m mark --mark 0x853 -j SNAT --to-source '127.0.0.1'
	done


	#  IPv6
	if [ "$IP6T_BLOCK" == 'yes' ]; then
		# 建链 dns_block
		ip6tables -w 5 -t filter -N dns_block
		# 放行 PKG应用 IPv6 53
		iptrules_accept 'ip6tables' '-A' 'dns_block'
		# tun接口 放行
		[ "$TUN" == 'yes' ] && ip6tables -w 5 -t filter -A dns_block -o tun+ -j RETURN
		# 封锁
		ip6tables -w 5 -t filter -A dns_block -p udp -j DROP
		ip6tables -w 5 -t filter -A dns_block -p tcp -j REJECT --reject-with tcp-reset
		# 进入链 dns_block
		for IPP in 'udp' 'tcp'
		do
			ip6tables -w 5 -t filter -A OUTPUT -p ${IPP} --dport 53 -j dns_block
		done
	else
		# 建链 dns_redirect
		ip6tables -w 5 -t nat -N dns_redirect
		# 加载重定向规则
		iptrules_load 'ip6tables' '-A'
		# 外链
		for IPP in $packet_type
		do
			ip6tables -w 5 -t nat -A OUTPUT -p ${IPP} --dport 53 -j dns_redirect
			ip6tables -w 5 -t nat -A POSTROUTING -p ${IPP} -m mark --mark 0x853 -j SNAT --to-source '::1'
		done
	fi
}



# 删一条规则：删到删不动为止。删不到说明本来就没有，不算错误（幂等是硬要求）。
# 上限 32 次只是防呆，正常最多删几次就返回非 0 了。
_del_all() {
	local ipt="$1"; shift
	local n=0
	while [ "$n" -lt 32 ] && ${ipt} -w 5 "$@" 2>/dev/null; do n=$((n + 1)); done
	return 0
}

# 清理本模块装过的所有防火墙规则。
#
# 审查 C1：这里原来拿 MODE 当开关（不是 local/proxy 就直接 return），可
# iptrules_on 同样按 MODE 短路，于是「改成仅服务 → 停止/卸载」时一条规则都不删，
# nat 表里仍把 53 重定向到已经没人监听的端口，整机 DNS 直接不可用。清理必须看
# 「实际装过什么」，与当前配置无关 —— 因此去掉 MODE / IP6T_BLOCK 判断，
# v4/v6 两个方向的规则都删一遍（删不到就当没装过）。
#
# 审查 C2：原来是 `while iptrules_check` 收敛 + 超过 3 轮 exit 1。但 iptrules_check
# 的判据是「nat 表里还有指向本模块端口的 REDIRECT」，而 proxy 模式装的是
# PREROUTING 规则，本函数从来没删过 —— local,proxy 下必然死循环，第 5 轮 exit 1。
# 这个 exit 正好落在 server_restart 的 server_stop 与 server_start 之间：内核已停、
# 规则删了一半，看门狗再拉一次还是 exit 1 → 永久断网且自愈失效。
# 现在改成「删跳转 → 清链 → 删链」的固定序列，任何一步失败都继续往下走。
#
# 审查 C5：原来循环末尾 `|| let count++` 在 count=0 时返回 1（后自增返回旧值），
# 清理成功反而让函数返回 1；log=yes 时 command.sh 带 set -ex，直接中断 start/stop。
# 循环去掉后这个问题自然消失，函数恒定 return 0。
iptrules_off() {
	local IPP spec
	#  IPv4
	for IPP in $packet_type; do
		_del_all iptables -t nat -D OUTPUT -p ${IPP} --dport 53 -j dns_redirect
		_del_all iptables -t nat -D POSTROUTING -p ${IPP} -m mark --mark 0x853 -j SNAT --to-source 127.0.0.1
	done
	# proxy 模式装的是 PREROUTING 跳转，规格里带 -d <本机IP>，IP 变了就删不掉，
	# 因此按「目标端口」从 -S 里反查整条规格再原样 -D（审查 C2）
	if [ -n "$Second_PORT" ]; then
		iptables -w 5 -t nat -S PREROUTING 2>/dev/null | sed -n 's/^-A /-D /p' | \
		while read -r spec; do
			case "$spec" in
				*"--to-ports ${Second_PORT}") iptables -w 5 -t nat $spec 2>/dev/null || true ;;
			esac
		done
	fi
	# 审查 C5 补充：log=yes 时 main 带 set -ex，真机上 `-F` 因为链已不存在返回 1，
	# 直接把 stop 打断（内核没停、标记已置）。清理里的每条命令都必须吞掉退出码。
	iptables -w 5 -t nat -F dns_redirect 2>/dev/null || true
	iptables -w 5 -t nat -X dns_redirect 2>/dev/null || true


	#  IPv6
	# 封锁(dns_block)与重定向(dns_redirect)两条路都清，不按 IP6T_BLOCK 二选一
	for IPP in $packet_type; do
		_del_all ip6tables -t nat -D OUTPUT -p ${IPP} --dport 53 -j dns_redirect
		_del_all ip6tables -t nat -D POSTROUTING -p ${IPP} -m mark --mark 0x853 -j SNAT --to-source ::1
		_del_all ip6tables -t filter -D OUTPUT -p ${IPP} --dport 53 -j dns_block
	done
	ip6tables -w 5 -t nat -F dns_redirect 2>/dev/null || true
	ip6tables -w 5 -t nat -X dns_redirect 2>/dev/null || true
	ip6tables -w 5 -t filter -F dns_block 2>/dev/null || true
	ip6tables -w 5 -t filter -X dns_block 2>/dev/null || true

	iptrules_assert_clear
	return 0
}

# 清完再验一次（审查 C1 的验收标准）：nat 表里只要还有指向本模块端口的 REDIRECT，
# 就把这些跳转整条扫出来再删一遍，并留一条 boot.log。只告警，绝不 exit。
iptrules_assert_clear() {
	local p spec left=''
	for p in $Main_PORT $Second_PORT; do
		[ -n "$p" ] || continue
		iptables -w 5 -t nat -S 2>/dev/null | sed -n 's/^-A /-D /p' | \
		while read -r spec; do
			case "$spec" in
				*"--to-ports ${p}"*) iptables -w 5 -t nat $spec 2>/dev/null || true ;;
			esac
		done
		# 用 if 而不是 `cmd && 语句`：log=yes 时 shell 带 set -e，
		# 一个「没匹配到」的 grep 就能把整个 stop 打断
		if iptables -w 5 -t nat -S 2>/dev/null | grep -qE "REDIRECT.+--to-ports ${p}$"; then
			left="$left ${p}/v4"
		fi
	done
	if [ -z "$left" ]; then
		return 0
	fi
	boot_note "防火墙规则有残留:${left}（已强制清理，仍残留请重启设备）"
	return 0
}



# 列出「内核自己会去连的明文 DNS 上游」IP（审查 C6 的放行依据）。
#
# 为什么要这个：链首放行 uid 0 能把内核自己的上游查询放过去（防自环），但 Android
# 的 netd 也是 uid 0，于是系统解析被一起放行 —— 本机模式对普通应用完全无效（真机
# 实测 dns_redirect 里 uid-0 计数 40、REDIRECT 恒 0）。既然两者同 UID，改从「目的地」
# 区分：把这几个上游 IP 放行，其余（netd 发给路由器的查询）照常重定向。
#
# 只统计明文 :53 的 `server` 行；DoT(853)/DoH(443) 不经过 --dport 53，用不着放行。
# 主机名形式的明文上游必须能用 `address /名字/IP` 钉死，钉不住就输出 UNRESOLVED，
# 调用方据此退回「放行 uid 0」的老做法 —— 宁可本机模式不生效，也不能让内核自环。
# 主配置 + 它 include 进来的 conf-file（相对路径按「被包含文件所在目录」解析）。
# 之前只读主配置，用户把 server 写进 conf-file 里就会漏掉 —— 漏掉的明文上游
# 会被自己的重定向劫持，直接自环。层数与文件数都设了上限，防止被奇怪的配置拖死。
core_conf_files() {
	local f base list="$TEMP_DIR/.conflist.$$" cur="$TEMP_DIR/.confcur.$$" depth=0
	printf '%s\n' "$CONF_FILE" > "$cur"
	: > "$list"
	while [ -s "$cur" ] && [ "$depth" -lt 3 ]; do
		: > "$cur.next"
		while IFS= read -r f; do
			[ -n "$f" ] || continue
			grep -qxF "$f" "$list" 2>/dev/null && continue
			[ -f "$f" ] || continue
			printf '%s\n' "$f" >> "$list"
			base=$(dirname "$f")
			awk -v b="$base" '
				/^[[:space:]]*conf-file[[:space:]]+/ {
					p = $2
					if (p !~ /^\//) p = b "/" p
					print p
				}' "$f" 2>/dev/null >> "$cur.next"
		done < "$cur"
		mv -f "$cur.next" "$cur" 2>/dev/null
		depth=$((depth + 1))
	done
	cat "$list" 2>/dev/null
	rm -f "$list" "$cur" "$cur.next" 2>/dev/null
}

core_upstream_ips() {
	core_conf_files 2>/dev/null | while IFS= read -r f; do cat "$f" 2>/dev/null; done | \
	awk '
	# 先把所有 address 钉死的映射和 server 行都收下来，最后统一判定：
	# 这样 address 写在 server 后面也不影响结果。
	$1 == "address" {
		n = split($2, a, "/")
		if (n >= 3 && a[3] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) pin[a[2]] = a[3]
		next
	}
	$1 == "server" { order[++cnt] = $2 }
	END {
		for (i = 1; i <= cnt; i++) {
			h = order[i]
			if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?$/) { sub(/:.*/, "", h); print h; continue }
			if (h ~ /:/) continue                       # IPv6 字面量：v4 链用不着
			if (h in pin) { print pin[h]; continue }
			print "UNRESOLVED:" h
		}
	}'
}

# 明文上游是否都能落到具体 IP（能，才敢用「按目的地放行」）
core_upstream_ok() {
	case "$(core_upstream_ips)" in
		*UNRESOLVED:*) return 1 ;;
		*) return 0 ;;
	esac
}

# 内核这次启动时实际读到的上游清单。规则必须按它生成，而不是按磁盘上
# 可能已经被改过、但内核还没重启的 smartdns.conf —— 否则「改了配置没重启」
# 期间重装一次规则，规则按新配置、内核还在用旧配置，两边对不上就自环。
CORE_UPSTREAM_SNAP="$TEMP_DIR/.upstream.ips"
core_upstream_snapshot() {
	core_upstream_ips > "$CORE_UPSTREAM_SNAP" 2>/dev/null
	return 0
}
core_upstream_list() {
	if [ -f "$CORE_UPSTREAM_SNAP" ]; then
		cat "$CORE_UPSTREAM_SNAP" 2>/dev/null
	else
		core_upstream_ips 2>/dev/null
	fi
}
core_upstream_list_ok() {
	case "$(core_upstream_list)" in
		*UNRESOLVED:*) return 1 ;;
		*) return 0 ;;
	esac
}

# 链里的“按目的地放行”是否与清单一致（看门狗定期对账用，返回 0 表示一致）
iptrules_dest_synced() {
	local want have
	# 放行了 uid 0 说明走的是旧模式，没有按目的地放行这么一说
	iptables -w 5 -t nat -S dns_redirect 2>/dev/null | grep -q -- '--uid-owner 0 ' && return 0
	want=$(core_upstream_list 2>/dev/null | grep -v '^UNRESOLVED:' | sort -u)
	have=$(iptables -w 5 -t nat -S dns_redirect 2>/dev/null \
		| sed -n 's/^-A dns_redirect -d \([^ ]*\) -j RETURN$/\1/p' \
		| sed 's#/32$##' | sort -u)
	[ "$want" = "$have" ]
}

# 加载重定向规则
iptrules_load() {
	# [iptables/ip6tables]  [-A/-D]
	local ipt=${1} action=${2} IP IPP
	
	# LOCAL
	if [[ "$MODE" == *'local'* ]]; then
		# 审查 C6：优先「按目的地放行内核自己的上游」，而不是放行 uid 0。
		# 只有 v4 链能做（core_upstream_ips 给的是 v4 地址）；v6 链照旧放行 uid 0。
		if [ "$ipt" = 'iptables' ] && core_upstream_list_ok; then
			iptrules_accept ${ipt} ${action} 'dns_redirect' 'no'
			for IP in $(core_upstream_list | grep -v '^UNRESOLVED:'); do
				${ipt} -w 5 -t nat ${action} dns_redirect -d "$IP" -j RETURN
			done
		else
			# 特定UID 放行（含 uid 0，行为与旧版一致）
			iptrules_accept ${ipt} ${action} 'dns_redirect'
		fi
		# tun接口 放行
		[ "$TUN" == 'yes' ] && ${ipt} -w 5 -t nat ${action} dns_redirect -o tun+ -j RETURN
		# wlan接口 放行
		[ "$WLAN" == 'yes' ] && ${ipt} -w 5 -t nat ${action} dns_redirect -o wlan+ -j RETURN
		# data接口 放行
		[ "$DATA" == 'yes' ] && ${ipt} -w 5 -t nat ${action} dns_redirect -o rmnet_data+ -j RETURN
		for IPP in $packet_type
		do
			${ipt} -w 5 -t nat ${action} dns_redirect -p ${IPP} -j MARK --set-xmark 0x853
			${ipt} -w 5 -t nat ${action} dns_redirect -p ${IPP} -j REDIRECT --to-ports ${Main_PORT}
		done
	fi
	
	
	# PROXY
	if [[ "$MODE" == *'proxy'* ]]; then
		for IPP in $packet_type
		do
			if [ "$ipt" == 'iptables' ]; then
				# 获取本机IP
				IP=''; for IP in "$(ifconfig |grep "inet addr" |grep -v ":127" |grep "Bcast" |awk '{print $2}' |awk -F: '{print $2}')"
				do
					echo $IP |grep -q -E '(^192\.168\.*)|(^10\.*)|(^172\.(1[6-9]|2[0-9]|3[0-1])\.*)' || continue
					# v4 安全代理
					${ipt} -w 5 -t nat ${action} PREROUTING -i wlan+ -p ${IPP} -d ${IP} --dport 53 -j REDIRECT --to-ports ${Second_PORT}
				done
			# else
			# v6 代理 停用
			#	${ipt} -w 5 -t nat ${action} PREROUTING -p ${IPP} --dport 53 -j REDIRECT --to-ports ${Second_PORT}
			fi
		done
	fi
}



# 放行特定UID
	#[iptables/ip6tables]  (raw->mangle->nat->filter)  [-A/-D]  (udp/tcp)
	## dns_redirect 链
	# ${ipt} -w 5 -t nat ${action} dns_redirect -m owner --uid-owner $uid -j RETURN
	## dns_block 链 (IPv6)
	# ${ipt} -w 5 -t filter ${action} dns_block -m owner --uid-owner $uid -j RETURN
iptrules_accept() {
	# $4 = 是否放行 uid 0（默认 yes）。审查 C6：dns_redirect 在没有把 uid 0 放进
	# 放行名单时，说明调用方改用了「按目的地放行上游」，这里就不能再放过 netd。
	[ -z "$PKG" ] && [ "${4:-yes}" = 'yes' ] && return 0
	local ipt=${1} action=${2} allow_root=${4:-yes}
	local tables chains uid list
	case "${3}" in
		dns_block)
		tables='filter'; chains='dns_block';;
		dns_redirect)
		tables='nat'; chains='dns_redirect';;
	esac

	# 放行名单：uid 0（netd/内核，二者同 UID，见 C6）+ shell + 用户指定的应用
	list='1001'
	[ "$allow_root" = 'yes' ] && list="0 $list"
	for uid in $list $PKG
	do
		# 包名转换UID
		echo "$uid" |grep -q -i '[a-z]' && uid=$(grep -m1 -i $uid /data/system/packages.list |cut -d' ' -f2)
		# 不存在则跳过
		[ -z "$uid" ] && continue
		${ipt} -w 5 -t ${tables} ${action} ${chains} -m owner --uid-owner ${uid} -j RETURN
	done
}





## 服务器部分

# 启动失败时的解释：光把内核日志贴出来，用户往往看不懂
start_fail_hint() {
	local out="$1" owner
	if [ -s "$out" ]; then
		echo "---- 内核输出 ($out) ----"
		tail -n 20 "$out" 2>/dev/null
		echo '------------------------'
	fi
	if [ -s "$out" ] && grep -q 'Address in use' "$out" 2>/dev/null; then
		echo "[提示]: 端口 $Main_PORT 已被占用。"
		# 直接查出来是谁占的，别让用户自己去猜 netstat
		owner=$(port_owner "$Main_PORT" 2>/dev/null | head -n 1)
		[ -n "$owner" ] && set -- $owner && echo "  当前占用者: $2 (pid $1) ${3:-}"
		echo "  常见原因："
		echo "  1. 配置里同一端口同时 bind 了 [::]:$Main_PORT 和 0.0.0.0:$Main_PORT。"
		echo "     Android 的 IPv6 默认双栈，[::] 已经包含 IPv4，再 bind 0.0.0.0 必然冲突。"
		echo "     删掉 0.0.0.0 那一行即可（推荐只保留 bind [::]:$Main_PORT）。"
		echo "  2. 其它程序占着该端口，可执行: ss -lntup 2>/dev/null | grep $Main_PORT"
		echo "  涉及文件: $CONF_FILE"
	fi
}

# 启动内核进程：必须与调用者会话脱钩。
# 开机路径是 service.sh -> command.sh -> 内核，父 shell 一退出，同会话的子进程
# 可能被按进程组一起收走，表现就是「start 报成功、一两分钟后进程却没了」。
# setsid 让内核自成一个会话，父 shell 死活与它无关；缺 setsid 时退回 nohup。
core_spawn() {
	# 让日志里的时间跟手机对得上（内核只认 POSIX 时区串，见 constant.sh）
	local tz
	tz=$(core_tz 2>/dev/null)
	[ -n "$tz" ] && export TZ="$tz"
	if command -v setsid >/dev/null 2>&1; then
		setsid "$CORE_EXE" "$@" &
	elif command -v nohup >/dev/null 2>&1; then
		nohup "$CORE_EXE" "$@" &
	else
		"$CORE_EXE" "$@" &
	fi
}

# 启动服务器
server_start() {
	core_ready
	# 起进程之前先把几个坑填了：落盘路径不可写、端口还被占着、日志级别没设
	conf_path_fix
	conf_log_fix
	conf_rules_fix
	free_port_for_start
	local count='0' PID out="$LOG_DIR/core.log"
	# 内核输出单独留档：启动失败时能直接看到原因（log=yes 时同时进 boot.log）
	: > "$out" 2>/dev/null || out=/dev/null
	core_spawn -c "$CONF_FILE" -p "$PID_FILE" >> "$out" 2>&1
	# 启动检测
	while true; do
		PID="$(core_pids | head -n 1)"
		if [ -n "$PID" ]; then
			# 二次确认：内核 bind 失败时是"起来即退出"，只轮询一次会抓到那个
			# 还没退干净的残影，从而误报"成功启动"（服务其实已经死了）。
			# 隔 1 秒再看一眼，仍然在才算数。
			sleep 1
			PID="$(core_pids | head -n 1)"
			if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
				# 内核 bind 失败后不一定退出：进程还活着，DNS 却没在听。
				# 只看"进程在"就报成功是假成功，必须看它有没有报这句错。
				if [ -s "$out" ] && grep -q 'start dns server failed' "$out" 2>/dev/null; then
					print_server_start_failed
					start_fail_hint "$out"
					# 这个进程留着没用，还会继续占着端口挡住下一次启动
					kill -9 "$PID" 2>/dev/null
					exit 1
				fi
				# PID写入文件
				echo "$PID" > $PID_FILE
				# 审查 C6：把「这次启动读到的上游清单」钉下来，规则一律按它生成
				core_upstream_snapshot
				print_server_start_success
				break
			fi
			# 刚才还在、1 秒后就没了：内核确实退出了，没必要再空等 15 秒
			if [ -z "$PID" ]; then
				print_server_start_failed
				start_fail_hint "$out"
				exit 1
			fi
		fi
		if [ ${count} -ge 30 ] ; then
			print_server_start_failed
			start_fail_hint "$out"
			exit 1
		fi
		# 有输出却查不到进程：内核打印完日志就退出了（极快失败）。
		# 连续 2 次判定，避开 pidof 的瞬时抖动。
		if [ -s "$out" ] && [ -z "$PID" ]; then
			hits=$((${hits:-0} + 1))
			if [ "${hits}" -ge 2 ]; then
				print_server_start_failed
				start_fail_hint "$out"
				exit 1
			fi
		else
			hits='0'
		fi
		sleep .5; count=$((${count} + 1))
	done
}

# 停止服务器
# 关键在「等」：以前 kill -TERM 发出去就返回了，紧接着的 start 去 bind 同一个
# 端口，撞上还没退干净的旧进程，core.log 里就是那句
# "bind service [::]:6053 failed, Address in use"。
# 开机时进程多、回收慢，所以这个问题只在开机那条路径上偶发。
server_stop() {
	local PID pids p
	pids=$(core_pids)

	if [ -f "$PID_FILE" ]; then
		# 正常退出
		rm -f "$PID_FILE"
		for PID in $pids; do kill -TERM "$PID" 2>/dev/null; done
		for PID in $pids; do
			wait_pid_gone "$PID" 15 || kill -9 "$PID" 2>/dev/null || true
			wait_pid_gone "$PID" 10 || true
		done
	else
		# 强制退出
		for PID in $pids; do kill -9 "$PID" 2>/dev/null || true; done
		for PID in $pids; do wait_pid_gone "$PID" 10 || true; done
	fi

	# 兜底：进程已经没了，但内核还没来得及回收 socket
	for p in $Main_PORT $Second_PORT; do
		[ -n "$p" ] && wait_port_free "$p" 10
	done

	if [ -n "$pids" ]; then
		print_server_stop_success
	else
		print_status_server_not_running
	fi
	return 0
}

# 重启 = 先停再起。**不要**直接调 server_start：内核还在跑的时候直接起第二个，
# 端口被占，free_port_for_start 会去全机扫 /proc/*/fd 找 socket 属主，
# 真机上能卡好几分钟（规则更新后的重载就是这么被拖死的，.running 一直清不掉）。
#
# 另外要串行：WebUI 点一下、规则更新、看门狗都可能在同一秒要求重启，
# 两个 start 撞在一起会互相把对方刚拉起的核当成"旧核占用端口"杀掉，
# 日志里一串端口抢占（最终能恢复，但脏且慢）。
server_restart() {
	local lk="$DATA_BASE/.restart.lock" owner i=0 rc
	while ! mkdir "$lk" 2>/dev/null; do
		owner=$(cat "$lk/pid" 2>/dev/null)
		# 持锁的进程已经没了 = 上一轮异常退出留下的锁，直接接管
		if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
			rm -rf "$lk"
			continue
		fi
		i=$((i + 1))
		if [ "$i" -ge 60 ]; then
			rm -rf "$lk"
			mkdir "$lk" 2>/dev/null
			break
		fi
		sleep 1
	done
	echo $$ > "$lk/pid" 2>/dev/null

	server_stop
	iptrules_off
	server_start && iptrules_on
	rc=$?

	rm -f "$lk/pid" 2>/dev/null
	rmdir "$lk" 2>/dev/null
	return "$rc"
}


## 状态部分
# 检查服务器状态
server_check() {
	local PID
	PID="$(core_pids | head -n 1)"
	if [ -z "$PID" ]; then
		[ -f "$PID_FILE" ] && rm -f "$PID_FILE"
		return 1
	fi
	# 修复PID文件
	[ ! -f "$PID_FILE" ] && echo "$PID" > $PID_FILE
	return 0
}

# 检查防火墙状态
iptrules_check() {
	# Second_PORT 在 start 之前是空串，直接拼进正则会变成 `(6053|)` —— 空分支让
	# 任何一条 REDIRECT 都命中（真机 script_conf 里 Second_PORT 确实是空的）。
	# 顺带把判据锚到 `--to-ports`，否则 `--to-ports 16053` 也会被当成命中。
	local ports="$Main_PORT"
	if [ -n "$Second_PORT" ] && [ "$Second_PORT" != "$Main_PORT" ]; then
		ports="$ports|$Second_PORT"
	fi
	if iptables -w 5 -t nat -S 2>/dev/null | grep -qE "REDIRECT.+--to-ports ($ports)$"; then
		return 0
	fi
	if [ "$IP6T_BLOCK" != 'yes' ]; then
		if ip6tables -w 5 -t nat -S 2>/dev/null | grep -qE "REDIRECT.+--to-ports ($ports)$"; then
			return 0
		fi
	fi
	return 1
}

# 检查服务状态
service_check() {
	local count='0'
	# 服务器状态
	if server_check; then
		print_status_server_already_running
	else
		print_status_server_not_running; let count+=2
	fi
	# 防火墙规则状态
	if [[ "$MODE" == *'local'* ]] || [[ "$MODE" == *'proxy'* ]]; then
		local i='0'
		if [[ "$MODE" == *'local'* ]]; then
			iptables -w 5 -t nat -S 2>/dev/null |grep -q -E "REDIRECT.+$Main_PORT" || { let i--; print_status_iptRules_Local_not_added; }
		fi
		if [[ "$MODE" == *'proxy'* ]]; then
			iptables -w 5 -t nat -S 2>/dev/null |grep -q -E "REDIRECT.+$Second_PORT" || { let i--; print_status_iptRules_Proxy_not_added; }
		fi
		if [ "$i" -eq 0 ]; then
			print_status_iptRules_added
		else
			let count++
		fi
	fi
	# 返回状态值
	case $count in
		3)   # 未启动
			return 3 ;;
		1|2) # 非正常工作状态
			return 1 ;;
		0)   # 正常工作
			return 0 ;;
	esac
}


## 看门狗

# boot.log 只留最近的部分，避免看门狗长期运行把日志撑爆。
# 必须原地截断（不能 mv），因为 service.sh 还攥着这个文件的 fd。
trim_boot_log() {
	local n
	n=$(wc -c < "$BOOT_LOG" 2>/dev/null)
	[ -n "$n" ] && [ "$n" -gt 262144 ] || return 0
	tail -n 400 "$BOOT_LOG" > "$TEMP_DIR/boot.trim" 2>/dev/null || return 1
	cat "$TEMP_DIR/boot.trim" > "$BOOT_LOG" 2>/dev/null
	rm -f "$TEMP_DIR/boot.trim"
	return 0
}

# 规则源到期检查。挂在看门狗里，不额外起守护进程。
# 更新失败只记日志，绝不影响服务本身。
watch_rules() {
	local due out rc
	[ -f "$RULES_SOURCES" ] || return 0
	due=$(rules_due 2>/dev/null)
	[ -n "$due" ] || return 0
	out=$(sh "$MODDIR/command.sh" rulesrc update all 2>&1)
	rc=$?
	{
		echo "[watchdog] $(date +%c) 规则源到期，已更新 (rc=$rc): $(printf '%s' "$due" | tr '\n' ' ')"
		printf '%s\n' "$out" | tail -n 12
	} >> "$BOOT_LOG" 2>&1
	trim_boot_log
	return 0
}

# 有别的进程正在重启内核（server_restart 持锁）：这时看门狗绝不能插一脚，
# 否则两个 start 会互相把对方刚拉起的核当成"旧核"杀掉。
# 锁里的 pid 已经不存在 = 上一轮异常退出的残留，当作没有锁。
restart_in_progress() {
	local lk="$DATA_BASE/.restart.lock" owner
	[ -d "$lk" ] || return 1
	owner=$(cat "$lk/pid" 2>/dev/null)
	[ -n "$owner" ] || return 1
	kill -0 "$owner" 2>/dev/null || return 1
	return 0
}

# 常驻看门狗：内核自己退出（开机时端口/网络没就绪、被系统杀掉等）后自动拉起。
# 以前只能等用户发现"服务怎么停了"再手动点启动，这里补上自愈。
# 用户主动停止会写 $STOP_FLAG，此时看门狗完全不干预。
# 健康判定直接看进程 + 防火墙规则，不调用 status 子进程——
# 否则每 30 秒都会往 script.log 里刷一遍状态文本。
# 看门狗单实例。
# 两个看门狗会各自判活、各自把内核「拉起来」，互相把对方的进程当成异常，
# 结果是每 30 秒重启一次内核 —— DNS 反复抖动，比没有看门狗更糟。
# 不用 pid 文件：/dev 是 tmpfs 重启即清，pid 还会被复用，残留文件反而误判。
# 直接扫 /proc 的 cmdline，要求「最后一个参数正好是 watch」且「路径含 command.sh」，
# 这样不会把 `sh -c '... grep command.sh watch ...'` 这类命令误当成看门狗。
watch_singleton() {
	local p pid last cmd
	for p in /proc/[0-9]*; do
		pid="${p#/proc/}"
		[ "$pid" = "$$" ] && continue
		last=$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | grep -v '^$' | tail -n 1)
		[ "$last" = 'watch' ] || continue
		cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
		case "$cmd" in
			*command.sh*watch*) ;;
			*) continue ;;
		esac
		echo "[watchdog] 已有看门狗在运行 (pid $pid)，本次退出"
		return 1
	done
	return 0
}

watch_loop() {
	local rc2 out first=20 fail=0 gap dead=0 rtick=0
	# 常驻进程里绝不能留着 -e / -x：log=yes 时 main 会开 set -ex，
	# 任何一次非 0 返回都会把看门狗自己干掉
	set +e
	set +x
	while true; do
		# 连续失败 3 次后降到 5 分钟一次：配置本身有问题时不该每 30 秒
		# 反复拉起、反复写日志（耗电且掩盖真正的原因）
		gap=$first
		[ "$fail" -ge 3 ] && gap=300
		sleep "$gap"
		first=30
		[ -f "$STOP_FLAG" ] && { fail=0; dead=0; continue; }

		# 内核活着：只补防火墙规则，绝不重启进程。
		# 规则没装上不等于服务挂了（有的机器 iptables 被别的工具接管），
		# 为此每 30 秒重启一次内核反而会造成 DNS 抖动。
		if core_pids | grep -q .; then
			if [ "$MODE" = 'server' ] || iptrules_check; then
				# 但"进程在"不等于"DNS 在听"：bind 失败的内核不一定会退出，
				# 于是进程活着、端口空着，看门狗会一直当它正常。
				# 只在能读 /proc/net、且连续 3 次确认端口没在听时才重启，
				# 免得读不到 /proc 的设备上把好进程反复杀掉。
				if proc_net_ok && ! port_busy "$Main_PORT"; then
					dead=$((dead + 1))
					if [ "$dead" -ge 3 ]; then
						out=$(sh "$MODDIR/command.sh" start 2>&1)
						rc2=$?
						{
							echo "[watchdog] $(date +%c) 内核进程在，但端口 $Main_PORT 没在监听，已重启 (start rc=$rc2)"
							printf '%s\n' "$out" | tail -n 8
							tail -n 8 "$LOG_DIR/core.log" 2>/dev/null
						} >> "$BOOT_LOG" 2>&1
						trim_boot_log
						dead=0
					fi
				else
					dead=0
				fi
				fail=0
				# 服务本身没问题时，顺带看看有没有规则源到期。
				# 不额外起守护进程：crond 在 Magisk 环境里的坑已经踩过一次了。
				watch_rules
				# 审查 C6 补充：定期对账「按目的地放行」的列表（约 5 分钟一次）。
				# 规则按内核启动时的快照生成，所以正常不会不一致；这里兜的是
				# iptables 被别的工具改过、或重装规则时漏了的情况 —— 只重装规则，
				# 不动内核进程。
				rtick=$((rtick + 1))
				if [ "$rtick" -ge 10 ]; then
					rtick=0
					if ! iptrules_dest_synced; then
						sh "$MODDIR/command.sh" rules >/dev/null 2>&1
						boot_note "[watchdog] 防火墙放行列表与内核实际使用的上游不一致，已重装规则"
					fi
				fi
				continue
			fi
			out=$(sh "$MODDIR/command.sh" rules 2>&1)
			rc2=$?
			if [ "$rc2" -eq 0 ]; then fail=0; else fail=$((fail + 1)); fi
			{
				echo "[watchdog] $(date +%c) 防火墙规则缺失，已尝试补回 (rc=$rc2, 连续 $fail 次)"
				printf '%s\n' "$out" | tail -n 4
			} >> "$BOOT_LOG" 2>&1
			trim_boot_log
			continue
		fi

		# 进程不在：拉起来
		# 但要先看看是不是别人正在动内核：规则更新完会自己重启一次，
		# 如果这时插一脚，两个 start 会互相把对方刚拉起的核当"旧核"杀掉。
		if rules_job_alive || restart_in_progress; then
			sleep 5
			continue
		fi
		out=$(sh "$MODDIR/command.sh" start 2>&1)
		rc2=$?
		if [ "$rc2" -eq 0 ]; then fail=0; else fail=$((fail + 1)); fi
		{
			echo "[watchdog] $(date +%c) 内核进程不在了，已尝试拉起 (start rc=$rc2, 连续失败 $fail 次)"
			printf '%s\n' "$out" | tail -n 8
			if [ "$rc2" -ne 0 ]; then
				echo '[watchdog] 内核输出:'
				tail -n 10 "$LOG_DIR/core.log" 2>/dev/null
			fi
		} >> "$BOOT_LOG" 2>&1
		trim_boot_log
	done
}


## 其他部分
# 保存数值
save_values() {
	# $1(参数名) | $2(参数数值) | $3(为bool时，接受布尔值，没有则自行反转)
	local value_name="$1" value="$2" content
	content="$(grep "${value_name}=" $SCRIPT_CONF)"
	#更改前停止
	iptrules_check && iptrules_off
	server_check && server_stop

	#分离非布尔值
	if [ "$3" != 'bool' ]; then
		sed -i "s/^${content}/${value_name}=\'${value}\'/g" $SCRIPT_CONF
	else
		#判断是否布尔值
		if [ "${value}" == 'yes' -o "${value}" == 'no' ]; then
			sed -i "s/^${content}/${value_name}=\'${value}\'/g" $SCRIPT_CONF
		else
			#自行反转
			if [ "$(echo ${content} |awk -F "=" '{print $2}')" == 'yes' ]; then
				sed -i "s/^${content}/${value_name}=\'no\'/g" $SCRIPT_CONF
				return 2
			else
				sed -i "s/^${content}/${value_name}=\'yes\'/g" $SCRIPT_CONF
				return 1
			fi
		
		fi
	fi
	return 0
}

# 验证端口是否正确
# 注意：不要用 grep -E 的扩展语法。Android 上的 toybox / busybox grep
# 不支持非捕获组 (?:...) 和 \d，会报 "repetition-operator operand invalid"
# 并把合法端口判为非法，导致所有命令在 main() 里直接退出。
port_valid() {
	local p
	case "$1" in
		'' | *[!0-9]*) return 1 ;; # 空值或含非数字字符
	esac
	[ "${#1}" -le 5 ] || return 1
	# 去掉前导零，避免部分 shell 按八进制解析（如 0900）
	p=$(printf '%s\n' "$1" | sed 's/^0*//')
	[ -n "$p" ] || return 1 # 全为 0
	[ "$p" -ge 1 ] 2>/dev/null || return 1
	[ "$p" -le 65535 ] 2>/dev/null || return 1
	return 0
}

### 命令选项 ###

get_args() {
	while [ ${#} -gt 0 ]; do
	case "$1" in
		-h|--help) # 帮助信息
			print_help 0
			;;

		start) # 启动
			rm -f "$STOP_FLAG"
			server_restart
			;;

		stop) # 停止
			touch "$STOP_FLAG" 2>/dev/null
			iptrules_off
			server_stop
			;;

		status) # 检查状态
			service_check
			exit $?
			;;

		watch) # 看门狗（常驻，由 service.sh 在开机时拉起）
			watch_singleton || exit 0
			watch_loop
			;;

		rules) # 只重装防火墙规则（看门狗用，不动内核进程）
			iptrules_off
			iptrules_on
			iptrules_check && exit 0
			exit 1
			;;

		clean) # 清除
			touch "$STOP_FLAG" 2>/dev/null
			# 审查 C1：先按「实际装过的」清一遍自建链与外链。只靠下面的
			# iptables-restore 是不行的：备份在 tmpfs，缺失时 restore 静默失败，
			# 而且 PREROUTING 的代理跳转从来不在备份的还原范围里。
			iptrules_off
			# 还原 iptables
			# iptables -F
			# ip6tables -F
			iptables-restore < $IPT_BAK
			ip6tables-restore < $IP6T_BAK
			# 停止服务器
			server_stop
			server_stop  
			print_reset_network
			# 移除缓存持久化
			rm `awk '!/#/ && /cache-file/ {print $2}' $CONF_FILE 2>/dev/null` 2>/dev/null
			;;

		--mode) # 工作模式
			shift
			case "$1" in
				lo*pr*)
					save_values MODE 'local,proxy'
					MODE='local,proxy'
					;;
				lo*)
					save_values MODE 'local'
					MODE='local'
					;;
				pr*)
					save_values MODE 'proxy'
					MODE='proxy'
					;;
				ser*)
					save_values MODE 'server'
					MODE='server'
					;;
				*)
					print_invalid_value "$1"
					exit 1
					;;
			esac
			;;

		boot) # 开机任务（后台）：等联网后执行 hosts 更新等，不阻塞服务启动
			wait_network
			bootTask
			exit 0
			;;

		rulesrc) # 规则源管理
			# 用法: rulesrc list|status|due|update [id|all]|add|del|reload
			case "$2" in
				list|status)
					rules_init >/dev/null 2>&1
					rules_status
					exit 0
					;;
				due)
					rules_due
					exit 0
					;;
				update)
					target="${3:-all}"
					force='0'
					[ "$4" = 'force' ] && force='1'
					was_running='0'
					core_pids | grep -q . && was_running='1'
					rules_update "$target" "$force"
					rc=$?
					rules_merge_summary
					# 规则变了必须重载内核才生效（smartdns 不支持热重载配置文件）
					if [ "$rc" -eq 0 ] && [ "$was_running" = '1' ]; then
						echo '[rules] 规则已变化，重启内核使其生效'
						server_restart
					fi
					exit "$rc"
					;;
				reload)
					rules_regen
					server_restart
					exit $?
					;;
				merge)
					rules_init >/dev/null 2>&1
					rules_gen_merged
					rc=$?
					rules_merge_summary
					exit "$rc"
					;;
				add)
					# rulesrc add <id> <type> <url> [interval] [enabled] [at]
					#   at = HH:MM（每天）/ w1-HH:MM（每周一）/ m15-HH:MM（每月 15 日）
					rules_init >/dev/null 2>&1
					rules_add_source "$3" "$4" "$5" "${6:-0}" "${7:-1}" "${8:-}"
					rc=$?
					case "$rc" in
						0) echo "[rules] 已添加: $3" ;;
						2) echo "[rules] 源已存在: $3" ;;
						*) echo "[rules] 添加失败：id 只能用字母数字和连字符，类型必须是 $RULES_TYPES" ;;
					esac
					exit "$rc"
					;;
				del)
					rules_init >/dev/null 2>&1
					rules_del_source "$3"
					rc=$?
					case "$rc" in
						0) echo "[rules] 已删除: $3" ;;
						3) echo "[rules] 内置规则源不允许删除: $3" ;;
						*) echo "[rules] 源不存在: $3" ;;
					esac
					exit "$rc"
					;;
				set)
					# rulesrc set <id> <interval> <enabled> [at|-] [url] [type]
					rules_init >/dev/null 2>&1
					rules_set_source "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-}"
					rc=$?
					case "$rc" in
						0) echo "[rules] 已修改: $3" ;;
						1) echo "[rules] 源不存在: $3" ;;
						*) echo '[rules] 参数不合法：interval 为小时数，enabled 为 0/1，时间为 HH:MM / w1-HH:MM / m15-HH:MM' ;;
					esac
					exit "$rc"
					;;
				init)
					rules_init
					echo "[rules] 初始化完成: $RULESRC_DIR"
					exit 0
					;;
				*)
					echo '用法: command.sh rulesrc <list|status|due|update|add|del|set|merge|reload|init>'
					echo '  update <id>|all [force]   立即更新（force 忽略 enabled 开关）'
					echo '  add <id> <type> <url> [interval] [enabled] [at]'
					echo '  set <id> <interval> <enabled> [at|-] [url] [type]'
					echo '  at: HH:MM 每天 / w1-HH:MM 每周一 / m15-HH:MM 每月 15 日'
					echo '  del <id>                  内置源（anti-ad/chnroute/chnlist/gfwlist/local-hosts）不可删'
					echo '  merge                     只重建跨源合并去重文件（不下载）'
					exit 1
					;;
			esac
			;;

		diag) # 诊断信息
			diag_info
			exit 0
			;;

		*) # 无效命令
			# 常见误用：把内核参数传给了本脚本（说明调用的是 /system/bin 的转发脚本，
			# 也就是真正要执行的 smartdns 没被找到）
			case "$1" in
				-c|-p|-f|-v|-x)
					echo "[提示]: '$1' 是 SmartDNS 内核的参数，不该传给本脚本。"
					echo "        出现这种情况通常是内核文件缺失，请运行: sh $MODDIR/command.sh diag"
					;;
			esac
			print_invalid_argument "$1"
			print_help 1
			;;
	esac
	shift
	done
}



# main
	# 解析内核与配置的绝对路径（并修复可能丢失的工作目录挂载）
	ensure_workdir
	# 兼容旧变量：部分分支仍会用到
	CORE_BOOT="$CORE_EXE -c $CONF_FILE -p $PID_FILE"

	# diag 必须在日志重定向之前处理。
	# log=yes 时下面的 `exec 1>>$RUN_LOG 2>&1` 会把所有输出（含 set -x）写进
	# script.log，终端上就表现为「敲了命令什么都没发生」，最容易误导排查。
	if [ "${1:-}" = 'diag' ]; then
		diag_info
		exit 0
	fi

	# 生成日志
	if [ "$log" == 'yes' ]; then
		echo -e "\nDate: $(date +%c)\ncommand: $*\n" >> $RUN_LOG
		exec 1>>$RUN_LOG 2>&1
		set -ex
	fi

	# 未设置主端口 停止
	port_valid "$Main_PORT" || { echo "[Error]: Main_PORT 无效，需为 1-65535 的整数（当前值: '${Main_PORT}'），请检查 ${SCRIPT_CONF}"; exit 1; }
	# 未设置代理端口 使用主端口
	port_valid "$Second_PORT" || Second_PORT="$Main_PORT"
	# 未tcp端口设置 不使用tcp规则 # (?<!#\s*)bind-tcp.*\:+
	[ -n "`awk '!/#/ && /bind-tcp/' $CONF_FILE 2>/dev/null`" ] && readonly packet_type='udp tcp' || readonly packet_type='udp'
	# 检查IPv6 nat支持
	[ "$IP6T_BLOCK" == 'no' ] && { ip6tables -w 5 -t nat -S >/dev/null 2>&1 || { print_kernel_not_support; IP6T_BLOCK='yes'; }; }

	if [ "${1}" == 'command' ]; then
		shift
		# 直接命令
		"$CORE_EXE" "$@"
	elif [ "$1" == 'check' ]; then
		shift
		# 带配置命令
		"$CORE_EXE" -c "$CONF_FILE" "$@"
	else
		if [ -z "$1" ]; then
			print_help 0
		else
			get_args "$@"
		fi
	fi
