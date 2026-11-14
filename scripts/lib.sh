#!/system/bin/sh
# 为脚本提供常用函数

CORE_NAME="smartdns"
MODDIR="/data/adb/modules/$CORE_NAME"
. $MODDIR/constant.sh

### 路径类 ###
# 临时文件路径
readonly SCRIPT_TEMP_DIR="/data/local/tmp/$CORE_NAME/scripts_$RANDOM"
readonly LOG_DIR="$LOG_DIR/scripts"

### 函数类 ###

# 文件更新间隔
file_update_interval() {
	# $1 文件路径 $2 最小间隔(小时)
	local file="$1" Interval="$2"
	# 检测命令
	type stat > /dev/null 2>&1
	if [ "$?" != '0' ]; then
		# 不可用 强制更新
		printf '[warn]: stat 命令不存在\n'
		return 0
	else
		# 获取时间戳
		timestamp=$(date +%s)
		[ -e "$file" ] && filestamp=`stat -c %Y $file` || filestamp='0'
		if [ "$(($timestamp - $filestamp))" -gt "$(($Interval * 3600))" ]; then
			return 0
		fi
	fi
	return 1
}

# 文件变化
check_md5() {
	# $1 $2 文件路径
	if [ "`md5sum "${1}" | awk '{print $1}'`" == "`md5sum "${2}" | awk '{print $1}'`" ]; then
		return 0
	else
		return 1
	fi
}

# 重载配置数据
reload_config() {
	# 不能用裸 $CORE_NAME：PATH 里 /system/bin/smartdns 是安装时生成的转发脚本
	# （exec command.sh "$@"），从 cron 环境调用时会把 status/start 当成脚本参数，
	# 行为和预期完全不同。统一走模块的 command.sh。
	sh "$MODDIR/command.sh" status >/dev/null 2>&1
	if [ "$?" != '3' ]; then
		echo '[info]: 加载新数据, 重启服务器'
		sh "$MODDIR/command.sh" start
	fi
}

# 下载文件 E7KMbb/AD-hosts 
download_links() {
	# $1 链接	$2 下载文件名
	local file_link="$1" file_name="$2" tries

	# 审查 C4：这里原来是 `curl -k` / `wget --no-check-certificate`，TLS 只加密
	# 不验身份。下载到的 hosts 会被转成 `address /域名/IP` 写进内核配置（root 权限、
	# 没有任何人工确认），中间人就能决定任意域名解析到哪 —— 公共 Wi-Fi、拦截门户
	# 都能利用。改成强制 https + 校验证书 + 限制大小。
	if $(curl -V > /dev/null 2>&1) ; then
		for tries in $(seq 1 20); do
			if curl -fsSL --proto '=https' --tlsv1.2 --retry 2 --max-filesize 67108864 \
					"${file_link}" -o "$file_name" >&2; then
				break;
			fi
			sleep 2
			if [[ $tries == 20 ]]; then
				echo '[warn]: curl连接失败, 更新失败'
				rm -rf $file_name
				return 1
			fi
		done
	elif $(wget --help > /dev/null 2>&1) ; then
		for tries in $(seq 1 5); do
			# busybox wget 默认就校验证书，去掉 --no-check-certificate 即可；
			# --https-only 让它拒绝明文链接（老版本没有这个开关，失败也算安全）
			if wget --https-only -T 30 -t 2 ${file_link} -O $file_name; then
				break;
			fi
			if [[ $tries == 5 ]]; then
				echo '[warn]: wget连接失败, 更新失败'
				rm -rf $file_name
				return 1
			fi
		done
	else
		echo '[error]: 您没有下载所需要用到的指令文件, 请安装Busybox for Android NDK模块'
		return 1
	fi
}

# 封锁类型
blackhole() {
	# $1 文件路径(需要smartdns格式)
	sed -i "s/127.0.0.1/#/g" $1
	sed -i "s/0.0.0.0/#/g" $1
	sed -i "s/::1/#/g" $1
	sed -i "s/::/#/g" $1
	# 分辨#注释
	[ "${2}" == '#' ] || sed -i "s/\/#/\/${2}/g" "$1"
}

