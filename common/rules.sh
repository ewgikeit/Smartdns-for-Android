#!/system/bin/sh
# 规则源管理器
#
# 背景：原来规则表（block / ip / domain_diverg）是随包下发的静态快照，
# 路径写死在 smartdns.conf 里，想更新只能等模块发版。这一层把"规则"
# 变成可配置的源：每个源有自己的地址、类型、刷新节奏，落地成
# config/rules/*.conf 由内核加载。
#
# 数据流：
#   rulesrc/sources.conf  ──┐
#   rulesrc/local.hosts   ──┤  抓取 → 转换 → 校验 → 原子替换
#   远程 URL              ──┘                              ↓
#                                          config/rules/auto-<id>.conf
#                                                        ↓ 跨源合并去重
#                                          config/rules/merged.conf
#                                                        ↓
#                                          config/rules/index.conf（汇总）
#                                                        ↓
#                                            smartdns.conf 只引用 index.conf
#
# 设计约束（都是踩过的坑换来的）：
#   · 不依赖 crond：调度挂在 command.sh 的 watch 循环里，少一个进程少一处失败点
#   · 不依赖 conf-file 的通配符：生成固定文件名，任何内核版本都稳
#   · 先写 .tmp 再 mv：更新中途断电不会留下半个规则文件
#   · 只有内容真的变了才重启内核：避免每轮更新都把 DNS 抖一下

RULES_TYPES='domain-block domain-cn domain-foreign ip-whitelist ip-blacklist hosts'

# 内置源：随包下发的规则表（seed/）+ 本地 hosts。删掉它们内核就只剩 upstream 可用，
# 所以 WebUI 里不给删除按钮，后端也再挡一次（前端能改，后端不能信前端）。
RULES_BUILTIN='anti-ad chnroute chnlist gfwlist local-hosts'

rules_is_builtin() {
	case " $RULES_BUILTIN " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# at 的格式（值里不能有空格：sources.conf 是按空格分列的）：
#   HH:MM        每天
#   w1-HH:MM     每周一（w1..w7，周一=1、周日=7，与 date +%u 一致）
#   m15-HH:MM    每月 15 日（该月没有这一天就跳过，比如 m31 的 2 月）
rules_valid_at() {
	local spec='' hm="$1"
	case "$1" in
		*-*) spec="${1%%-*}"; hm="${1#*-}" ;;
	esac
	case "$hm" in
		[0-2][0-9]:[0-5][0-9]) ;;
		*) return 1 ;;
	esac
	[ "$((10#${hm%%:*}))" -le 23 ] || return 1
	case "$spec" in
		'') return 0 ;;
		w[1-7]) return 0 ;;
		m[1-9]|m1[0-9]|m2[0-9]|m3[01]) return 0 ;;
	esac
	return 1
}

# 到期判断抽成纯函数：$1=at $2=当前 HH:MM $3=星期(1-7) $4=日(01-31)
# 独立出来才好测 —— rules_due 依赖系统时间，没法规造"今天是周几"。
rules_at_match() {
	local at="$1" now_hm="$2" wd="$3" dom="$4"
	local spec='' hm="$at"
	case "$at" in
		*-*) spec="${at%%-*}"; hm="${at#*-}" ;;
	esac
	[ "$hm" = "$now_hm" ] || return 1
	case "$spec" in
		'') return 0 ;;
		w*) [ "${spec#w}" = "$wd" ] || return 1 ;;
		m*) [ "$((10#${spec#m}))" = "$((10#$dom))" ] || return 1 ;;
		*) return 1 ;;
	esac
	return 0
}

### 路径与初始化 ----------------------------------------------------------

rules_dir_init() {
	mkdir -p "$RULESRC_DIR" "$RULES_CACHE" "$RULES_STATE" "$RULES_SEED" "$RULES_OUT" 2>/dev/null
	return 0
}

# 首次使用生成默认源清单。seed/* 是包内自带的三张大表的副本，
# 把它们也当"本地源"，这样「内置规则」和「在线规则」走完全相同的代码路径，
# 不用为内置表维护一套特例。
rules_write_defaults() {
	local seed_block="$RULES_SEED/block-defaults.conf"
	local seed_chn="$RULES_SEED/domain-chnlist.txt"
	local seed_gfw="$RULES_SEED/domain-gfwlist.txt"
	{
		printf '# 规则源清单\n'
		printf '# 每行一个源，字段用空格分隔，形如 key=value\n'
		printf '#   id       唯一标识（同时是生成的文件名，只能用字母数字和连字符）\n'
		printf '#   type     %s\n' "$RULES_TYPES"
		printf '#   url      https://... 或 /绝对路径 或 seed/<文件名> 或 system（读 /system/etc/hosts）\n'
		printf '#   interval 刷新间隔（小时），0 表示只手动更新\n'
		printf '#   at       可选，改成定点更新，与 interval 二选一：\n'
		printf '#              HH:MM      每天这个时间\n'
		printf '#              w1-HH:MM   每周一（w1..w7，周一=1、周日=7）\n'
		printf '#              m15-HH:MM  每月 15 日\n'
		printf '#   enabled  1 启用 / 0 停用\n'
		printf '#\n'
		printf '# 内置规则表（离线可用，随模块更新）\n'
		printf 'id=anti-ad type=domain-block url=seed/block-defaults.conf interval=168 enabled=1\n'
		printf 'id=chnroute type=ip-whitelist url=seed/ip-chnroute.txt interval=168 enabled=1\n'
		printf 'id=chnlist type=domain-cn url=seed/domain-chnlist.txt interval=168 enabled=1\n'
		printf 'id=gfwlist type=domain-foreign url=seed/domain-gfwlist.txt interval=0 enabled=1\n'
		printf '#\n'
		printf '# 在线 hosts 源（域名 -> IP）\n'
		printf 'id=github520 type=hosts url=https://raw.hellogithub.com/hosts interval=6 enabled=1\n'
		printf 'id=steam520 type=hosts url=https://cdn.jsdelivr.net/gh/pboymt/Steam520/hosts interval=0 enabled=0\n'
		printf '#\n'
		printf '# 本地 hosts：WebUI 里编辑，或者直接改 rulesrc/local.hosts\n'
		printf 'id=local-hosts type=hosts url=%s interval=0 enabled=1\n' "$RULES_LOCAL_HOSTS"
	} > "$RULES_SOURCES"
	[ -s "$seed_block" ] || return 0
	return 0
}

