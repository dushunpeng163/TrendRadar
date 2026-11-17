#!/usr/bin/env bash
# 把看板改成「只有自己能看」：登录密码 + 加密传输（HTTPS）+ 私密的消息主题。
#
# 用法（在 ECS 上）:
#   sudo bash /opt/trendradar-src/deploy/ecs/setup_cn_private.sh
#
# 它会做什么:
#   1. 让你设一个登录账号和密码（不回显），存成加密摘要 /etc/nginx/trendradar.htpasswd
#   2. 生成本机的 HTTPS 证书（自签名，绑定公网 IP，10 年）。自签名证书浏览器第一次会提示「不受信任」，
#      确认继续即可；之后传输全程加密，途中的设备看不到内容
#   3. 生成一个随机的私密消息主题，存到 /etc/trendradar/private.env（仅 root 可读）。
#      旧主题 trendradar-mac-511 写在公开代码里，任何人都能读；新主题名只有这台服务器、你的 GitHub 私密设置和你的手机知道
#   4. 更新同步脚本（改读私密主题），同步间隔 5 分钟 → 2 分钟
#   5. nginx：80 端口只做跳转，443 端口要求登录
#
# 运行前：到阿里云控制台 → 实例 → 安全组 → 入方向，放行 443/TCP（授权对象 0.0.0.0/0）。不放行的话页面会打不开。
# 运行后还有两步要你自己做（脚本结束时会再提示一次）：
#   a. GitHub → daily_stock_analysis 仓库 → Settings → Secrets and variables → Actions → NTFY_URL，改成脚本打印的新地址
#   b. 手机 ntfy App：订阅新主题，退订旧主题
# 可以重复运行：直接回车 = 沿用已有的账号密码；证书和主题已存在就不会重新生成（想换主题：加参数 --new-topic）。
# 撤销：sudo cp /etc/nginx/sites-available/trendradar.before-private /etc/nginx/sites-available/trendradar && sudo systemctl reload nginx
set -euo pipefail

DESTDIR="${DESTDIR:-}"                      # 仅测试用：所有文件写到这个目录下
SRC="${TR_SRC:-/opt/trendradar-src}"
WEB_ROOT="${TR_WEB_ROOT:-$DESTDIR/var/www/trendradar}"
HTTP_PORT="${TR_HTTP_PORT:-80}"
HTTPS_PORT="${TR_HTTPS_PORT:-443}"
ENV_FILE="$DESTDIR/etc/trendradar/private.env"
HTPASSWD="$DESTDIR/etc/nginx/trendradar.htpasswd"
SSL_DIR="$DESTDIR/etc/nginx/ssl"
CERT="$SSL_DIR/trendradar.crt"
KEY="$SSL_DIR/trendradar.key"
SITE="$DESTDIR/etc/nginx/sites-available/trendradar"
SITE_LINK="$DESTDIR/etc/nginx/sites-enabled/trendradar"
LIMIT_CONF="$DESTDIR/etc/nginx/conf.d/trendradar-limit.conf"
SYNC_BIN="$DESTDIR/usr/local/bin/trendradar-sync"
CRON_FILE="$DESTDIR/etc/cron.d/trendradar-sync"
NEW_TOPIC=0
IP_ARG=""
for a in "$@"; do
  case "$a" in
    --new-topic) NEW_TOPIC=1 ;;
    *) IP_ARG="$a" ;;
  esac
done

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then echo "请用 root 执行：sudo bash $0" >&2; exit 1; fi
for c in openssl nginx python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少 ${c}，请先运行 setup_cn_web.sh 安装基础环境" >&2; exit 1; }
done
[ -f "$SRC/deploy/ecs/trendradar-sync.py" ] || { echo "找不到 ${SRC}/deploy/ecs/trendradar-sync.py，请确认仓库已同步" >&2; exit 1; }
mkdir -p "$(dirname "$ENV_FILE")" "$(dirname "$HTPASSWD")" "$SSL_DIR" "$(dirname "$SITE")" "$(dirname "$SITE_LINK")" \
         "$(dirname "$LIMIT_CONF")" "$(dirname "$SYNC_BIN")" "$(dirname "$CRON_FILE")" "$WEB_ROOT"

