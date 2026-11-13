#!/system/bin/sh
# 模块卸载清理
#
# 卸载脚本在「Magisk 删除模块目录之前」执行，这里做三件升级/重装最容易漏的事：
#   1. 先停服务。卸载不会杀进程，内核会一直占着 6053，重装后第一次 start 就是
#      bind failed, Address in use（真机上遇到过）。
#   2. 删 /dev/$CORE_NAME。它是 tmpfs，重启会清；但「卸载后不等重启就刷新版」
#      时它还在，里面还挂着两个 bind 挂载点，新模块会挂回旧目录。
#   3. 删上游原版留下的旧模块 id 目录（smartdns-aarch64 / smartdns-arm）。
#      它自带一份 service.sh，会和本模块抢同一个监听端口。
#
# 取模块目录（同样兼容以相对文件名调用的场景）
case "$0" in
	*/*) MODDIR=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
	*) MODDIR=$(pwd) ;;
esac
# 加载参数（只依赖路径常量；不加载 lib.sh，避免它内部的 readonly 冲突）
[ -f "$MODDIR/constant.sh" ] && . "$MODDIR/constant.sh"
[ -n "$CORE_NAME" ] || CORE_NAME="smartdns"
[ -n "$DATA_BASE" ] || DATA_BASE="/data/adb/$CORE_NAME"
[ -n "$WORK_DIR" ] || WORK_DIR="/dev/$CORE_NAME"

# 1. 先停服务（卸载流程不需要输出，全部静默）
if [ -f "$MODDIR/command.sh" ]; then
	sh "$MODDIR/command.sh" stop >/dev/null 2>&1
fi
# 兜底：command.sh 跑不动时按可执行文件路径精确清理，不用裸名字免得误杀
if command -v pkill >/dev/null 2>&1; then
	pkill -f "$WORK_DIR/binary/$CORE_NAME" 2>/dev/null
	pkill -f "$DATA_BASE/binary/$CORE_NAME" 2>/dev/null
fi

# 2. 工作目录：先解 bind，否则 rm 删掉的只是挂载点里的空壳
umount "$WORK_DIR/binary" 2>/dev/null
umount "$WORK_DIR/config" 2>/dev/null
umount "$WORK_DIR" 2>/dev/null
rm -rf "$WORK_DIR"

# 3. 配置与日志数据（用户配置、规则目录、日志都在这里）
rm -rf "$DATA_BASE"

# 4. 脚本临时目录（lib.sh 里 SCRIPT_TEMP_DIR 的父目录）
rm -rf "/data/local/tmp/$CORE_NAME"

# 5. 上游原版模块（id 用架构命名）残留，只删确认是 smartdns 的目录
for old in /data/adb/modules/smartdns-aarch64 /data/adb/modules/smartdns-arm; do
	[ -d "$old" ] || continue
	grep -qi "$CORE_NAME" "$old/module.prop" 2>/dev/null && rm -rf "$old"
done

exit 0
