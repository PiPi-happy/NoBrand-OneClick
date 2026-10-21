#!/usr/bin/env bash
# ena-agent — ExtraNodeAccess 中转 VPS 通信脚本 (v2.1 全量同步)
#
# 面板生成完整配置表 → 本脚本拉取后合并进本机 users.json →
# 一条 `nobrand mieru --user-restore` 应用全部用户（含 tc 限速）。
# 语义：缺的创建、多的删除、参数变化自动更新。面板是唯一事实源。
#
# 配置文件 /etc/ena-agent.conf:
#   ENA_URL="https://面板域名/api/v2/ena-agent/v1"
#   ENA_TOKEN="节点Token"
#   ENA_NODE="节点名"
#   ENA_NOBRAND="nobrand"        # 可选
#   ENA_ADV_HOST="120.x.x.x"     # 可选，覆盖面板播报地址
set -u
export LC_ALL=C

CONF="${ENA_CONF:-/etc/ena-agent.conf}"
LOG="${ENA_LOG:-/var/log/ena-agent.log}"
LOCK="/var/run/ena-agent.lock"
CURL_OPTS=(--max-time 25 -sS)

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

[ -r "$CONF" ] && . "$CONF"
: "${ENA_URL:?ENA_URL 未配置}"
: "${ENA_TOKEN:?ENA_TOKEN 未配置}"
: "${ENA_NODE:?ENA_NODE 未配置}"
ENA_NOBRAND="${ENA_NOBRAND:-nobrand}"

exec 9>"$LOCK" || exit 1
flock -n 9 || { log "已有实例在运行，跳过"; exit 0; }

command -v jq >/dev/null || { log "缺少 jq：apt-get install -y jq"; exit 1; }
command -v python3 >/dev/null || { log "缺少 python3"; exit 1; }
command -v "$ENA_NOBRAND" >/dev/null || { log "缺少 $ENA_NOBRAND（NoBrand-OneClick）"; exit 1; }

log "=== 开始拉取期望状态 ==="
RESP=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer $ENA_TOKEN" \
    -H "X-ENA-Node: $ENA_NODE" "$ENA_URL/desired" 2>&1) || { log "拉取失败: $RESP"; exit 1; }

STATUS=$(printf '%s' "$RESP" | jq -r '.status // empty' 2>/dev/null)
[ "$STATUS" = "success" ] || { log "面板返回异常: $(printf '%s' "$RESP" | head -c 200)"; exit 1; }

ADV_HOST_DEFAULT=$(printf '%s' "$RESP" | jq -r '.data.node.advertise_host // empty')
[ -n "${ENA_ADV_HOST:-}" ] && ADV_HOST_DEFAULT="$ADV_HOST_DEFAULT"

VERSION=$(printf '%s' "$RESP" | jq -r '.data.version // ""')

LOCAL_JSON="/var/lib/nobrand-oneclick/mieru/users.json"
[ -r "$LOCAL_JSON" ] || { log "本机 users.json 不存在: $LOCAL_JSON"; exit 1; }

# ---- 期望配置表落盘 ----
TABLE_FILE=$(mktemp /tmp/ena-table.XXXXXX)
printf '%s' "$RESP" | jq '.data.table' > "$TABLE_FILE" 2>/dev/null
jq -e '.users | type == "array"' "$TABLE_FILE" >/dev/null 2>&1 || {
    log "期望配置表解析失败"; rm -f "$TABLE_FILE"; exit 1;
}

REPORT_FILE=$(mktemp /tmp/ena-report.XXXXXX)
NEW_LOCAL=$(mktemp /tmp/ena-users.XXXXXX.json)
# Python 合并: 期望配置表 + 本机现状 → 新 users.json + 回报数据
#  已有用户保留 instance_id / ingress / created_at 等本机字段;
#  新用户生成 instance_id 并克隆本机首个用户作模板;
#  本机多出的 ena* 用户不进入新配置 (restore 覆盖后自动消失)
python3 - "$LOCAL_JSON" "$TABLE_FILE" "$NEW_LOCAL" "$REPORT_FILE" << 'ENA_PY'
import json, sys, time, hashlib

