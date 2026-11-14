#!/system/bin/sh
# SmartDNS 模块 - WebUI 后端接口
# 由 webroot/index.html 通过 KernelSU / MMRL 的 exec 桥以 root 身份调用。
#
# 用法: sh webui.sh <action> [args...]
#
# 输出约定:
#   - 成功: 向 stdout 输出 key=value 行；base64 类字段统一以 b64= 前缀
#   - 失败: 向 stderr 输出可读原因，并以非 0 退出码结束
#   - 所有会写文件/改动服务的动作都在本脚本内做白名单与参数校验，前端不直接拼命令

# 解析模块目录：传入绝对路径时用 dirname，直接 sh webui.sh 时退化为当前目录
case "$0" in
	*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
	*)   MODDIR=$(pwd) ;;
esac
[ -n "$MODDIR" ] && [ -f "$MODDIR/constant.sh" ] || MODDIR=/data/adb/modules/smartdns
[ -f "$MODDIR/constant.sh" ] || {
	echo "找不到模块目录，无法继续（MODDIR=$MODDIR）" >&2
	exit 1
}

. "$MODDIR/constant.sh"
. "$MODDIR/rules.sh"

CONF="$DATA_INTERNAL_DIR/smartdns.conf"
CORE_BIN="$CORE_INTERNAL_DIR/$CORE_NAME"
WEBUI_BAK="$CONF.webui.bak"
FACTORY_CONF="$MODDIR/defaults/smartdns.conf"
CHECK_CONF="$DATA_INTERNAL_DIR/.webui-check.conf"
TMP_PREFIX="${TMP_PREFIX:-/data/local/tmp/smartdns-webui}"

err() {
	echo "$*" >&2
	exit 1
}

### 基础工具 ###

# 定位可用的 base64 实现
B64=''
init_b64() {
	[ -n "$B64" ] && return 0
	if command -v base64 >/dev/null 2>&1; then
		B64='base64'
	elif command -v busybox >/dev/null 2>&1; then
		B64='busybox base64'
	elif command -v toybox >/dev/null 2>&1; then
		B64='toybox base64'
	else
		err '设备缺少 base64 命令，无法与 WebUI 传输文件内容'
	fi
	return 0
}

b64_enc_file() {
	init_b64
	$B64 < "$1" 2>/dev/null
}

b64_dec_to() {
	init_b64
	printf '%s' "$1" | $B64 -d > "$2" 2>/dev/null
}

# 读取模块参数（默认值 + 用户配置）
load_conf() {
	[ -f "$MODDIR/defaults.sh" ] && . "$MODDIR/defaults.sh"
	[ -f "$SCRIPT_CONF" ] && . "$SCRIPT_CONF"
	: "${Main_PORT:=6053}"
	: "${Second_PORT:=}"
	: "${MODE:=local}"
	: "${TUN:=yes}"
	: "${WLAN:=no}"
	: "${DATA:=no}"
	: "${PKG:=}"
	: "${IP6T_BLOCK:=yes}"
	: "${log:=no}"
	: "${language:=zh-CN}"
	return 0
}

module_prop() {
	grep "^$1=" "$MODDIR/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-
}

# 真正在跑的管理器（不能靠 WebUI 里的全局对象名字猜：Magisk 也提供 ksu 兼容对象）
manager_ver() {
	local v=''
	if command -v magisk >/dev/null 2>&1; then
		v=$(magisk -v 2>/dev/null | head -n 1)
		v=${v%%:*}
		[ -n "$v" ] && { echo "Magisk $v"; return 0; }
	fi
	if command -v ksud >/dev/null 2>&1; then
		v=$(ksud -V 2>/dev/null | head -n 1)
		v=${v%%:*}
		[ -n "$v" ] && { echo "KernelSU $v"; return 0; }
	fi
	if command -v apd >/dev/null 2>&1; then
		v=$(apd -V 2>/dev/null | head -n 1)
		v=${v%%:*}
		[ -n "$v" ] && { echo "APatch $v"; return 0; }
	fi
	echo '未知'
	return 0
}

core_version() {
	[ -x "$CORE_BIN" ] || return 0
	"$CORE_BIN" -v 2>/dev/null | awk '{print $2}'
}

is_running() {
	pidof "$CORE_NAME" >/dev/null 2>&1
}

