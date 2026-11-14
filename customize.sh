SKIPUNZIP=1
	ui_print "- module version: [ $(grep_prop version $TMPDIR/module.prop | awk -F " " '{print $1}') ]"

	# 只从管理器安装
	[ "$BOOTMODE" == 'true' ] || abort "[Error]: Please install from Magisk Manager."

	# 冲突判断
	[ "$API" -ge 28 -a $(settings get global private_dns_mode) != 'off' ] && {
		ui_print "****************"
		ui_print '(!) 请关闭私人DNS以防止冲突'
		ui_print '(!) Please close the Private DNS to prevent conflict.'
		ui_print "****************"
	}

	ui_print "- Extracting module files"

	# 控制脚本
	unzip -oj "$ZIPFILE" 'common/*' -d $MODPATH >&2
	# 语言文件
	unzip -o "$ZIPFILE" 'translations/*' -d $MODPATH >&2
	# WebUI 页面（KernelSU / MMRL 的「打开 WebUI」读取此目录）
	unzip -o "$ZIPFILE" 'webroot/*' -d $MODPATH >&2
	# 出厂配置模板（WebUI 的「恢复出厂配置」使用，仅保留主配置以节省体积）
	mkdir -p $MODPATH/defaults
	unzip -oj "$ZIPFILE" 'config/smartdns.conf' -d $MODPATH/defaults >&2

	# 创建 /etc/resolv.conf
	# realpath 缺失时退回 readlink -f，再退回 /etc，避免误判为"结构未适配"
	etcPATH=$(realpath /etc 2>/dev/null)
	[ -n "$etcPATH" ] || etcPATH=$(readlink -f /etc 2>/dev/null)
	[ -n "$etcPATH" ] || etcPATH=/etc
	if echo $etcPATH |grep -q -e '^\/system' ; then
		mkdir -p $MODPATH$etcPATH
		echo -e 'nameserver 9.9.9.9\nnameserver 208.67.222.222' > $MODPATH$etcPATH/resolv.conf
	else
		ui_print "****************"
		ui_print '[错误]: 文件结构未适配，请联系作者寻求帮助。'
		ui_print '[Error]: The file structure is not adapted, Please contact the author for help.'
		ui_print "****************"
		abort "$(ls -l /etc)"
	fi

	# 为 constant.sh 提供路径
	readonly MODDIR=$MODPATH
	. $MODPATH/constant.sh
	# 已安装模块路径
	readonly installed_PATH=${MODPATH/modules_update/modules}

	# 创建调用
	mkdir -p $MODPATH/system/bin
	#ln -fs $installed_PATH/command.sh $MODPATH/system/bin/$CORE_NAME
	echo -e "#!/system/bin/sh\nexec $installed_PATH/command.sh \"\$@\"" > $MODPATH/system/bin/$CORE_NAME

	#####

	# binary 文件解压
	unzip -oj "$ZIPFILE" 'binary/*' -d $TMPDIR >&2
	# 证书库
	# 必须显式建目录：以前这里唯一"创建 $MODPATH/binary"的动作就是下面这句
	# unzip -d。一旦 ca-certificates.zip 没被打进包（CI 的 zip 排除规则曾误伤
	# 嵌套的 *.zip），unzip 会直接失败、目录不存在，后面 cp 内核静默失败，
	# 模块"安装成功"却没有任何内核，启动时报「找不到可执行的内核文件」。
	mkdir -p $MODPATH/binary
	if [ -f "$TMPDIR/ca-certificates.zip" ]; then
		unzip -o "$TMPDIR/ca-certificates.zip" -d $MODPATH/binary >&2 \
			|| ui_print '(!) 证书库解压失败，DoH/DoT 可能无法校验证书'
	else
		ui_print '(!) 包内缺少证书库 binary/ca-certificates.zip'
	fi

	# 架构判断
	case $ARCH in
	arm|arm64)
		sleep 1
		;;
	*)
		abort "[Error]: $ARCH are unsupported architecture." ;;
	esac
	readonly BINARY_PATH=$TMPDIR/$ARCH


	#核心
	if [ -f "$BINARY_PATH" ]; then
		# 版本信息写入到模块信息
		chmod 0755 $BINARY_PATH
		coreVer=$($BINARY_PATH -v |awk -F ' ' '{print $2}')
		Ver=`grep_prop versionCode $TMPDIR/module.prop`
		ui_print "- Server: [ $coreVer ] Script: [ $Ver ]"
		sed -i -e "s/<VER>/${coreVer}/" $TMPDIR/module.prop
		cp $TMPDIR/module.prop $MODPATH
		# 安装程序
		cp -f $BINARY_PATH $CORE_INTERNAL_DIR/$CORE_NAME
		chmod 0755 $CORE_INTERNAL_DIR/$CORE_NAME 2>/dev/null
		# 复制结果必须校验：以前 cp 失败不 abort，装完就是"没有内核的模块"
		if [ ! -s "$CORE_INTERNAL_DIR/$CORE_NAME" ]; then
			abort "[Error]: 内核复制失败: $CORE_INTERNAL_DIR/$CORE_NAME 不存在。请重新下载模块包后刷入。"
		fi
	else
		abort "[Error]: $ARCH binary file missing."
	fi


	## 版本变化配置处理↓
	#配置文件（只剩手写规则：blacklist-ip / bogus-nxdomain / 内网后缀 / localhost）
	unzip -o "$ZIPFILE" 'config/*' -d $TMPDIR >&2
	#内置规则表（订阅类大表，作为规则源的初始副本，不再进 config/）
	unzip -o "$ZIPFILE" 'rulesrc/*' -d $TMPDIR >&2
	#其他脚本
	unzip -o "$ZIPFILE" 'scripts/*' -d $TMPDIR >&2

	# ---- 升级时的配置/脚本继承 ----------------------------------------
	# 安装会「继承」已存在的 $DATA_INTERNAL_DIR，这是升级不丢配置的前提。
	# 只处理 4.x 自己留下的结构：4.0 之前的目录名（list_block/list_ip/
	# list_location、bootTask 深度 1 的旧脚本）已经不再迁移 —— 从那么老的版本
	# 直接升级请先放 reset 文件重置一次，否则主配置还指着旧的静态表。
	sync_scripts() {
		local src="$1" dst="$2" rel
		[ -d "$src" ] || return 0
		mkdir -p "$dst"
		( cd "$src" && find . -type f ) | while read -r rel; do
			mkdir -p "$dst/${rel%/*}" 2>/dev/null
			cp -f "$src/$rel" "$dst/$rel" 2>/dev/null
		done
		return 0
	}

	if [ ! -d "$DATA_INTERNAL_DIR" ]; then
		# 若配置路径不存在
		ui_print "****************"
		ui_print '(!) 需要自行设置配置。'
		ui_print '(!) Requires you to set the configuration yourself.'
		ui_print "****************"
		# 创建配置
		mkdir -p $DATA_INTERNAL_DIR
		cp -a $TMPDIR/config/* $DATA_INTERNAL_DIR/
		mkdir -p $SCRIPT_INTERNAL_DIR
		cp -a $TMPDIR/scripts/* $SCRIPT_INTERNAL_DIR/
		# 创建脚本配置
		cp $MODPATH/defaults.sh $SCRIPT_CONF
	else
		ui_print "****************"
		ui_print '(!) 尝试继承模块设置。如果出错,请使用示例文件重新配置。'
		ui_print '(!) Try inheriting the module setting. If something goes wrong, reconfigure it.'
		ui_print "****************"
		# 配置更新
		if [ -f $DATA_INTERNAL_DIR/reset ]; then
			rm -r $DATA_INTERNAL_DIR
			mkdir -p $DATA_INTERNAL_DIR
			cp -a $TMPDIR/config/* $DATA_INTERNAL_DIR/
			cp $MODPATH/defaults.sh $SCRIPT_CONF
		else
			# 更新程序示例配置
			cp -f $TMPDIR/config/smartdns.conf $DATA_INTERNAL_DIR/example-smartdns.conf
			# 更新脚本示例配置
			cp -f $MODPATH/defaults.sh $DATA_INTERNAL_DIR/example-script_conf.sh
		fi
		# scripts 更新
		if [ -f $SCRIPT_INTERNAL_DIR/reset ]; then
			rm -r $SCRIPT_INTERNAL_DIR
			mkdir -p $SCRIPT_INTERNAL_DIR
			cp -rf $TMPDIR/scripts/* $SCRIPT_INTERNAL_DIR/
		else
			# 增量同步：旧版 scripts 会一直留着，导致开机任务结构对不上
			sync_scripts "$TMPDIR/scripts" "$SCRIPT_INTERNAL_DIR"
		fi
	fi

	# ── 规则源 ────────────────────────────────────────────────────────
	# 包内的四张订阅大表放在 rulesrc/seed/，不进 config/：
	# 它们由「规则源」管理器统一转换、去重后落到 config/rules/ 给内核加载。
	# 这些是订阅数据不是用户配置，每次安装覆盖是预期的。
	mkdir -p "$RULESRC_DIR/seed" "$RULES_OUT" 2>/dev/null
	if [ -d "$TMPDIR/rulesrc/seed" ]; then
		cp -f $TMPDIR/rulesrc/seed/* "$RULESRC_DIR/seed/" 2>/dev/null
	fi
	# 索引必须先存在：主配置引用了 ./rules/index.conf，
	# 文件不存在时内核会因为 conf-file 打不开而拒绝启动。
	[ -f "$RULES_OUT/index.conf" ] || : > "$RULES_OUT/index.conf"
	chmod 0644 "$RULES_OUT/index.conf" 2>/dev/null
	ui_print "- 规则源: seed $(ls $RULESRC_DIR/seed 2>/dev/null | wc -l | tr -d ' ') 个内置表"

	ui_print '- Setting permissions'
	set_perm_recursive $MODPATH 0 0 0755 0644

	set_perm $MODPATH/command.sh 0 0 0755
	set_perm $MODPATH/webui.sh 0 0 0755
	set_perm_recursive $MODPATH/webroot 0 0 0755 0644
	set_perm_recursive $MODPATH/defaults 0 0 0755 0644
	set_perm $MODPATH/system/bin/$CORE_NAME 0 0 0755

	set_perm $CORE_INTERNAL_DIR/setuidgid 0 0 0755
	set_perm $CORE_INTERNAL_DIR/$CORE_NAME 0 0 0755

	set_perm_recursive $DATA_INTERNAL_DIR 0 $(id -g radio) 0755 0644
	set_perm_recursive $SCRIPT_INTERNAL_DIR 0 0 0755 0644

	# for file in $(find $MODPATH -type f -maxdepth 1 -name '*.sh'); do
	# 	set_perm $file 0 0 0755
	# done
