#!/system/bin/sh
# 取模块目录
# Magisk / KernelSU 可能以相对文件名（如 `sh service.sh`）调用本脚本，此时
# ${0%/*} 解析不出目录，cd 失败会让开机自启静默失效。
case "$0" in
	*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
	*) MODDIR=$(pwd) ;;
esac
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/smartdns
cd "$MODDIR" || exit 1
. $MODDIR/constant.sh

# 日志清理（crond 链路已删除，不再有 crond.log）
rm -f $BOOT_LOG $RUN_LOG 2>/dev/null

# 开机日志无条件落盘。
# 原来只在 log=yes 时才重定向，结果是开机失败时 boot.log 压根不存在，
# 手上一点线索都没有。开机路径没有控制台，必须写文件。
exec 1>>$BOOT_LOG 2>&1
echo "===== $(date +%c) boot ====="

# 启动服务：必须最先做。
# 旧版把"等待联网 + 开机任务"放在 command.sh 的初始化里，会 ping dns.google
# 最多 60 次 × 10 秒，开机时网络没就绪就会把这里卡住最长 10 分钟，
# 表现为"开机后服务一直没起来、规则也没加载"。
sh "$MODDIR/command.sh" start
rc=$?
echo "[boot] command.sh start -> rc=$rc"

# 启动失败的现场留档：开机时没有终端，只能写文件
if [ "$rc" != '0' ]; then
	echo '[boot] 启动失败，内核输出:'
	tail -n 20 "$LOG_DIR/core.log" 2>&1
	ps -A 2>/dev/null | grep -i "$CORE_NAME" | grep -v grep
fi

# 看门狗：常驻后台，每 30 秒确认一次服务活着。
# 3.3.x 的写法只是 20 秒后复检一次并打印结果——发现了也救不回来，用户看到
# 「服务自己停了」还得手动点启动。现在改成掉了就自动拉起（用户主动停止除外）。
# 必须用 setsid 脱离本次启动会话，否则 service.sh 退出时看门狗会被一起回收。
if command -v setsid >/dev/null 2>&1; then
	setsid sh "$MODDIR/command.sh" watch >/dev/null 2>&1 &
else
	sh "$MODDIR/command.sh" watch >/dev/null 2>&1 &
fi
# $! 是 setsid 的 pid，不是看门狗的；拿它写日志会在「陈旧锁误判」时
# 谎报「已启动」（复审 R1）。改为回读看门狗自己写进锁文件的 pid，并核对
# cmdline 确认那个进程确实是看门狗。
wpid=''; wi=0
while [ "$wi" -lt 3 ]; do
	wpid=$(cat "$WATCH_LOCK/pid" 2>/dev/null)
	[ -n "$wpid" ] && break
	sleep 1
	wi=$((wi + 1))
done
if [ -n "$wpid" ] && tr '\0' ' ' < "/proc/$wpid/cmdline" 2>/dev/null | grep -q 'command.sh watch'; then
	echo "[boot] watchdog started (pid $wpid)"
else
	echo "[boot] watchdog 未启动（锁: ${wpid:-无}）—— 执行 sh command.sh watch 可看到原因"
fi

# 开机任务（hosts 更新等）需要联网，放后台跑，不影响已经启动的服务
sh "$MODDIR/command.sh" boot >/dev/null 2>&1 &
exit $rc