# 与 command.sh 的 iptrules_check 保持一致的判定
# 端口为空时不拼进正则（空分支会让任意 REDIRECT 命中），并锚定 --to-ports
ipt_active() {
	local p1="$1" p2="$2"
	[ -n "$p1" ] || return 1
	if [ -n "$p2" ] && [ "$p2" != "$p1" ]; then
		p1="$p1|$p2"
	fi
	iptables -t nat -S 2>/dev/null | grep -qE "REDIRECT.+--to-ports ($p1)$"
}

# 预建运行环境，避免 command.sh 首次启动时进入最长 10 分钟的联网等待
ensure_env() {
	[ -d "$WORK_DIR" ] && return 0
	mkdir -p "$CORE_DIR" "$DATA_DIR" "$LOG_DIR" "$TEMP_DIR" 2>/dev/null
	mount -o bind "$CORE_INTERNAL_DIR" "$CORE_DIR" 2>/dev/null
	mount -o bind "$DATA_INTERNAL_DIR" "$DATA_DIR" 2>/dev/null
	iptables-save > "$IPT_BAK" 2>/dev/null
	ip6tables-save > "$IP6T_BAK" 2>/dev/null
	chmod 0640 "$TEMP_DIR"/*.bak 2>/dev/null
	return 0
}

### 动作实现 ###

do_status() {
	load_conf
	local pid='' running=0 ipt=0 work=0
	if is_running; then
		running=1
		pid=$(pidof "$CORE_NAME" 2>/dev/null | awk '{print $1}')
	fi
	ipt_active "${Main_PORT}" "${Second_PORT:-$Main_PORT}" && ipt=1
	[ -d "$WORK_DIR" ] && work=1
	echo "running=$running"
	echo "pid=$pid"
	echo "mode=$MODE"
	echo "main_port=$Main_PORT"
	echo "second_port=${Second_PORT:-$Main_PORT}"
	echo "ipt=$ipt"
	echo "work_dir=$work"
	echo "core_ver=$(core_version)"
	echo "ver=$(module_prop version)"
	echo "ver_code=$(module_prop versionCode)"
	echo "arch=$(uname -m)"
	echo "conf_file=$CONF"
	echo "script_conf=$SCRIPT_CONF"
	return 0
}

do_conf() {
	load_conf
	echo "log=$log"
	echo "language=$language"
	echo "Main_PORT=$Main_PORT"
	echo "Second_PORT=$Second_PORT"
	echo "MODE=$MODE"
	echo "TUN=$TUN"
	echo "WLAN=$WLAN"
	echo "DATA=$DATA"
	echo "PKG=$PKG"
	echo "IP6T_BLOCK=$IP6T_BLOCK"
	return 0
}

# sed 替换用的转义
esc_sed() {
	printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

set_one() {
	local key="$1" val="$2" line
	case "$key" in
		Main_PORT|Second_PORT)
			if [ -n "$val" ]; then
				case "$val" in
					*[!0-9]*) err "端口只能是数字: $key=$val" ;;
				esac
				[ "$val" -ge 1 ] 2>/dev/null && [ "$val" -le 65535 ] 2>/dev/null \
					|| err "端口超出范围 (1-65535): $key=$val"
			fi
			;;
		MODE)
			case "$val" in
				local|proxy|server|local,proxy) ;;
				*) err "工作模式无效: $val" ;;
			esac
			;;
		TUN|WLAN|DATA|IP6T_BLOCK|log)
			case "$val" in
				yes|no) ;;
				*) err "开关项只能是 yes/no: $key=$val" ;;
			esac
			;;
		language)
			case "$val" in
				zh-CN|en) ;;
				*) err "语言无效: $val" ;;
			esac
			;;
		PKG)
			# 只保留包名/UID 允许的字符，避免注入到 shell 配置文件
			val=$(printf '%s' "$val" | tr -cd 'A-Za-z0-9 ._-')
			[ ${#val} -gt 512 ] && err '放行应用列表过长'
			;;
		*)
			err "不允许修改的参数: $key"
			;;
	esac

	if grep -q "^${key}=" "$SCRIPT_CONF" 2>/dev/null; then
		line=$(esc_sed "$val")
		sed -i "s|^${key}=.*|${key}='${line}'|" "$SCRIPT_CONF"
	else
		printf "%s='%s'\n" "$key" "$(printf '%s' "$val" | sed -e "s/'//g")" >> "$SCRIPT_CONF"
	fi
}

do_set() {
	[ -f "$SCRIPT_CONF" ] || err '配置文件不存在，请先启动一次服务以生成 /data/adb/smartdns/config/script_conf.sh'
	[ $# -gt 0 ] || err '缺少参数'
	local kv
	for kv in "$@"; do
		case "$kv" in
			*=*) ;;
			*) err "参数格式错误: $kv" ;;
		esac
		set_one "${kv%%=*}" "${kv#*=}"
	done
	echo 'ok=1'
	return 0
}

do_ctl() {
	local action="$1" out rc=0
	case "$action" in
		start|stop|restart|clean) ;;
		*) err "不支持的操作: $action" ;;
	esac
	[ -f "$MODDIR/command.sh" ] || err 'command.sh 缺失，请重新安装模块'

	case "$action" in
		start|restart) ensure_env ;;
	esac

	case "$action" in
		restart)
			# 两段的退出码必须分开取：以前这里 rc 取的是 stop 的，
			# 而 stop 现在恒返回 0 —— 结果 start 失败也报「重启完成」。
			out=$(sh "$MODDIR/command.sh" stop 2>&1)
			sleep 1
			out2=$(sh "$MODDIR/command.sh" start 2>&1)
			rc=$?
			out="$out
$out2"
			;;
		*)
			out=$(sh "$MODDIR/command.sh" "$action" 2>&1); rc=$?
			;;
	esac

	# command.sh 的部分分支会以非 0 退出（例如 status），这里只透传实际结果
	init_b64
	echo "rc=$rc"
	printf 'b64='
	# 两层 base64 会把体积放大到 1.8 倍，而某些管理器的 exec 对回包长度有限制，
	# 超了就会被截断——表现就是按钮「未知错误」、第二次又好了。
	# 前端只用最后一行做提示，这里只带回尾部 20 行，把体积压下来。
	printf '%s' "$out" | tail -n 20 | $B64 | tr -d '\n'
	echo
	[ "$rc" -eq 0 ] || exit 0
	return 0
}

# 文件名白名单 -> 实际路径
resolve_path() {
	case "$1" in
		smartdns.conf) echo "$CONF" ;;
		script_conf.sh) echo "$SCRIPT_CONF" ;;
		server.log) echo "$LOG_DIR/smartdns.log" ;;
		audit.log) echo "$LOG_DIR/smartdns-audit.log" ;;
		core.log) echo "$LOG_DIR/core.log" ;;
		script.log) echo "$MODDIR/script.log" ;;
		boot.log) echo "$MODDIR/boot.log" ;;
		*) return 1 ;;
	esac
}

do_cat() {
	local f
	f=$(resolve_path "$1") || err "不允许读取该文件: $1"
	[ -f "$f" ] || err "文件不存在: $1"
	b64_enc_file "$f"
	return 0
}

do_tail() {
	local f n="${2:-300}"
	f=$(resolve_path "$1") || err "不允许读取该文件: $1"
	case "$n" in
		''|*[!0-9]*) n=300 ;;
	esac
	[ "$n" -gt 5000 ] && n=5000
	# /dev/smartdns 是 tmpfs，重启后由 initTask 重建；万一目录没建起来，
	# 日志自然也不会存在，这里顺手补一下
	mkdir -p "$LOG_DIR" 2>/dev/null
	if [ ! -f "$f" ]; then
		# 日志"还没生成"是最常见的正常状态（审计日志默认就是关的），
		# 不该当成读取错误抛出去。直接把原因和处理办法写进日志框。
		log_missing_hint "$1"
		return 0
	fi
	init_b64
	tail -n "$n" "$f" 2>/dev/null | $B64
	return 0
}

# 日志文件不存在时给一段人话说明；输出的是纯文本，前端会原样显示
log_missing_hint() {
	load_conf
	case "$1" in
		server.log)
			echo "服务日志还没有生成：$LOG_DIR/smartdns.log"
			echo
			if grep -q '^[[:space:]]*log-file' "$CONF" 2>/dev/null; then
				echo "配置里已经有 log-file 指令，但文件还不存在，常见原因："
				echo "  1. 服务改过配置后没有重启（重启后才会按新配置写日志）"
				echo "  2. 内核启动失败，压根没跑起来 —— 切到「内核输出」看它报了什么"
				echo "  3. 没写 log-level（或写成了 off）：内核默认不产生任何日志，连文件都不建。"
				echo "     模块启动时会自动补一个 log-level info，重启一次服务即可。"
				echo
				echo "配置里现在指向：$(grep -m1 '^[[:space:]]*log-file' "$CONF" 2>/dev/null | awk '{print $2}')"
				echo "本模块使用的日志目录：$LOG_DIR"
			else
				echo "smartdns.conf 里没有 log-file 指令，内核不会写日志。"
				echo "到「DNS 配置」里加一行（保存后重启服务）："
				echo "  log-file $LOG_DIR/smartdns.log"
			fi
			;;
		audit.log)
			echo "审计日志默认是关闭的：$LOG_DIR/smartdns-audit.log 不存在。"
			echo
			echo "到「DNS 配置」里把这两行取消注释（保存后重启服务）："
			echo "  audit-enable yes"
			echo "  audit-file $LOG_DIR/smartdns-audit.log"
			echo
			echo "审计日志会记录每一次查询，写盘量比较大，排查完建议再关掉。"
			;;
		core.log)
			echo "内核还没有输出：$LOG_DIR/core.log"
			echo
			echo "这个文件是内核的 stdout/stderr，每次启动都会被重写。"
			echo "它不存在通常意味着服务还没启动过 —— 先点「状态 → 启动」，再看这里。"
			;;
		script.log)
			echo "脚本日志当前是关闭的（log=$log），所以没有 $RUN_LOG。"
			echo
			echo "到「运行参数」里打开「脚本日志」并保存，重启服务后开始记录。"
			;;
		boot.log)
			echo "本次开机还没有产生开机日志（$BOOT_LOG）。"
			echo
			echo "service.sh 在开机时写入；如果刚开机就没起来，重启一次再看。"
			;;
		*)
			echo "文件不存在: $1"
			;;
	esac
	return 0
}

do_put() {
	local name="$1" b64="$2" tmp
	[ "$name" = 'smartdns.conf' ] || err "不允许写入该文件: $name"
	[ -n "$b64" ] || err '内容为空'

	tmp="$TMP_PREFIX.$$"
	b64_dec_to "$b64" "$tmp" || { rm -f "$tmp"; err '内容解码失败'; }
	[ -s "$tmp" ] || { rm -f "$tmp"; err '解码后内容为空，已放弃写入'; }
	grep -q '^bind' "$tmp" || { rm -f "$tmp"; err '配置中未找到 bind 指令，疑似内容不完整，已放弃写入'; }

	# 同一端口同时 bind [::]:P 和 0.0.0.0:P，在 Android 上必然 Address in use：
	# IPv6 默认双栈，[::] 已经把 IPv4 一起占了。内核起来就退出，但旧版启动检测
	# 会误报"成功"。这里在保存阶段直接拦掉，比事后翻日志友好。
	local dup
	dup=$(awk '
		function proto(s) {
			if (s ~ /^[ \t]*bind-tcp/) return "tcp"
			if (s ~ /^[ \t]*bind-tls/) return "tls"
			return "udp"
		}
		/^[ \t]*bind(-tcp|-tls)?[ \t]/ {
			a = $2; p = proto($0); port = a
			sub(/^.*:/, "", port)
			sub(/@.*$/, "", port)
			if (port == "") next
			if (a ~ /^\[::\]:/)          v6[p ":" port] = 1
			else if (a ~ /^0\.0\.0\.0:/) v4[p ":" port] = 1
		}
		END {
			for (k in v6) if (k in v4) { sub(/^[a-z]*:/, "", k); print k; exit }
		}
	' "$tmp")
	if [ -n "$dup" ]; then
		rm -f "$tmp"
		err "配置里 [::]:$dup 与 0.0.0.0:$dup 同时 bind，Android 下 IPv6 是双栈，内核会报 Address in use。二选一即可（推荐只保留 bind [::]:$dup）。"
	fi

	# 校验通过后才覆盖备份，避免一次失败写入把上一版备份也弄丢
	[ -f "$CONF" ] && cp -f "$CONF" "$WEBUI_BAK"

	cat "$tmp" > "$CONF"
	rm -f "$tmp"
	chmod 0644 "$CONF" 2>/dev/null
	chown 0:1001 "$CONF" 2>/dev/null
	echo 'ok=1'
	return 0
}

# 备份有两个来源：WebUI 保存时生成的 .webui.bak，以及模块启动自愈时留下的 .bak。
# 只认前一个的话，刚装好还没在界面上保存过时，「关于」显示"暂无"、还原按钮直接报错。
conf_bak_file() {
	if [ -f "$WEBUI_BAK" ]; then
		echo "$WEBUI_BAK"
	elif [ -f "$CONF.bak" ]; then
		echo "$CONF.bak"
	fi
}

do_restore() {
	local bak
	bak=$(conf_bak_file)
	[ -n "$bak" ] || err '没有可还原的备份'
	[ -f "$CONF" ] && cp -f "$CONF" "$TMP_PREFIX.cur" && mv -f "$TMP_PREFIX.cur" "$CONF.rollback"
	cat "$bak" > "$CONF"
	chmod 0644 "$CONF" 2>/dev/null
	chown 0:1001 "$CONF" 2>/dev/null
	echo 'ok=1'
	return 0
}

do_factory() {
	[ -f "$FACTORY_CONF" ] || err '模块内未找到出厂配置模板'
	[ -f "$CONF" ] && cp -f "$CONF" "$WEBUI_BAK"
	cp -f "$FACTORY_CONF" "$CONF"
	chmod 0644 "$CONF" 2>/dev/null
	chown 0:1001 "$CONF" 2>/dev/null
	echo 'ok=1'
	return 0
}

# 语法/启动检查：服务需停止，临时配置放在配置目录内以保证相对 conf-file 路径可解析
# 可选参数 $1 = base64 的配置内容：编辑器里还没保存的版本也能直接测，
# 否则测的就是磁盘上当前这份 smartdns.conf。
do_check() {
	local b64="${1:-}" src="$CONF" tmp='' out rc
	command -v timeout >/dev/null 2>&1 || err '设备缺少 timeout 命令，无法执行配置测试'
	is_running && err '服务正在运行，请先停止服务后再测试配置'
	[ -f "$CONF" ] || err '配置文件不存在'

	if [ -n "$b64" ]; then
		tmp="$DATA_INTERNAL_DIR/.webui-check-src.conf"
		if ! b64_dec_to "$b64" "$tmp" || [ ! -s "$tmp" ]; then
			rm -f "$tmp"
			err '待测试的内容解码失败或为空'
		fi
		grep -q '^bind' "$tmp" 2>/dev/null || { rm -f "$tmp"; err '待测试的配置里没有 bind 指令，疑似内容不完整'; }
		src="$tmp"
	fi

	ensure_env
	printf 'conf-file ./%s\nlog-console yes\nlog-level info\n' "${src##*/}" > "$CHECK_CONF"
	local tz
	tz=$(core_tz 2>/dev/null)
	[ -n "$tz" ] && export TZ="$tz"
	out=$(cd "$DATA_INTERNAL_DIR" && timeout 8 "$CORE_BIN" -c "$CHECK_CONF" -f -p - 2>&1)
	rc=$?
	rm -f "$CHECK_CONF" "$tmp"

	init_b64
	echo "rc=$rc"
	printf 'b64='
	# 必须压成一行：前端按 key=value 逐行解析，base64 默认每 76 字符折行，
	# 折行后 b64= 只剩第一行，长输出（配置测试的内核日志）就会被截掉。
	printf '%s' "$out" | $B64 | tr -d '\n'
	echo
	return 0
}