# ---------- 1. 账号密码 ----------
echo "==> 1/5 登录账号和密码"
USER_NAME="${TR_USER:-}"
PASS="${TR_PASS:-}"
if [ -z "$PASS" ] && [ -z "${TR_NONINTERACTIVE:-}" ]; then
  if [ -s "$HTPASSWD" ]; then echo "    已有账号：$(cut -d: -f1 "$HTPASSWD" | head -1)。直接回车 = 沿用，输入新密码 = 更换"; fi
  read -rp "    账号（回车默认 me）: " USER_NAME </dev/tty || USER_NAME=""
  while :; do
    read -rsp "    密码（至少 10 位，输入时不显示）: " PASS </dev/tty || PASS=""
    echo
    if [ -z "$PASS" ]; then
      if [ -s "$HTPASSWD" ]; then break; fi
      echo "    第一次设置必须输入密码"; continue
    fi
    if [ "${#PASS}" -lt 10 ]; then echo "    太短了，至少 10 位"; continue; fi
    read -rsp "    再输入一次: " PASS2 </dev/tty || PASS2=""
    echo
    if [ "$PASS" = "$PASS2" ]; then break; fi
    echo "    两次不一致，重来"
  done
fi
if [ -n "$PASS" ]; then
  if [ "${#PASS}" -lt 10 ]; then echo "密码至少 10 位" >&2; exit 1; fi
  USER_NAME="${USER_NAME:-me}"
  case "$USER_NAME" in *:*|*" "*) echo "账号里不能有冒号或空格" >&2; exit 1 ;; esac
  HASH="$(printf '%s' "$PASS" | openssl passwd -apr1 -stdin)"
  umask 027
  printf '%s:%s\n' "$USER_NAME" "$HASH" > "$HTPASSWD"
  umask 022
  echo "    已保存账号 ${USER_NAME}（只存加密摘要，不存明文）"
elif [ -s "$HTPASSWD" ]; then
  USER_NAME="$(cut -d: -f1 "$HTPASSWD" | head -1)"
  echo "    沿用已有账号 ${USER_NAME}"
else
  echo "没有设置密码，已中止（未做任何改动）" >&2; exit 1
fi
PASS=""; PASS2=""
# nginx 的工作进程（www-data）要能读这个文件，其他用户不能读
if [ -z "$DESTDIR" ]; then
  if getent group www-data >/dev/null 2>&1; then chown root:www-data "$HTPASSWD"; chmod 640 "$HTPASSWD"; else chmod 644 "$HTPASSWD"; fi
fi

# ---------- 2. 证书 ----------
echo "==> 2/5 HTTPS 证书"
IP="${TR_IP:-$IP_ARG}"
if [ -z "$IP" ]; then
  IP="$(curl -fsS -m 6 https://myip.ipip.net 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
if [ -z "$IP" ]; then
  IP="$(curl -fsS -m 6 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
fi
if [ -z "$IP" ]; then echo "没能自动识别公网 IP，请这样运行：sudo bash $0 <公网IP>" >&2; exit 1; fi
if [ -s "$CERT" ] && [ -s "$KEY" ] && openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -q "IP Address:${IP}\$"; then
  echo "    证书已存在（绑定 ${IP}），不重新生成"
else
  umask 077
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$KEY" -out "$CERT" \
    -subj "/CN=${IP}" -addext "subjectAltName=IP:${IP}" >/dev/null 2>&1
  umask 022
  chmod 600 "$KEY"; chmod 644 "$CERT"
  echo "    已生成自签名证书（绑定 ${IP}，有效期 10 年）"
fi
FP="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2)"

# ---------- 3. 私密主题 ----------
echo "==> 3/5 私密消息主题"
TOPIC=""
if [ -s "$ENV_FILE" ]; then TOPIC="$(grep -E '^TR_NTFY_TOPIC=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"; fi
if [ -z "$TOPIC" ] || [ "$NEW_TOPIC" -eq 1 ]; then
  TOPIC="tr-$(openssl rand -hex 16)"
  umask 077
  printf 'TR_NTFY_TOPIC=%s\nTR_NTFY_BASE=https://ntfy.sh\n' "$TOPIC" > "$ENV_FILE"
  umask 022
  echo "    已生成新主题（32 位随机字符，猜不到）"
else
  echo "    沿用已有的私密主题"
fi
chmod 600 "$ENV_FILE"