rules_init() {
	rules_dir_init
	if [ ! -f "$RULES_SOURCES" ]; then
		rules_write_defaults
	fi
	# 本地 hosts 必须存在，否则 local-hosts 这个源第一次就会报错
	[ -f "$RULES_LOCAL_HOSTS" ] || {
		{
			printf '# 本地 hosts\n'
			printf '# 格式与原样 hosts 一致：IP 域名（域名可以一行写多个）\n'
			printf '# 例：\n'
			printf '#   192.168.1.10 nas.lan nas\n'
			printf '#   0.0.0.0 ads.example.com\n'
			printf '# 改动后到「规则」页点「立即更新」，或执行 sh command.sh rules update local-hosts\n'
		} > "$RULES_LOCAL_HOSTS"
	}
	return 0
}

### 源清单解析 ------------------------------------------------------------

# 规范化输出：id <TAB> type <TAB> url <TAB> interval <TAB> enabled <TAB> at
# 用 substr 而不是 split("=")，因为 URL 的 query 里带等号很常见
rules_list_sources() {
	[ -f "$RULES_SOURCES" ] || return 0
	awk '
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*$/ { next }
	{
		id = ""; type = ""; url = ""; intv = "0"; en = "1"; at = ""
		for (i = 1; i <= NF; i++) {
			if ($i ~ /^id=/)            id   = substr($i, 4)
			else if ($i ~ /^type=/)     type = substr($i, 6)
			else if ($i ~ /^url=/)      url  = substr($i, 5)
			else if ($i ~ /^interval=/) intv = substr($i, 10)
			else if ($i ~ /^enabled=/)  en   = substr($i, 9)
			else if ($i ~ /^at=/)       at   = substr($i, 4)
		}
		if (id == "" || type == "" || url == "") next
		printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, type, url, intv, en, at
	}' "$RULES_SOURCES"
}

rules_src_field() {
	# $1=id $2=字段序号(2=type 3=url 4=interval 5=enabled 6=at)
	rules_list_sources | awk -F'\t' -v id="$1" -v n="$2" '$1 == id { print $n; exit }'
}

rules_src_exists() {
	[ -n "$(rules_src_field "$1" 2)" ]
}

### 抓取 ------------------------------------------------------------------

