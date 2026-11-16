#!/usr/bin/env bash
# 让阿里云 ECS 按北京时间准点触发 DSA 的「每日股票分析」和「Qlib 每日量化流水线」，
# 不再依赖 GitHub 自带的定时（实测每次晚 6.5～8 小时）。
#
# 用法（在 ECS 上）:
#   sudo bash /opt/trendradar-src/deploy/ecs/setup_cn_trigger.sh
#
# 它会做什么:
#   1. 让你粘贴 GitHub 令牌（不回显），存到 /etc/dsa-trigger.env（仅 root 可读）
#   2. 安装 /usr/local/bin/dsa-trigger：调用 GitHub 接口触发分析，网络失败自动重试
#   3. 安装 /etc/cron.d/dsa-trigger（北京时间）：
#        工作日 08:20 仅个股、20:30 完整分析
#        周二到周六 07:00 Qlib 量化，用前一交易日的数据。数据源 chenditc/investment_data 每天 18:00～次日 01:00
#        才发布当天数据，所以不能在收盘当晚 18:20 跑，否则多数日子拿到的是前一天的数据
#   4. 可选：立刻触发一次做验证
#
# 令牌要求：Fine-grained token，只选 daily_stock_analysis 仓库，Repository permissions → Actions: Read and write。
# 换令牌 / 改时间：重新运行本脚本即可。卸载：sudo rm /etc/cron.d/dsa-trigger /usr/local/bin/dsa-trigger /etc/dsa-trigger.env
set -euo pipefail

REPO="${1:-dushunpeng163/daily_stock_analysis}"
WORKFLOW="00-daily-analysis.yml"
QLIB_WORKFLOW="30-quant-pipeline.yml"
BRANCH="main"
GH_API="${GH_API:-https://api.github.com}"
DESTDIR="${DESTDIR:-}"                       # 仅测试用：把文件装到别的目录
ENV_FILE="$DESTDIR/etc/dsa-trigger.env"
BIN="$DESTDIR/usr/local/bin/dsa-trigger"
CRON_FILE="$DESTDIR/etc/cron.d/dsa-trigger"
LOG="${DESTDIR:+$DESTDIR}/var/log/dsa-trigger.log"

if [ -z "$DESTDIR" ]; then
  [ "$(id -u)" = 0 ] || { echo "请用 sudo 运行: sudo bash $0"; exit 1; }
  TZ_NOW="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo unknown)"
  if [ "$TZ_NOW" != "Asia/Shanghai" ]; then
    echo "服务器时区是 ${TZ_NOW}，不是 Asia/Shanghai，定时会跑偏。请先执行下面两条再重新运行本脚本:"
    echo "  sudo timedatectl set-timezone Asia/Shanghai"
    echo "  sudo systemctl restart cron"
    exit 1
  fi
fi
mkdir -p "$(dirname "$ENV_FILE")" "$(dirname "$BIN")" "$(dirname "$CRON_FILE")" "$(dirname "$LOG")"

echo "==> 1/4 GitHub 令牌"
TOKEN="${DSA_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  if [ -f "$ENV_FILE" ]; then
    read -rsp "粘贴新的 GitHub 令牌后回车（输入不显示；直接回车 = 沿用已保存的令牌）: " TOKEN </dev/tty || TOKEN=""; echo
  else
    read -rsp "粘贴 GitHub 令牌后回车（输入不显示）: " TOKEN </dev/tty || TOKEN=""; echo
  fi
fi
TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
if [ -z "$TOKEN" ] && [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  TOKEN="$(. "$ENV_FILE" && printf '%s' "$GH_TOKEN")"
fi
[ -n "$TOKEN" ] || { echo "没有输入令牌，已退出"; exit 1; }

echo "    校验令牌能否访问 $REPO 的分析任务..."
code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
  "$GH_API/repos/$REPO/actions/workflows/$WORKFLOW" 2>/dev/null || true)"
case "$code" in
  200) echo "    令牌有效" ;;
  401) echo "    令牌无效或已过期（http 401）。请重新生成后再运行本脚本"; exit 1 ;;
  403|404) echo "    令牌没有这个仓库的 Actions 权限（http ${code}）。生成时要选中 ${REPO}，并给 Actions: Read and write"; exit 1 ;;
  *) echo "    暂时连不上 GitHub（http ${code:-000}），先继续安装；触发时会自动重试" ;;
esac

