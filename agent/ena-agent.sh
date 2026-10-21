#!/usr/bin/env bash
# ena-agent — ExtraNodeAccess 中转 VPS 通信脚本 (v2.0 M2)
#
# 从面板拉取 Mieru 期望状态，调用 nobrand mieru CLI 幂等收敛本机用户，
# 并回报执行结果。面板是唯一事实源；本脚本除显式 deleted 外不删除用户。
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
command -v "$ENA_NOBRAND" >/dev/null || { log "缺少 $ENA_NOBRAND（NoBrand-OneClick）"; exit 1; }

log "=== 开始拉取期望状态 ==="
RESP=$(curl "${CURL_OPTS[@]}" -H "Authorization: Bearer $ENA_TOKEN" \
    -H "X-ENA-Node: $ENA_NODE" "$ENA_URL/desired" 2>&1) || { log "拉取失败: $RESP"; exit 1; }

STATUS=$(printf '%s' "$RESP" | jq -r '.status // empty' 2>/dev/null)
[ "$STATUS" = "success" ] || { log "面板返回异常: $(printf '%s' "$RESP" | head -c 200)"; exit 1; }

ADV_HOST_DEFAULT=$(printf '%s' "$RESP" | jq -r '.data.node.advertise_host // empty')
[ -n "${ENA_ADV_HOST:-}" ] && ADV_HOST_DEFAULT="$ENA_ADV_HOST"

VERSION=$(printf '%s' "$RESP" | jq -r '.data.version // ""')

# 本机现状：用户名 -> 端口（nobrand 用户表第二列）
USERS_TABLE=$(timeout 30 "$ENA_NOBRAND" mieru --users 2>/dev/null || true)
user_port() { printf '%s' "$USERS_TABLE" | awk -v u="$1" '$1==u {print $2; exit}'; }

APPLIED='[]'; DISABLED='[]'; ERRORS='[]'; DELETED='[]'
N_OK=0; N_DIS=0; N_ERR=0; N_DEL=0
LOCAL_JSON="/var/lib/nobrand-oneclick/mieru/users.json"
[ -r "$LOCAL_JSON" ] || { log "本机 users.json 不存在: $LOCAL_JSON"; exit 1; }

# ---- 合并前的本机用户名快照（孤儿对照用，读文件不依赖 nobrand 锁） ----
LOCAL_NAMES_BEFORE=$(jq -r '.users[]?.name' "$LOCAL_JSON" 2>/dev/null | sort || true)

# ---- 期望配置表落盘 ----
TABLE_FILE=$(mktemp /tmp/ena-table.XXXXXX)
printf '%s' "$RESP" | jq '.data.table' > "$TABLE_FILE" 2>/dev/null
jq -e '.users | type == "array"' "$TABLE_FILE" >/dev/null 2>&1 || {
    log "期望配置表解析失败"; rm -f "$TABLE_FILE"; exit 1;
}