# 把源解析成一个可读的本地文件路径。
# 支持：http(s) 下载、绝对路径、seed/ 与 cache/ 相对路径、system
# 本地源的真实路径。seed/ 和绝对路径都落在这里，system 特指系统 hosts。
# 单独抽出来是为了让调用方能"直接读原文件"，不必先复制一份到 cache ——
# 以前 seed 的 5 MB 会在 cache 里再存一份，等于凭空多占一倍。
rules_local_path() {
	local url="$1" src=''
	case "$url" in
		system) src='/system/etc/hosts' ;;
		/*) src="$url" ;;
		*) src="$RULESRC_DIR/$url" ;;
	esac
	[ -f "$src" ] || return 1
	printf '%s' "$src"
	return 0
}

# 只负责远程下载。本地源走 rules_local_path，不再经过这里。
rules_fetch() {
	# $1=url  $2=输出文件
	local url="$1" out="$2" try
	case "$url" in
		http://*|https://*) ;;
		*) return 1 ;;
	esac
	rm -f "$out"
	if command -v curl >/dev/null 2>&1; then
		for try in 1 2 3; do
			curl -fsSL --connect-timeout 15 --max-time 180 -o "$out" "$url" 2>/dev/null && break
			[ "$try" = 3 ] && return 1
			sleep 2
		done
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" --timeout=180 "$url" 2>/dev/null || return 1
	else
		return 1
	fi
	[ -s "$out" ]
}

### 转换器 ----------------------------------------------------------------
# 统一约定：stdin 无关，$1 输入文件，结果打到 stdout。
# 都要能吃掉 Windows 换行和 BOM —— 在线列表里这两样都很常见。

# 域名 -> 直接返回空地址（屏蔽）
conv_domain_block() {
	awk '
	{ sub(/\r$/, ""); sub(/^\357\273\277/, "") }
	/^[[:space:]]*$/ { next }
	/^[[:space:]]*#/ { next }
	# 已经是 smartdns 语法，原样保留
	/^[[:space:]]*address[[:space:]]+\// { print; next }
	{
		for (i = 1; i <= NF; i++) {
			d = $i
			if (d ~ /^#/) break
			if (d ~ /^\//) { gsub(/^\//, "", d); sub(/\/.*$/, "", d) }
			if (d == "") continue
			# 纯 IP 不是域名：hosts 格式的第一列会走到这里
			if (d ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
			if (d ~ /:/) continue
			if (d !~ /\./) continue
			print "address /" d "/#"
		}
	}' "$1" | sort -u
}

# 域名 -> 走国内组
conv_domain_cn() {
	awk '
	{ sub(/\r$/, ""); sub(/^\357\273\277/, "") }
	/^[[:space:]]*$/ { next }
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*nameserver[[:space:]]+\// { print; next }
	{
		for (i = 1; i <= NF; i++) {
			d = $i
			if (d ~ /^#/) break
			if (d ~ /^\//) { gsub(/^\//, "", d); sub(/\/.*$/, "", d) }
			if (d == "") continue
			if (d ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
			if (d ~ /:/) continue
			if (d !~ /\./) continue
			print "nameserver /" d "/China"
		}
	}' "$1" | sort -u
}

# 域名 -> 走国外组并打 ipset 标记（给代理分流用）
# 测速一律 none：被墙的 IP 基本不回 ICMP/TCP，ping 只会把上游返回的有效答案整批
# 丢掉（真机实测：www.google.com 拿到 8 个 142.251.x 的答案，ping 全 timeout，
# 最终返回 SERVFAIL）。境外域名的 IP 选择交给客户端或代理自己挑。
conv_domain_foreign() {
	awk '
	{ sub(/\r$/, ""); sub(/^\357\273\277/, "") }
	/^[[:space:]]*$/ { next }
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*domain-rules[[:space:]]+\// {
		gsub(/-speed-check-mode[[:space:]]+[^ ]+/, "-speed-check-mode none")
		print; next
	}
	{
		for (i = 1; i <= NF; i++) {
			d = $i
			if (d ~ /^#/) break
			if (d ~ /^\//) { gsub(/^\//, "", d); sub(/\/.*$/, "", d) }
			if (d == "") continue
			if (d ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) continue
			if (d ~ /:/) continue
			if (d !~ /\./) continue
			print "domain-rules /" d "/ -speed-check-mode none -nameserver foreign -ipset gfwlist"
		}
	}' "$1" | sort -u
}

# 网段 -> 白名单
conv_ip_whitelist() {
	awk '
	{ sub(/\r$/, ""); sub(/^\357\273\277/, "") }
	/^[[:space:]]*$/ { next }
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*whitelist-ip[[:space:]]/ { print; next }
	{
		ip = $1
		if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ && ip !~ /^[0-9a-fA-F:]+\/[0-9]+$/) next
		print "whitelist-ip " ip
	}' "$1" | sort -u
}

# 网段 -> 黑名单
conv_ip_blacklist() {
	awk '
	{ sub(/\r$/, ""); sub(/^\357\273\277/, "") }
	/^[[:space:]]*$/ { next }
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*blacklist-ip[[:space:]]/ { print; next }
	{
		ip = $1
		if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ && ip !~ /^[0-9a-fA-F:]+\/[0-9]+$/) next
		print "blacklist-ip " ip
	}' "$1" | sort -u
}

# hosts -> address /域名/IP
# 关键点：
#   · 一行可以写多个域名（0.0.0.0 a.com b.com c.com），都要展开
#   · 行尾 # 注释要截断，不能把注释当域名
#   · 0.0.0.0 与 :: 不是有效主机地址，出现在屏蔽类 hosts 里表示"干掉它"，
#     直接转成 # 比返回 0.0.0.0 更干净（有些客户端会对 0.0.0.0 重试）
#   · 127.0.0.1 / ::1 保留原样，用户可能真的指向本机服务
conv_hosts() {
	awk '
	{ sub(/\r$/, ""); sub(/^\357\273\277/, "") }
	/^[[:space:]]*$/ { next }
	/^[[:space:]]*#/ { next }
	{
		ip = $1
		if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip !~ /^[0-9a-fA-F:]+$/) next
		blocked = (ip == "0.0.0.0" || ip == "::")
		for (i = 2; i <= NF; i++) {
			d = $i
			if (d ~ /^#/) break
			if (d == "") continue
			if (d !~ /\./ && d !~ /^[0-9a-fA-F:]+$/) continue
			if (blocked) print "address /" d "/#"
			else        print "address /" d "/" ip
		}
	}' "$1" | sort -u
}

rules_conv() {
	# $1=type $2=输入 $3=输出
	case "$1" in
		domain-block)   conv_domain_block   "$2" > "$3" ;;
		domain-cn)      conv_domain_cn      "$2" > "$3" ;;
		domain-foreign) conv_domain_foreign "$2" > "$3" ;;
		ip-whitelist)   conv_ip_whitelist   "$2" > "$3" ;;
		ip-blacklist)   conv_ip_blacklist   "$2" > "$3" ;;
		hosts)          conv_hosts          "$2" > "$3" ;;
		*) return 2 ;;
	esac
	return 0
}

# 转换结果自检：防"源挂掉返回 404 页面被当成规则写进去"这类事故。
# 只看行数与格式，不跑内核 —— 规则文件只是纯文本指令，格式对了就行。
rules_validate() {
	# $1=type $2=生成的文件
	local n bad
	[ -f "$2" ] || return 1
	n=$(wc -l < "$2" 2>/dev/null | tr -d ' \t')
	[ -n "$n" ] || return 1
	# 空结果是合法的：本地 hosts 还没填内容时就是 0 条。内核加载空 conf 也没问题。
	[ "$n" -eq 0 ] && return 0
	case "$1" in
		domain-block)   bad=$(head -200 "$2" | grep -cv '^address /' ) ;;
		domain-cn)      bad=$(head -200 "$2" | grep -cv '^nameserver /') ;;
		domain-foreign) bad=$(head -200 "$2" | grep -cv '^domain-rules /') ;;
		ip-whitelist)   bad=$(head -200 "$2" | grep -cv '^whitelist-ip ') ;;
		ip-blacklist)   bad=$(head -200 "$2" | grep -cv '^blacklist-ip ') ;;
		hosts)          bad=$(head -200 "$2" | grep -cv '^address /') ;;
		*) return 1 ;;
	esac
	# 允许极少量异形行（源里偶尔混着别的指令），但超过一半就判定为源格式变了
	[ "${bad:-0}" -le 100 ] || return 1
	return 0
}

### 状态 ------------------------------------------------------------------

rules_state_get() {
	# $1=id $2=key
	local f="$RULES_STATE/$1"
	[ -f "$f" ] || return 0
	sed -n "s/^$2=//p" "$f" 2>/dev/null | head -n 1
}

rules_state_set() {
	# $1=id 之后为 k=v 对
	# 不用 sed -i 改写：URL 里带 & 时，替换串里的 & 会被展开成"匹配到的内容"，
	# 状态就写坏了。这里统一重写整个小文件。
	local id="$1" kv k v f tmp
	shift
	f="$RULES_STATE/$id"
	tmp="$f.tmp"
	mkdir -p "$RULES_STATE" 2>/dev/null
	[ -f "$f" ] && cp -f "$f" "$tmp" || : > "$tmp"
	for kv in "$@"; do
		case "$kv" in
			*=*) ;;
			*) continue ;;
		esac
		k="${kv%%=*}"
		v="${kv#*=}"
		awk -v key="$k" 'index($0, key "=") != 1 { print }' "$tmp" > "$tmp.n"
		printf '%s=%s\n' "$k" "$v" >> "$tmp.n"
		mv -f "$tmp.n" "$tmp"
	done
	mv -f "$tmp" "$f" 2>/dev/null
	return 0
}

### 更新 ------------------------------------------------------------------

# 单源更新。返回值：0=有变化 1=无变化 2=失败
rules_update_one() {
	# $1=id  $2=force(1=忽略 enabled)
	local id="$1" force="${2:-0}"
	local type url intv en at raw out tmp old_md5 new_md5 n rc

	type=$(rules_src_field "$id" 2)
	[ -n "$type" ] || { echo "[rules] 未知源: $id"; return 2; }
	url=$(rules_src_field "$id" 3)
	intv=$(rules_src_field "$id" 4)
	en=$(rules_src_field "$id" 5)
	at=$(rules_src_field "$id" 6)

	[ -n "$en" ] || en='1'
	if [ "$force" != '1' ] && [ "$en" = '0' ]; then
		return 1
	fi

	rules_dir_init
	raw="$RULES_CACHE/$id.raw"
	out="$RULES_OUT/auto-$id.conf"
	tmp="$out.tmp"

	echo "[rules] $id ($type) <- $url"
	case "$url" in
		http://*|https://*)
			if ! rules_fetch "$url" "$raw"; then
				rules_state_set "$id" "status=fail" "msg=下载失败" "lastfail=$(date +%s)"
				echo "[rules] $id 下载失败"
				return 2
			fi
			;;
		*)
			# 本地源直接读原文件，不复制到 cache（seed 有 5 MB，复制等于翻倍）
			rm -f "$raw" 2>/dev/null
			raw=$(rules_local_path "$url")
			if [ -z "$raw" ]; then
				rules_state_set "$id" "status=fail" "msg=源文件不存在" "lastfail=$(date +%s)"
				echo "[rules] $id 源文件不存在: $url"
				return 2
			fi
			;;
	esac

	# 远程源拿到一张网页，基本就是 404 / 被劫持 / 跳转到登录页。
	# 这类内容必须当场拒掉，不能顺着转换器往下走（多数转换器会输出 0 行，
	# 看起来像"空列表"，一提交就把用户的规则清空了）。
	case "$url" in
		http://*|https://*)
			if head -c 512 "$raw" 2>/dev/null | tr 'A-Z' 'a-z' | grep -qE '<!doctype[[:space:]]+html|<html|<head|<body'; then
				rm -f "$raw"
				rules_state_set "$id" "status=fail" "msg=源返回网页而非规则" "lastfail=$(date +%s)"
				echo "[rules] $id 返回的是网页而不是规则文件，已忽略"
				return 2
			fi
			;;
	esac

	if ! rules_conv "$type" "$raw" "$tmp"; then
		rm -f "$tmp"
		rules_state_set "$id" "status=fail" "msg=类型不支持: $type" "lastfail=$(date +%s)"
		echo "[rules] $id 类型不支持: $type"
		return 2
	fi

	n=$(wc -l < "$tmp" 2>/dev/null | tr -d ' \t')
	# 本地源（含 local.hosts）允许为空：用户还没填内容时就是 0 条。
	# 远程源为空则视为异常 —— 源格式变了或返回了空响应，保留旧规则更安全。
	case "$url" in
		http://*|https://*)
			if [ "${n:-0}" -eq 0 ]; then
				rm -f "$tmp"
				rules_state_set "$id" "status=fail" "msg=转换结果为空，疑似源格式变化" "lastfail=$(date +%s)"
				echo "[rules] $id 转换结果为空，保留上一次的规则"
				return 2
			fi
			;;
	esac

	if ! rules_validate "$type" "$tmp"; then
		rm -f "$tmp"
		rules_state_set "$id" "status=fail" "msg=内容校验未通过(行数 ${n:-0})" "lastfail=$(date +%s)"
		echo "[rules] $id 内容校验未通过，保留上一次的规则"
		return 2
	fi

	n=$(wc -l < "$tmp" 2>/dev/null | tr -d ' \t')
	old_md5=$( [ -f "$out" ] && md5sum "$out" 2>/dev/null | awk '{print $1}' )
	new_md5=$(md5sum "$tmp" 2>/dev/null | awk '{print $1}')

	if [ -n "$old_md5" ] && [ "$old_md5" = "$new_md5" ]; then
		rm -f "$tmp"
		rules_state_set "$id" "status=ok" "msg=无变化" "lines=${n:-0}" "last=$(date +%s)" "lastfail=0" "lastday=$(date +%Y%m%d)"
		echo "[rules] $id 无变化 (${n:-0} 条)"
		# 文件没变，但合并文件/索引可能因为别的源变了而不一致，顺手对齐
		rules_after_update
		return 1
	fi

	mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp"; return 2; }
	rules_state_set "$id" "status=ok" "msg=已更新" "lines=${n:-0}" "last=$(date +%s)" "lastfail=0" "lastday=$(date +%Y%m%d)"
	echo "[rules] $id 已更新 (${n:-0} 条)"
	# 单源更新（WebUI 点「立即更新」）也必须重建合并文件，
	# 否则生成的文件存在、内核加载的还是上一份。
	rules_after_update
	return 0
}

# 生成本地 hosts 的规则（local-hosts 源就是往这个文件里写）
rules_update_local_hosts() {
	rules_update_one 'local-hosts' 1
}

### 跨源合并 --------------------------------------------------------------
# 每个源仍然各自生成 auto-<id>.conf —— 留着它才能判断"这个源这次变了没有"，
# 也才能在某个源挂掉时继续用它的旧规则。但内核最终只读合并后的 merged.conf：
# 同一个域名被多个源收录时只留一条，省掉重复占用的那份内存和解析时间。
#
# 优先级（数值大的赢）：
#   60  local-hosts                      用户手写的映射
#   40  hosts                            域名 -> IP 的显式映射
#   30  domain-block / ip-blacklist      屏蔽
#   20  domain-foreign                   走国外组
#   10  domain-cn / ip-whitelist         走国内组
# 同优先级按 sources.conf 里的先后，先出现的赢。
#
# 为什么必须把顺序定死：chnlist 和 gfwlist 本来就有重叠域名，两条语义不同的
# 规则同时丢给内核时，最终哪条生效取决于内部匹配顺序，等于听天由命。
# 合并时按类型取用，行为才可解释、可复现。
rules_merge_prio() {
	# $1=id $2=type
	[ "$1" = 'local-hosts' ] && { echo 60; return 0; }
	case "$2" in
		hosts) echo 40 ;;
		domain-block|ip-blacklist) echo 30 ;;
		domain-foreign) echo 20 ;;
		domain-cn|ip-whitelist) echo 10 ;;
		*) echo 15 ;;
	esac
}

# 合并所有启用源的 auto-*.conf -> config/rules/merged.conf（跨源去重）。
# 返回值：0 成功  2 失败（此时上一份 merged.conf 原样保留）
# 合并会被多个入口同时发起：WebUI 删源/改配置、更新收尾、开机补建。
# 中间文件原来是固定路径（.merge.src / .merge.raw），两个进程一起进来时
# 后一个会把前一个正在写的 raw 截断，合出一份残缺的 merged.conf
# （真机上见过只剩 3 万行的版本，内核照样加载了）。所以先加锁，中间文件也带 pid。
rules_merge_lock() {
	local lk="$RULES_STATE/.merge.lock" i=0 op
	mkdir -p "$RULES_STATE" 2>/dev/null
	while ! mkdir "$lk" 2>/dev/null; do
		# 持锁进程已经没了（被强杀、刷机中）就接管，否则永远合不了
		if [ -f "$lk/owner" ]; then
			op=$(cat "$lk/owner" 2>/dev/null)
			if [ -n "$op" ] && [ ! -d "/proc/$op" ]; then
				rm -rf "$lk" 2>/dev/null
				continue
			fi
		fi
		i=$((i + 1))
		[ "$i" -ge 100 ] && return 1        # 最多等 20 秒
		sleep 0.2
	done
	echo $$ > "$lk/owner" 2>/dev/null
	return 0
}

rules_merge_unlock() {
	rm -rf "$RULES_STATE/.merge.lock" 2>/dev/null
}

rules_gen_merged() {
	rules_merge_lock || return 2
	_rules_gen_merged_body
	local rc=$?
	rules_merge_unlock
	return $rc
}

_rules_gen_merged_body() {
	local src="$TEMP_DIR/.merge.$$.src" raw="$TEMP_DIR/.merge.$$.raw"
	local tmp="$RULES_OUT/merged.conf.$$.tmp" stmp="$RULES_OUT/merged.stats.$$.tmp"
	local stats="$RULES_OUT/merged.stats"
	local p pp id type url intv en at f n=0 lines

	mkdir -p "$RULES_OUT" "$TEMP_DIR" 2>/dev/null
	# 先把每个启用源的优先级算出来，省得在双重循环里反复 fork 子 shell
	rules_list_sources | while IFS='	' read -r id type url intv en at; do
		[ "$en" = '0' ] && continue
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$(rules_merge_prio "$id" "$type")" "$id" "$type" "$url" "$intv" "$en" "$at"
	done > "$src"

	# 按优先级从高到低拼接：先写进去的赢，所以拼接顺序就是优先级顺序
	: > "$raw"
	for p in 60 40 30 20 10 15; do
		while IFS='	' read -r pp id type url intv en at; do
			[ "$pp" = "$p" ] || continue
			f="$RULES_OUT/auto-$id.conf"
			[ -s "$f" ] || continue
			cat "$f" >> "$raw" || { rm -f "$raw" "$src"; return 2; }
			n=$((n + 1))
		done < "$src"
	done

	# 去重键按"指令族 + 域名/CIDR"算：
	#   address /x/...                    同一域名只能有一个结果（屏蔽 还是 映射到 IP）
	#   nameserver|domain-rules /x/...    同一域名只能有一种走法（国内 还是 国外）
	#   whitelist-ip|blacklist-ip X       同一网段只能归一边
	# 其余行（源里透传的陌生指令）按整行去重，只求不重复。
	awk -v st="$stmp" '
	BEGIN { total = 0; kept = 0; removed = 0; conflict = 0; invalid = 0; sample = ""; badsample = "" }
	NF == 0 { next }
	{
		t = $0
		sub(/^[ \t]+/, "", t)
		if (t ~ /^address[ \t]+\//) {
			d = t; sub(/^address[ \t]+\//, "", d); sub(/\/.*/, "", d)
			# 只接受 address /域名/目标，且目标必须是 # 或 IP。
			# easylist 这类 ABP 源转换后会残留 `address /$object,.../#`、
			# `address /!#xx.com/#`、`address /0gg/gg*.js/#` 之类，
			# 内核会逐条拒绝；数量上万时加载几万行就整体退出（rc=0），
			# 真机上表现为服务起不来且日志只有几行 failed。
			tg = t; sub(/^.*\//, "", tg)
			mid = t; sub(/^address[ \t]+\//, "", mid); sub(/\/[^\/]*$/, "", mid)
			if (d !~ /^[A-Za-z0-9._*|-]+$/ || tg !~ /^(#|[0-9.]+|[0-9A-Fa-f:]+)$/ || mid != d || length(t) > 300) {
				invalid++
				if (invalid <= 3) badsample = badsample (badsample == "" ? "" : ",") substr(t, 9, 40)
				next
			}
			key = "a:" tolower(d)
		} else if (t ~ /^(nameserver|domain-rules)[ \t]+\//) {
			d = t; sub(/^(nameserver|domain-rules)[ \t]+\//, "", d); sub(/\/.*/, "", d)
			key = "r:" tolower(d)
		} else if (t ~ /^(whitelist-ip|blacklist-ip)[ \t]+/) {
			d = t; sub(/^(whitelist-ip|blacklist-ip)[ \t]+/, "", d); sub(/[ \t].*/, "", d)
			key = "i:" d
		} else {
			key = "l:" t
		}
		if (key == "") next
		total++
		if (key in seen) {
			removed++
			if (seen[key] != t) {
				conflict++
				if (conflict <= 3) sample = sample (sample == "" ? "" : ",") substr(key, 3)
			}
			next
		}
		seen[key] = t
		print $0
		kept++
	}
	END {
		printf "total=%d\nkept=%d\nremoved=%d\nconflict=%d\ninvalid=%d\nsources=%d\nsample=%s\nbadsample=%s\n", \
			total, kept, removed, conflict, invalid, srcn, sample, badsample > st
	}
	' srcn="$n" "$raw" > "$tmp" || { rm -f "$tmp" "$raw" "$src"; return 2; }

	lines=$(wc -l < "$tmp" 2>/dev/null | tr -d ' \t')
	# 输入明明有内容却合成了 0 条：合并逻辑本身出问题了。
	# 这时保留上一份 merged.conf，也不能让内核突然一条规则都没有。
	if [ "${lines:-0}" -eq 0 ] && [ -s "$raw" ]; then
		rm -f "$tmp" "$raw" "$src" "$stmp"
		return 2
	fi
	# 先替换规则再替换统计，避免界面上读到"新统计配旧规则"
	mv -f "$tmp" "$RULES_OUT/merged.conf" 2>/dev/null || { rm -f "$tmp" "$raw" "$src" "$stmp"; return 2; }
	if [ -f "$stmp" ]; then
		printf 'time=%s\n' "$(date +%s)" >> "$stmp"
		mv -f "$stmp" "$stats" 2>/dev/null
	fi
	rm -f "$raw" "$src"
	return 0
}

# 合并结果一行摘要，写进更新日志，出问题好回看
rules_merge_summary() {
	local f="$RULES_OUT/merged.stats"
	local total kept removed conflict invalid sources
	[ -f "$f" ] || { echo '[rules] 合并文件尚未生成'; return 0; }
	total=$(sed -n 's/^total=//p' "$f" 2>/dev/null | head -n 1)
	kept=$(sed -n 's/^kept=//p' "$f" 2>/dev/null | head -n 1)
	removed=$(sed -n 's/^removed=//p' "$f" 2>/dev/null | head -n 1)
	conflict=$(sed -n 's/^conflict=//p' "$f" 2>/dev/null | head -n 1)
	invalid=$(sed -n 's/^invalid=//p' "$f" 2>/dev/null | head -n 1)
	sources=$(sed -n 's/^sources=//p' "$f" 2>/dev/null | head -n 1)
	printf '[rules] 合并 %s 个源：%s 条 -> 去重后 %s 条（删除重复 %s，语义冲突 %s，丢弃非法 %s）\n' \
		"${sources:-0}" "${total:-0}" "${kept:-0}" "${removed:-0}" "${conflict:-0}" "${invalid:-0}"
}

# 重建"合并文件 + 索引"。改了源清单、更新了某个源、切了启停都走这里。
rules_regen() {
	rules_gen_merged
	rules_gen_index
	return 0
}

# 单个源更新完后重建合并文件与索引。
# 批量更新时 rules_update 会把 RULES_MERGE_DEFER 置 1，最后只合一次 ——
# 七个源各合一次纯属白烧 CPU 和闪存。
rules_after_update() {
	[ "${RULES_MERGE_DEFER:-0}" = '1' ] && return 0
	rules_regen
	return 0
}

# 汇总 index.conf。主配置只引用这一个文件，源增删都不必改主配置。
#
# 正常情况下 index.conf 只有一行：合并去重后的 merged.conf。
# 合并文件不在时（升级首启还没生成、或合并失败）退回逐源引用 ——
# 内核多解析几份重复规则无所谓，但绝不能出现"一条规则都没加载"。
#
# 注意这里必须写绝对路径。内核解析 conf-file 的相对路径时，基准是
# 「被包含文件所在目录」而不是主配置目录，于是 index.conf 里再写
# ./rules/auto-x.conf 会被拼成 config/rules/./rules/auto-x.conf，
# 实测直接报 no such file 并拒绝启动（4.0 首刷就踩到这个）。
# 主配置那行 ./rules/index.conf 保持相对（基准是 config/），这里用绝对路径
# 彻底绕开两套语义的差异。
rules_gen_index() {
	local id type url intv en at f tmp="$RULES_OUT/index.conf.$$.tmp"
	: > "$tmp"
	if [ -s "$RULES_OUT/merged.conf" ]; then
		printf 'conf-file %s/merged.conf\n' "$RULES_OUT" >> "$tmp"
	else
		rules_list_sources | while IFS='	' read -r id type url intv en at; do
			[ "$en" = '0' ] && continue
			f="$RULES_OUT/auto-$id.conf"
			[ -s "$f" ] && printf 'conf-file %s/auto-%s.conf\n' "$RULES_OUT" "$id" >> "$tmp"
		done
	fi
	# 用户手写的规则放最后，语义上覆盖/补充前面的自动规则
	for f in user-block.conf user-allow.conf user-hosts.conf; do
		[ -s "$RULES_OUT/$f" ] && printf 'conf-file %s/%s\n' "$RULES_OUT" "$f" >> "$tmp"
	done
	mv -f "$tmp" "$RULES_OUT/index.conf" 2>/dev/null
	return 0
}

# 批量更新。changed 由返回值汇总，是否需要重启内核交给调用方决定。
# $1 = all | due | <id>
#   all  手动全量更新（WebUI「立即更新」）
#   due  只更到期的源（看门狗用）
rules_update() {
	# $1 = all | due | <id>   $2 = force
	local target="${1:-all}" force="${2:-0}"
	local id rc changed=0 failed=0 _due
	rules_init

	# 只更新到期的源。看门狗原来用 rules_due 判断"有源到期"，但执行的是
	# update all：只要有任意一个源（比如 6 小时的 github520）到期，168 小时的
	# chnroute/chnlist/anti-ad 也会被一起重下，所有源实际都按最短 interval 在
	# 刷，流量、写盘和内核重启次数都被放大。
	if [ "$target" = 'due' ]; then
		_due=$(rules_due 2>/dev/null)
		if [ -z "$_due" ]; then
			echo '[rules] 没有到期的源'
			return 1
		fi
		rm -f "$TEMP_DIR/rules.changed" "$TEMP_DIR/rules.failed"
		RULES_MERGE_DEFER=1
		for id in $_due; do
			rules_update_one "$id" "$force"
			case "$?" in
				0) echo "$id" >> "$TEMP_DIR/rules.changed" ;;
				2) echo "$id" >> "$TEMP_DIR/rules.failed" ;;
			esac
		done
		RULES_MERGE_DEFER=0
		rules_regen
		changed=0
		failed=0
		[ -f "$TEMP_DIR/rules.changed" ] && changed=$(wc -l < "$TEMP_DIR/rules.changed" | tr -d ' \t')
		[ -f "$TEMP_DIR/rules.failed" ] && failed=$(wc -l < "$TEMP_DIR/rules.failed" | tr -d ' \t')
		echo "[rules] 到期源更新完成：${changed:-0} 个有变化，${failed:-0} 个失败"
		[ "${changed:-0}" -gt 0 ] && return 0
		[ "${failed:-0}" -gt 0 ] && return 2
		return 1
	fi

	if [ "$target" != 'all' ]; then
		RULES_MERGE_DEFER=1
		rules_update_one "$target" "$force"
		rc=$?
		RULES_MERGE_DEFER=0
		rules_regen
		[ "$rc" = '0' ] && return 0
		[ "$rc" = '1' ] && return 1
		return 2
	fi

	rules_list_sources > "$TEMP_DIR/rules.list"
	rm -f "$TEMP_DIR/rules.changed" "$TEMP_DIR/rules.failed"
	RULES_MERGE_DEFER=1
	# 用重定向而不是管道：管道会开子 shell，里面的 return 和计数变量都传不回来
	while IFS='	' read -r id type url intv en at; do
		[ "$en" = '0' ] && continue
		rules_update_one "$id" "$force"
		case "$?" in
			0) echo "$id" >> "$TEMP_DIR/rules.changed" ;;
			2) echo "$id" >> "$TEMP_DIR/rules.failed" ;;
		esac
	done < "$TEMP_DIR/rules.list"
	RULES_MERGE_DEFER=0
	rules_regen

	changed=0
	failed=0
	[ -f "$TEMP_DIR/rules.changed" ] && changed=$(wc -l < "$TEMP_DIR/rules.changed" | tr -d ' \t')
	[ -f "$TEMP_DIR/rules.failed" ] && failed=$(wc -l < "$TEMP_DIR/rules.failed" | tr -d ' \t')
	echo "[rules] 完成：${changed:-0} 个源有变化，${failed:-0} 个失败"
	[ "${changed:-0}" -gt 0 ] && return 0
	[ "${failed:-0}" -gt 0 ] && return 2
	return 1
}