umask 077
cat > "$ENV_FILE" <<EOF
GH_TOKEN=$TOKEN
REPO=$REPO
WORKFLOW=$WORKFLOW
QLIB_WORKFLOW=$QLIB_WORKFLOW
BRANCH=$BRANCH
GH_API=$GH_API
LOG=$LOG
EOF
chmod 600 "$ENV_FILE"
umask 022

echo "==> 2/4 安装触发脚本 $BIN"
cat > "$BIN" <<EOF
#!/usr/bin/env bash
# 触发 DSA 的分析任务。用法:
#   dsa-trigger <full|stocks-only|market-only> [force]   每日股票分析；force = 跳过交易日检查（节假日也跑）
#   dsa-trigger qlib                                     Qlib 每日量化流水线
set -uo pipefail
. "$ENV_FILE"
EOF
cat >> "$BIN" <<'EOF'
MODE="${1:-full}"
FORCE="false"; [ "${2:-}" = "force" ] && FORCE="true"
case "$MODE" in
  full|stocks-only|market-only)
    WF="$WORKFLOW"; DESC="每日股票分析 mode=$MODE force=$FORCE"
    BODY="{\"ref\":\"$BRANCH\",\"inputs\":{\"mode\":\"$MODE\",\"force_run\":\"$FORCE\"}}" ;;
  qlib)
    WF="${QLIB_WORKFLOW:-30-quant-pipeline.yml}"; DESC="Qlib 每日量化流水线"
    BODY="{\"ref\":\"$BRANCH\"}" ;;
  *) echo "模式只能是 full / stocks-only / market-only / qlib"; exit 2 ;;
esac
RETRY_SLEEP="${RETRY_SLEEP:-60}"
say() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
for i in 1 2 3 4 5 6; do
  code="$(curl -sS -m 30 -o "$OUT" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    "$GH_API/repos/$REPO/actions/workflows/$WF/dispatches" \
    -d "$BODY" 2>/dev/null || true)"
  if [ "$code" = "204" ]; then
    say "已触发 ${DESC}（第 ${i} 次尝试）"
    exit 0
  fi
  say "触发失败 ${DESC} http=${code:-000}（第 ${i} 次尝试）$(head -c 200 "$OUT" 2>/dev/null | tr '\n' ' ')"
  case "$code" in
    401) say "令牌无效或已过期：重新运行 setup_cn_trigger.sh 换一个令牌"; exit 1 ;;
    403|404|422) say "令牌权限不足或参数不对，重试无用"; exit 1 ;;
  esac
  [ "$i" -lt 6 ] && sleep "$RETRY_SLEEP"
done
say "连续 6 次失败，放弃本次触发"
exit 1
EOF
chmod 755 "$BIN"

echo "==> 3/4 安装定时 $CRON_FILE"
cat > "$CRON_FILE" <<EOF
# 北京时间（服务器时区 Asia/Shanghai）。节假日由分析任务自己的交易日检查跳过。
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
20 8 * * 1-5 root /usr/local/bin/dsa-trigger stocks-only >/dev/null 2>&1
30 20 * * 1-5 root /usr/local/bin/dsa-trigger full >/dev/null 2>&1
# Qlib 用前一交易日的数据；数据源最晚次日 01:00 前后才发布，所以放在周二到周六早上
0 7 * * 2-6 root /usr/local/bin/dsa-trigger qlib >/dev/null 2>&1
EOF
chmod 644 "$CRON_FILE"

echo "==> 4/4 验证"
if [ -z "$DESTDIR" ] && [ -z "${DSA_NO_TEST:-}" ]; then
  echo "    要不要立刻触发一次做验证？  1 = 仅个股分析（约 30 分钟）   2 = Qlib 量化（约 5 分钟）   直接回车 = 不触发"
  read -rp "    请输入 1 / 2 / 回车: " ans </dev/tty || ans=""
  case "${ans:-}" in
    1) "$BIN" stocks-only force && echo "    触发成功：GitHub 仓库的 Actions 页面会出现一条新的运行" || echo "    触发失败，原因见上一行" ;;
    2) "$BIN" qlib && echo "    触发成功：GitHub 仓库的 Actions 页面会出现一条新的 Qlib 运行" || echo "    触发失败，原因见上一行" ;;
    *) echo "    已跳过。之后可手动执行: sudo dsa-trigger stocks-only   或   sudo dsa-trigger qlib" ;;
  esac
fi

echo
echo "完成。定时（北京时间）：工作日 08:20 仅个股、20:30 完整分析；周二到周六 07:00 Qlib 量化"
echo "触发记录: tail -n 20 $LOG"
echo "手动触发: sudo dsa-trigger full   （加 force 可跳过交易日检查）   Qlib: sudo dsa-trigger qlib"