do_upstream() {
	local tool='' latest=''
	if command -v curl >/dev/null 2>&1; then
		tool='curl -s --max-time 10'
	elif command -v busybox >/dev/null 2>&1 && busybox wget --help >/dev/null 2>&1; then
		tool='busybox wget -q -O - -T 10'
	else
		err '设备上没有 curl 或 busybox wget，无法查询上游版本'
	fi

	latest=$($tool https://api.github.com/repos/pymumu/smartdns/releases/latest 2>/dev/null | grep -o '"tag_name"[^"]*"[^"]*"' | head -n 1 | sed -e 's/.*"\([^"]*\)"$/\1/')
	[ -n "$latest" ] || err '查询上游版本失败（网络不可达或 API 限流）'
	echo "latest=$latest"
	echo "current=$(core_version)"
	return 0
}

do_info() {
	echo "module_path=$MODDIR"
	echo "data_path=$DATA_INTERNAL_DIR"
	echo "script_path=$SCRIPT_INTERNAL_DIR"
	echo "manager=$(manager_ver)"
	echo "core_ver=$(core_version)"
	echo "ver=$(module_prop version)"
	echo "ver_code=$(module_prop versionCode)"
	echo "author=$(module_prop author)"
	echo "update_json=$(module_prop updateJson)"
	echo "arch=$(uname -m)"
	echo "kernel=$(uname -r)"
	echo "android=$(getprop ro.build.version.release 2>/dev/null)"
	local bak
	bak=$(conf_bak_file)
	[ -n "$bak" ] && echo "backup_time=$(date -r "$bak" '+%Y-%m-%d %H:%M' 2>/dev/null)"
	echo 'ok=1'
	return 0
}

### 入口 ###

action="$1"
[ -n "$action" ] || err '缺少动作参数'
shift 2>/dev/null

### 规则源 ###

# 用户可编辑的三份文件（hosts 与自定义黑白名单）
rules_user_file() {
	case "$1" in
		hosts) echo "$RULES_LOCAL_HOSTS" ;;
		block) echo "$RULES_OUT/user-block.conf" ;;
		allow) echo "$RULES_OUT/user-allow.conf" ;;
		*) return 1 ;;
	esac
}