# 只跑本地源（seed + local.hosts），不碰网络。
# 用途：首次迁移后必须马上有一份可用规则，否则内核起来时规则是空的 ——
# 连国内/国外分流都没了。远程源留给看门狗在后台补。
rules_update_local_only() {
	local id type url intv en at
	rules_dir_init
	rules_list_sources > "$TEMP_DIR/rules.list"
	RULES_MERGE_DEFER=1
	while IFS='	' read -r id type url intv en at; do
		[ "$en" = '0' ] && continue
		case "$url" in
			http://*|https://*) continue ;;
		esac
		rules_update_one "$id" 1 >/dev/null 2>&1
	done < "$TEMP_DIR/rules.list"
	RULES_MERGE_DEFER=0
	rules_regen
	return 0
}

### 调度 ------------------------------------------------------------------
# 列出到期该更新的源。watch 循环每轮调用一次，结果为空就跳过。
rules_due() {
	local id type url intv en at now last lastday lastfail hm today dow dom
	now=$(date +%s)
	today=$(date +%Y%m%d)
	hm=$(date +%H:%M)
	dow=$(date +%u)
	dom=$(date +%d)
	rules_list_sources | while IFS='	' read -r id type url intv en at; do
		[ "$en" = '0' ] && continue
		last=$(rules_state_get "$id" last)
		lastday=$(rules_state_get "$id" lastday)
		lastfail=$(rules_state_get "$id" lastfail)
		# 失败冷却：失败不写 last，若不冷却，看门狗每轮（30 秒）都会重撞一次；
		# 冷却 RULES_RETRY_COOLDOWN 秒（默认 900）既不会把源晾一整个周期，
		# 也不会把日志刷满。
		if [ -n "$lastfail" ] && [ "$lastfail" -gt 0 ] 2>/dev/null; then
			[ $((now - lastfail)) -lt "${RULES_RETRY_COOLDOWN:-900}" ] && continue
		fi
		if [ -n "$at" ]; then
			# 定点模式：分钟对上才跑。每周/每月由 rules_at_match 按星期/日期判断，
			# lastday 保证当天只跑一次（同一天重复命中也不会重复下载）。
			[ "$lastday" = "$today" ] && continue
			rules_at_match "$at" "$hm" "$dow" "$dom" || continue
			echo "$id"
			continue
		fi
		# 间隔模式：interval=0 表示只手动更新
		case "$intv" in ''|*[!0-9]*) continue ;; esac
		[ "$intv" -gt 0 ] || continue
		last=${last:-0}
		[ $((now - last)) -ge $((intv * 3600)) ] || continue
		echo "$id"
	done
}