# ---- 合并: 期望表 + 本机现状 → 新 users.json ----
#  已有用户: 保留 instance_id / ingress 等本机字段, 更新核心字段
#  新用户:   instance_id 按用户名生成, ingress 字段克隆本机首个用户
#  本机多出的 ena* 用户: 不进入新配置 (restore 覆盖后自动消失)
NEW_LOCAL=$(mktemp /tmp/ena-users.XXXXXX.json)
log "jq 版本: $(jq --version 2>&1)"
jq --slurpfile loc "$LOCAL_JSON" --slurpfile tbl "$TABLE_FILE" '
  ($tbl[0]) as $t
  | $loc[0] as $L
  | ($L.users | map({key:.name, value:.}) | from_entries) as $lm
  | ($L.users[0] // null) as $tpl
  | ($L | .users = [
      $t.users[] | . as $u |
      (if $lm[$u.name] then
         ($lm[$u.name] * {
            password: $u.password,
            port: $u.port,
            advertise_host: $t.advertise_host,
            advertise_port: $u.port,
            enabled: $u.enabled,
            quota_mb: $u.quota_mb,
            quota_days: $u.quota_days,
            expire_at: $u.expire_at,
            bandwidth_mbps: $u.bandwidth_mbps,
            updated_at: (now|floor)
         })
       else
         (($tpl // {}) * {
            instance_id: ("u" + ($u.name | @base64 | gsub("[^a-zA-Z0-9]";"") | .[0:16])),
            name: $u.name,
            password: $u.password,
            port: $u.port,
            advertise_host: $t.advertise_host,
            advertise_port: $u.port,
            enabled: $u.enabled,
            quota_mb: $u.quota_mb,
            quota_days: $u.quota_days,
            quota_mode: "rolling",
            last_quota_reset: "",
            expire_at: $u.expire_at,
            package: "unlimited",
            bandwidth_mbps: $u.bandwidth_mbps,
            created_at: (now|floor),
            updated_at: (now|floor)
         })
       end)
    ]) | sort_by(.port)
  ' > "$NEW_LOCAL" 2>>"$LOG" || {
    log "jq 合并失败"; rm -f "$TABLE_FILE" "$NEW_LOCAL"; exit 1;
}
jq -e '.users | type == "array"' "$NEW_LOCAL" >/dev/null 2>&1 || {
    log "合并结果校验失败"; rm -f "$TABLE_FILE" "$NEW_LOCAL"; exit 1;
}

# ---- 统计差异用于回报 ----
APPLIED=$(jq -r --slurpfile loc "$LOCAL_JSON" '
    ($loc[0].users | map(.name)) as $old
    | [.users[] | select(.enabled == true) | .name | select(. as $n | $old | index($n) | not)]' "$NEW_LOCAL" | jq -s '.[0]')
DISABLED=$(jq -r '[.users[] | select(.enabled == false) | .name]' "$NEW_LOCAL" | jq -s .[0])
DELETED=$(jq -r --slurpfile loc "$LOCAL_JSON" '
    ($loc[0].users | map(.name)) as $old
    | [.users[]?.name] as $new
    | [$old[] | select(. as $n | ($new | index($n)) | not)]' "$NEW_LOCAL" | jq -s '.[0]' 2>/dev/null || printf '[]')
N_OK=$(printf '%s' "$APPLIED" | jq 'length')
N_DIS=$(printf '%s' "$DISABLED" | jq 'length')
N_DEL=$(printf '%s' "$DELETED" | jq 'length')

# ---- 备份 + 一次性应用 ----
cp "$LOCAL_JSON" "$LOCAL_JSON.bak.$(date +%s)" 2>/dev/null
log "应用配置表: 保留/新增 $(jq ".users | length" "$NEW_LOCAL") 用户, 生效 $N_OK, 停用 $N_DIS, 移除 $N_DEL"
if ! "$ENA_NOBRAND" timeout 300 mieru --user-restore "$NEW_LOCAL" >>"$LOG" 2>&1; then
    ERRORS=$(printf '%s' "$ERRORS" | jq '. + [{username:"restore",message:"user-restore 失败, 详见日志"}]')
    N_ERR=1; log "❌ user-restore 失败 (已保留备份)"
else
    log "✅ user-restore 应用成功"
fi

rm -f "$TABLE_FILE" "$NEW_LOCAL"

# ---- 全量对账：删除合并前存在、但期望表中没有的 ena 前缀孤儿用户 ----
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

# ---- 回报 ----
BODY=$(jq -n --argjson a "$APPLIED" --argjson d "$DISABLED" --argjson e "$ERRORS" --argjson x "$DELETED" \
    '{applied:$a, disabled:$d, errors:$e, deleted:$x, version:'"\"$VERSION\""' }')
RESP2=$(curl "${CURL_OPTS[@]}" -X POST -H "Authorization: Bearer $ENA_TOKEN" \
    -H "X-ENA-Node: $ENA_NODE" -H "Content-Type: application/json" \
    -d "$BODY" "$ENA_URL/report" 2>&1) || RESP2="report-failed"

log "=== 完成: 生效 $N_OK, 停用 $N_DIS, 删除 $N_DEL, 失败 $N_ERR | report: $(printf '%s' "$RESP2" | head -c 120) ==="