# ---------- 4. 同步脚本 ----------
echo "==> 4/5 更新同步脚本，间隔改为 2 分钟"
install -m 0755 "$SRC/deploy/ecs/trendradar-sync.py" "$SYNC_BIN"
cat > "$CRON_FILE" <<EOF
*/2 * * * * root /usr/local/bin/trendradar-sync >> /var/log/trendradar-sync.log 2>&1
EOF
chmod 0644 "$CRON_FILE"
if [ -z "$DESTDIR" ]; then "$SYNC_BIN" || true; fi

# ---------- 5. nginx ----------
echo "==> 5/5 配置 nginx（${HTTP_PORT} 只跳转，${HTTPS_PORT} 要求登录）"
if [ -f "$SITE" ] && [ ! -f "$SITE.before-private" ]; then cp -p "$SITE" "$SITE.before-private"; fi
[ -f "$SITE" ] && cp -p "$SITE" "$SITE.rollback"
REDIRECT_PORT=""; [ "$HTTPS_PORT" != "443" ] && REDIRECT_PORT=":$HTTPS_PORT"
cat > "$LIMIT_CONF" <<'EOF'
# 限制单个来源的请求频率，防止有人不停地试密码
limit_req_zone $binary_remote_addr zone=tr_auth:10m rate=5r/s;
EOF
cat > "$SITE" <<EOF
# 由 setup_cn_private.sh 生成。${HTTP_PORT} 端口不提供任何内容，只跳到加密地址，避免密码和数据明文传输。
server {
    listen ${HTTP_PORT} default_server;
    listen [::]:${HTTP_PORT} default_server;
    server_name _;
    server_tokens off;
    return 301 https://\$host${REDIRECT_PORT}\$request_uri;
}

server {
    listen ${HTTPS_PORT} ssl default_server;
    listen [::]:${HTTPS_PORT} ssl default_server;
    server_name _;
    server_tokens off;
    root $WEB_ROOT;
    index index.html;

    ssl_certificate     $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:tr_ssl:5m;

    # 所有内容（页面、数据、资源）都要先登录
    auth_basic "511";
    auth_basic_user_file $HTPASSWD;
    limit_req zone=tr_auth burst=60 nodelay;

    gzip on;
    gzip_types text/html text/css application/javascript application/json font/woff2;
    gzip_min_length 1024;

    # 页面与数据不缓存，保证拿到的总是最新；数据不允许其它网站跨域读取
    location = /index.html { add_header Cache-Control "no-cache"; add_header X-Robots-Tag "noindex, nofollow"; }
    location = /snapshot.json { add_header Cache-Control "no-store"; add_header X-Robots-Tag "noindex, nofollow"; }
    location /assets/ { add_header Cache-Control "private, max-age=604800"; }

    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
ln -sf "$SITE" "$SITE_LINK" 2>/dev/null || true
if [ -z "$DESTDIR" ]; then
  if nginx -t 2>/tmp/trendradar-nginx-test.log; then
    systemctl reload nginx
    rm -f "$SITE.rollback"
  else
    echo "nginx 配置检查没通过，已恢复原来的配置（页面不受影响）。错误信息：" >&2
    cat /tmp/trendradar-nginx-test.log >&2
    if [ -f "$SITE.rollback" ]; then mv -f "$SITE.rollback" "$SITE"; else rm -f "$SITE"; fi
    rm -f "$LIMIT_CONF"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    exit 1
  fi
fi

URL="https://${IP}${REDIRECT_PORT}/"
echo
echo "完成。以后用这个地址访问（账号 ${USER_NAME}）： ${URL}"
echo "第一次打开浏览器会提示证书不受信任，点「高级 → 继续访问」。证书指纹（SHA-256），想核对时在浏览器的证书详情里比对："
echo "  ${FP}"
echo
echo "还有两步需要你自己做，做完之前新的分析不会出现在页面上："
echo "  a. GitHub → daily_stock_analysis 仓库 → Settings → Secrets and variables → Actions → NTFY_URL → 更新为："
echo "       https://ntfy.sh/${TOPIC}"
echo "  b. 手机 ntfy App：订阅主题 ${TOPIC}（服务器 ntfy.sh），然后退订旧主题 trendradar-mac-511"
echo "这个主题名相当于密码，不要发给别人，也不要贴到聊天里。忘了可以再运行本脚本查看。"
echo "如果页面打不开：检查阿里云安全组入方向是否放行了 443/TCP。"