# 后台更新是否真的在跑。
# .running 只是个快速标记：进程被强杀（刷机、改配置、系统回收）之后文件会留下，
# 之后每一次更新都会被"已有更新任务在进行"挡掉，界面永远停在更新中。
# 所以以"有没有对应的活进程"为准，发现标记是孤儿就顺手清掉。
rules_job_alive() {
	local psout cmdf
	[ -f "$RULES_STATE/.running" ] || return 1
	# ps 的参数姿势在 toybox/busybox/Git-Bash 上各不相同，读不到就退回扫 /proc
	psout=$(ps -A -o ARGS 2>/dev/null)
	if [ -n "$psout" ]; then
		printf '%s\n' "$psout" | grep -q '[r]ulesrc update' && return 0
	else
		for cmdf in /proc/[0-9]*/cmdline; do
			[ -r "$cmdf" ] || continue
			tr '\0' ' ' < "$cmdf" 2>/dev/null | grep -q 'rulesrc update' && return 0
		done
	fi
	rm -f "$RULES_STATE/.running" 2>/dev/null
	return 1
}

# 给 WebUI 用：一行一个源，字段用 | 分隔
# id|type|url|interval|enabled|at|status|lines|last|msg|bin
# bin=1 表示内置源（前端不显示删除按钮）
rules_status() {
	local id type url intv en at bin
	rules_list_sources | while IFS='	' read -r id type url intv en at; do
		bin=0
		rules_is_builtin "$id" && bin=1
		printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$id" "$type" "$url" "$intv" "$en" "$at" \
			"$(rules_state_get "$id" status)" \
			"$(rules_state_get "$id" lines)" \
			"$(rules_state_get "$id" last)" \
			"$(rules_state_get "$id" msg)" \
			"$bin"
	done
}

