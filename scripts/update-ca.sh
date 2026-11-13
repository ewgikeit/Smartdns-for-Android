#!/bin/sh
# 重新生成 binary/ca-certificates.zip（Mozilla 根证书库）
#
# 数据来源：https://curl.se/ca/cacert.pem（Mozilla 官方信任库的 PEM 打包）
# 产物结构（与历史版本保持一致）：
#   CA/ca-certificates.crt   合并包，smartdns 的 ca-file 指向它
#   CA/<证书名>.crt          单证书文件，供 ca-path 使用
#   binary/CA_VERSION        记录本次使用的 Mozilla 快照日期
#
# 用法：sh scripts/update-ca.sh
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/binary/ca-certificates.zip"
VER_FILE="$ROOT/binary/CA_VERSION"
URL="https://curl.se/ca/cacert.pem"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t cacert)
# 统一成 POSIX 路径：Git Bash 下 mktemp 会给出 C:\... 形式，
# 带反斜杠的路径传给 awk -v 会被当转义序列吃掉
TMP=$(cd "$TMP" && pwd)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "==> 下载 $URL"
curl -fsSL --retry 3 --retry-delay 5 --max-time 120 "$URL" -o "$TMP/cacert.pem"

count=$(grep -c '^-----BEGIN CERTIFICATE-----' "$TMP/cacert.pem" || true)
echo "==> 证书数量：$count"
# 数量异常说明下载被劫持/截断，宁可不更新
[ "$count" -ge 60 ] || { echo "证书数量过少，疑似下载不完整，已放弃" >&2; exit 1; }
[ "$count" -le 400 ] || { echo "证书数量过多，疑似内容异常，已放弃" >&2; exit 1; }

stamp=$(sed -n 's/^## Certificate data from Mozilla as of: //p' "$TMP/cacert.pem" | head -n 1)
[ -n "$stamp" ] || stamp="unknown"

mkdir -p "$TMP/CA"

# 1) 先按 PEM 块拆分
awk -v dir="$TMP/CA" '
	/^-----BEGIN CERTIFICATE-----$/ { n++; file = sprintf("%s/cert-%03d.pem", dir, n); inblk = 1 }
	inblk { print > file }
	/^-----END CERTIFICATE-----$/ { close(file); inblk = 0 }
' "$TMP/cacert.pem"

split_n=$(ls "$TMP"/CA/cert-*.pem 2>/dev/null | wc -l | tr -d ' ')
[ "$split_n" = "$count" ] || { echo "拆分结果($split_n)与证书数($count)不符" >&2; exit 1; }

# 2) 用 CN 命名（去掉非 ASCII，避免不同平台解压时乱码；重名自动加序号）
for f in "$TMP"/CA/cert-*.pem; do
	cn=$(openssl x509 -in "$f" -noout -subject -nameopt multiline 2>/dev/null \
		| sed -n 's/^ *commonName *= *//p' | head -n 1)
	if [ -z "$cn" ]; then
		cn=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^subject=//; s/.*CN *= *//')
	fi
	name=$(printf '%s' "$cn" | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-80)
	[ -n "$name" ] || name='cert'
	base="$name"
	k=2
	while [ -e "$TMP/CA/$name.crt" ]; do
		name="$base-$k"
		k=$((k + 1))
	done
	mv "$f" "$TMP/CA/$name.crt"
done

# 3) 合并包：先按文件名排序再拼接，保证输出稳定（便于 diff）
cat $(ls "$TMP"/CA/*.crt | sort) > "$TMP/CA/ca-certificates.crt"

bundle_n=$(grep -c '^-----BEGIN CERTIFICATE-----' "$TMP/CA/ca-certificates.crt" || true)
[ "$bundle_n" = "$count" ] || { echo "合并包证书数($bundle_n)不符" >&2; exit 1; }
echo "==> 合并包证书数：$bundle_n；Mozilla 快照：$stamp"

# 4) 打包（优先 zip，缺失时退回 python3）
rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
	(cd "$TMP" && zip -qr "$OUT" CA)
elif command -v python3 >/dev/null 2>&1; then
	python3 - "$TMP" "$OUT" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(src, 'CA'), 'CA')
    for name in sorted(os.listdir(os.path.join(src, 'CA'))):
        z.write(os.path.join(src, 'CA', name), 'CA/' + name)
PY
else
	echo '缺少 zip / python3，无法打包' >&2
	exit 1
fi

printf '%s\n' "$stamp" > "$VER_FILE"
echo "==> 已生成 $OUT（$(wc -c < "$OUT" | tr -d ' ') 字节）"
echo "==> 版本标记 $VER_FILE：$stamp"