loc_path, tbl_path, out_path, rep_path = sys.argv[1:5]
loc = json.load(open(loc_path))
tbl = json.load(open(tbl_path))
lmap = {u["name"]: u for u in loc.get("users", [])}
users_old = [u["name"] for u in loc.get("users", [])]
now = int(time.time())
applied, disabled, deleted = [], [], []
out_users = []
tpl = loc["users"][0] if loc.get("users") else {
    "ingress_profile_id": "legacy-default-route",
    "ingress_enforcement": "permissive",
    "ingress_enforcement_method": "wildcard",
    "ingress_local_address": "",
}
for u in tbl.get("users", []):
    name = u["name"]
    base = lmap.get(name)
    if base is None:
        base = dict(tpl) if isinstance(tpl, dict) else {}
        base["instance_id"] = "u" + hashlib.md5(name.encode()).hexdigest()[:16]
        base.setdefault("quota_mode", "rolling")
        base.setdefault("last_quota_reset", "")
        base.setdefault("package", "unlimited")
        base.setdefault("created_at", now)
    base.update({
        "name": name,
        "password": u["password"],
        "port": u["port"],
        "advertise_host": tbl.get("advertise_host", ""),
        "advertise_port": u["port"],
        "enabled": bool(u["enabled"]),
        "quota_mb": u.get("quota_mb", 0),
        "quota_days": u.get("quota_days", 30),
        "expire_at": u.get("expire_at", ""),
        "bandwidth_mbps": u.get("bandwidth_mbps", 0),
        "updated_at": now,
    })
    out_users.append(base)
    (applied if u["enabled"] else disabled).append(name)

loc["users"] = sorted(out_users, key=lambda x: x.get("port", 0))
json.dump(loc, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

desired_names = {u["name"] for u in tbl.get("users", [])}
for name in users_old:
    if name.startswith("ena") and name not in desired_names:
        deleted.append(name)

json.dump({"applied": applied, "disabled": disabled, "deleted": deleted},
          open(rep_path, "w", encoding="utf-8"), ensure_ascii=False)
ENA_PY

[ -s "$REPORT_FILE" ] || { log "Python 合并失败"; rm -f "$TABLE_FILE" "$NEW_LOCAL" "$REPORT_FILE"; exit 1; }
jq -e '.users | type == "array"' "$NEW_LOCAL" >/dev/null 2>&1 || {
    log "合并结果校验失败"; rm -f "$TABLE_FILE" "$NEW_LOCAL" "$REPORT_FILE"; exit 1;
}

APPLIED=$(jq -c '.applied' "$REPORT_FILE")
DISABLED=$(jq -c '.disabled' "$REPORT_FILE")
DELETED=$(jq -c '.deleted' "$REPORT_FILE")
N_OK=$(jq '.applied | length' "$REPORT_FILE")
N_DIS=$(jq '.disabled | length' "$REPORT_FILE")
N_DEL=$(jq '.deleted | length' "$REPORT_FILE")

cp "$LOCAL_JSON" "$LOCAL_JSON.bak.$(date +%s)" 2>/dev/null
log "应用配置表: 保留/新增 $(jq '.users | length' "$NEW_LOCAL") 用户, 生效 $N_OK, 停用 $N_DIS, 移除 $N_DEL"
if ! timeout 300 "$ENA_NOBRAND" mieru --user-restore "$NEW_LOCAL" >>"$LOG" 2>&1; then
    ERRORS=$(printf '%s' "$ERRORS" | jq '. + [{username:"restore",message:"user-restore 失败, 详见日志"}]')
    N_ERR=1; log "❌ user-restore 失败 (已保留备份)"
else
    log "✅ user-restore 应用成功"
fi

# ---- 移除：restore 为合并导入，本机多出的 ena 前缀用户需显式删除 ----
DESIRED_NAMES=$(printf '%s' "$RESP" | jq -r '.data.table.users[]?.name' | sort)
while read -r LU; do
    [ -z "$LU" ] && continue
    case "$LU" in ena*) ;; *) continue ;; esac
    if ! printf '%s\n' "$DESIRED_NAMES" | grep -qxF "$LU"; then
        if timeout 60 "$ENA_NOBRAND" mieru --user-del "$LU" -y >>"$LOG" 2>&1; then
            DELETED=$(printf '%s' "$DELETED" | jq --arg u "$LU" '. + [$u]')
            N_DEL=$((N_DEL+1)); log "移除多余用户: $LU"
        else
            log "移除失败: $LU（下轮重试）"
        fi
    fi
done < <(printf '%s\n' "$LOCAL_NAMES_BEFORE")

rm -f "$TABLE_FILE" "$NEW_LOCAL" "$REPORT_FILE"

# ---- 回报 ----
BODY=$(jq -n --argjson a "$APPLIED" --argjson d "$DISABLED" --argjson e "$ERRORS" --argjson x "$DELETED" \
    '{applied:$a, disabled:$d, errors:$e, deleted:$x, version:'"\"$VERSION\""' }')
RESP2=$(curl "${CURL_OPTS[@]}" -X POST -H "Authorization: Bearer $ENA_TOKEN" \
    -H "X-ENA-Node: $ENA_NODE" -H "Content-Type: application/json" \
    -d "$BODY" "$ENA_URL/report" 2>&1) || RESP2="report-failed"

log "=== 完成: 生效 $N_OK, 停用 $N_DIS, 移除 $N_DEL, 失败 $N_ERR | report: $(printf '%s' "$RESP2" | head -c 120) ==="