### 增删改（WebUI / CLI 调用）--------------------------------------------

# 返回值约定（调用方据此给出人话错误提示）：
#   0 成功   1 参数不合法   2 同名源已存在   3 内置源不允许删
rules_add_source() {
	# $1=id $2=type $3=url $4=interval $5=enabled [$6=at]
	local id="$1" type="$2" url="$3" intv="${4:-0}" en="${5:-1}" at="${6:-}"
	case "$id" in
		''|*[!A-Za-z0-9_-]*) return 1 ;;
	esac
	case " $RULES_TYPES " in
		*" $type "*) ;;
		*) return 1 ;;
	esac
	# sources.conf 是空格分列的，url 里带空白会把后面的字段全切错位
	case "$url" in
		''|*[[:space:]]*) return 1 ;;
	esac
	case "$intv" in ''|*[!0-9]*) return 1 ;; esac
	case "$en" in 0|1) ;; *) return 1 ;; esac
	[ -n "$at" ] && { rules_valid_at "$at" || return 1; }
	rules_src_exists "$id" && return 2
	printf 'id=%s type=%s url=%s interval=%s enabled=%s%s\n' \
		"$id" "$type" "$url" "$intv" "$en" "${at:+ at=$at}" >> "$RULES_SOURCES"
	return 0
}

