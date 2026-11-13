#!/system/bin/sh
# PATH
readonly WORK_DIR=/data/adb/smartdns/scripts/bootTask/crond
readonly TASK_DIR=/data/adb/smartdns/scripts/cronTask

# busybox 直接取绝对路径。不用 alias：alias 在不同 shell 下的展开时机不一致，
# 脚本里不可靠（原来这么写，crond 是否真跑起来全看运气）。
if [ -x /data/adb/magisk/busybox ]; then
	BUSYBOX=/data/adb/magisk/busybox
elif [ -x /system/xbin/busybox ]; then
	BUSYBOX=/system/xbin/busybox
else
	exit 1
fi

cd $WORK_DIR

# 生成列表
[ -d user ] || mkdir -p user
lists=`find $TASK_DIR -mindepth 2 -name 'crond.reg'`
[ -n "$lists" ] && {
	rm -f user/* 2>/dev/null
	for file in $lists; do
		grep -v '#' "$file" >> user/root
	done
	chmod 0750 user/root
}

# 启动 crond
# 两个坑（真机验证过）：
#   1. -c / -L 必须给绝对路径。crond 会 chdir("/")，相对路径直接
#      "can't change directory to './user'"，任务一条都不会跑。
#   2. 不要用 -b（daemon）。在 Magisk 环境里 fork 出去的子进程会被回收，
#      日志里写了 "crond started"、ps 里却查不到，开机任务静默失效。
#      改成前台模式 + setsid 脱离会话。
pkill -9 -f "$WORK_DIR/user" 2>/dev/null
if command -v setsid >/dev/null 2>&1; then
	setsid "$BUSYBOX" crond -f -c "$WORK_DIR/user" -L "$WORK_DIR/crond.log" >/dev/null 2>&1 &
else
	nohup "$BUSYBOX" crond -f -c "$WORK_DIR/user" -L "$WORK_DIR/crond.log" >/dev/null 2>&1 &
fi

exit
