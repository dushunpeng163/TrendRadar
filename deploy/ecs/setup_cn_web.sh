#!/usr/bin/env bash
# 在国内 Ubuntu 服务器（如阿里云 ECS）上用 nginx 托管 TrendRadar 前端（index.html + assets + snapshot.json）。
#
# 用法（root 执行）：
#   curl -fsSL -m 60 https://ghfast.top/https://raw.githubusercontent.com/<owner>/TrendRadar/master/deploy/ecs/setup_cn_web.sh -o setup_cn_web.sh
#   GH_PROXY=https://ghfast.top/ bash setup_cn_web.sh <owner>/TrendRadar
#
# 做了什么：
#   1. 安装 nginx / git / python3
#   2. 以 sparse checkout 方式克隆仓库到 /opt/trendradar-src（只取 index.html、assets、snapshot.json）
#   3. 安装同步脚本 /usr/local/bin/trendradar-sync（git pull + ntfy 合并 snapshot），cron 每 5 分钟跑一次
#   4. nginx 站点监听 80 端口，根目录 /var/www/trendradar
# 之后在阿里云安全组放行 80/TCP，浏览器访问 http://<公网IP>/ 即可。
set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then echo "用法: $0 <owner>/<repo>  （例如 dushunpeng163/TrendRadar）" >&2; exit 1; fi
if [ "$(id -u)" -ne 0 ]; then echo "请用 root 执行" >&2; exit 1; fi

BRANCH="${BRANCH:-master}"
SRC=/opt/trendradar-src
WEB_ROOT=/var/www/trendradar
GH_PROXY="${GH_PROXY:-}"

echo "==> 安装 nginx / git / python3"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx git python3 ca-certificates curl >/dev/null

echo "==> 克隆仓库（sparse checkout）"
if [ ! -d "$SRC/.git" ]; then
  ok=0
  for prefix in "$GH_PROXY" "" "https://ghfast.top/" "https://ghproxy.net/" "https://gh-proxy.com/"; do
    [ -z "$prefix" ] && [ -n "$GH_PROXY" ] && continue
    url="${prefix}https://github.com/${REPO}.git"
    echo "    尝试: $url"
    rm -rf "$SRC"
    if timeout 300 git clone -q --depth 1 --sparse -b "$BRANCH" "$url" "$SRC" 2>/dev/null; then ok=1; break; fi
  done
  [ "$ok" -eq 1 ] || { echo "克隆失败：GitHub 及镜像都不可达" >&2; exit 1; }
  git -C "$SRC" sparse-checkout set --no-cone /index.html /snapshot.json /assets/ /deploy/ecs/
  # 让后续 pull 走同一个可用源；放宽低速判定避免卡死
  git -C "$SRC" config http.lowSpeedLimit 1000
  git -C "$SRC" config http.lowSpeedTime 60
else
  echo "    已存在 $SRC，跳过克隆"
fi

echo "==> 安装同步脚本与定时任务"
install -m 0755 "$SRC/deploy/ecs/trendradar-sync.py" /usr/local/bin/trendradar-sync
cat > /etc/cron.d/trendradar-sync <<EOF
*/5 * * * * root /usr/local/bin/trendradar-sync >> /var/log/trendradar-sync.log 2>&1
EOF
chmod 0644 /etc/cron.d/trendradar-sync

echo "==> 首次同步"
mkdir -p "$WEB_ROOT"
/usr/local/bin/trendradar-sync || true

echo "==> 配置 nginx"
cat > /etc/nginx/sites-available/trendradar <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root $WEB_ROOT;
    index index.html;

    gzip on;
    gzip_types text/html text/css application/javascript application/json font/woff2;
    gzip_min_length 1024;

    # 页面与数据不缓存，保证手机上拿到的总是最新
    location = /index.html { add_header Cache-Control "no-cache"; }
    location = /snapshot.json { add_header Cache-Control "no-store"; add_header Access-Control-Allow-Origin "*"; }
    location /assets/ { add_header Cache-Control "public, max-age=604800"; }

    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
ln -sf /etc/nginx/sites-available/trendradar /etc/nginx/sites-enabled/trendradar
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx >/dev/null
systemctl reload nginx

IP=$(curl -fsS -m 5 https://myip.ipip.net 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
echo
echo "完成。请到阿里云控制台 → 实例 → 安全组 → 入方向，放行 80/TCP（授权对象 0.0.0.0/0）。"
echo "然后访问: http://${IP:-<公网IP>}/"
echo "同步日志: tail -f /var/log/trendradar-sync.log"