do_rules() {
	local cmd="$1" which f tmp target changed id old_en
	rules_init >/dev/null 2>&1
	init_b64

	case "$cmd" in
		list)
			# running=1 表示后台更新任务还在跑，前端据此轮询
			if rules_job_alive; then
				echo 'running=1'
			else
				echo 'running=0'
			fi
			# 状态用 | 分隔，前端直接拆：id|type|url|interval|enabled|at|status|lines|last|msg|bin
			printf 'b64_list='
			rules_status | $B64 | tr -d '\n'
			echo
			# 合并结果。条数以 merged.conf 的实际行数为准（stats 可能落后一步：
			# 统计写失败时规则文件已经替换过了），其余取 merged.stats。
			if [ -s "$RULES_OUT/merged.conf" ]; then
				echo "merged_kept=$(wc -l < "$RULES_OUT/merged.conf" | tr -d ' \t')"
				if [ -f "$RULES_OUT/merged.stats" ]; then
					while IFS='=' read -r k v; do
						case "$k" in
							total|removed|conflict|sources|time) echo "merged_$k=$v" ;;
						esac
					done < "$RULES_OUT/merged.stats"
				fi
			else
				echo 'merged_kept=0'
			fi
			;;
		log)
			printf 'b64='
			[ -f "$LOG_DIR/rules.log" ] && tail -n "${2:-120}" "$LOG_DIR/rules.log" | $B64 | tr -d '\n'
			echo
			;;
		file)
			f=$(rules_user_file "${2:-}") || err '未知文件，可选: hosts / block / allow'
			printf 'b64='
			[ -f "$f" ] && cat "$f" | $B64 | tr -d '\n'
			echo
			;;
		putfile)
			which="${2:-}"
			f=$(rules_user_file "$which") || err '未知文件，可选: hosts / block / allow'
			[ -n "${3:-}" ] || err '内容为空'
			mkdir -p "$(dirname "$f")" 2>/dev/null
			tmp="$TMP_PREFIX.$$"
			b64_dec_to "$3" "$tmp" || { rm -f "$tmp"; err '内容解码失败'; }
			# 允许写空文件：清空用户规则是合法操作
			cat "$tmp" > "$f" || { rm -f "$tmp"; err '写入失败'; }
			rm -f "$tmp"
			chmod 0644 "$f" 2>/dev/null
			echo 'ok=1'
			# 写完立即转换并重载，否则用户点了保存还得再点一次「更新」才生效
			# —— 3.5.0 就是这样，保存完看着成功、规则却没动。
			# 只写文件不动内核的话，界面上"已保存"和"已生效"是两回事。
			changed=0
			case "$which" in
				hosts)
					rules_update_local_hosts >/dev/null 2>&1
					[ $? -eq 0 ] && changed=1
					;;
				*)
					rules_gen_index >/dev/null 2>&1
					changed=1
					;;
			esac
			# 重载放后台：桥接 exec 是同步的，前台重启内核会把自己这个会话一起杀掉
			if [ "$changed" = '1' ]; then
				setsid sh -c "sh '$MODDIR/command.sh' start >/dev/null 2>&1" >/dev/null 2>&1 &
			fi
			;;
		update)
			target="${2:-all}"
			rules_job_alive && err '已有更新任务在进行，请等它结束'
			[ "$target" != 'all' ] && ! rules_src_exists "$target" && err "未知的源: $target"
			mkdir -p "$RULES_STATE" "$LOG_DIR" 2>/dev/null
			: > "$RULES_STATE/.running"
			: > "$LOG_DIR/rules.log"
			# 更新要下载 + 转换几十万行，可能超过桥接 exec 的超时，
			# 所以放后台跑（setsid 脱离会话，前端轮询 running 状态）
			setsid sh -c "sh '$MODDIR/command.sh' rulesrc update '$target' >> '$LOG_DIR/rules.log' 2>&1; rm -f '$RULES_STATE/.running'" >/dev/null 2>&1 &
			echo 'started=1'
			;;
		add)
			# add <id> <type> <url> <interval> <enabled> [at]
			rules_add_source "${2:-}" "${3:-}" "${4:-}" "${5:-0}" "${6:-1}" "${7:-}" >/dev/null 2>&1
			case "$?" in
				0) echo 'ok=1' ;;
				2) err '同名规则源已存在' ;;
				*) err "参数不合法：名称只能用字母、数字、连字符；类型必须是 $RULES_TYPES；地址不能含空格；时间格式 HH:MM 或 w1-HH:MM 或 m15-HH:MM" ;;
			esac
			;;
		del)
			id="${2:-}"
			rules_is_builtin "$id" && err "「$id」是内置规则源，不能删除（可以停用它）"
			rules_src_exists "$id" || err "规则源不存在: $id"
			rules_del_source "$id" >/dev/null 2>&1
			case "$?" in
				0) echo 'ok=1' ;;
				3) err '内置规则源不允许删除' ;;
				*) err '删除失败' ;;
			esac
			# 索引已重建，但内核只在启动时读配置，必须重启才真的生效
			setsid sh -c "sh '$MODDIR/command.sh' start >/dev/null 2>&1" >/dev/null 2>&1 &
			;;
		set)
			# set <id> <interval> <enabled> [at] [url] [type]
			# at 传 - 表示清掉定点时间
			id="${2:-}"
			old_en=$(rules_src_field "$id" 5)
			rules_set_source "$id" "${3:-0}" "${4:-1}" "${5:-}" "${6:-}" "${7:-}" >/dev/null 2>&1
			case "$?" in
				0) echo 'ok=1' ;;
				1) err "未知的规则源: $id" ;;
				*) err '参数不合法：间隔为小时数（0=手动），enabled 为 0/1，时间为 HH:MM / w1-HH:MM / m15-HH:MM' ;;
			esac
			# 合并文件由 rules_set_source 按需重建，只有"是否启用"变过才需要重启内核
			if [ "$old_en" != "${4:-1}" ]; then
				setsid sh -c "sh '$MODDIR/command.sh' start >/dev/null 2>&1" >/dev/null 2>&1 &
			fi
			;;
		reload)
			# 用户规则改完后重建索引并重载内核（不下载任何东西，很快）
			rules_regen
			# 重启必须放后台：command.sh start 会停掉旧内核，前台跑的话
			# 连当前这个桥接会话一起被杀，echo ok=1 永远回不去 ——
			# 前端看到的现象就是"点了没反应/未知错误"。
			setsid sh -c "sh '$MODDIR/command.sh' start >/dev/null 2>&1" >/dev/null 2>&1 &
			echo 'ok=1'
			;;
		*)
			err '用法: rules <list|log|file|putfile|update|add|del|set|reload>'
			;;
	esac
	return 0
}

case "$action" in
	status)   do_status ;;
	conf)     do_conf ;;
	set)      do_set "$@" ;;
	ctl)      do_ctl "$@" ;;
	cat)      do_cat "$@" ;;
	tail)     do_tail "$@" ;;
	put)      do_put "$@" ;;
	restore)  do_restore ;;
	factory)  do_factory ;;
	check)    do_check "$@" ;;
	upstream) do_upstream ;;
	info)     do_info ;;
	rules)    do_rules "$@" ;;
	*)        err "未知动作: $action" ;;
esac