rules_del_source() {
	local id="$1" tmp="$RULES_SOURCES.tmp"
	rules_is_builtin "$id" && return 3
	rules_src_exists "$id" || return 1
	awk -v id="$id" '
	{
		if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { print; next }
		hit = 0
		for (i = 1; i <= NF; i++) if ($i == "id=" id) { hit = 1; break }
		if (!hit) print
	}' "$RULES_SOURCES" > "$tmp" && mv -f "$tmp" "$RULES_SOURCES"
	rm -f "$RULES_OUT/auto-$id.conf" "$RULES_STATE/$id" "$RULES_CACHE/$id.raw"
	rules_regen
	return 0
}

# 改某个源。$2..$6 传空串表示"这一项不动"。
#   $1=id $2=interval $3=enabled $4=at $5=url $6=type
# at 传 "-" 表示清掉定点时间（切换到纯间隔/手动模式时用）。
# 返回值：0 成功  1 源不存在  4 参数不合法
rules_set_source() {
	local id="$1" intv="$2" en="$3" at="$4" url="$5" type="$6"
	local tmp="$RULES_SOURCES.tmp"
	local o_at o_en o_url o_type o_intv

	rules_src_exists "$id" || return 1
	o_type=$(rules_src_field "$id" 2)
	o_url=$(rules_src_field "$id" 3)
	o_intv=$(rules_src_field "$id" 4)
	o_en=$(rules_src_field "$id" 5)
	o_at=$(rules_src_field "$id" 6)

	case "$intv" in ''|*[!0-9]*) return 4 ;; esac
	case "$en" in 0|1) ;; *) return 4 ;; esac
	case "$at" in
		'') ;;
		'-') ;;
		*) rules_valid_at "$at" || return 4 ;;
	esac
	if [ -n "$url" ]; then
		case "$url" in *[[:space:]]*) return 4 ;; esac
	fi
	if [ -n "$type" ]; then
		case " $RULES_TYPES " in *" $type "*) ;; *) return 4 ;; esac
	fi
	[ -n "$url" ] || url="$o_url"
	[ -n "$type" ] || type="$o_type"
	case "$at" in
		'-') new_at='' ;;
		'')  new_at="$o_at" ;;
		*)   new_at="$at" ;;
	esac

	awk -v id="$id" -v intv="$intv" -v en="$en" -v at="$new_at" \
	    -v url="$url" -v type="$type" '
	{
		if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) { print; next }
		hit = 0
		for (i = 1; i <= NF; i++) if ($i == "id=" id) { hit = 1; break }
		if (!hit) { print; next }
		line = "id=" id " type=" type " url=" url " interval=" intv " enabled=" en
		if (at != "") line = line " at=" at
		print line
	}' "$RULES_SOURCES" > "$tmp" && mv -f "$tmp" "$RULES_SOURCES"

	# 地址/类型变了，旧的生成结果就不再对应这份配置了：把状态标成"待更新"，
	# 但**不删**已生成的 conf —— 源万一挂了，旧规则还能继续用（fail-safe）。
	if [ "$url" != "$o_url" ] || [ "$type" != "$o_type" ]; then
		rules_state_set "$id" "status=pending" "msg=配置已修改，待更新"
	fi
	# 启停或类型变了，合并文件的内容和取用顺序都会变，必须重建
	if [ "$en" != "$o_en" ] || [ "$type" != "$o_type" ]; then
		rules_regen >/dev/null 2>&1
	fi
	return 0
}
